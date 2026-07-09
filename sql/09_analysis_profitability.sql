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
    --
    -- PERFORMANCE: we group by the fact's SMALLINT transaction_type_key and only
    -- resolve type_name afterwards. Grouping directly on dim_transaction_type
    -- .type_name lets the planner satisfy the downstream merge join by walking
    -- idx_fact_type -- a nested-loop index scan over all 6.36M rows with ~424k
    -- random heap reads, which took 89 SECONDS to return five rows. Grouping on
    -- the integer key instead gives a sequential scan into a hash aggregate.
    SELECT
        f.transaction_type_key,
        COUNT(*)      AS txn_count,
        SUM(f.amount) AS total_value,
        SUM(fn_transaction_fee(f.amount, m.fee_rate, m.fee_min, m.fee_max)) AS fee_revenue,
        SUM(m.cost_per_txn)                                                 AS processing_cost,
        -- How often the cap and floor actually bind. If the cap binds on most
        -- rows the model has degenerated into a flat fee and should be retuned.
        COUNT(*) FILTER (WHERE f.amount * m.fee_rate > m.fee_max)           AS txns_hitting_cap,
        COUNT(*) FILTER (WHERE f.amount * m.fee_rate < m.fee_min)           AS txns_hitting_floor
    FROM fact_transactions f
    JOIN fee_model m ON m.transaction_type_key = f.transaction_type_key
    GROUP BY f.transaction_type_key
),
revenue_and_cost_named AS (
    -- Attach the label to five aggregated rows, not to 6.36M raw ones.
    SELECT t.type_name, rc.*
    FROM revenue_and_cost rc
    JOIN dim_transaction_type t ON t.transaction_type_key = rc.transaction_type_key
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
    FROM revenue_and_cost_named rc
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
WITH banded AS (
    -- PERFORMANCE: band as a SMALLINT id, and group by the fact's integer type
    -- key. Grouping by the text type_name and the text CASE label makes the
    -- planner sort all 6.36M rows (external merge, ~98MB spilled to disk, ~14s).
    -- Grouping on two small integers gives a hash aggregate over 30 groups.
    -- The human-readable labels are attached afterwards, to 30 rows.
    SELECT
        f.transaction_type_key,
        CASE
            WHEN f.amount <    10000 THEN 1
            WHEN f.amount <   100000 THEN 2
            WHEN f.amount <   500000 THEN 3
            WHEN f.amount <  1000000 THEN 4
            WHEN f.amount < 10000000 THEN 5
            ELSE                          6
        END::SMALLINT AS band_id,
        f.amount,
        fn_transaction_fee(f.amount, m.fee_rate, m.fee_min, m.fee_max) AS fee,
        m.cost_per_txn,
        -- Count the theft only where it is real money leaving a victim: exclude
        -- the duplicate CASH_OUT leg (see mv_duplicate_cashout_legs in 07).
        --
        -- PERFORMANCE: a LEFT JOIN evaluated once, not a correlated NOT EXISTS
        -- inside the CASE. The correlated form issues 6.36M index lookups and
        -- takes ~14s; the hash anti-join takes ~1s. dup.transaction_key IS NULL
        -- means "this row is not a duplicate leg".
        CASE
            WHEN f.is_fraud AND dup.transaction_key IS NULL
            THEN f.amount ELSE 0
        END AS attributed_fraud_loss
    FROM fact_transactions f
    JOIN fee_model m                 ON m.transaction_type_key = f.transaction_type_key
    LEFT JOIN mv_duplicate_cashout_legs dup
                                     ON dup.transaction_key = f.transaction_key
),
aggregated AS (
    -- 30 rows out of 6.36M, via a hash aggregate on two integer keys.
    SELECT
        transaction_type_key,
        band_id,
        COUNT(*)                      AS txn_count,
        SUM(amount)                   AS total_value,
        SUM(fee)                      AS fee_revenue,
        SUM(cost_per_txn)             AS processing_cost,
        SUM(attributed_fraud_loss)    AS fraud_loss
    FROM banded
    GROUP BY transaction_type_key, band_id
),
band_labels AS (
    SELECT * FROM (VALUES
        (1::SMALLINT, '1. under 10K'),
        (2::SMALLINT, '2. 10K - 100K'),
        (3::SMALLINT, '3. 100K - 500K'),
        (4::SMALLINT, '4. 500K - 1M'),
        (5::SMALLINT, '5. 1M - 10M'),
        (6::SMALLINT, '6. over 10M')
    ) AS v(band_id, amount_band)
)
SELECT
    t.type_name,
    bl.amount_band,
    a.txn_count,
    ROUND(a.total_value / 1e6, 2)                    AS total_value_millions,
    ROUND(a.fee_revenue / 1e6, 2)                    AS fee_revenue_millions,
    ROUND(a.processing_cost / 1e6, 2)                AS processing_cost_millions,
    ROUND(a.fraud_loss / 1e6, 2)                     AS fraud_loss_millions,
    ROUND((a.fee_revenue - a.processing_cost - a.fraud_loss) / 1e6, 2)
                                                     AS net_profit_millions,
    ROUND(100.0 * a.fee_revenue / NULLIF(a.total_value, 0), 4) AS effective_take_rate_pct,
    (a.fee_revenue - a.processing_cost - a.fraud_loss) < 0     AS is_loss_making
FROM aggregated a
JOIN dim_transaction_type t ON t.transaction_type_key = a.transaction_type_key
JOIN band_labels bl         ON bl.band_id = a.band_id
ORDER BY t.type_name, bl.amount_band;


-- =============================================================================
-- vw_profitability_daily
--
-- BUSINESS QUESTION: How does profitability move day by day, and does a single
-- bad day of fraud swing the month?
--
-- Feeds a combo chart: revenue bars with a net-profit line.
-- =============================================================================
CREATE OR REPLACE VIEW vw_profitability_daily AS
WITH daily AS (
    SELECT
        d.day_number,
        COUNT(*)                                                             AS txn_count,
        SUM(fn_transaction_fee(f.amount, m.fee_rate, m.fee_min, m.fee_max))  AS fee_revenue,
        SUM(m.cost_per_txn)                                                  AS processing_cost,
        -- Excludes the duplicate CASH_OUT leg (see mv_duplicate_cashout_legs).
        -- LEFT JOIN anti-join rather than a correlated NOT EXISTS: see the note
        -- in vw_profitability_by_type_and_band.
        SUM(CASE
                WHEN f.is_fraud AND dup.transaction_key IS NULL
                THEN f.amount ELSE 0
            END)                                                             AS fraud_loss,
        COUNT(DISTINCT d.date_key)                                           AS hours_observed
    FROM fact_transactions f
    JOIN dim_date d             ON d.date_key = f.date_key
    JOIN fee_model m            ON m.transaction_type_key = f.transaction_type_key
    LEFT JOIN mv_duplicate_cashout_legs dup ON dup.transaction_key = f.transaction_key
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
