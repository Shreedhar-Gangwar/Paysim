# Power BI Build Guide — PaySim FinTech Analytics

Everything in this guide assumes the database is built (`sql/01` … `sql/10` run in
order). You build the visuals; the data layer is done.

---

## 1. Connect

**Get Data → PostgreSQL database**

| Field | Value |
|---|---|
| Server | `localhost:5432` |
| Database | `paysim` |
| Data Connectivity mode | **Import** |

Credentials: `postgres` / the password in your local `.env`. Power BI stores this
in its own credential manager — it never enters the `.pbix` file.

### Import ONLY these views

| View | Rows | Feeds |
|---|---:|---|
| `vw_dashboard_kpi` | 1 | KPI cards |
| `vw_dashboard_date` | 31 | The date table |
| `vw_dashboard_daily` | 31 | Activity + profitability over time |
| `vw_dashboard_fraud_waterfall` | 3 | Fraud deduplication waterfall |
| `vw_dashboard_data_caveats` | 9 | Caveat panel |
| `vw_growth_daily_by_type` | 152 | Product mix over time |
| `vw_growth_hourly_profile` | 24 | Hour-of-day profile |
| `vw_growth_top_destinations` | 500 | Destination leaderboard |
| `vw_growth_account_recurrence` | 2 | The "why no retention" exhibit |
| `vw_risk_fraud_by_type` | 5 | Fraud by product |
| `vw_risk_fraud_by_amount_band` | 6 | Fraud by transaction size |
| `vw_risk_flagged_vs_actual` | 1 | Incumbent-rule confusion matrix |
| `vw_risk_balance_signature` | 7 | Ledger-consistency exhibit |
| `vw_profitability_by_type` | 5 | Profit by product |
| `vw_profitability_by_type_and_band` | 24 | Profit heatmap |

**Do NOT import `fact_transactions` (6,362,620 rows) or `dim_accounts`
(9,073,900 rows).** Nothing on this dashboard needs them. Every view above is
pre-aggregated in Postgres, where the indexes are; the entire model imports in
seconds and refreshes instantly. Importing the fact table would give you a
multi-hundred-MB `.pbix` and gain nothing.

### Before the first refresh: the materialized view

`mv_duplicate_cashout_legs` holds the 3,933 duplicate fraud legs and underpins
every deduplicated fraud number. It does **not** update itself. If the star
schema is ever rebuilt, refresh it before refreshing Power BI:

```sql
REFRESH MATERIALIZED VIEW mv_duplicate_cashout_legs;
```

Skip this after a reload and the fraud figures silently revert toward the naive
12,056.42M.

### Expected refresh cost

A full import of all 15 views takes roughly **35 seconds**, almost all of it in
one view:

| View | Time |
|---|---:|
| `vw_growth_top_destinations` | ~25s (aggregates 2.7M destinations) |
| `vw_profitability_by_type_and_band` | ~1.9s |
| `vw_dashboard_daily` | ~1.1s |
| `vw_profitability_by_type` | ~1.0s |
| everything else | < 1s each |

If a refresh takes minutes rather than seconds, something has regressed — check
that `fn_transaction_fee` is still declared `IMMUTABLE PARALLEL SAFE` and **not**
`STRICT`. That one keyword is the difference between the fee aggregate running in
0.9 seconds and 40 seconds, because a STRICT SQL function whose body is
non-strict cannot be inlined by the planner.

---

## 2. Model the date table

PaySim has **no calendar**. `vw_dashboard_date` anchors simulated day 0 to
2024-01-01 — a Monday, chosen only so weekday labels line up sensibly. The dates
are fake. They exist so DAX time intelligence works at all.

1. Select `vw_dashboard_date`.
2. **Table tools → Mark as date table**, choose `simulated_date`.
3. Create relationships (both single-direction, one-to-many from the date table):

| From | To | Cardinality |
|---|---|---|
| `vw_dashboard_date[day_number]` | `vw_dashboard_daily[day_number]` | 1 → * |
| `vw_dashboard_date[day_number]` | `vw_growth_daily_by_type[day_number]` | 1 → * |

Every other view is standalone. Do not relate them — they sit at different
grains, and a relationship would silently produce wrong cross-filtered numbers.

> **Label every date axis "Simulated day".** A reader who sees "Jan 2024" will
> assume it is real. It is not.

---

## 3. DAX measures

Create a blank table named `_Measures` (**Enter data → OK**, then hide the
column) and put every measure in it. Keeps them out of the tables.

### 3.1 Headline KPIs

```dax
Total Transactions = SUM(vw_dashboard_kpi[total_txns])

Total Value (bn) = SUM(vw_dashboard_kpi[total_value_billions])

Fee Revenue (M) = SUM(vw_dashboard_kpi[fee_revenue_millions])

Gross Profit (M) = SUM(vw_dashboard_kpi[gross_profit_millions])

Net Profit (M) = SUM(vw_dashboard_kpi[net_profit_millions])

-- The DEDUPLICATED figure. This is the only fraud loss number that belongs
-- on a card. See "Fraud Loss (naive)" below for why.
Fraud Loss (M) = SUM(vw_dashboard_kpi[fraud_loss_millions])

-- Exists so the waterfall can show what a careless analyst would report.
-- Never put this on a card by itself.
Fraud Loss naive (M) = SUM(vw_dashboard_kpi[fraud_loss_naive_millions])

Fraud % of Value = SUM(vw_dashboard_kpi[fraud_pct_of_total_value])

Fraud % of Count = SUM(vw_dashboard_kpi[fraud_pct_of_txn_count])

-- Fraud eats 89% of gross profit. This is the single most arresting number
-- in the project.
Fraud as % of Gross Profit =
DIVIDE (
    [Fraud Loss (M)],
    [Gross Profit (M)]
)
```

### 3.2 Growth

```dax
Daily Transactions = SUM(vw_dashboard_daily[txn_count])

Daily Value (M) = SUM(vw_dashboard_daily[total_value_millions])

Active Originators = SUM(vw_dashboard_daily[active_originators])

-- Excludes the partial final day (day 30 has only 23 hours), so the trend
-- line does not end in a phantom cliff.
Daily Value (complete days only) (M) =
CALCULATE (
    [Daily Value (M)],
    vw_dashboard_daily[is_complete_day] = TRUE
)

-- 7-day moving average. The daily series is extremely spiky
-- (day 0 = 574,255 txns; day 2 = 1,070), so the raw line is hard to read.
Value 7d Moving Avg (M) =
AVERAGEX (
    DATESINPERIOD (
        vw_dashboard_date[simulated_date],
        LASTDATE ( vw_dashboard_date[simulated_date] ),
        -7,
        DAY
    ),
    [Daily Value (M)]
)

Cumulative Net Profit (M) = SUM(vw_dashboard_daily[cumulative_net_profit_millions])
```

### 3.3 Risk

```dax
Fraud Transactions = SUM(vw_risk_fraud_by_type[fraud_txns])

-- RECOMPUTE the rate; never average a percentage column. Averaging
-- fraud_rate_pct across types weights CASH_IN's 0% equally with TRANSFER's
-- 0.77% and gives a meaningless answer.
Fraud Rate % =
DIVIDE (
    SUM ( vw_risk_fraud_by_type[fraud_txns] ),
    SUM ( vw_risk_fraud_by_type[total_txns] )
) * 100

Incumbent Rule Recall % =
DIVIDE (
    SUM ( vw_risk_flagged_vs_actual[true_positives] ),
    SUM ( vw_risk_flagged_vs_actual[true_positives] )
        + SUM ( vw_risk_flagged_vs_actual[false_negatives] )
) * 100

Frauds Missed = SUM(vw_risk_flagged_vs_actual[false_negatives])

Value Missed (M) = SUM(vw_risk_flagged_vs_actual[gross_value_missed_millions])
```

### 3.4 Profitability

```dax
Net Profit by Type (M) = SUM(vw_profitability_by_type[net_profit_millions])

Fee Revenue by Type (M) = SUM(vw_profitability_by_type[fee_revenue_millions])

Fraud Loss by Type (M) = SUM(vw_profitability_by_type[fraud_loss_millions])

-- Again: recompute, do not average. The effective take rate is a
-- value-weighted ratio; averaging the per-band column is wrong.
Effective Take Rate % =
DIVIDE (
    SUM ( vw_profitability_by_type[fee_revenue_millions] ),
    SUM ( vw_profitability_by_type[total_value_millions] )
) * 100

-- Drives conditional formatting: red where a segment destroys value.
Is Loss Making =
IF ( [Net Profit by Type (M)] < 0, 1, 0 )

Net Profit Band (M) = SUM(vw_profitability_by_type_and_band[net_profit_millions])
```

> **The two `DIVIDE` measures above are the ones an interviewer will probe.**
> `AVERAGE(fraud_rate_pct)` and `AVERAGE(effective_take_rate_pct)` both look
> correct and are both wrong — they average ratios instead of dividing the
> summed numerator by the summed denominator. Being able to explain that
> distinction is worth more than any visual on this dashboard.

---

## 4. Pages and visuals

### Page 1 — Overview

| Visual | Type | Fields |
|---|---|---|
| KPI row (5 cards) | Card | `Total Transactions`, `Total Value (bn)`, `Net Profit (M)`, `Fraud Loss (M)`, `Fraud as % of Gross Profit` |
| Activity over time | Line chart | Axis `simulated_date`; Values `Daily Value (M)`, `Value 7d Moving Avg (M)` |
| Product mix | Stacked column | Axis `simulated_date`; Legend `type_name`; Values `txn_count` (from `vw_growth_daily_by_type`) |
| Net profit by product | Bar chart | Axis `type_name`; Values `Net Profit by Type (M)`; conditional colour on `Is Loss Making` |
| Caveats | Table | `vw_dashboard_data_caveats[applies_to]`, `[caveat_text]` |

Put the caveats table on page 1, not buried at the back. It is the difference
between a dashboard that looks credible and one that *is* credible.

### Page 2 — Growth

| Visual | Type | Fields |
|---|---|---|
| Daily volume & value | Line and clustered column | Axis `simulated_date`; Column `Daily Transactions`; Line `Daily Value (M)` |
| Hour-of-day profile | Column chart | Axis `hour_of_day`; Values `avg_txns_per_hour` (`vw_growth_hourly_profile`) |
| Active accounts vs transactions | Line chart | Axis `simulated_date`; Values `Active Originators`, `Daily Transactions` |
| **Why no retention** | Table | `vw_growth_account_recurrence`: `account_role`, `distinct_accounts`, `pct_single_txn`, `pct_multi_day`, `max_txns` |
| Top destinations | Table | `vw_growth_top_destinations`, sorted by `value_received_millions` desc |

The "Active accounts vs transactions" chart is deliberately two lines that sit
almost on top of each other. **That is the finding.** Accounts do not repeat, so
active accounts ≈ transaction count. Caption it.

The recurrence table is the evidence for why this project reports no MAU and no
cohort retention. Showing it converts an omission into a demonstrated result.

### Page 3 — Risk

| Visual | Type | Fields |
|---|---|---|
| Fraud rate by product | Bar chart | Axis `type_name`; Values `fraud_rate_pct` (`vw_risk_fraud_by_type`) |
| Fraud value by product | Bar chart | Axis `type_name`; Values `gross_fraud_value_millions` |
| **Fraud loss waterfall** | Waterfall | Category `step`; Y `value_millions`; from `vw_dashboard_fraud_waterfall` |
| Fraud by transaction size | Column chart | Axis `amount_band`; Values `fraud_rate_pct`, `pct_of_all_fraud_value` |
| Incumbent rule | Multi-row card | `true_positives`, `false_positives`, `Frauds Missed`, `Incumbent Rule Recall %` |
| Ledger consistency | Clustered bar | Axis `type_name`; Legend `is_fraud`; Values `pct_orig_inconsistent` |

Two visuals here need captions or they will mislead:

- **The waterfall** is the point of the page. It shows 12,056.42M → −4,563.70M →
  7,492.72M. Title it "Fraud loss, before and after removing double-counted
  thefts."
- **Ledger consistency** shows fraudulent rows are *more* internally consistent
  than legitimate ones (0.55% vs 56.68% inconsistent). Caption:
  *"A property of PaySim's generator, not a real-world detection rule."*

### Page 4 — Profitability

| Visual | Type | Fields |
|---|---|---|
| Profit bridge by product | Clustered bar | Axis `type_name`; Values `Fee Revenue by Type (M)`, `Fraud Loss by Type (M)`, `Net Profit by Type (M)` |
| **Profit heatmap** | Matrix | Rows `type_name`; Columns `amount_band`; Values `Net Profit Band (M)`; background colour diverging red→green through 0 |
| Effective take rate | Column chart | Axis `type_name`; Values `Effective Take Rate %` |
| Cumulative profit | Area chart | Axis `simulated_date`; Values `Cumulative Net Profit (M)` |
| Fee model assumptions | Table | Import `fee_model` joined to `dim_transaction_type` if you want it visible |

The matrix is the most valuable visual in the project. TRANSFER's `1M–10M` cell
(−2,587.43M) and `over 10M` cell (−1,394.93M) go deep red beside profitable
mid-size bands. That single view carries the entire argument.

---

## 5. Things that will bite you

**Fraud loss will read 12,056.42M if you build it from the fact table.** You are
not importing the fact table, so this cannot happen — but if you add it later,
remember that `SUM(amount) WHERE is_fraud` double-counts each two-step theft.

**Do not average `fraud_rate_pct` or `effective_take_rate_pct`.** See §3.4.

**Day 30 is 23 hours long.** Any daily chart ends on an artificial dip. Use
`Daily Value (complete days only) (M)` or filter `is_complete_day = TRUE`.

**Daily volume is genuinely spiky, not broken.** Day 0 has 574,255 transactions;
day 2 has 1,070. Those are real quiet periods in the simulation. The 7-day moving
average makes the series readable without hiding them.

**CASH_IN shows a loss (−4.20M). This is correct.** Deposits are free by design —
a cost centre that feeds the float. If someone "fixes" it by charging a deposit
fee, the model no longer describes how mobile money actually works.

**Every currency figure rests on an invented fee model.** PaySim has no fee data.
Say so on the page. The ranking of segments is the finding; the absolute numbers
are illustrative.

---

## 6. The four numbers to lead with

If you get sixty seconds to present this:

1. **Fraud consumes 89% of gross profit** — 7,492.72M against 8,426.28M.
2. **TRANSFER moves the most value of any product and loses the most money**
   (−3,206.44M). It stays loss-making even with the fee cap removed, so this is
   a fraud problem, not a pricing problem.
3. **The naive fraud number is 38% too high.** 12,056.42M vs a true 7,492.72M,
   because PaySim writes each theft twice — a TRANSFER out of the victim's
   account and a CASH_OUT of the same money.
4. **The existing fraud rule catches 16 of 8,213 frauds** — 0.19% recall at
   100% precision. It was tuned never to raise a false alarm and consequently
   never raises one.
