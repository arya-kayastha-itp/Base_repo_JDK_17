# Trébol API load test

Apache JMeter test plan for the Trébol API: `trebol-load.jmx`. It is the plan we hand to the evaluators for the
official 10,000-user test; they may also use their own tool. Targets: **P95 response time < 500 ms** and
**errors < 1%** at 10,000 concurrent users.

## 1. What a virtual user does

| Step | Request | When |
|---|---|---|
| Sign up | `POST /public/register` with a random 18-digit number (user name `lt<number>`, ID number) and a random 16-character password | Once per user |
| Log in | `POST /public/login`; the token comes back in the `Authorization` response header | Once per user |
| Browse | `GET /data/products` (random page of 20), `GET /data/product_categories`, `GET /data/products?barcode=LT-P-nnn` (random product), `GET /data/product_list_contents?listCode=lt-featured`, `GET /account/profile` (with the token) | Every iteration, until the end of the test |
| Think time | 1-3 s (uniform) before every browse request | Between requests |

- No checkout: it would call the external payment service (Transbank's integration environment).
- The browse requests read the load-test catalog (10 categories, 200 products, one product list), created by the
  Flyway migration `V3__loadtest_catalog.sql` in the cloud database.
- Passwords are random per run and kept only in JMeter's memory. Each run leaves one customer account per virtual
  user in the database (they can be removed afterwards).
- An optional second group, **Login burst** (`loginUsers` > 0), only logs in repeatedly. Logins hash the password
  (BCrypt) and are CPU-heavy, so a small number of these users shows CPU-based scaling. Leave it at 0 for the
  official test.

## 2. Requirements

- Apache JMeter 5.6.3 (`https://jmeter.apache.org`, verify the SHA-512 of the download) and Java 17 or newer.
- For 10,000 users: several load generators (about 2,000-4,000 threads each) or JMeter's distributed mode, with
  JMeter's heap raised (`HEAP="-Xms4g -Xmx4g"` before starting it). A single laptop cannot generate this load.
- The app's host name (given separately; it is not in this public repository).

## 3. Running it

Always in non-GUI mode. All settings are JMeter properties:

| Property | Default | Meaning |
|---|---|---|
| `host` | `localhost` | Host name of the app (no protocol, no path) |
| `protocol`, `port` | `https`, `443` | Use `http` and `8080` for a local run |
| `users` | 50 | Shoppers (concurrent virtual users) |
| `rampup` | 60 | Seconds until all users have started |
| `duration` | 600 | Seconds the test runs, including the ramp-up |
| `thinkMin`, `thinkRange` | 1000, 2000 | Think time = `thinkMin` + random(0..`thinkRange`) ms |
| `loginUsers`, `loginPause` | 0, 500 | Login-burst users and their pause between logins (ms) |

Official test, for example 10,000 users over 10 minutes, then 20 minutes at full load (bash):

```bash
jmeter -n -t loadtest/trebol-load.jmx -Jhost=APP_HOST -Jusers=10000 -Jrampup=600 -Jduration=1800 \
  -l results/run.jtl -e -o results/report
```

PowerShell: replace `\` by `` ` `` at the line ends (or write it on one line) and **quote every `-J` argument that
contains a dot**, for example `'-Jhost=my-app.example.net'`. PowerShell splits an unquoted argument that starts with
`-` at its first dot, and JMeter then stops with "Unknown arg".

Local check against the compose stack (`docker compose up -d`, see `docs/02-container.md`):

```bash
jmeter -n -t loadtest/trebol-load.jmx -Jprotocol=http -Jport=8080 -Jusers=5 -Jrampup=5 -Jduration=60 \
  -JthinkMin=200 -JthinkRange=300 -JloginUsers=2 -l results/local.jtl -e -o results/local-report
```

`results/` is git-ignored.

## 4. Reading the result

Open `results/report/index.html`:

- **Statistics** table, row **Total**: column **95th pct** must be below 500 ms; column **Error %** below 1%.
- Per request, the same columns show which request type is the slowest (sign-up and login are expected to be the
  slowest because of password hashing).
- **Response Times Over Time** and **Active Threads Over Time** show how latency follows the load.

At the same time, the Azure Monitor workbook **Trebol API operations** shows the server side: requests per minute,
P50/P95/P99, 5xx rate, replicas per revision, CPU, memory, restarts and MySQL CPU and connections. The P95 measured
by JMeter includes the network between the load generator and Azure (South India); the workbook shows the server time
only.

Rough throughput to expect: requests per second ≈ users / (think time + response time). With 10,000 users and
about 2 s mean think time that is about 5,000 requests per second, plus the sign-ups during the ramp-up (10,000 over
10 minutes is about 17 per second). The agreed evaluation target is a peak of 2,500 requests per second, raised step
by step; capacity per level and the expected break point: [docs/08-scalability-plan.md](../docs/08-scalability-plan.md).

## 5. Evaluation-window runbook

The development setup is deliberately small (1 vCPU / 2 GiB replicas, at most 3, Burstable MySQL). For the official
test one switch, `TREBOL_EVALUATION=true`, scales it up for the window, and removing it scales it back down:

| Part | Development | `TREBOL_EVALUATION=true` | Set by |
|---|---|---|---|
| App replicas | 1 vCPU / 2 GiB, at most 3 | 2 vCPU / 4 GiB, at most 20 (40 of the environment's 100 cores) | Repository variable, read by the release (`infra/app.bicepparam`) |
| MySQL | Burstable B1ms, 171 connections, fixed 360 IOPS | General Purpose D4ads_v5, 1,365 connections, Autoscale IOPS | Shell variable when the engineer deploys `infra/main.bicep` |
| Log Analytics daily cap | 0.1 GB | 1 GB | Same deployment |
| Alerts | replicas at 3, connections above 136 | replicas at 20, connections above 1,092 | Same deployment |

Order matters because of the connections (20 replicas x 15 = 300, more than the 171 of the Burstable server):
**up: database first, then the app; down: app first, then the database.** Changing the database size restarts it
(usually 60-120 s), so it happens before the test, never during it. Every Azure change is previewed (what-if) and
approved by the engineer before it runs.

| When | Action | How |
|---|---|---|
| About 90 minutes before | Environment on, warm minimum of 4 replicas | Repository variables `TREBOL_EVALUATION=true` and `TREBOL_DAY_MIN_REPLICAS=4`; the schedule's manual `start` (MySQL must be running for the next step) |
| About 75 minutes before | MySQL General Purpose with Autoscale IOPS, cap 1 GB, alert limits | Engineer: `$env:TREBOL_EVALUATION = 'true'`, then what-if and deployment of `infra/main.bicep` |
| About 60 minutes before | Replicas 2 vCPU / 4 GiB, at most 20 | A release reads the repository variable: merge the pending pull request, or run the `deploy` workflow by hand |
| 15 minutes before | Check: readiness 200, a second catalog read answers `X-Cache: HIT`, the workbook shows 4 replicas | Browser or curl; Azure portal, Monitor, Workbooks |
| During | Watch the workbook and the alerts; note when each limit is reached | [docs/08-scalability-plan.md](../docs/08-scalability-plan.md), section 6 |
| Right after | App back: repository variables `TREBOL_EVALUATION=false`, `TREBOL_DAY_MIN_REPLICAS=1`, then the `deploy` workflow by hand | GitHub Actions |
| Then | Database, cap and alerts back: deploy `infra/main.bicep` without the shell variable | Engineer (MySQL must be running) |
| End of the day | The schedule's `stop` (or the manual `stop`) | GitHub Actions |

Cost of a one-hour test (list prices, South India): replicas 0.22 USD per running hour each (about 2 USD for an
average of 10, 4.3 USD if all 20 run the whole hour), requests 0.40 USD per million (about 1.8 USD for 4.5 million,
3.6 USD at 2,500 per second for the full hour), MySQL D4ads_v5 0.48 USD per hour (about 1.2 USD for 2.5 hours
including the preparation), Autoscale IOPS 0.30 USD per million I/O operations. Realistic total about 6 USD, worst
case about 16 USD; the project budget has room for it.

## 6. Laptop checks (our part)

Small runs from the engineer's laptop against the Azure URL, inside working hours: a few hundred users at most, plus
the login burst to show CPU-based scaling (1 -> 3 replicas and back), the dashboard under load and a fired alert.
Results, the scaling timeline and the tuning recommendations are in the test report
([docs/06-load-test.md](../docs/06-load-test.md)). Two lessons from the first run (16 Nov 2026, 165 users,
80 requests per second): the 0.1 GB/day Log Analytics cap was reached after 17 minutes (raise it for any longer
test), and a laptop's network can stall all requests at once (the official test should run from a data centre).
