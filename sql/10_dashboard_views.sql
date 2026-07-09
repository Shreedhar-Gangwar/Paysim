-- =============================================================================
-- 10_dashboard_views.sql
-- Stage D: the layer Power BI actually connects to.
--
-- What this step is: the analytical views from Stage C are correct but not all
-- of them are shaped for a BI tool. This file adds what Power BI needs and
-- nothing more.
--
-- TWO PROBLEMS THIS FILE SOLVES
--
-- 1. Power BI's time intelligence (DATEADD, SAMEPERIODLASTYEAR, running totals
--    over a date hierarchy) requires a real DATE column. dim_date has none --
--    PaySim is a bare hour counter with no calendar. vw_dashboard_date below
--    anchors day 0 to an ARBITRARY date so the hierarchy works. The dates are
--    fake and must be labelled as such on every axis.
--
-- 2. dim_accounts has 9,073,900 rows and fact_transactions has 6,362,620.
--    Importing either into Power BI is unnecessary and slow. Every view here is
--    tiny (the largest is 500 rows), so the whole model imports in seconds and
--    refreshes instantly. DO NOT import the fact or account tables.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- vw_dashboard_date — a synthetic calendar so DAX time intelligence works.
--
-- Day 0 is anchored to 2024-01-01, chosen ONLY because it is a Monday, which
-- makes the synthetic Day_0..Day_6 buckets line up with a real week for anyone
-- reading the axis. The dataset has no real calendar: these dates carry NO
-- meaning beyond ordering. Every visual using them must say "simulated day".
--
-- Grain: one row per simulated DAY (31 rows), not per hour. Power BI's date
-- table must be at day grain and have no gaps, which this satisfies.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_dashboard_date AS
WITH day_bounds AS (
    -- Cast to INTEGER: day_number is SMALLINT, and generate_series has no
    -- unambiguous SMALLINT overload.
    SELECT MIN(day_number)::INTEGER AS min_day, MAX(day_number)::INTEGER AS max_day
    FROM dim_date
),
day_series AS (
    SELECT generate_series(min_day, max_day) AS day_number
    FROM day_bounds
),
hours_per_day AS (
    -- Detects the partial day at the end of the simulation (day 30 has 23 hours).
    SELECT day_number, COUNT(*) AS hours_observed
    FROM dim_date
    GROUP BY day_number
)
SELECT
    s.day_number,
    -- SYNTHETIC. Anchored at 2024-01-01 purely to give DAX a date hierarchy.
    (DATE '2024-01-01' + s.day_number)             AS simulated_date,
    'Day ' || s.day_number                         AS day_label,
    h.hours_observed,
    (h.hours_observed = 24)                        AS is_complete_day,
    -- Real weekday of the SYNTHETIC date. Useful for a week grid; meaningless
    -- as a statement about when people actually transact.
    TRIM(TO_CHAR(DATE '2024-01-01' + s.day_number, 'Day')) AS synthetic_weekday,
    ((s.day_number / 7) + 1)                       AS simulated_week
FROM day_series s
JOIN hours_per_day h ON h.day_number = s.day_number
ORDER BY s.day_number;


-- -----------------------------------------------------------------------------
-- vw_dashboard_kpi — one row, one column per headline number.
--
-- Power BI cards bind to a measure, not a row. Rather than make the report
-- author write five SUM() measures over a one-row table, this exposes each KPI
-- as its own column so each card is a trivial SUM of a single value.
--
-- fraud_loss_millions is the DEDUPLICATED figure (7,492.72M). The naive
-- 12,056.42M is exposed alongside it, deliberately, so a card showing the wrong
-- number can only be built on purpose and never by accident.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_dashboard_kpi AS
SELECT
    total_txns,
    total_value_billions,
    fee_revenue_millions,
    processing_cost_millions,
    gross_profit_millions,
    net_profit_millions,
    deduplicated_fraud_loss_millions  AS fraud_loss_millions,
    gross_fraud_loss_millions         AS fraud_loss_naive_millions,
    double_counted_millions,
    fraud_pct_of_total_value,
    -- Fraud rate by COUNT, to sit beside fraud share by VALUE. The gap between
    -- them (0.129% vs 0.655%) is the point: fraudulent transactions are ~5x
    -- the average size.
    (SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud) / COUNT(*), 4)
     FROM fact_transactions)          AS fraud_pct_of_txn_count
FROM vw_profitability_summary;


-- -----------------------------------------------------------------------------
-- vw_dashboard_daily — growth and profitability on one daily grain.
--
-- Stage C keeps these separate (vw_growth_daily_activity, vw_profitability_daily)
-- because they answer different questions. A dashboard wants them on one row per
-- day so a single date slicer drives both. Joined here rather than in Power BI,
-- where a relationship on day_number would be an unnecessary modelling step.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_dashboard_daily AS
SELECT
    g.day_number,
    d.simulated_date,
    d.is_complete_day,
    g.txn_count,
    g.total_value_millions,
    g.active_originators,
    g.active_destinations,
    g.avg_txn_value,
    p.fee_revenue_millions,
    p.processing_cost_millions,
    p.gross_profit_millions,
    p.fraud_loss_millions,
    p.net_profit_millions,
    p.cumulative_net_profit_millions
FROM vw_growth_daily_activity g
JOIN vw_profitability_daily   p ON p.day_number = g.day_number
JOIN vw_dashboard_date        d ON d.day_number = g.day_number
ORDER BY g.day_number;


-- -----------------------------------------------------------------------------
-- vw_dashboard_fraud_waterfall — the deduplication, shaped for a waterfall.
--
-- A Power BI waterfall needs signed contributions that sum to the final total.
-- vw_fraud_loss_attribution is descriptive; this restates it so the visual
-- lands on 7,492.71M and the 4,563.70M double-count appears as an explicit
-- negative bar rather than being silently dropped.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_dashboard_fraud_waterfall AS
SELECT 1 AS sort_order,
       'Naive SUM(amount) WHERE is_fraud' AS step,
       ROUND((SELECT SUM(amount) FILTER (WHERE is_fraud) FROM fact_transactions) / 1e6, 2)
           AS value_millions,
       'total' AS bar_type
UNION ALL
SELECT 2,
       'Less: duplicate CASH_OUT leg of the same theft',
       -1 * ROUND((SELECT attributed_loss FROM vw_fraud_loss_attribution
                   WHERE attributed_to = 'NOT COUNTED (duplicate leg)') / 1e6, 2),
       'decrease'
UNION ALL
SELECT 3,
       'True fraud loss',
       ROUND((SELECT SUM(attributed_loss) FROM vw_fraud_loss_attribution
              WHERE counts_toward_true_loss) / 1e6, 2),
       'total'
ORDER BY sort_order;


-- -----------------------------------------------------------------------------
-- vw_dashboard_data_caveats — the honesty layer, as data.
--
-- Every caveat that must appear on a visual, stored as rows so the dashboard can
-- render them from the model rather than relying on the report author to
-- remember them. If a caveat is in the model, it ships with the model.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_dashboard_data_caveats AS
SELECT * FROM (VALUES
    (1, 'Fraud loss',
        'Reported fraud loss is DEDUPLICATED (7,492.71M). The naive SUM(amount) WHERE is_fraud gives 12,056.42M and double-counts each two-step theft (a TRANSFER draining the victim, then a CASH_OUT of the same money).'),
    (2, 'Dates',
        'All dates are SYNTHETIC. PaySim provides an hour counter (step 1-743, ~31 days) and no calendar. Day 0 is anchored to 2024-01-01 arbitrarily so date hierarchies work.'),
    (3, 'Final day',
        'Day 30 is a PARTIAL day (23 hours, steps 721-743). Its lower totals are not a decline in activity. Filter on is_complete_day to exclude it.'),
    (4, 'Retention',
        'No MAU or cohort retention is reported. 99.85% of originating accounts transact exactly once; only 0.14% are active on more than one day. Repeat behaviour exists only on the destination side.'),
    (5, 'Balance signature',
        'Fraudulent rows are ledger-exact on the originator side (0.55% inconsistent vs 56.68% for legitimate rows). This describes PaySim''s GENERATOR. It is not a real-world fraud detection rule.'),
    (6, 'The 10M cash-outs',
        'All 142 CASH_OUTs of exactly 10,000,000.00 are fraudulent, because those victim accounts were SEEDED with exactly that balance and drained to zero. It is not a truncation cap: 2,920 legitimate TRANSFERs also sit at exactly 10M.'),
    (7, 'Fee model',
        'All revenue and cost figures rest on an INVENTED fee model (see fee_model table). PaySim contains no fee data. The ranking of segments is the finding; absolute currency values are illustrative.'),
    (8, 'Total value',
        'Total value processed (1,144.39bn) is THROUGHPUT, not distinct money. A transfer followed by a cash-out counts the same value twice, for legitimate transactions as well as fraudulent ones.'),
    (9, 'Zero-amount rows',
        '16 fraudulent CASH_OUT rows have amount = 0. They are retained as-is; the fee floor charges a nominal fee on them (~160 units total, immaterial against 8.4bn revenue).')
) AS v(caveat_id, applies_to, caveat_text);
