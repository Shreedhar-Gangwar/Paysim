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

The two largest bands destroy the product. Above ~1M the 10,000 cap crushes the
effective take rate to 0.49% and then 0.07%, while fraud scales with the
transaction size, uncapped. **The cap protects the customer from a runaway fee
and hands the entire downside to us.**

This is exactly the trade-off the hybrid model was chosen to expose, and it is
the strongest argument in the project for a risk-based fee or a hard transfer
limit above 1M.

---

## The 10M CASH_OUT ceiling — a perfect (and useless) fraud rule

**Every CASH_OUT of exactly 10,000,000.00 is fraudulent. All 142 of them.**

PaySim hard-caps CASH_OUT at 10M. Fraudsters draining large accounts hit that
ceiling, so the amount truncates to exactly 10M. No legitimate transaction ever
lands on that value.

That single band is 1,420.00M of loss — 19% of all fraud loss in the dataset —
against 0.71M of fee revenue.

It is a 100%-precision detection rule and it is **entirely a simulator
artifact.** Worth showing on the dashboard as a striking exhibit; worth
captioning as an artifact, not a technique. TRANSFER has no such ceiling
(max 92,445,516.64), which is why only 145 of its 5,508 over-10M rows are fraud.

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

## Carried into Stage D
- Which views feed which visuals, and the DAX for each measure.
- Every fraud-related visual needs the deduplication caption, or the dashboard
  will silently report 12.06bn.
- The 10M CASH_OUT exhibit and the balance-signature exhibit both need
  "simulator artifact" captions.
