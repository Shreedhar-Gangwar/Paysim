# PaySim — FinTech Transaction Analytics

A PostgreSQL star schema and analytical SQL layer over the PaySim mobile-money
dataset (6.36M transactions), feeding a Power BI dashboard. Built to answer three
questions a payments provider actually asks: **how is activity growing, where does
fraud concentrate, and which products make money.**

The value here is the data modelling and the SQL, not visual flash. Everything is
commented, every metric is defensible, and the metrics the data *cannot* support
were cut rather than faked.

---

## Headline findings

**Fraud consumes 89% of gross profit.** 7,492.72M against 8,426.28M.

**TRANSFER moves the most value of any product and loses the most money.**
It is 8.38% of transactions but 42.41% of value, and nets **−3,206.44M** once
fraud is charged to it. It stays loss-making even with the fee cap removed
(−1,214.82M), so this is a fraud problem, not a pricing problem.

**The obvious fraud number is 38% too high.** `SUM(amount) WHERE is_fraud` gives
12,056.42M. The true loss is **7,492.72M**. PaySim writes each theft twice — a
TRANSFER draining the victim, then a CASH_OUT of the same money. Matching the two
legs on amount *and* originator starting balance yields 3,937 pairs, 3,933 of them
in the same simulation hour.

**The incumbent fraud rule catches 16 of 8,213 frauds** — 0.19% recall at 100%
precision. Tuned never to raise a false alarm, and consequently never raising one.

**Every CASH_OUT of exactly 10,000,000.00 is fraudulent — all 142.** Not because
of a cap: those victim accounts were *seeded* with exactly that balance and
drained to zero. 2,920 legitimate TRANSFERs also sit at exactly 10M. A
100%-precision rule that detects the simulator, not fraud.

---

## What this project deliberately does not do

**No MAU. No cohort retention.** 99.85% of originating accounts transact exactly
once across the whole ~31-day window; the maximum any account reaches is three;
only 0.14% are active on more than one day. A retention curve here would show
~100% churn by day 2 — a property of the simulator, not a finding about a
business.

Rather than hide that, `vw_growth_account_recurrence` ships the evidence and the
dashboard displays it. Repeat behaviour exists **only on the destination side**
(up to 113 transactions), which is where the recurrence analysis lives.

**All revenue and cost figures rest on an invented fee model.** PaySim contains no
fee data. See [`sql/06_fee_model.sql`](sql/06_fee_model.sql) for the rules and the
reasoning. The *ranking* of segments is the finding; absolute currency values are
illustrative.

**All dates are synthetic.** PaySim gives an hour counter (`step`, 1–743) and no
calendar. Day 0 is anchored to 2024-01-01 purely so Power BI's date hierarchy
works.

---

## Setup on a clean machine

### 1. Install PostgreSQL

Any version ≥ 13. Developed on **PostgreSQL 18.1**. Make sure `psql` is on your
`PATH`:

```powershell
psql --version
```

### 2. Get the data

The CSV is ~470 MB and is **not** in this repository (`data/raw/` is git-ignored).

1. Download **"Synthetic Financial Datasets For Fraud Detection"** from Kaggle:
   <https://www.kaggle.com/datasets/ealaxi/paysim1>
2. Place the file at exactly:

```
data/raw/paysim dataset.csv
```

It should have 6,362,620 data rows and this header:

```
step,type,amount,nameOrig,oldbalanceOrg,newbalanceOrig,nameDest,oldbalanceDest,newbalanceDest,isFraud,isFlaggedFraud
```

### 3. Configure credentials

```powershell
Copy-Item .env.example .env
```

Edit `.env` and set your PostgreSQL password. **`.env` is git-ignored — it must
never be committed.** No script or `.sql` file contains a credential; `psql` reads
them from the environment.

```ini
PGHOST=localhost
PGPORT=5432
PGUSER=postgres
PGPASSWORD=your_password_here
PGDATABASE=paysim
```

### 4. Build everything

```powershell
powershell -ExecutionPolicy Bypass -File scripts\run_all.ps1
```

This creates the database, bulk-loads the CSV via `COPY`, builds and validates the
star schema, and creates all 20 views.

**Budget 25–30 minutes on a cold cache.** The CSV load is only ~2 minutes; the
bulk of the time is the `fact_transactions` insert (6.36M rows joined twice into
the 9M-row account dimension) and the six indexes built afterwards. It is safe to
re-run — script 03 drops with `CASCADE` and scripts 06–10 rebuild the views.

On success it prints the headline figures, so a good run evidences itself:

```
 total_txns | total_value_billions | net_profit_millions | fraud_loss_deduplicated | fraud_loss_naive
------------+----------------------+---------------------+-------------------------+------------------
    6362620 |               1144.39|              933.56 |                 7492.72 |         12056.42
```

### 5. Build the dashboard

Follow [`docs/powerbi_build_guide.md`](docs/powerbi_build_guide.md). It lists the
15 views to import, the model relationships, every DAX measure written out, and
the four page layouts.

---

## Run order (if you prefer to run the SQL by hand)

Order matters. `06` must precede `09` (the profitability views call
`fn_transaction_fee`); `07` must precede `09` (it creates the materialized view
they anti-join against).

| # | File | What it does |
|---|---|---|
| 01 | `sql/01_create_staging.sql` | Raw landing table. |
| — | `\copy` | Bulk-load the CSV. |
| 02 | `sql/02_inspect_staging.sql` | *Optional.* Profiles the raw data — the distributions that justified every modelling decision. |
| 03 | `sql/03_create_star_schema.sql` | Star schema DDL. |
| 04 | `sql/04_populate_star_schema.sql` | Transform, load, index. Three data assertions. |
| 05 | `sql/05_validate_star_schema.sql` | Nine checks. All must print `PASS`. |
| 06 | `sql/06_fee_model.sql` | The fee assumptions + `fn_transaction_fee`. |
| 07 | `sql/07_analysis_risk.sql` | Risk views + `mv_duplicate_cashout_legs`. |
| 08 | `sql/08_analysis_growth.sql` | Growth views. |
| 09 | `sql/09_analysis_profitability.sql` | Profitability views. |
| 10 | `sql/10_dashboard_views.sql` | Power BI layer. |

> **Script 03 drops with `CASCADE`.** On a rebuild it removes all 18 dependent
> views and the materialized view, and it strips `fee_model`'s foreign key. That
> is why 06–10 must always be re-run after 03 and 04. `run_all.ps1` does this in
> the right order; running the SQL piecemeal is where people get caught.

> **After any rebuild of `fact_transactions`, refresh the materialized view:**
> ```sql
> REFRESH MATERIALIZED VIEW mv_duplicate_cashout_legs;
> ```
> Skip it and every fraud figure silently drifts back toward the naive 12,056.42M.
> `run_all.ps1` does this for you.

---

## Repository layout

```
data/raw/          The PaySim CSV. Git-ignored — download it yourself.
sql/               01→10, the entire data layer. Run in order.
scripts/
  run_all.ps1      Single entry point: builds everything from scratch.
  load_staging.ps1 Just the database creation + CSV load.
docs/
  powerbi_build_guide.md   Connection, DAX measures, visual layout.
  data_dictionary.md       Every table, column, and index, with rationale.
notes/
  stage_a.md       Raw-data profile. Why retention metrics were cut.
  stage_b.md       Star schema decisions. The direction-aware balance bug.
  stage_c.md       Fee model, fraud deduplication, the 10M cash-outs.
  stage_d.md       Dashboard layer + query optimisation (and three wrong guesses).
```

The `notes/` directory is the reasoning log — what was measured, what was decided,
and what turned out to be wrong. It is more useful than the code for understanding
*why* the model looks the way it does.

---

## The model

```
                   dim_date (743)
                        |
dim_accounts (9,073,900) ==< fact_transactions (6,362,620) >== dim_transaction_type (5)
        (role-playing: joined twice, as originator and destination)
```

**Grain:** one row per transaction. 6,362,620 in, 6,362,620 out, with total amount
and fraud count reconciling on both sides — row counts alone would not prove
correctness, since a join can match the wrong rows and preserve the count.

Full detail in [`docs/data_dictionary.md`](docs/data_dictionary.md).

### Three decisions worth knowing

**`dim_accounts` is one conformed dimension, not two.** 1,769 accounts appear as
*both* originator and destination. Splitting would give them two identities. It is
larger than the fact table, which is unusual and deliberate.

**Balance residuals are direction-aware.** `CASH_IN` credits the originator while
every other type debits it. A single debit identity marks all 1,399,284 `CASH_IN`
rows corrupt when only 33 are. `dest_balance_error` is **NULL** for `PAYMENT` —
PaySim never populates merchant balances, so the residual is undefined, not zero.

**Fraud indexes are partial.** Fraud is 0.129% of rows, so
`WHERE is_fraud` gives an index of ~8k entries instead of 6.36M.

---

## Tech stack

- **PostgreSQL** — schema, `COPY`-based ETL, and all analytical SQL. The core.
- **PowerShell** — orchestration only (`run_all.ps1`). No analysis lives outside SQL.
- **Power BI** — the dashboard layer, built manually from `docs/powerbi_build_guide.md`.

Credentials are read from `.env` and never appear in a script, a query, or the
repository.

---

## Data caveats

Nine of them, and they ship **inside the model** as
`vw_dashboard_data_caveats` rather than living only in this file — a caveat in the
database travels with the database:

1. Fraud loss is **deduplicated** (7,492.71M). The naive figure is 12,056.42M.
2. All dates are **synthetic**. There is no calendar in PaySim.
3. **Day 30 is a partial day** (23 hours). Its lower totals are not a decline.
4. **No MAU or retention** — accounts do not repeat.
5. The **balance signature** describes PaySim's generator, not real-world fraud.
6. The **10M cash-outs** are a seeded balance, not a truncation cap.
7. All revenue figures rest on an **invented fee model**.
8. Total value processed is **throughput**, not distinct money — a transfer
   followed by a cash-out counts the same value twice.
9. **16 fraudulent CASH_OUT rows have `amount = 0`.** Retained as-is; the fee
   floor charges a nominal ~160 units on them in total, immaterial against 8.4bn.
