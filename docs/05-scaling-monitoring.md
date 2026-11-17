# Trébol backend: scaling, availability and monitoring

This document covers Requirement 5 (scaling and high availability) and Requirement 7 (monitoring): how the API
scales, how it stays available during failures and releases, what is measured, the dashboard and the alert strategy.
The evidence comes from a load test against Azure on 16 Nov 2026 (full report: [06-load-test.md](06-load-test.md)).

## 1. Requirement checklist

| Requirement | How it is met | Evidence |
|---|---|---|
| Stateless application | Stateless JWT authentication (no HTTP session), every replica uses the same signing key from Key Vault, all data in MySQL, no local files | [01-analysis.md](01-analysis.md), sections 9-10 |
| At least 2 instances behind a load balancer | The Container Apps environment's load balancer spreads requests over all replicas. Minimum replicas: 2 for the demo and the evaluation, 1 during development to save cost (repository variable `TREBOL_DAY_MIN_REPLICAS`) | Section 3 |
| Health and readiness probes | Startup, liveness and readiness probes on the Actuator health endpoints | Section 4 |
| Autoscaling | HTTP concurrency (100 requests in flight per replica) and CPU (70%); the higher demand wins | Sections 3 and 7 |
| CPU and memory requests and limits | 1 vCPU / 2 GiB per replica in development (2 vCPU / 4 GiB for the evaluation); in Container Apps one value acts as both request and limit | Section 5 |
| Rolling, zero-downtime deployments | Each release is a new revision: tested at 0% traffic, 10% canary, then 100%; graceful shutdown; automatic rollback | Section 6 |
| Scales out under load and back in afterwards | 1 -> 2 -> 3 replicas under load, back to 1 seven minutes after the load stopped | Section 7 |
| Centralised logs | Container logs, platform events and application telemetry in one Log Analytics workspace | Section 8 |
| Dashboard: CPU, memory, request count, error rate, health | Azure Monitor workbook "Trebol API operations" | Section 9 |
| Alerts, at least one test alert fired | Six alert rules to e-mail; two fired from real load during the test | Sections 10 and 7 |

## 2. Why the app can scale horizontally

A replica keeps nothing that another replica would need: the login returns a signed JWT that every replica can verify
with the shared key, there is no session state, and products, users and orders live in the shared MySQL server. Any
request can therefore go to any replica, and replicas can be added or removed at any time. The one shared resource
is the database: replicas x connection pool (15) must stay below MySQL's `max_connections` (171 on the development
tier), which is why the evaluation uses a larger database tier (section 3 of [06-load-test.md](06-load-test.md)).

## 3. Scaling

| Setting | Development | Demo and evaluation | Where |
|---|---|---|---|
| Replica size | 1 vCPU / 2 GiB | 2 vCPU / 4 GiB | `infra/app.bicepparam` (`cpu`, `memory`) |
| Minimum replicas (weekdays 14:00-22:00 IST) | 1 | 2 for the demo, 4-6 for the evaluation | Repository variable `TREBOL_DAY_MIN_REPLICAS`, applied by the schedule's start |
| Minimum replicas (nights, weekends) | 0 (the HTTP rule wakes the app on a request) | - | `schedule.yml` stop |
| Maximum replicas | 3 | 25 | `infra/app.bicepparam` (`maxReplicas`) and `infra/main.bicepparam` (`alertMaxReplicas`) |
| Scale rule: HTTP | 100 concurrent requests per replica | same | `infra/app.bicepparam` (`concurrentRequestsPerReplica`) |
| Scale rule: CPU | 70% average utilisation | same | `infra/app.bicepparam` (`cpuUtilizationPercent`) |

**How the decision is made.** Container Apps uses KEDA: every 30 seconds it computes, for each rule, how many
replicas would bring the metric to its target (for CPU: current replicas x current utilisation / 70%), and runs the
highest of the results, within the minimum and maximum. Scale-in waits until the demand has been low for 5 minutes
(cooldown), so short dips do not remove capacity.

**Why two rules.** The HTTP rule reacts to the number of requests in flight and is the only one that can wake the
app from zero replicas. The CPU rule reacts to expensive requests: a login hashes the password with BCrypt
(strength 10, about 50-100 ms of CPU), so a few concurrent logins can fill a vCPU long before 100 requests are in
flight. A revision with a minimum of 0 accepts the CPU rule because the HTTP rule handles scaling from zero (tested
on 16 Nov with the schedule's stop and start).

**Warm capacity.** A new replica needs 13-45 seconds to start (13 s measured in Azure) plus the readiness check.
During the test, the single replica was overloaded for about 3 minutes before replicas 2 and 3 were ready (P95 up to
2.5 s in that phase, section 7). Before an expected peak (the evaluation), the minimum is raised so the capacity is
already there.

## 4. Health probes

| Probe | Endpoint | Timing | Purpose |
|---|---|---|---|
| Startup | `/actuator/health/liveness` | After 30 s, every 10 s, 10 failures allowed (up to 130 s) | Gives the app time to start; the other probes begin after it succeeds |
| Liveness | `/actuator/health/liveness` | Every 10 s, 3 failures | Restarts a stuck container. It does **not** check the database: a database outage must not restart every replica |
| Readiness | `/actuator/health/readiness` (includes the database) | Every 5 s, 3 failures | A replica that cannot reach MySQL, or is still starting, gets no traffic |

Only the `health` endpoints are exposed from Actuator; `env`, `heapdump` and the others return 404.

## 5. CPU and memory: requests and limits

Container Apps (Consumption profile) takes **one** CPU and memory value per container, and that value is both the
reservation (request) and the cap (limit); memory must be twice the vCPU count (for example 1 vCPU / 2 GiB), with at
most 4 vCPU / 8 GiB per container. The JVM follows the container: `-XX:MaxRAMPercentage=75` gives a 1.5 GiB heap at
2 GiB, and `-XX:+ExitOnOutOfMemoryError` lets the platform restart a container that runs out of memory. Separate
requests and limits (and a Horizontal Pod Autoscaler) are part of the planned Kubernetes (AKS) phase, which reuses
the same image, settings, probes and Key Vault.

## 6. Zero-downtime releases

Every release (described in [04-cicd.md](04-cicd.md)) is a new revision of the app:

1. It starts beside the serving revision with **0% of the traffic** and must pass its readiness probe.
2. The smoke test (48 checks) runs against **its own URL**.
3. **Canary**: 10% of the real traffic for 2 minutes, with health checks every 15 seconds.
4. **Promotion**: 100% to the new revision; the old revision is deactivated.
5. Any failure moves all traffic back to the old revision and deactivates the new one.

Requests already running on the old revision are not cut off: on deactivation the container gets SIGTERM,
Spring Boot's graceful shutdown lets in-flight requests finish (up to 30 s, `server.shutdown=graceful`), and Container
Apps waits 40 s (termination grace period) before stopping the container.

**Measured** on 16 Nov during the release of pull request #13, under a constant load of 20 users: **11,481 requests,
0 errors**, P95 between 91 and 131 ms in every phase (before, at 0%, during the canary, during the promotion,
after). Details: [06-load-test.md](06-load-test.md), section 8.

## 7. Evidence: scale-out, scale-in and alerts (16 Nov 2026)

Load test from a laptop in India against the app in South India: 150 users browsing plus 15 users logging in
repeatedly, 25 minutes, 14:34:38-14:59:42 UTC (details in [06-load-test.md](06-load-test.md)).

| Time (UTC) | Replicas | Average CPU per replica | Server P95 (Application Insights) | What happened |
|---|---|---|---|---|
| 14:34-14:35 | 1 | 0-1% | - | Ramp-up starts |
| 14:36 | 1 | 68% | 2,494 ms | One replica overloaded by the logins |
| 14:37 | **2** | 103% | 815 ms | First scale-out |
| 14:38 | 2 | 76% | 800 ms | Alert **P95 > 500 ms** fires (14:38:28) |
| 14:40 | **3** | 85% | 611 ms | Second scale-out; the maximum (3) is reached |
| 14:41-14:59 | 3 | about 68% | about 200 ms | Steady state just below the 70% target |
| 14:54:30 | 3 | 68% | - | P95 alert resolves itself |
| 14:55:23 | 3 | 68% | - | Alert **replicas at the limit for 10 minutes** fires |
| 15:00-15:06 | 3 | 0-15% | - | Load stopped; cooldown |
| 15:07 | **1** | - | - | Scale-in back to the minimum |

The server answered 0 requests with a server error (5xx); MySQL stayed below 35% CPU and 49 of 171 connections.

## 8. Logs and telemetry

| Source | Where | Content |
|---|---|---|
| Container console logs | Log Analytics, table `ContainerAppConsoleLogs_CL` | The application's log (Spring Boot, Flyway, Hibernate) |
| Platform events | Log Analytics, table `ContainerAppSystemLogs_CL` | Revision and replica events, probe failures, restarts, scaling |
| Application Insights | Log Analytics, tables `AppRequests`, `AppDependencies`, `AppExceptions`, `AppMetrics` | Every request with duration and status, every database call, exceptions |
| Platform metrics | Azure Monitor metrics (free, 93 days) | Replicas, CPU, memory, requests by status class, restarts, JVM memory and garbage collection; MySQL CPU, memory and connections |

- **Workspace**: `log-trebol-poc`, 30 days of retention, **daily cap 0.1 GB** (budget protection; raised for the
  evaluation).
- **Application Insights Java agent** 3.7.10, shipped in the image and loaded only in Azure (through
  `JDK_JAVA_OPTIONS`); no code change. It samples requests (about 5 per second are kept; `ItemCount` restores the real
  counts), so rates and percentiles stay correct at a fraction of the data volume.
- **Spring Boot's Micrometer metrics are not forwarded** (`APPLICATIONINSIGHTS_INSTRUMENTATION_MICROMETER_ENABLED=false`):
  during the first load test they were the largest data type, filled the daily cap after 17 minutes and duplicated
  the free platform metrics.

## 9. Dashboard

Azure portal, **Monitor, Workbooks, "Trebol API operations"** (`infra/modules/workbook.bicep`), with a time-range
selector:

| Tile | Source |
|---|---|
| Requests per minute | Application Insights |
| Response time P50 / P95 / P99 | Application Insights |
| Server error rate (5xx, %) | Application Insights |
| Responses by status code | Application Insights |
| Operations: volume, P95, server errors | Application Insights |
| Database calls per minute and P95 | Application Insights |
| Platform events (probes, restarts, scaling) | Container Apps system logs |
| Replicas by revision, CPU %, memory %, restarts, requests by status class | Container Apps metrics |
| MySQL CPU and active connections | MySQL metrics |

## 10. Alert strategy

All alerts e-mail the project address through one action group (`ag-trebol-poc`); every rule resolves itself when
the condition clears.

| Alert | Signal | Fires when | Severity | Why this threshold |
|---|---|---|---|---|
| Server error rate | Application Insights, every 5 min | More than 1% of requests in 5 minutes are 5xx, with at least 20 requests | 1 | The evaluation's error target is < 1%. Only 5xx count: the API returns 4xx on purpose (wrong password, missing permission, invalid input) |
| Response time | Application Insights, every 5 min | P95 above 500 ms over 5 minutes, with at least 20 requests | 2 | The evaluation's latency target |
| Replicas at the limit | Platform metric `Replicas` | The minimum over 10 minutes reaches the maximum replica count | 2 | The app cannot scale any further; the minimum ignores short peaks |
| Restarts | Platform metric `RestartCount` | A replica restarted more than 3 times | 2 | Crash loop or failing liveness probe |
| CPU | Platform metric `CpuPercentage` | Average above 85% for 10 minutes | 3 | Scaling does not keep up (or the maximum is reached) |
| Database connections | MySQL metric `active_connections` | Above 80% of `max_connections` (136 of 171) | 2 | Replicas x pool size approaching the server's limit |
| Pipeline failure | GitHub Actions | A release or pull-request run fails | - | GitHub e-mails the author of the change |

**Design choices.** Metric alerts (0.10 USD per month each) read numbers Azure already collects and react within
minutes; the two log alerts (1.50 USD per month each at a 5-minute interval) query the telemetry because a share of
errors or a percentile cannot be expressed as a platform metric; they see data 2-5 minutes late. The minimum volume
of 20 requests avoids alarms on almost no traffic at night.

**Test alert.** Both "P95 > 500 ms" and "replicas at the limit" fired from real load on 16 Nov (section 7); e-mails
arrived. The action group can also be tested on demand from the portal (Monitor, Alerts, Action groups, Test).

## 11. Lessons learned

| Observation | Consequence |
|---|---|
| Application Insights counts every 4xx response as "failed" | The error alert and the dashboard use 5xx only |
| The 0.1 GB/day cap was reached 17 minutes into a 25-minute test; afterwards no logs or telemetry until the daily reset, and the log alerts were blind (metric alerts kept working) | Micrometer forwarding switched off; the cap is raised for the evaluation window |
| An infrastructure deployment (`main.bicep`) failed while MySQL was stopped, because every deployment re-sends the database server | Infrastructure is deployed only while MySQL runs (weekdays during working hours) |
| GitHub's scheduler started the working-hours runs 5.5 to 10 hours late, and one start never ran | Backup triggers and a clock check in `schedule.yml` (a 10-hour-late start was correctly skipped); moving the schedule into Azure is recommended ([04-cicd.md](04-cicd.md), section 5) |

## 12. Limitations and next steps

| Item | Today | Next |
|---|---|---|
| High availability in development | Minimum 1 replica (cost); 2 only when the variable is raised | Keep 2 or more for the demo and the evaluation |
| Zone redundancy | Not used (development envelope) | Zone-redundant environment and database for production |
| Single region | South India for the app and the database | A second region with Front Door, out of scope for the POC |
| Database scaling | Burstable B1ms (171 connections) | General Purpose for the evaluation; read replicas or a cache for higher read load |
| Scale-out lag | 1-4 minutes from overload to added capacity | Warm minimum before peaks; consider a lower CPU target (60%) |
