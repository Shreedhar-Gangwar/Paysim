-- =============================================================================
-- 09_analysis_profitability.sql
-- Stage C — PROFITABILITY pillar. Which segments make money, which lose it?
--
-- EVERY revenue and cost figure below rests on the invented assumptions in
-- 06_fee_model.sql. PaySim contains no fee data. The RANKING of segments is the
-- deliverable; the absolute currency values are illustrative.
--
-- Profit is built in three layers so each can be inspected separately:
--     fee_revenue                          -- what we charge
--   - processing_cost                      -- what it costs us to serve
--   = gross_profit
--   - fraud_loss (deduplicated, attributed)
--   = net_profit
-- =============================================================================


-- =============================================================================
-- vw_profitability_by_type
--
-- BUSINESS QUESTION: Which products are profitable once fraud is charged to the
-- segment that caused it?
--
-- FRAUD ATTRIBUTION: uses the deduplicated rule from vw_fraud_loss_attribution.
-- Charging the naive SUM(amount) WHERE is_fraud to each type would double-count
-- ~4.56bn of stolen money -- the same theft appearing as both a TRANSFER and a
-- CASH_OUT -- and would make CASH_OUT look far worse than it is.
--
-- Expect CASH_IN to be loss-making. That is CORRECT, not a bug: deposits are
-- free by design (a cost centre that feeds the float). Reporting it as a loss
-- and explaining why is the honest result.
-- =============================================================================
CREATE OR REPLACE VIEW vw_profitability_by_type AS
WITH revenue_and_cost AS (
    -- Layer 1: fee revenue and processing cost, per transaction, rolled up.
    SELECT
        t.type_name,
        COUNT(*)      AS txn_count,
        SUM(f.amount) AS total_value,
        SUM(fn_transaction_fee(f.amount, m.fee_rate, m.fee_min, m.fee_max)) AS fee_revenue,
        SUM(m.cost_per_txn)                                                 AS processing_cost,
        -- How often the cap and floor actually bind. If the cap binds on most
        -- rows the model has degenerated into a flat fee and should be retuned.
        COUNT(*) FILTER (WHERE f.amount * m.fee_rate > m.fee_max)           AS txns_hitting_cap,
        COUNT(*) FILTER (WHERE f.amount * m.fee_rate < m.fee_min)           AS txns_hitting_floor
    FROM fact_transactions f
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    JOIN fee_model m            ON m.transaction_type_key = f.transaction_type_key
    GROUP BY t.type_name
),
attributed_fraud AS (
    -- Layer 2: deduplicated fraud loss, charged to the type that took the money.
    -- The 'NOT COUNTED' row is excluded, so no theft is charged twice.
    SELECT attributed_to AS type_name, attributed_loss AS fraud_loss
    FROM vw_fraud_loss_attribution
    WHERE counts_toward_true_loss
),
combined AS (
    SELECT
        rc.type_name,
        rc.txn_count,
        rc.total_value,
        rc.fee_revenue,
        rc.processing_cost,
        rc.txns_hitting_cap,
        rc.txns_hitting_floor,
        COALESCE(af.fraud_loss, 0) AS fraud_loss
    FROM revenue_and_cost rc
    LEFT JOIN attributed_fraud af ON af.type_name = rc.type_name
)
SELECT
    type_name,
    txn_count,
    ROUND(total_value / 1e6, 2)                          AS total_value_millions,
    ROUND(fee_revenue / 1e6, 2)                          AS fee_revenue_millions,
    ROUND(processing_cost / 1e6, 2)                      AS processing_cost_millions,
    ROUND((fee_revenue - processing_cost) / 1e6, 2)      AS gross_profit_millions,
    ROUND(fraud_loss / 1e6, 2)                           AS fraud_loss_millions,
    ROUND((fee_revenue - processing_cost - fraud_loss) / 1e6, 2)
                                                         AS net_profit_millions,
    -- Revenue per transaction: exposes the volume-vs-value trade-off directly.
    ROUND(fee_revenue / txn_count, 4)                    AS avg_fee_per_txn,
    -- Effective take rate AFTER the cap and floor bite. Compare to the headline
    -- fee_rate in fee_model: a large gap means the cap is doing heavy lifting.
    ROUND(100.0 * fee_revenue / NULLIF(total_value, 0), 4) AS effective_take_rate_pct,
    txns_hitting_cap,
    txns_hitting_floor,
    ROUND(100.0 * txns_hitting_cap / txn_count, 2)       AS pct_hitting_cap,
    (fee_revenue - processing_cost - fraud_loss) < 0     AS is_loss_making
FROM combined
ORDER BY net_profit_millions DESC;


-- =============================================================================
-- vw_profitability_by_type_and_band
--
-- BUSINESS QUESTION: Within a product, which transaction SIZES make money?
--
-- This is where the cap becomes visible. Large transfers generate a fee that is
-- capped, while the fraud they attract is not -- so the biggest band can be the
-- least profitable even though it moves the most money.
--
-- Fraud loss here is GROSS (not deduplicated) because the deduplication is only
-- defined at the type level -- we know which CASH_OUT rows are duplicate legs,
-- so we exclude those rows outright rather than pro-rate them across bands.
-- =============================================================================
CREATE OR REPLACE VIEW vw_profitability_by_type_and_band AS
WITH fraudulent_transfers AS (
    SELECT f.amount, f.oldbalance_org
    FROM fact_transactions f
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    WHERE f.is_fraud AND t.type_name = 'TRANSFER'
),
duplicate_cashout_keys AS (
    -- Same rule as vw_fraud_loss_attribution: a fraudulent CASH_OUT whose
    -- (amount, starting balance) matches a fraudulent TRANSFER is the second
    -- leg of a theft already counted.
    SELECT f.transaction_key
    FROM fact_transactions f
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    WHERE f.is_fraud
      AND t.type_name = 'CASH_OUT'
      AND EXISTS (
          SELECT 1 FROM fraudulent_transfers ft
          WHERE ft.amount = f.amount AND ft.oldbalance_org = f.oldbalance_org
      )
),
banded AS (
    SELECT
        t.type_name,
        CASE
            WHEN f.amount <    10000 THEN '1. under 10K'
            WHEN f.amount <   100000 THEN '2. 10K - 100K'
            WHEN f.amount <   500000 THEN '3. 100K - 500K'
            WHEN f.amount <  1000000 THEN '4. 500K - 1M'
            WHEN f.amount < 10000000 THEN '5. 1M - 10M'
            ELSE                          '6. over 10M'
        END AS amount_band,
        f.amount,
        fn_transaction_fee(f.amount, m.fee_rate, m.fee_min, m.fee_max) AS fee,
        m.cost_per_txn,
        -- Count the theft only where it is real money leaving a victim.
        CASE
            WHEN f.is_fraud AND f.transaction_key NOT IN (SELECT transaction_key FROM duplicate_cashout_keys)
            THEN f.amount ELSE 0
        END AS attributed_fraud_loss
    FROM fact_transactions f
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    JOIN fee_model m            ON m.transaction_type_key = f.transaction_type_key
)
SELECT
    type_name,
    amount_band,
    COUNT(*)                                        AS txn_count,
    ROUND(SUM(amount) / 1e6, 2)                     AS total_value_millions,
    ROUND(SUM(fee) / 1e6, 2)                        AS fee_revenue_millions,
    ROUND(SUM(cost_per_txn) / 1e6, 2)               AS processing_cost_millions,
    ROUND(SUM(attributed_fraud_loss) / 1e6, 2)      AS fraud_loss_millions,
    ROUND((SUM(fee) - SUM(cost_per_txn) - SUM(attributed_fraud_loss)) / 1e6, 2)
                                                    AS net_profit_millions,
    ROUND(100.0 * SUM(fee) / NULLIF(SUM(amount), 0), 4) AS effective_take_rate_pct,
    (SUM(fee) - SUM(cost_per_txn) - SUM(attributed_fraud_loss)) < 0 AS is_loss_making
FROM banded
GROUP BY type_name, amount_band
ORDER BY type_name, amount_band;


-- =============================================================================
-- vw_profitability_daily
--
-- BUSINESS QUESTION: How does profitability move day by day, and does a single
-- bad day of fraud swing the month?
--
-- Feeds a combo chart: revenue bars with a net-profit line.
-- =============================================================================
CREATE OR REPLACE VIEW vw_profitability_daily AS
WITH fraudulent_transfers AS (
    SELECT f.amount, f.oldbalance_org
    FROM fact_transactions f
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    WHERE f.is_fraud AND t.type_name = 'TRANSFER'
),
duplicate_cashout_keys AS (
    SELECT f.transaction_key
    FROM fact_transactions f
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    WHERE f.is_fraud
      AND t.type_name = 'CASH_OUT'
      AND EXISTS (
          SELECT 1 FROM fraudulent_transfers ft
          WHERE ft.amount = f.amount AND ft.oldbalance_org = f.oldbalance_org
      )
),
daily AS (
    SELECT
        d.day_number,
        COUNT(*)                                                             AS txn_count,
        SUM(fn_transaction_fee(f.amount, m.fee_rate, m.fee_min, m.fee_max))  AS fee_revenue,
        SUM(m.cost_per_txn)                                                  AS processing_cost,
        SUM(CASE
                WHEN f.is_fraud
                 AND f.transaction_key NOT IN (SELECT transaction_key FROM duplicate_cashout_keys)
                THEN f.amount ELSE 0
            END)                                                             AS fraud_loss,
        COUNT(DISTINCT d.date_key)                                           AS hours_observed
    FROM fact_transactions f
    JOIN dim_date d             ON d.date_key = f.date_key
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    JOIN fee_model m            ON m.transaction_type_key = f.transaction_type_key
    GROUP BY d.day_number
)
SELECT
    day_number,
    txn_count,
    ROUND(fee_revenue / 1e6, 2)                                   AS fee_revenue_millions,
    ROUND(processing_cost / 1e6, 2)                               AS processing_cost_millions,
    ROUND((fee_revenue - processing_cost) / 1e6, 2)               AS gross_profit_millions,
    ROUND(fraud_loss / 1e6, 2)                                    AS fraud_loss_millions,
    ROUND((fee_revenue - processing_cost - fraud_loss) / 1e6, 2)  AS net_profit_millions,
    (hours_observed = 24)                                         AS is_complete_day,
    -- Running total, so the month's cumulative position is readable at a glance.
    ROUND(SUM(fee_revenue - processing_cost - fraud_loss) OVER (ORDER BY day_number) / 1e6, 2)
                                                                  AS cumulative_net_profit_millions
FROM daily
ORDER BY day_number;


-- =============================================================================
-- vw_profitability_summary
--
-- BUSINESS QUESTION: One row. Did the business make money over the period?
--
-- Also surfaces the gross-vs-deduplicated fraud figures side by side, so the
-- 12,056.41M headline and the 7,492.71M truth are both visible and the gap is
-- explicitly labelled rather than quietly resolved.
-- =============================================================================
CREATE OR REPLACE VIEW vw_profitability_summary AS
WITH totals AS (
    SELECT
        COUNT(*)                                                            AS total_txns,
        SUM(f.amount)                                                       AS total_value,
        SUM(fn_transaction_fee(f.amount, m.fee_rate, m.fee_min, m.fee_max)) AS fee_revenue,
        SUM(m.cost_per_txn)                                                 AS processing_cost,
        COALESCE(SUM(f.amount) FILTER (WHERE f.is_fraud), 0)                AS gross_fraud_loss
    FROM fact_transactions f
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    JOIN fee_model m            ON m.transaction_type_key = f.transaction_type_key
),
deduplicated_fraud AS (
    SELECT SUM(attributed_loss) AS true_fraud_loss
    FROM vw_fraud_loss_attribution
    WHERE counts_toward_true_loss
)
SELECT
    t.total_txns,
    ROUND(t.total_value / 1e9, 2)                    AS total_value_billions,
    ROUND(t.fee_revenue / 1e6, 2)                    AS fee_revenue_millions,
    ROUND(t.processing_cost / 1e6, 2)                AS processing_cost_millions,
    ROUND((t.fee_revenue - t.processing_cost) / 1e6, 2) AS gross_profit_millions,

    -- The naive number a careless analyst would report.
    ROUND(t.gross_fraud_loss / 1e6, 2)               AS gross_fraud_loss_millions,
    -- The true number, after removing the second leg of each two-step theft.
    ROUND(d.true_fraud_loss / 1e6, 2)                AS deduplicated_fraud_loss_millions,
    ROUND((t.gross_fraud_loss - d.true_fraud_loss) / 1e6, 2)
                                                     AS double_counted_millions,

    ROUND((t.fee_revenue - t.processing_cost - d.true_fraud_loss) / 1e6, 2)
                                                     AS net_profit_millions,
    -- Fraud as a share of everything we moved. Compare with the 0.129% rate by
    -- COUNT: fraudulent transactions are roughly 5x the average size.
    ROUND(100.0 * d.true_fraud_loss / t.total_value, 4) AS fraud_pct_of_total_value
FROM totals t
CROSS JOIN deduplicated_fraud d;
