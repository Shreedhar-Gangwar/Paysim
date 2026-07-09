# Stage B — Star schema: design, build, validation

## What this stage is
Turn the raw staging table into a dimensional model that all analysis sits on.
Three conformed dimensions, one fact table at transaction grain, indexes chosen
deliberately, and a validation script that must pass before Stage C is allowed
to trust any of it.

## Files
| File | What it is |
|---|---|
| `sql/03_create_star_schema.sql` | DDL only — the model's specification, readable on its own. |
| `sql/04_populate_star_schema.sql` | Set-based ETL from staging, plus indexes and three data assertions. |
| `sql/05_validate_star_schema.sql` | Nine checks that must all pass. Prints PASS/FAIL. |

## The model
```
                  dim_date (743)
                       |
dim_accounts (9,073,900) ==< fact_transactions (6,362,620) >== dim_transaction_type (5)
        (joined twice: orig + dest)
```

**Grain:** exactly one row per PaySim transaction. 6,362,620 in, 6,362,620 out.

## Decisions and why

**`dim_date`'s surrogate key is the `step` value itself.** Normally a dimension
gets a meaningless surrogate, but `step` is already dense, immutable and
identifies the grain exactly. A second key would add a join hop and buy nothing.

**The `-1` offset in the day/hour mapping.** `day = (step-1)/24`,
`hour = (step-1)%24`. Without the offset, step 1 lands on hour 1 and the first
simulated day holds only 23 hours, quietly skewing every daily average.

**`day_of_week` is labelled `Day_0..Day_6`, not Monday..Sunday.** There is no
basis for claiming day 0 is a Monday. The label is deliberately synthetic so
nobody reads real weekday semantics into it.

**`dim_accounts` is one conformed dimension, joined twice** (role-playing:
`orig_account_key`, `dest_account_key`). It is large — 9,073,900 rows, bigger
than the fact table — which is unusual and worth defending: PaySim's originators
are 99.85% single-use, so the dimension is nearly 1:1 with the fact on that side.
We keep it because it is the correct model, and validation proved it earns its
place: **1,769 accounts appear in both roles**. Split dimensions would have given
those accounts two identities and made "what did this account do overall"
unanswerable.

**Surrogate keys are assigned by `ROW_NUMBER() OVER (ORDER BY ...)`**, not a
sequence. Sorting makes assignment deterministic, so re-running the build yields
identical keys and the fact table stays reproducible.

## The bug this stage caught

The first version of the fact table computed one balance residual for every row:
`oldbalance - amount - newbalance`. That assumes every transaction **debits** the
originator. It does not. Measured per type:

- **Originator:** `CASH_IN` is a **credit**; all other types are debits.
- **Destination:** `CASH_IN` is a **debit**; `CASH_OUT`, `TRANSFER`, `DEBIT` are credits.
- **`PAYMENT` destinations are never tracked at all** — all 2,151,495 rows carry
  `oldbalance_dest = newbalance_dest = 0`.

Under the naive single-identity formula, **100% of the 1,399,284 CASH_IN rows
looked corrupt when only 33 actually are.** It also reported a headline "78.70%
of non-fraud rows have an inconsistent originator ledger" — a number that was
mostly an artifact of the formula, not a property of the data.

The fix: `dim_transaction_type` now stores `orig_balance_sign` and
`dest_balance_sign` (+1 credit / −1 debit / NULL not tracked), and the residual
is `actual_new - (old + sign * amount)`.

`dest_balance_error` is **nullable**, and NULL for PAYMENT. Storing 0 there would
have been a lie that inflated any "consistent destinations" count by a third of
the table. Validation excludes NULLs from the denominator rather than counting
them as consistent.

Three assertions now guard these facts inside the populate script, so they fail
loudly rather than drift: `is_fraud_bearing` matches the data, merchants appear
only as PAYMENT destinations, and PAYMENT destination balances really are all zero.

## Index rationale
| Index | Why |
|---|---|
| `idx_fact_date` | Every Growth query groups/filters on `date_key`. |
| `idx_fact_type` | Nearly every Risk and Profitability query slices by type. |
| `idx_fact_type_date` | The common Risk roll-up: fraud exposure by type over time. |
| `idx_fact_dest_account` | Destinations recur (up to 113x), so destination-side grouping is real work. |
| `idx_fact_is_fraud_true` (**partial**) | Fraud is 0.1291% of rows. A partial index is ~8k entries instead of 6.36M. A full boolean index on data this skewed would be near-useless and waste ~140MB. |
| `idx_fact_is_flagged_true` (**partial**) | Same, more extreme: 16 rows. |

**Deliberately NOT created:** an index on `orig_account_key` (99.85% of
originators appear once, so grouping by originator ≈ grouping by row), and one on
`dim_accounts.party_type` (2 distinct values over 9M rows — the planner would
never use it).

Indexes are built **after** the bulk insert. Maintaining a b-tree during a
6.36M-row insert is markedly slower than building it once over the finished table.

## Validation results — all nine checks PASS

| Check | Result |
|---|---|
| Fact rows = staging rows | 6,362,620 = 6,362,620 **PASS** |
| Total amount reconciles | 1,144,392,944,759.77 both sides **PASS** |
| Fraud rows reconcile | 8,213 both sides **PASS** |
| `transaction_key` unique | 6,362,620 distinct **PASS** |
| Orphaned dimension keys | 0 / 0 / 0 / 0 **PASS** |
| `dim_date` dense, no gaps | 743 rows, steps 1–743 **PASS** |
| Fraud by type via joins | matches Stage A exactly **PASS** |

Row counts alone would not prove correctness — a join can match the wrong rows
and preserve the count. Summing `amount` and the fraud count catches that.

`dim_accounts`: 6,923,499 customers, 2,150,401 merchants, 1,769 accounts in both
originator and destination roles.

## Balance-error findings (corrected figures) — material for Stage C

Percent of rows failing the direction-aware ledger identity:

| | orig inconsistent | dest inconsistent |
|---|---:|---:|
| **non-fraud** (6,354,407) | 56.68% | 15.14% |
| **fraud** (8,213) | **0.55%** | **51.58%** |

By type:

| type | orig inconsistent | dest inconsistent |
|---|---:|---:|
| CASH_OUT | 88.54% | 9.46% |
| PAYMENT | 51.18% | *not tracked* |
| CASH_IN | 0.00% | 26.25% |
| TRANSFER | 95.24% | 10.90% |
| DEBIT | 28.45% | 8.31% |

**The signal is inverted from the naive expectation, and that is the interesting
part.** Fraudulent transactions have an almost perfectly *consistent* originator
ledger (0.55% inconsistent) while ordinary transactions are inconsistent 56.68%
of the time. Fraud in PaySim drains the originating account exactly — old balance
minus amount lands precisely on the new balance — whereas legitimate rows are
littered with unexplained balance movement.

On the destination side the relationship flips: fraud is inconsistent 51.58% of
the time versus 15.14% for non-fraud.

Stage C should treat these as **descriptive, not causal**. This is a simulator
artifact of how PaySim generates fraud, and the honest framing is "fraudulent
rows are ledger-exact on the originator side," not "ledger-exactness predicts
fraud in the real world." Worth showing; worth captioning carefully.

## Open question carried into Stage C
TRANSFER is 8.38% of transactions but the largest share of value (485.3B of
1,144.4B). A flat per-transaction fee and a percentage-of-amount fee rank
TRANSFER's profitability in **opposite** directions. That rule must be chosen
deliberately and written down, not picked by default.
