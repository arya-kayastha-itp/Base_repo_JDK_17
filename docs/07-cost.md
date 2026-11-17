# Trébol backend: cost analysis

This document covers the cost side of the POC (bonus): the budget and its controls, what the environment really
cost, where the money goes, a projection, the cost of the evaluation window and the teardown plan. Amounts are in
Indian rupees (INR), the billing currency of the subscription; USD values use about 85 INR per USD and are
approximate. Measured values come from Azure Cost Management (16 Nov 2026); list prices from the Azure retail price
list for the regions used.

## 1. Budget and controls

| Control | Setting | Effect |
|---|---|---|
| Project budget | 4,000 INR (below 50 USD) for 1 Nov 2026 - 31 Oct 2027 as one annual period, on `rg-trebol-poc` | E-mail at 50%, 80% and 100% of actual cost and at 100% of forecast cost. A budget only warns; it never stops anything |
| Working-hours schedule | Weekdays 14:00-22:00 IST; app at 0 replicas and MySQL stopped outside (`schedule.yml`) | Compute and database are billed about 40 of 168 hours a week |
| Development limits | 1 vCPU / 2 GiB replicas, at most 3; MySQL Burstable B1ms; registry Basic | No accidental scale-up |
| Log Analytics daily cap | 0.1 GB per day | Bounds the monitoring cost (and stops data collection when reached) |
| Cost tag | `project=trebol-poc` on every resource, also on the Azure-managed load balancer and public IP | Cost reports per project |
| Decisions | No NAT gateway, no extra public IPs, no premium or redundant tiers, no Azure Load Testing (the evaluators run the official test) | - |

**Gap:** the budget covers `rg-trebol-poc` only. The load balancer and public IP of the Container Apps environment
live in the Azure-managed group `rg-trebol-poc-aca-infra` and are not counted by it. A subscription-level budget
filtered on the tag `project=trebol-poc` would cover both (postponed); until then the managed group's cost is
checked in Cost Management.

## 2. Measured cost, 1-16 Nov 2026

| Resource | INR | Notes |
|---|---|---|
| Container registry (Basic) | 41.81 | Billed per day, from 12 Nov |
| MySQL compute (B1ms) | 24.46 | Running hours only |
| MySQL storage (20 GB) | 16.35 | Billed also when the server is stopped |
| Private DNS zone | 4.18 | |
| Log Analytics | 1.47 | Within the cap |
| Key Vault | 0.10 | |
| **`rg-trebol-poc`** | **88.37** | What the budget sees |
| Load balancer (Standard) | 111.54 | Azure-managed, from 13 Nov |
| Public IP (Standard) | 22.30 | Azure-managed, from 13 Nov |
| **`rg-trebol-poc-aca-infra`** | **133.84** | Not seen by the budget |
| **Total** | **222.21 (about 2.6 USD)** | |

Container Apps compute cost nothing in this period: the usage stayed within the monthly free allowance of the
Consumption plan (about 180,000 vCPU-seconds and 360,000 GiB-seconds per subscription).

## 3. Where the money goes

| Item | Per day (INR) | Per month (INR) | Share of the fixed cost |
|---|---|---|---|
| Load balancer + public IP of the environment | about 60 | about 1,800 | 65% |
| Container registry (Basic) | about 14 | about 420 | 15% |
| Alerts (2 log alerts + 4 metric alerts, from 16 Nov) | about 10 | about 290 | 11% |
| MySQL storage | about 7 | about 220 | 8% |
| DNS zone, Key Vault, logs | about 1-2 | about 50 | 1% |
| **Fixed cost, everything stopped** | **about 92 (about 1.1 USD)** | **about 2,800** | |
| MySQL compute, per working day (8 h) | about 17 | about 370 (22 days) | Variable |
| Container Apps compute | 0 within the free allowance; about 0.03 USD per idle and 0.11 USD per busy replica-hour beyond it | | Variable |

**The largest item is not the app but its network entry point.** A Container Apps environment connected to a
private network gets its own Standard load balancer and public IP, billed by the hour whether or not any replica
runs. Only deleting the environment stops that cost (and deleting it changes the app's URL), so it is part of the
running cost until the teardown.

## 4. Projection

| Period | Estimate (INR) | Notes |
|---|---|---|
| 1-16 Nov (measured) | 222 | |
| 17-30 Nov | about 1,450 | 14 days of fixed cost + 10 working days of MySQL compute |
| **Total by 30 Nov, before the evaluation** | **about 1,700 (about 20 USD, 42% of the budget)** | |
| Each further month, if nothing is removed | about 3,200 | Fixed cost + working-day database |

## 5. Cost of the evaluation window

The runbook in [`loadtest/README.md`](../loadtest/README.md) scales up for an agreed window and back down right after.

| Item | Cost per hour of the window |
|---|---|
| Container Apps at full scale (up to 25 replicas of 2 vCPU / 4 GiB; South India list price 0.000024 USD per vCPU-second, 0.000003 USD per GiB-second) | up to about 5.4 USD |
| MySQL General Purpose, 4 vCores | about 0.4 USD |
| Log Analytics with a raised cap (for example 2 GB for the day) | up to about 5 USD for the day |
| Requests (beyond 2 million per month free) | about 0.40 USD per million |

With about 2,300 INR (about 27 USD) left by 30 Nov, the budget allows **one window of about one hour at full scale**,
plus warm-up and scale-down. The warm minimum (4-6 replicas for 15 minutes before) and the raised log cap are
included in that estimate.

## 6. Teardown after the evaluation

Deletions are done by the engineer (the assistant and the pipeline never delete). Suggested order:

1. Container App `trebol-api` and the environment `cae-trebol-poc` (removes the load balancer and public IP, the
   largest cost).
2. Alert rules, action group and workbook.
3. MySQL server (export the data first if it is needed).
4. Container registry, Application Insights, Log Analytics workspace.
5. Key Vault (soft delete: recoverable for 7 days; purge protection keeps the name reserved meanwhile).
6. Network, DNS zone and the unused first network `vnet-trebol-poc`.
7. Role assignments (subscription administrator) and the budget last.

Everything except the role assignments can be recreated from the Bicep templates ([03-infrastructure.md](03-infrastructure.md),
section 8).
