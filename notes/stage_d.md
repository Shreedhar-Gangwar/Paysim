# Stage D — Dashboard handoff

## What this stage is
The layer Power BI connects to, plus the build guide. You build the visuals; the
data layer is finished.

| File | What it is |
|---|---|
| `sql/10_dashboard_views.sql` | Five BI-shaped views: synthetic date table, KPI row, joined daily grain, fraud waterfall, caveats. |
| `docs/powerbi_build_guide.md` | Connection settings, model relationships, every DAX measure written out, page-by-page visual layout. |

## Two problems this stage had to solve

**Power BI's time intelligence needs real dates.** PaySim has none — `step` is a
bare hour counter. `vw_dashboard_date` anchors simulated day 0 to 2024-01-01
(chosen only because it is a Monday, so weekday labels line up). The dates are
fake and every axis must say "simulated day".

**The base tables are far too large to import.** `fact_transactions` is 6.36M
rows and `dim_accounts` is 9.07M. Nothing on the dashboard needs either. Every
imported view is pre-aggregated in Postgres — the largest is 500 rows.

## The caveats are shipped as data, not as documentation

`vw_dashboard_data_caveats` holds nine rows, one per thing that will mislead a
reader: the fraud deduplication, the synthetic dates, the partial final day, the
absence of retention metrics, the balance-signature artifact, the 10M seeded
balances, the invented fee model, throughput-vs-distinct-money, and the
zero-amount rows.

If a caveat lives in the model it ships with the model. The guide puts that
table on page 1, not buried at the back.

---

## Performance: four measurements, three wrong guesses

The views were correct but several were unusably slow. Every fix below was found
by reading `EXPLAIN (ANALYZE)`, and **three of my four initial guesses were wrong.**

### 1. `fn_transaction_fee` declared STRICT — 45x penalty

`vw_profitability_by_type` took **89 seconds** to return five rows.

The cause was one keyword. PostgreSQL **will not inline a STRICT SQL function
whose body is non-strict**, and `LEAST`/`GREATEST` are non-strict — they ignore
NULL arguments rather than returning NULL. Declared `STRICT`, the function was
called 6,362,620 times through the executor.

| form | time |
|---|---:|
| `SUM(fn_transaction_fee(...))` with `STRICT` | 40,179 ms |
| the identical expression written inline | 881 ms |

Removing `STRICT` (keeping `IMMUTABLE PARALLEL SAFE`) lets the planner inline the
body. The arguments are never NULL: `amount` is NOT NULL on the fact and every
`fee_model` column is NOT NULL.

### 2. Grouping on text columns forced sorts over 6.36M rows

Two views grouped by `dim_transaction_type.type_name` and, in one case, by a text
`CASE` label. Both made the planner abandon hash aggregation:

- `vw_profitability_by_type`: a nested-loop index scan over all 6.36M rows with
  ~424k random heap reads, to deliver sorted input to a merge join.
- `vw_profitability_by_type_and_band`: a `GroupAggregate` with an external merge
  sort, **spilling 98MB to disk**.

Fix: group on the fact's integer keys (`transaction_type_key`, a `SMALLINT`
`band_id`) and attach human-readable labels afterwards, to 24 aggregated rows
rather than 6.36M raw ones.

### 3. Correlated `NOT EXISTS` per row → single anti-join

The duplicate-fraud-leg exclusion ran as a correlated subquery inside a `CASE`,
issuing 6.36M index lookups (~14s). Replaced with one `LEFT JOIN` against
`mv_duplicate_cashout_legs` and an `IS NULL` test (~1s).

### 4. `mv_duplicate_cashout_legs` — materialized, and it did NOT fix the slow view

The 3,933 duplicate legs are now a materialized view with a unique index.

Honest note: **this was my first hypothesis for the 89-second view and it was
wrong.** Materialising changed nothing; the STRICT function was the real cause.
The matview is kept because it is genuinely the right structure — the definition
is worth reading, the anti-joins become index lookups, and it removed duplicated
logic from three views — but it is not what fixed the problem.

**It must be refreshed whenever the star schema is rebuilt:**
```sql
REFRESH MATERIALIZED VIEW mv_duplicate_cashout_legs;
```
Skip that after a reload and every fraud figure silently drifts back toward the
naive 12,056.42M.

### 5. `vw_growth_top_destinations` — two "optimisations", both worse

At ~25s this is the slowest view in the project. It aggregates all 2,722,362
destinations to keep 500. I tried to fix it twice and made it worse both times:

| version | time |
|---|---:|
| straightforward single-pass hash aggregate | **27s** |
| top-500 first, then `active_days` per account via `LATERAL` | 315s |
| `COUNT(DISTINCT (date_key-1)/24)` instead of joining `dim_date` | 355s |

The lateral re-scans the fact table per account. The computed expression inside
`COUNT(DISTINCT ...)` defeats the hash aggregate that a plain column reference
gets. Both were reverted. The simple version stayed, and 27s is fine for a view
Power BI imports once.

### Result

| view | before | after |
|---|---:|---:|
| `vw_profitability_by_type` | 89,801 ms | **963 ms** |
| `vw_profitability_by_type_and_band` | 13,616 ms | **1,892 ms** |
| `vw_profitability_daily` | — | 708 ms |
| `vw_growth_top_destinations` | 27,113 ms | 27,113 ms (unchanged, by choice) |

Full model refresh: roughly **35 seconds**, almost all of it in
`vw_growth_top_destinations`.

**All headline figures verified identical after every rewrite** — 6,362,620 rows,
933.56M net profit, 7,492.72M deduplicated fraud loss, 4,563.70M double-counted,
TRANSFER at −3,206.44M.

---

## The DAX trap worth knowing

Two measures must be written as `DIVIDE(SUM(numerator), SUM(denominator))`, never
as `AVERAGE(the_percentage_column)`:

- `Fraud Rate %` — averaging `fraud_rate_pct` across types weights CASH_IN's 0%
  equally with TRANSFER's 0.77%.
- `Effective Take Rate %` — it is a value-weighted ratio.

Both wrong forms look right and return plausible numbers. Being able to explain
why they are wrong is worth more than any visual on the dashboard.

## Pages
1. **Overview** — KPI cards, activity over time, product mix, net profit by type, caveats table.
2. **Growth** — daily volume/value, hour-of-day profile, active-accounts-vs-transactions (two lines that overlap; that *is* the finding), the recurrence exhibit, top destinations.
3. **Risk** — fraud by type, the deduplication waterfall (12,056.42 → −4,563.70 → 7,492.72), fraud by amount band, incumbent-rule confusion matrix, ledger-consistency exhibit.
4. **Profitability** — profit bridge by product, the type × band heatmap (the single most valuable visual), effective take rate, cumulative profit.

## Carried into Stage E
- `README.md` with clean-machine setup and the run order `01 → 10`.
- The `REFRESH MATERIALIZED VIEW` step belongs in the documented run order.
- Data dictionary for the star schema.
