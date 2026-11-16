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

PowerShell (the same with backticks): replace `\` by `` ` `` at the line ends, or write it on one line.

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
10 minutes is about 17 per second).

## 5. Evaluation-window runbook

The development setup is deliberately small (1 vCPU / 2 GiB replicas, at most 3, Burstable MySQL). For the official
test it is scaled up for an agreed window and back down right after. Every Azure change is reviewed (what-if) and
approved by the engineer before it runs.

| When | Action | How |
|---|---|---|
| A day before | Agree the date and time (inside weekday 14:00-22:00 IST, or start everything by hand) | With the evaluators |
| A day before | Replicas 2 vCPU / 4 GiB, maximum 25 | Pull request: `cpu`, `memory`, `maxReplicas` in `infra/app.bicepparam` and `alertMaxReplicas` in `infra/main.bicepparam` |
| A day before | MySQL General Purpose (4 vCores) for the window: 25 replicas x 15 connections = 375, the Burstable server allows 171 | Parameter change in `infra/main.bicep`, deployed by the engineer |
| Start of the window | Log Analytics daily cap raised (for example to 2 GB), so the dashboard keeps the whole test | `logAnalyticsDailyCapGb` in `infra/main.bicepparam` |
| 15 minutes before | Minimum replicas 4-6 (warm capacity: a replica needs 13-45 s to start) | Repository variable `TREBOL_DAY_MIN_REPLICAS`, then the schedule's manual `start` |
| During | Watch the workbook and the alerts | Azure portal, Monitor, Workbooks |
| Right after | Everything back: minimum 1, maximum 3, 1 vCPU / 2 GiB, MySQL Burstable, cap 0.1 GB, variable back to 1 | The same files and variable, reverted |

Cost of the window (list prices, South India): at full scale about 5-6 USD per hour of replica compute
(25 x 2 vCPU / 4 GiB), MySQL General Purpose about 0.4 USD per hour, plus requests. The project budget leaves room
for roughly one to two hours at full scale: plan a single window of about one hour.

## 6. Laptop checks (our part)

Small runs from the engineer's laptop against the Azure URL, inside working hours: a few hundred users at most, plus
the login burst to show CPU-based scaling (1 -> 3 replicas and back), the dashboard under load and a fired alert.
Results and the scaling timeline are recorded in the test report (`docs/06-load-test.md`).
