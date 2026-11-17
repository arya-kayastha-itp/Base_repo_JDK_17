# Trébol backend: load test report

This report covers Requirement 6 (load testing). The official test with 10,000 concurrent users is run by the
evaluators with the plan in [`loadtest/`](../loadtest/README.md); this report records our own checks from a laptop
on 16 Nov 2026, what they show about scaling and capacity, and the tuning recommendations for the official test.
Targets: **P95 response time < 500 ms** and **errors < 1%**.

## 1. Summary

| Measure | Result (laptop test, 165 virtual users, 25 minutes) | Target |
|---|---|---|
| Requests | 119,340 (79.5 per second) | - |
| Errors | 2 (0.00%), both connection resets on the client side | < 1%: met |
| P95 response time, measured by JMeter (includes the network to Azure) | 401 ms over the whole run; 254 ms once 3 replicas were running | < 500 ms: met |
| P95 on the server (Application Insights) | 333 ms over the run; about 200 ms on 3 replicas | - |
| Server errors (5xx) | 0 | - |
| Scaling | 1 -> 2 -> 3 replicas under load (CPU rule), back to 1 seven minutes after the end | Scales out and in: met |
| Alerts | "P95 > 500 ms" fired during the ramp-up and resolved itself; "replicas at the limit" fired after 10 minutes at 3 replicas | At least one fired: met |

**Main findings.** The first resource to saturate is the replicas' CPU, driven by logins (BCrypt password hashing);
the CPU rule adds replicas as designed, but a single replica is overloaded for about 3 minutes until the new ones
are ready. The database had ample headroom. The monitoring pipeline reached its daily data cap during the test;
that has been fixed. For 10,000 users the deciding factors are warm capacity, larger replicas and a cache for the
catalog reads (section 9).

## 2. Test setup

| Item | Value |
|---|---|
| Tool | Apache JMeter 5.6.3, non-GUI mode, plan `loadtest/trebol-load.jmx` |
| Load generator | One laptop in India, home or office network |
| Target | `https://` URL of the Container App in South India |
| Shoppers | 150 users: sign up once, log in once, then browse in a loop (product page, categories, product detail, featured list, own profile) with 1-3 s think time |
| Login burst | 15 users logging in repeatedly with a 0.5 s pause (to drive CPU-based scaling) |
| Load profile | 120 s ramp-up, 1,500 s in total, 14:34:38-14:59:42 UTC |
| App | 1 vCPU / 2 GiB per replica, 1-3 replicas, HTTP rule 100 concurrent requests, CPU rule 70% |
| Database | MySQL 8.4, Burstable B1ms (1 vCore, 2 GiB, 171 connections) |
| Data | Load-test catalog: 10 categories, 200 products, one list (Flyway V3) |
| Not tested | Checkout (it would call the payment provider's external test service) |

## 3. Results by request type (JMeter)

| Request | Samples | Errors | P50 ms | P95 ms | P99 ms |
|---|---|---|---|---|---|
| POST /public/login (burst) | 25,101 | 0 | 171 | 965 | 2,035 |
| GET /data/products (page of 20) | 18,847 | 0 | 76 | 312 | 483 |
| GET /data/product_categories | 18,813 | 1 | 56 | 182 | 301 |
| GET /data/products (detail) | 18,783 | 0 | 57 | 192 | 316 |
| GET /data/product_list_contents | 18,755 | 1 | 97 | 458 | 676 |
| GET /account/profile | 18,726 | 0 | 59 | 217 | 372 |
| POST /public/register (shoppers) | 150 | 0 | 1,820 | 3,243 | 3,923 |
| POST /public/register (burst users) | 15 | 0 | 1,755 | 3,284 | 3,284 |
| POST /public/login (once per shopper) | 150 | 0 | 1,415 | 3,395 | 3,615 |
| **Total** | **119,340** | **2** | **86** | **401** | **1,278** |

Sign-up and the first login ran during the ramp-up on one overloaded replica, hence their high percentiles; logins
are expensive by design (BCrypt strength 10). JMeter's numbers include the network between the laptop and Azure and
the TLS handshakes.

**Server side (Application Insights, until the data cap at 14:52 UTC):** 86,306 requests, 0 server errors, P50 32 ms,
P95 333 ms, P99 1,119 ms, slowest 4.0 s (during the overload). Database calls: 622,457, P95 7.6 ms, 0 failed.

**Database (Azure metrics):** CPU at most 34%, at most 49 of 171 connections (3 replicas x a pool of 15, plus
administration), memory 25%.

## 4. Scaling timeline

| Time (UTC) | Replicas | CPU per replica | Server P95 | Requests per minute (server) |
|---|---|---|---|---|
| 14:35 | 1 | 0% | 1,422 ms | 1,966 (ramp-up) |
| 14:36 | 1 | 68% | 2,494 ms | 3,662 |
| 14:37 | 2 | 103% | 815 ms | 4,706 |
| 14:38 | 2 | 76% | 800 ms | 5,079 |
| 14:39 | 2 | 93% | 703 ms | 5,144 |
| 14:40 | 3 | 85% | 611 ms | 5,115 |
| 14:41-14:42 | 3 | about 70% | 216-247 ms | about 5,500 |
| 14:43 | 3 | 71% | - | 54 (client-side stall, section 6) |
| 14:45-14:52 | 3 | about 68% | 183-220 ms | about 5,500 |
| 15:07 | 1 | - | - | - (scale-in) |

## 5. Alerts during the test

| Alert | Fired (UTC) | Resolved (UTC) | Correct? |
|---|---|---|---|
| P95 response time > 500 ms | 14:38:28 | 14:54:30 | Yes: the single replica was overloaded during the ramp-up |
| Replicas at the limit (10 minutes) | 14:55:23 | after the scale-in | Yes: 3 replicas from 14:40 |
| Server error rate > 1% | - | - | Yes: no 5xx responses |
| CPU > 85% for 10 minutes | - | - | Yes: about 68% at 3 replicas |

## 6. Incidents during the test

1. **Client-side stall at 14:42:57 UTC.** Every request in flight waited about 111 s; two ended in connection
   resets reported by Windows on the laptop ("an established connection was aborted by the software in your host
   machine"). In that minute the server received 54 requests instead of about 5,500, and its CPU fell to 0%: the
   requests did not reach Azure. The cause was on the laptop or its network, not in the app. Lesson: the official
   test should run from load generators in a data centre.
2. **Log Analytics daily cap reached at 14:51:59 UTC.** The workspace stopped collecting logs and Application
   Insights data until the daily reset (09:00 UTC); the two log-based alerts were blind from then on, while platform
   metrics and metric alerts kept working. The largest data type was Spring Boot's Micrometer metrics forwarded by
   the monitoring agent, which duplicate the platform metrics. Fix: forwarding switched off (pull request #13); the
   cap is raised for the evaluation window.

## 7. First saturated resource and capacity estimate

**Replica CPU, because of logins.** With 15 users logging in every 0.5 s (about 25 logins per second), one 1-vCPU
replica went above 100% CPU; three replicas at about 68% carried the load. Per replica that is about 31 requests per
second including about 8 logins per second: the logins (about 70 ms of CPU each) account for roughly 58% of a vCPU,
the other 23 requests per second for about 10%, which suggests **about 4-5 ms of CPU per browse request**.

**Estimate for 10,000 users** (an extrapolation, to be confirmed by the official test): with 1-3 s think time,
10,000 users send about 5,000 requests per second. At about 4.5 ms of CPU each that is about 23 vCPU at full
utilisation, or about 32 vCPU at the 70% target: **16 replicas of 2 vCPU**, within the planned maximum of 25. The
sign-ups during a 10-minute ramp-up (about 17 per second) add about 1.2 vCPU.

**Database.** Each request made about 7 database calls on average (622,457 calls for 86,306 requests): the product
pages load the category of each product separately (an "N+1" pattern found in Phase 1). At 5,000 requests per second
that would be about 35,000 queries per second, far beyond the development database and a heavy load even for
General Purpose. This is the most likely bottleneck of the official test.

## 8. Zero-downtime release under load

Measured on 16 Nov during the release of pull request #13 (a configuration change of the app, so a full release):
20 users browsing for 20 minutes while the pipeline created the new revision, smoke-tested it, sent it 10% of the
traffic for 2 minutes and promoted it.

Load: 20 users (sign-up, login, browsing with 1-3 s think time), 15:20:25-15:40:25 UTC. Release steps from the
pipeline run, matched with JMeter's results:

| Phase (UTC) | Requests | Errors | P50 ms | P95 ms | Slowest ms |
|---|---|---|---|---|---|
| Before the release, 15:20:25-15:27:55 | 4,189 | 0 | 56 | 115 | 735 (a sign-up) |
| New revision created and smoke-tested at 0% traffic, 15:27:55-15:30:14 | 1,336 | 0 | 55 | 91 | 220 |
| Canary: 10% of the traffic on the new revision, 15:30:14-15:32:49 | 1,500 | 0 | 57 | 98 | 230 |
| Promotion to 100%, old revision deactivated and draining (40 s), 15:32:49-15:33:51 | 596 | 0 | 70 | 131 | 254 |
| After the release, 15:33:51-15:40:25 | 3,860 | 0 | 57 | 97 | 261 |
| **Whole window** | **11,481** | **0** | **57** | **104** | **735** |

**No request failed and none was noticeably slower while the traffic moved between revisions.** The slight rise of
the median during the promotion (70 ms against 56 ms) is the new revision's first requests (warm-up) plus the old one
finishing its last requests; the graceful shutdown let every in-flight request complete.

## 9. Tuning recommendations for the official test

| # | Recommendation | Why (evidence) | Effort |
|---|---|---|---|
| 1 | **Cache the catalog reads** (Caffeine, 30-60 s) and load product categories with the products (fetch join or batch fetching); cap the page size at 50 | About 7 queries per request; at 5,000 requests per second the database becomes the bottleneck (section 7) | Code change, about a day |
| 2 | **Warm capacity**: minimum 4-6 replicas 15 minutes before the test | One replica was overloaded for about 3 minutes while new ones started (P95 up to 2.5 s) | Repository variable + schedule start |
| 3 | **Replicas of 2 vCPU / 4 GiB, maximum 25** | About 32 vCPU needed at the 70% target (section 7); "replicas at the limit" fired at the development maximum of 3 | Pull request, runbook |
| 4 | **MySQL General Purpose (4 vCores) for the window** | 25 replicas x 15 connections = 375 > 171; query volume (recommendation 1) | Parameter change, runbook |
| 5 | **Raise the Log Analytics cap** for the window (for example 2 GB) | The 0.1 GB cap was reached in 17 minutes at 80 requests per second | Parameter change, runbook |
| 6 | Keep login cost in mind: clients log in once and reuse the token (the JMeter plan does) | Logins cost about 70 ms of CPU each; repeated logins drove the scale-out | Test design |
| 7 | One shared JSON mapper in the login filter instead of one per login | A new mapper per login on the busiest CPU path (Phase 1 finding 16) | Small code change |
| 8 | Consider a lower CPU target (60%) | Earlier scale-out at the cost of more replicas | Parameter change |
| 9 | Run the official test from load generators in a data centre close to South India | The laptop's network caused the only errors of our test | Evaluators |

## 10. Notes for the evaluators

- How to run the plan, its parameters and how to read the report: [`loadtest/README.md`](../loadtest/README.md).
- Before the window we follow the runbook in that README (larger replicas, warm minimum, database tier, log cap);
  please agree the date and time with us.
- The live view during the test: Azure Monitor workbook "Trebol API operations"
  ([05-scaling-monitoring.md](05-scaling-monitoring.md), section 9).
- Each virtual user creates one customer account (random name and password); no shared credentials are needed.

## 11. Tuning for the evaluation (17-18 Nov)

The evaluation target was set to a peak of 2,500 requests per second, raised step by step until the system breaks.
Recommendations 1-5 and 7 of section 9 were carried out:

| Change | Recommendation | Effect (measured on a local MySQL 8.4 with the load test's requests, 20 calls each) |
|---|---|---|
| Hibernate batch fetching (`default_batch_fetch_size=50`) | 1 | Product page 13 -> 4 queries, list contents 24 -> 6; average per browse request 8.9 -> 3.5 |
| Page size capped at 50 (was 1,000) | 1 | One request can no longer load a whole table |
| Catalog cache: public reads of products, categories and lists kept 30 s per replica; staff always read live data | 1 | Cached reads need no database query (categories and list contents 0.05 queries per call); in steady state about 0.5 queries per browse request (estimate) |
| One shared JSON reader in the login filter | 7 | Less work per login |
| Evaluation switch `TREBOL_EVALUATION`: replicas 2 vCPU / 4 GiB up to 20, warm minimum 4, MySQL General Purpose D4ads_v5 with Autoscale IOPS, log cap 1 GB | 2-5 | Capacity per level and the expected break point: [08-scalability-plan.md](08-scalability-plan.md) |

Build: 381 tests passed; smoke test 48/48 on MySQL. The evaluators' results and the break point found will be added
here after the test.
