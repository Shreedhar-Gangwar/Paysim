# Stage E — Repo polish and reproducibility

## What this stage is
Make the project runnable by someone who has never seen it, on a clean machine,
without asking questions.

| File | What it is |
|---|---|
| `README.md` | Front door. Findings, honest scope, clean-machine setup, run order. |
| `scripts/run_all.ps1` | Single entry point. Creates the DB, loads the CSV, builds and validates the schema, creates all 20 views, refreshes the matview, prints the headline figures. |
| `docs/data_dictionary.md` | Every table, column, index — generated from the live schema, with the reasoning for each non-obvious choice. |

## The bug this stage caught

`run_all.ps1` **failed on its first real test**, and it failed in exactly the way
a reproducibility script is supposed to: on the second run, not the first.

`03_create_star_schema.sql` began with a bare `DROP TABLE IF EXISTS
fact_transactions`. On a virgin database that works. On a database that already
has the analytical views, PostgreSQL refuses:

```
ERROR: cannot drop table fact_transactions because other objects depend on it
DETAIL: view vw_risk_fraud_by_type depends on table fact_transactions
        ... 17 more
```

So the script only ever worked once — the case I had been testing all along,
because I built the schema before I built the views. The README's claim that it is
"safe to re-run" was **false when written**.

Fixed by dropping with `CASCADE`, which is correct here rather than merely
convenient: scripts 06–10 recreate every dependent object immediately afterwards.

Two consequences worth knowing, both now documented:
- The cascade also strips `fee_model`'s foreign key to `dim_transaction_type`
  (the table survives; script 06 rebuilds it).
- **Running 03 and 04 by hand without re-running 06–10 leaves you with no views.**

## Why the runner prints its own results

The last thing `run_all.ps1` does is `SELECT` the headline figures. A successful
run therefore evidences itself:

```
 total_txns | total_value_billions | net_profit_millions | fraud_loss_deduplicated | fraud_loss_naive
    6362620 |              1144.39 |              933.56 |                 7492.72 |         12056.42
```

If those five numbers appear, the whole pipeline — load, transform, assertions,
validation, fee model, deduplication — worked. If they do not, something upstream
threw and `ON_ERROR_STOP=1` halted it.

## Runtime — measured, after two wrong estimates

I guessed 6–8 minutes, then 25–30. **The measured cold-cache rebuild is 70.7
minutes.** Both earlier figures were written before anyone had run the thing end
to end.

Where the time goes: the CSV `COPY` is ~2 minutes. Nearly everything else is the
`fact_transactions` insert, which assigns surrogate keys with
`ROW_NUMBER() OVER (ORDER BY step, name_orig, amount)`. That sorts 6.36M wide rows
(including a text column) and **spilled 16 GB across 2,744 temp files**, competing
with WAL writes for the same disk — WAL throughput measured at 1.9 MB/s while it
ran.

The sort is the price of deterministic surrogate keys across rebuilds, which is
worth paying. Raising `work_mem` / `maintenance_work_mem` in
`04_populate_star_schema.sql` is the lever if you want it faster.

### And the runner lied about its own runtime

`"{0:mm}m {0:ss}s" -f $elapsed` prints the **minutes component** of a `TimeSpan`
and silently discards the hours. The 70.7-minute build reported itself as
**"Build complete in 10m 38s"**. Fixed to use `$elapsed.TotalMinutes`.

A timing bug in a script whose only job is to prove reproducibility is not a
cosmetic defect: it would have quietly convinced the next person that a
70-minute build takes 10.

## Data dictionary highlights

Generated from `information_schema`, not transcribed from the DDL — so it cannot
drift from the database.

It records the things a reviewer will ask about: why `dim_date`'s surrogate key is
the `step` value, why the `−1` offset in the day/hour mapping matters, why
`dim_accounts` is conformed despite being larger than the fact table, why the
fraud indexes are partial, why `dest_balance_error` is nullable, and why
`fn_transaction_fee` must not be declared `STRICT`.

## Project status

All five stages complete:

- **A** — scaffold, load, profile. Established that retention metrics are not supportable.
- **B** — star schema. Caught the direction-aware balance-residual bug.
- **C** — fee model, fraud deduplication, the three analytical pillars.
- **D** — dashboard layer, Power BI build guide, query optimisation.
- **E** — README, runner, data dictionary.

Remaining work is yours: build the Power BI dashboard from
`docs/powerbi_build_guide.md`.
