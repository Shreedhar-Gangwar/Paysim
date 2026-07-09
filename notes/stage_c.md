# Stage C — Analytical SQL: Growth, Risk, Profitability

## What this stage is
Fourteen commented, CTE-based views over the star schema, grouped into three
pillars. Each view header states the business question it answers and is
runnable on its own.

| File | What it is |
|---|---|
| `sql/06_fee_model.sql` | The hybrid fee rules. **Assumptions, not data** — isolated in their own table so a rate can change without touching the star schema. |
| `sql/07_analysis_risk.sql` | Fraud concentration, exposure, deduplication, incumbent-rule performance. |
| `sql/08_analysis_growth.sql` | Activity over time. No MAU, no cohort retention — see below. |
| `sql/09_analysis_profitability.sql` | Revenue − cost − attributed fraud loss, by type, band, and day. |

## The fee model (hybrid: percentage, floored and capped)

`fee = clamp(amount × rate, floor, cap)`

| type | rate | floor | cap | cost/txn | why |
|---|---:|---:|---:|---:|---|
| CASH_IN | 0.00% | 0 | 0 | 3.00 | Deposits free — universal in mobile money; feeds the float. |
| CASH_OUT | 1.50% | 10 | 5,000 | 3.00 | Highest rate: drains float, agent dispenses cash. |
| TRANSFER | 1.00% | 10 | 10,000 | 1.00 | Core P2P. Ledger-only, cheap to serve. |
| PAYMENT | 0.50% | 1 | 1,000 | 0.50 | Merchant-funded, low to drive acceptance. |
| DEBIT | 0.75% | 5 | 2,000 | 1.00 | Bank rails cost more than an internal ledger move. |

PaySim has no fee data whatsoever. Every number above is invented. **The ranking
of segments is the deliverable; absolute currency values are illustrative.**

The cap does real work without degenerating the model into a flat fee: it binds
on 24.18% of TRANSFERs and 12.19% of CASH_OUTs. Effective take rates land at
0.59% and 1.38% against headline rates of 1.00% and 1.50%.

---

## Headline results

### The business is profitable overall — but only because of CASH_OUT

| | millions |
|---|---:|
| Fee revenue | 8,438.84 |
| Processing cost | 12.56 |
| **Gross profit** | **8,426.28** |
| Fraud loss (deduplicated) | 7,492.72 |
| **Net profit** | **933.56** |

Fraud consumes **89%** of gross profit.

### Profitability by type — TRANSFER is the loss-maker

| type | txns | value (M) | revenue (M) | fraud loss (M) | **net (M)** |
|---|---:|---:|---:|---:|---:|
| CASH_OUT | 2,237,500 | 394,413.00 | 5,435.35 | 1,425.50 | **+4,003.14** |
| PAYMENT | 2,151,495 | 28,093.37 | 140.48 | 0 | **+139.40** |
| DEBIT | 41,432 | 227.20 | 1.70 | 0 | **+1.66** |
| CASH_IN | 1,399,284 | 236,367.39 | 0.00 | 0 | **−4.20** |
| **TRANSFER** | 532,909 | 485,291.99 | 2,861.31 | 6,067.21 | **−3,206.44** |

**TRANSFER moves the most value of any product and loses the most money.** Its
fraud loss is more than double its fee revenue. This is the central finding.

CASH_IN's −4.20M loss is **correct, not a bug**: deposits are free by design.
It is a cost centre that feeds the float, and reporting it honestly as a loss is
the right answer.

### Where TRANSFER bleeds — the cap and the fraud collide

| band | txns | revenue (M) | fraud loss (M) | net (M) | eff. take rate |
|---|---:|---:|---:|---:|---:|
| under 10K | 6,084 | 0.31 | 0.60 | −0.30 | 1.01% |
| 10K–100K | 55,959 | 30.88 | 35.70 | −4.88 | 1.00% |
| 100K–500K | 209,798 | 594.81 | 339.23 | +255.37 | 1.00% |
| 500K–1M | 132,209 | 946.73 | 420.87 | +525.72 | 1.00% |
| **1M–10M** | 123,351 | 1,233.51 | 3,820.81 | **−2,587.43** | 0.49% |
| **over 10M** | 5,508 | 55.08 | 1,450.00 | **−1,394.93** | 0.07% |

Above ~1M the 10,000 cap crushes the effective take rate to 0.49% and then 0.07%,
while fraud scales with transaction size, uncapped.

**Why revenue in the over-10M band (55.08M) is LOWER than in 1M–10M (1,233.51M).**
This looks wrong and is not. The cap binds at exactly 1M (1% of 1M = 10,000), so
**every** TRANSFER at or above 1M pays a flat 10,000 — regardless of whether it
moves 1M or 92M. Revenue in those bands is therefore purely a headcount:

- 1M–10M: 123,351 txns × 10,000 = **1,233.51M**
- over 10M: 5,508 txns × 10,000 = **55.08M**

There are simply 22× fewer transactions above 10M. The band moves 78,786.92M of
value and earns 55.08M, which is the cap working exactly as designed.

**Does the cap CAUSE TRANSFER's loss? No — and my first framing overstated it.**
Removing the cap entirely (pure 1%, no ceiling) gives TRANSFER 4,852.92M of
revenue instead of 2,861.31M. Against 6,067.21M of fraud loss that is still
**−1,214.82M net**. The product loses money uncapped.

So the honest statement is: **fraud makes TRANSFER loss-making; the cap makes it
worse** (−1,214.82M → −3,206.44M). The cap is a contributing factor, not the
cause. Repricing alone cannot fix this product — the fraud has to be addressed.
That remains the strongest argument in the project for a risk-based fee or a
transfer limit above 1M, but for the right reason.

---

## The 10M CASH_OUT cluster — a seeded balance, not a truncation cap

**Every CASH_OUT of exactly 10,000,000.00 is fraudulent. All 142 of them.**
That much is true. My first explanation of *why* was wrong, and the correction
matters more than the finding.

**What I claimed:** PaySim hard-caps CASH_OUT at 10M, so large thefts truncate
to the ceiling.

**What the data shows:** all 142 of those victim accounts had
`oldbalance_org` of **exactly 10,000,000.00**, and all 142 were drained to zero.
The amount is 10M because the *balance* was 10M. Nothing was truncated.

Evidence against the truncation story:
- A truncating cap piles transactions up just below the ceiling. There are only
  **3** CASH_OUTs between 9.9M and 10M — no pile-up.
- A truncating cap would catch legitimate transactions too. There are **zero**
  non-fraud CASH_OUTs at exactly 10M.
- 10,000,000.00 is not a CASH_OUT-only value: **2,920 non-fraudulent TRANSFERs**
  sit at exactly 10M, alongside 145 fraudulent ones.

So 10,000,000.00 is a **seeded round number** in the simulator — a cohort of
accounts initialised with exactly that balance. CASH_OUT's maximum is 10M simply
because that is the largest seeded balance available to drain, not because a cap
clips it.

That band is 1,420.00M of loss — 19% of all fraud loss — against 0.71M of fee
revenue.

The rule "CASH_OUT of exactly 10M ⇒ fraud" has 100% precision, but what it
actually detects is *"an account seeded with a round 10M was emptied."* That is
a property of the generator, not of fraud. Show it as a curiosity; never present
it as a technique.

## Data quality: 16 zero-amount transactions

**16 CASH_OUT rows have `amount = 0.00`, and all 16 are flagged fraudulent.**

A zero-value cash-out is not a real transaction. Under the current fee model the
`fee_min` floor charges 10 currency units on each, so we book ~160 units of
revenue on transactions that moved no money. The sum is immaterial (160 against
8.4bn) but the principle is not: a floor should not charge a fee on a zero
amount. Flagged here rather than silently patched — the fix belongs in a
documented decision, not a quiet `WHERE amount > 0`.

---

## Fraud loss: 7,492.72M, not 12,056.42M

`SUM(amount) WHERE is_fraud` gives **12,056.42M** and overstates the loss by
**38%**. PaySim generates most fraud as a two-step: a TRANSFER drains the victim,
then a CASH_OUT withdraws the same money. Both rows are flagged, so the naive sum
counts the same theft twice.

**Evidence (measured, not assumed):**
- Matching fraudulent TRANSFER to fraudulent CASH_OUT on **both** amount and
  originator starting balance yields **3,937 pairs over 3,931 distinct
  signatures** — effectively one-to-one.
- **3,933 of those 3,937 occur in the same simulation hour.**
- In 3,943 of 4,097 fraudulent TRANSFERs, `amount = oldbalance_org` exactly:
  fraud drains the victim account to zero.

**Attribution:**

| | txns | loss (M) | counted? |
|---|---:|---:|:--:|
| TRANSFER — first leg, money leaves the victim | 4,097 | 6,067.21 | yes |
| CASH_OUT — independent theft, no matching transfer | 183 | 1,425.50 | yes |
| CASH_OUT — second leg of a theft already counted | 3,933 | 4,563.70 | **no** |
| **True loss** | | **7,492.71** | |

**The account ids do NOT link the two legs.** Zero fraudulent CASH_OUTs
originate from the account a fraudulent TRANSFER landed in — PaySim relabels the
account between legs. The pair is only detectable via the (amount, starting
balance) signature. So we can identify the duplication statistically but
**cannot trace a fraud chain account-to-account.** Any "follow the money" visual
is off the table.

Fraud is **0.65% of total value** moved but only 0.129% of transactions —
fraudulent transactions are roughly **5× the average size**.

Caveat on the 1,144.39bn denominator: it is *throughput*, not distinct money.
Transfer-then-cash-out counts the same value twice for legitimate transactions
too. Fine to report as "total value processed"; not "a trillion dollars of real
money."

---

## The incumbent fraud rule is worthless

| | |
|---|---:|
| True positives | 16 |
| False positives | 0 |
| False negatives | 8,197 |
| Precision | 100.00% |
| **Recall** | **0.1948%** |
| Gross value missed | 11,978.63M |

The classic signature of a rule tuned never to produce a false positive, at the
cost of catching essentially nothing. It is retained to **quantify** the
incumbent's failure, not as a baseline worth beating.

---

## Growth: what we built, and what we deliberately did not

**No MAU. No cohort retention.** 99.85% of originators transact exactly once, the
maximum is 3, and only 0.14% are active on more than one day. A retention curve
here is ~100% churn by day 2 — a property of the simulator, not a finding.

`vw_growth_account_recurrence` exists to be **shown, not hidden**. It is the
evidence for the omission, and it turns a limitation into a demonstrated result:

| role | accounts | single-txn | multi-day | max txns |
|---|---:|---:|---:|---:|
| ORIGINATOR | 6,353,307 | 99.85% | 0.14% | 3 |
| DESTINATION | 2,722,362 | 83.12% | 16.38% | 113 |

Repeat behaviour exists **only on the destination side**, which is where
`vw_growth_top_destinations` lives.

### A wrinkle for the daily chart
Daily volume is extremely uneven. Day 0 has 574,255 transactions; **day 2 has
1,070.** These are real quiet periods in the simulation, not missing data. Day 30
is a partial day (23 hours, steps 721–743) and `is_complete_day` marks it so the
final data point is not misread as a collapse.

---

## Balance signature — counter-intuitive, and a trap

Fraudulent transactions have an almost perfectly **consistent** originator ledger
(0.55% inconsistent) while ordinary transactions are inconsistent **56.68%** of
the time. Fraud drains the account exactly; legitimate rows are full of
unexplained balance movement.

This is descriptive of PaySim's **generator**, not a real-world detection rule.
The honest claim is "fraudulent rows are ledger-exact on the originator side",
**not** "ledger-exactness predicts fraud". That caveat belongs on any chart built
from `vw_risk_balance_signature`.

---

## Open decisions before Stage D
1. **Zero-amount rows.** 16 fraudulent CASH_OUTs with `amount = 0`. Exclude them
   from the fee floor, or leave and document? Immaterial in value, but a
   reviewer will notice a fee charged on a zero-value transaction.
2. **Is the TRANSFER cap right?** It binds on 24.18% of transfers. Uncapped, the
   product still loses 1,214.82M. Raising or removing the cap changes the size of
   the loss, not its sign. Worth deciding deliberately rather than inheriting.

## Carried into Stage D
- Which views feed which visuals, and the DAX for each measure.
- Every fraud-related visual needs the deduplication caption, or the dashboard
  will silently report 12.06bn.
- The 10M CASH_OUT exhibit and the balance-signature exhibit both need
  "simulator artifact" captions — and the 10M one must say *seeded balance*, not
  *truncation cap*.
