# Stage A — Scaffold, DB connection, bulk load, and data profile

## What this stage is
Stand up the project skeleton, connect to local PostgreSQL, land the raw PaySim
CSV in a staging table via `COPY`, and profile it. **No modeling happens here** —
the point is to find out what the data can honestly support before Stage B
designs the star schema.

## What each artifact does
| File | What it is |
|---|---|
| `.gitignore` | Keeps `data/raw/` (470 MB) and `.env` (credentials) out of git. |
| `.env` / `.env.example` | DB connection params, read at runtime. Credentials never appear in scripts or SQL. |
| `requirements.txt` | Python deps — orchestration only; the analysis lives in SQL. |
| `sql/01_create_staging.sql` | DDL for `stg_transactions`, a faithful 1:1 landing zone for the CSV. |
| `scripts/load_staging.ps1` | Creates the DB, applies the DDL, bulk-loads the CSV with `\copy` (one streaming pass, no row-by-row INSERTs). |
| `sql/02_inspect_staging.sql` | The profiling queries whose results are recorded below. |

## Why staging has no indexes or keys
It is written once by `COPY` and then read sequentially by the Stage B
transformation. Indexes would slow the bulk load and buy nothing. Primary keys
and indexes belong on the star schema, where queries actually filter and join.

## Why NUMERIC, not FLOAT, for money
Balances and amounts are exact decimal quantities. `NUMERIC(18,2)` avoids the
binary rounding error that would make balance-delta checks (`oldbalance -
newbalance = amount`) fail spuriously in Stage C's risk queries.

---

## Profile results (run 2026-07-09, 6,362,620 rows)

### Row count
`6,362,620` — matches the published PaySim row count. Load reconciles.

### Transaction type distribution
| type | txn_count | % of rows | total value |
|---|---:|---:|---:|
| CASH_OUT | 2,237,500 | 35.17% | 394,412,995,224.49 |
| PAYMENT | 2,151,495 | 33.81% | 28,093,371,138.37 |
| CASH_IN | 1,399,284 | 21.99% | 236,367,391,912.46 |
| TRANSFER | 532,909 | 8.38% | 485,291,987,263.17 |
| DEBIT | 41,432 | 0.65% | 227,199,221.28 |

Note the split between count and value: TRANSFER is only 8% of rows but the
**largest** share of value. Any profitability fee model in Stage C must be
explicit about whether fees are per-transaction or ad-valorem — the two produce
opposite rankings for TRANSFER.

### Fraud rate — overall and by type
| type | txn_count | fraud_count | fraud % | flagged_count |
|---|---:|---:|---:|---:|
| **ALL** | 6,362,620 | 8,213 | **0.1291%** | 16 |
| CASH_OUT | 2,237,500 | 4,116 | 0.1840% | 0 |
| TRANSFER | 532,909 | 4,097 | 0.7688% | 16 |
| DEBIT | 41,432 | 0 | 0.0000% | 0 |
| PAYMENT | 2,151,495 | 0 | 0.0000% | 0 |
| CASH_IN | 1,399,284 | 0 | 0.0000% | 0 |

**Confirmed:** fraud exists *only* in TRANSFER and CASH_OUT — zero elsewhere,
not merely rare. TRANSFER carries ~4.2x the fraud rate of CASH_OUT.

`isFlaggedFraud` is effectively useless as a detector: 16 flags against 8,213
actual frauds. Recall ≈ 0.19%. It is worth keeping purely to *quantify* how bad
the incumbent rule is (a good Stage C risk visual), not as a baseline to beat.

### Step range
`min=1`, `max=743`, 743 distinct steps ⇒ **~30.96 simulated days**, no gaps.
Synthetic mapping for `dim_date`: `day = (step - 1) / 24`, `hour = (step - 1) % 24`.
(Using `step - 1` so step 1 lands on day 0, hour 0.) There is no real calendar.

### Originator (`nameOrig`) recurrence — the MAU/cohort question
| metric | value |
|---|---:|
| distinct originators | 6,353,307 |
| appearing exactly once | 6,344,009 (**99.85%**) |
| max transactions per originator | **3** |
| avg transactions per originator | 1.001 |
| active on more than one day | 8,731 (**0.14%**) |

Full distribution: 6,344,009 accounts with 1 txn, 9,283 with 2, 15 with 3.

### Destination (`nameDest`) recurrence
| metric | value |
|---|---:|
| distinct destinations | 2,722,362 |
| appearing exactly once | 2,262,704 (83.12%) |
| max transactions per destination | 113 |
| avg transactions per destination | 2.337 |

Destination prefix: `C` (customer) 4,211,125 rows; `M` (merchant) 2,151,495 rows.
The 2,151,495 M-rows exactly equal the PAYMENT count — **merchants only ever
appear as the destination of a PAYMENT**. That is a clean, defensible rule for
an account-role attribute in `dim_accounts`.

---

## Verdict: MAU / cohort retention is NOT honestly supportable

99.85% of originating accounts transact exactly once in the entire ~31-day
window, and only 0.14% are active on more than one day. The ceiling is three
transactions. There is no repeat-usage signal to retain, and PaySim has no
signup event, so a cohort has nothing to be anchored on.

Building a retention curve here would produce a chart that is ~100% churn by
day 2 — an artifact of the simulator, not a finding. An interviewer who knows
PaySim would spot it immediately, and it is exactly the kind of thing that turns
a portfolio project into a liability. **Recommend we drop MAU and cohort
retention entirely.**

### What the data *does* support for the Growth pillar
- **Daily/hourly transaction volume and value**, split by `type` — 743 hourly
  points is a genuinely rich time series.
- **Daily active accounts** (distinct originators per day) — honest as a
  *volume* measure, provided we say plainly that it is near-identical to
  transaction count because accounts do not repeat. Worth showing precisely
  *because* it exposes the synthetic structure.
- **Hour-of-day activity profile** — the 24-hour cycle across 31 days is a real,
  visualizable pattern and the most defensible "growth/behavior" chart available.
- **Destination-side concentration** — destinations *do* recur (up to 113x), so
  "top destinations by value received" and merchant-vs-customer flows are
  supportable. Any repeat-behavior story must live on the **destination** side,
  never the originator side.
