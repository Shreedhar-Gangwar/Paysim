# Data Dictionary

Generated from the live schema. Every table, column, and index in the `paysim`
database, with the reasoning behind the non-obvious choices.

**Database size:** 2,744 MB total — `fact_transactions` 1,108 MB,
`dim_accounts` 989 MB.

---

## Model overview

```
                   dim_date (743 rows)
                        |
                        | date_key
                        |
dim_accounts  ----<  fact_transactions  >----  dim_transaction_type (5 rows)
(9,073,900)             (6,362,620)                      |
   ^      ^                                              | transaction_type_key
   |      |                                              |
   |      +-- dest_account_key                       fee_model (5 rows)
   +--------- orig_account_key
       (role-playing: joined twice)
```

**Grain of `fact_transactions`:** exactly one row per PaySim transaction.
Staging has 6,362,620 rows; the fact table has 6,362,620 rows.

---

## `stg_transactions` — raw landing zone

A faithful 1:1 copy of the CSV. No transformation, no keys, no indexes: it is
written once by `COPY` and read sequentially by the Stage B transform, so an
index would only slow the bulk load.

| Column | Type | Null | Description |
|---|---|:--:|---|
| `step` | `integer` | no | Simulation hour, 1–743 (~30.96 days). Not a calendar. |
| `type` | `text` | no | `CASH_IN`, `CASH_OUT`, `DEBIT`, `PAYMENT`, `TRANSFER`. |
| `amount` | `numeric(18,2)` | no | Transaction amount. |
| `name_orig` | `text` | no | Originating account id (`C…`). |
| `oldbalance_org` | `numeric(18,2)` | no | Originator balance before. |
| `newbalance_orig` | `numeric(18,2)` | no | Originator balance after. |
| `name_dest` | `text` | no | Destination account id (`C…` or `M…`). |
| `oldbalance_dest` | `numeric(18,2)` | no | Destination balance before. |
| `newbalance_dest` | `numeric(18,2)` | no | Destination balance after. |
| `is_fraud` | `smallint` | no | 0/1 ground truth. |
| `is_flagged_fraud` | `smallint` | no | 0/1, PaySim's incumbent rule. |

> **Why `NUMERIC`, not `FLOAT`, for money.** Balances are exact decimal
> quantities. Binary floating point would make the balance-delta checks
> (`old − amount = new`) fail spuriously on rounding error.

---

## `dim_date` — 743 rows, one per simulated hour

PaySim has **no calendar**. `step` is a bare hour counter.

| Column | Type | Null | Description |
|---|---|:--:|---|
| `date_key` | `integer` | no | **PK.** Equals `step` (1–743). |
| `day_number` | `smallint` | no | `(step − 1) / 24`. 0-based: step 1 → day 0. |
| `hour_of_day` | `smallint` | no | `(step − 1) % 24`. 0–23. |
| `day_of_week` | `text` | no | `Day_0`…`Day_6`. **Synthetic, not a real weekday.** |
| `is_weekend` | `boolean` | no | `day_of_week IN (Day_5, Day_6)`. Convention only. |

> **The `−1` offset matters.** Without it, step 1 lands on hour 1 and the first
> simulated day holds only 23 hours, quietly skewing every daily average.
>
> **The surrogate key IS `step`.** It is already dense, immutable, and identifies
> the grain exactly. A second key would add a join hop and buy nothing.
>
> **Day 30 is partial** — 23 hours (steps 721–743). Any daily chart ends on an
> artificial dip.

---

## `dim_transaction_type` — 5 rows

| Column | Type | Null | Description |
|---|---|:--:|---|
| `transaction_type_key` | `smallint` | no | **PK.** 1–5. |
| `type_name` | `text` | no | **Unique.** `CASH_IN` … `TRANSFER`. |
| `type_description` | `text` | no | Plain-English meaning. |
| `is_fraud_bearing` | `boolean` | no | True only for `TRANSFER`, `CASH_OUT`. **Verified against the data**, not assumed. |
| `orig_balance_sign` | `smallint` | no | `+1` credit / `−1` debit, applied to the originator. |
| `dest_balance_sign` | `smallint` | **yes** | `+1` / `−1`. **NULL for `PAYMENT`** — merchant balances are never populated. |

**Values:**

| key | type | fraud-bearing | orig sign | dest sign |
|---:|---|:--:|---:|:--:|
| 1 | `CASH_IN` | no | **+1** | **−1** |
| 2 | `CASH_OUT` | **yes** | −1 | +1 |
| 3 | `DEBIT` | no | −1 | +1 |
| 4 | `PAYMENT` | no | −1 | **NULL** |
| 5 | `TRANSFER` | **yes** | −1 | +1 |

> **`CASH_IN` is the odd one out on both sides** — the customer receives cash, so
> the originator is *credited* and the destination *debited*. Applying a single
> debit identity to every type marks all 1,399,284 `CASH_IN` rows corrupt when
> only 33 are.

---

## `dim_accounts` — 9,073,900 rows

**Conformed and role-playing.** The fact table carries two foreign keys into this
one table (`orig_account_key`, `dest_account_key`).

| Column | Type | Null | Description |
|---|---|:--:|---|
| `account_key` | `bigint` | no | **PK.** Surrogate, assigned by `ROW_NUMBER()` over the sorted `account_id` so re-runs are deterministic. |
| `account_id` | `text` | no | **Unique.** Natural key, e.g. `C1231006815`, `M1979787155`. |
| `party_type` | `text` | no | `CUSTOMER` (6,923,499) or `MERCHANT` (2,150,401). |

> **Why one dimension and not two.** 1,769 accounts appear as *both* originator
> and destination. Split dimensions would give those accounts two identities and
> make "what did this account do overall" unanswerable.
>
> **Why it is larger than the fact table.** PaySim's originators are 99.85%
> single-use, so the dimension is nearly 1:1 with the fact on that side. Unusual,
> deliberate, and defensible.
>
> **`party_type` is derived from a proven rule**, not the prefix alone: `M…`
> accounts appear *only* as the destination of a `PAYMENT` (2,151,495 rows —
> exactly the `PAYMENT` count) and never as an originator. An assertion in
> `04_populate_star_schema.sql` enforces it.

---

## `fact_transactions` — 6,362,620 rows

| Column | Type | Null | Description |
|---|---|:--:|---|
| `transaction_key` | `bigint` | no | **PK.** Surrogate. PaySim rows have no natural key. |
| `date_key` | `integer` | no | **FK** → `dim_date`. |
| `transaction_type_key` | `smallint` | no | **FK** → `dim_transaction_type`. |
| `orig_account_key` | `bigint` | no | **FK** → `dim_accounts`. |
| `dest_account_key` | `bigint` | no | **FK** → `dim_accounts`. |
| `amount` | `numeric(18,2)` | no | **Additive measure.** |
| `oldbalance_org` | `numeric(18,2)` | no | Snapshot. **Do not SUM across rows.** |
| `newbalance_orig` | `numeric(18,2)` | no | Snapshot. |
| `oldbalance_dest` | `numeric(18,2)` | no | Snapshot. |
| `newbalance_dest` | `numeric(18,2)` | no | Snapshot. |
| `orig_balance_delta` | `numeric(18,2)` | no | `newbalance_orig − oldbalance_org`. Additive. |
| `dest_balance_delta` | `numeric(18,2)` | no | `newbalance_dest − oldbalance_dest`. Additive. |
| `orig_balance_error` | `numeric(18,2)` | no | `newbalance_orig − (oldbalance_org + orig_sign × amount)`. Zero = consistent. |
| `dest_balance_error` | `numeric(18,2)` | **yes** | Same, destination side. **NULL for `PAYMENT`.** |
| `is_fraud` | `boolean` | no | Ground truth. 8,213 true. |
| `is_flagged_fraud` | `boolean` | no | Incumbent rule. 16 true. |

> **The balance snapshots are semi-additive.** Summing `oldbalance_org` across
> rows is meaningless. The `_delta` columns are the additive versions.
>
> **`dest_balance_error` is nullable on purpose.** PaySim never populates the
> merchant's balance on a `PAYMENT` (all 2,151,495 rows have
> `oldbalance_dest = newbalance_dest = 0`), so the residual is *undefined*, not
> zero. Storing 0 would inflate any "consistent destinations" count by a third of
> the table.

### Indexes

| Index | Columns | Why |
|---|---|---|
| `fact_transactions_pkey` | `transaction_key` | Primary key. |
| `idx_fact_date` | `date_key` | Every Growth query groups or filters on it. |
| `idx_fact_type` | `transaction_type_key` | Nearly every Risk / Profitability query slices by type. |
| `idx_fact_type_date` | `transaction_type_key, date_key` | The common Risk roll-up: fraud exposure by type over time. |
| `idx_fact_dest_account` | `dest_account_key` | Destinations genuinely recur (up to 113×). |
| `idx_fact_is_fraud_true` | `transaction_key` **WHERE `is_fraud`** | **Partial.** Fraud is 0.129% of rows, so ~8k entries instead of 6.36M. A full index on a boolean this skewed would waste ~140 MB and never be used for `is_fraud = false`. |
| `idx_fact_is_flagged_true` | `transaction_key` **WHERE `is_flagged_fraud`** | **Partial.** Same reasoning, 16 rows. |

**Deliberately absent:** an index on `orig_account_key` (99.85% of originators
appear once — grouping by originator ≈ grouping by row), and one on
`dim_accounts.party_type` (2 distinct values over 9M rows; the planner would
never use it).

Indexes are built **after** the bulk insert. Maintaining a b-tree during a
6.36M-row insert is markedly slower than building it once over a finished table.

---

## `fee_model` — 5 rows. **Assumptions, not data.**

PaySim contains no fee, cost, or revenue information. Every number here is
invented. It lives in its own table — not on `dim_transaction_type` — so a rate
can change and the analysis re-run without touching the star schema.

| Column | Type | Null | Description |
|---|---|:--:|---|
| `transaction_type_key` | `smallint` | no | **PK, FK** → `dim_transaction_type`. |
| `fee_rate` | `numeric(6,5)` | no | Proportion of amount. `0.01500` = 1.5%. |
| `fee_min` | `numeric(12,2)` | no | Floor. Charged even on tiny amounts. |
| `fee_max` | `numeric(12,2)` | no | Cap. Protects against outlier amounts. |
| `cost_per_txn` | `numeric(12,2)` | no | Our cost to serve one transaction. |
| `rationale` | `text` | no | Why this rule. |

**Values:**

| type | rate | floor | cap | cost/txn |
|---|---:|---:|---:|---:|
| `CASH_IN` | 0.00% | 0 | 0 | 3.00 |
| `CASH_OUT` | 1.50% | 10 | 5,000 | 3.00 |
| `TRANSFER` | 1.00% | 10 | 10,000 | 1.00 |
| `PAYMENT` | 0.50% | 1 | 1,000 | 0.50 |
| `DEBIT` | 0.75% | 5 | 2,000 | 1.00 |

### `fn_transaction_fee(amount, rate, min, max)`

```sql
LEAST(GREATEST(amount * rate, fee_min), fee_max)
```

Declared `IMMUTABLE PARALLEL SAFE` — and **deliberately not `STRICT`**.
PostgreSQL will not inline a `STRICT` SQL function whose body is non-strict, and
`LEAST`/`GREATEST` ignore NULLs rather than propagating them. Declared `STRICT`,
this function is invoked 6,362,620 times through the executor: **40.2 seconds**
against **0.88 seconds** inlined. The arguments are never NULL — `amount` and
every `fee_model` column are `NOT NULL`.

---

## `mv_duplicate_cashout_legs` — MATERIALIZED, 3,933 rows

The second leg of each two-step theft: a fraudulent `CASH_OUT` whose exact
`amount` **and** `oldbalance_org` match a fraudulent `TRANSFER`.

| Column | Type | Description |
|---|---|---|
| `transaction_key` | `bigint` | Unique index. Anti-joined against by the fraud and profitability views. |

> **This does not refresh itself.** After any rebuild of `fact_transactions`:
> ```sql
> REFRESH MATERIALIZED VIEW mv_duplicate_cashout_legs;
> ```
> Skip it and every fraud figure silently drifts back toward the naive
> 12,056.42M. `scripts/run_all.ps1` does it for you.

---

## Views

### Risk — `sql/07_analysis_risk.sql`
| View | Rows | Question it answers |
|---|---:|---|
| `vw_fraud_loss_attribution` | 3 | How much did fraud actually take? (7,492.71M, not 12,056.42M) |
| `vw_risk_fraud_by_type` | 5 | Which products carry fraud, and how does the incumbent rule fare? |
| `vw_risk_fraud_by_amount_band` | 6 | At what transaction sizes does fraud concentrate? |
| `vw_risk_flagged_vs_actual` | 1 | How good is the fraud rule we already have? (0.19% recall) |
| `vw_risk_balance_signature` | 7 | Does ledger consistency reveal fraud? (Yes — inverted, and it's an artifact.) |

### Growth — `sql/08_analysis_growth.sql`
| View | Rows | Question it answers |
|---|---:|---|
| `vw_growth_daily_activity` | 31 | How do volume, value, and active accounts move day by day? |
| `vw_growth_daily_by_type` | 152 | Which products drive daily activity, and does the mix shift? |
| `vw_growth_hourly_profile` | 24 | What does a typical day look like? |
| `vw_growth_top_destinations` | 500 | Where does money concentrate? (~27s — the slowest view.) |
| `vw_growth_account_recurrence` | 2 | Do accounts come back? (Evidence for why there is no retention metric.) |

### Profitability — `sql/09_analysis_profitability.sql`
| View | Rows | Question it answers |
|---|---:|---|
| `vw_profitability_by_type` | 5 | Which products make money once fraud is charged to them? |
| `vw_profitability_by_type_and_band` | 24 | Within a product, which transaction sizes make money? |
| `vw_profitability_daily` | 31 | Does a single bad day of fraud swing the month? |
| `vw_profitability_summary` | 1 | Did the business make money? |

### Dashboard — `sql/10_dashboard_views.sql`
| View | Rows | Purpose |
|---|---:|---|
| `vw_dashboard_date` | 31 | Synthetic calendar so DAX time intelligence works. Day 0 → 2024-01-01. |
| `vw_dashboard_kpi` | 1 | One column per headline card. |
| `vw_dashboard_daily` | 31 | Growth + profitability on one daily grain. |
| `vw_dashboard_fraud_waterfall` | 3 | 12,056.42 → −4,563.70 → 7,492.72. |
| `vw_dashboard_data_caveats` | 9 | Every caveat, as data, so it ships with the model. |
