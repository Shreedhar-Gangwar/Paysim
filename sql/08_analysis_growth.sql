-- =============================================================================
-- 08_analysis_growth.sql
-- Stage C — GROWTH pillar. How does activity evolve over the simulated period?
--
-- SCOPE NOTE, and it is the most important comment in this file:
-- There is NO MAU and NO cohort retention here, deliberately. Stage A measured
-- that 99.85% of originating accounts transact exactly once across the whole
-- ~31-day window, the maximum any account reaches is 3 transactions, and only
-- 0.14% are active on more than one day. A retention curve on this data would
-- show ~100% churn by day 2 -- a property of the PaySim simulator, not a
-- finding about a business. We do not build metrics the data cannot defend.
--
-- Repeat behaviour exists ONLY on the destination side (up to 113 transactions
-- per destination), so that is where the recurrence view lives.
-- =============================================================================


-- =============================================================================
-- vw_growth_daily_activity
--
-- BUSINESS QUESTION: How do transaction volume, value, and active accounts move
-- day by day across the simulated month?
--
-- "Active accounts" here means distinct originators active on that day. It is
-- an honest VOLUME measure, but note it tracks transaction count almost exactly
-- -- because accounts do not repeat. That near-identity is itself worth showing:
-- it is the clearest single exhibit of the dataset's synthetic structure.
--
-- Day 30 is a partial day: the simulation ends at step 743, so day 30 contains
-- only 23 hours (steps 721-743). is_complete_day marks it so nobody reads the
-- final data point as a collapse in activity.
-- =============================================================================
CREATE OR REPLACE VIEW vw_growth_daily_activity AS
WITH daily AS (
    SELECT
        d.day_number,
        COUNT(*)                              AS txn_count,
        SUM(f.amount)                         AS total_value,
        COUNT(DISTINCT f.orig_account_key)    AS active_originators,
        COUNT(DISTINCT f.dest_account_key)    AS active_destinations,
        COUNT(DISTINCT d.date_key)            AS hours_observed
    FROM fact_transactions f
    JOIN dim_date d ON d.date_key = f.date_key
    GROUP BY d.day_number
)
SELECT
    day_number,
    txn_count,
    ROUND(total_value, 2)                                  AS total_value,
    ROUND(total_value / 1e6, 2)                            AS total_value_millions,
    active_originators,
    active_destinations,
    ROUND(total_value / txn_count, 2)                      AS avg_txn_value,
    hours_observed,
    (hours_observed = 24)                                  AS is_complete_day,
    -- Day-over-day change in value, for a trend line. NULL on the first day.
    ROUND(total_value - LAG(total_value) OVER (ORDER BY day_number), 2)
                                                           AS value_change_vs_prior_day
FROM daily
ORDER BY day_number;


-- =============================================================================
-- vw_growth_daily_by_type
--
-- BUSINESS QUESTION: Which products drive daily activity, and does the mix
-- shift over the month?
--
-- Grain: one row per (day, transaction type). Feeds a stacked area chart.
-- =============================================================================
CREATE OR REPLACE VIEW vw_growth_daily_by_type AS
WITH daily_by_type AS (
    SELECT
        d.day_number,
        t.type_name,
        COUNT(*)      AS txn_count,
        SUM(f.amount) AS total_value
    FROM fact_transactions f
    JOIN dim_date d             ON d.date_key = f.date_key
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    GROUP BY d.day_number, t.type_name
)
SELECT
    day_number,
    type_name,
    txn_count,
    ROUND(total_value / 1e6, 2) AS total_value_millions,
    -- This type's share of that day's transactions, so the mix is directly readable.
    ROUND(100.0 * txn_count / SUM(txn_count) OVER (PARTITION BY day_number), 2)
        AS pct_of_day_txns,
    ROUND(100.0 * total_value / SUM(total_value) OVER (PARTITION BY day_number), 2)
        AS pct_of_day_value
FROM daily_by_type
ORDER BY day_number, txn_count DESC;


-- =============================================================================
-- vw_growth_hourly_profile
--
-- BUSINESS QUESTION: What does a typical day look like? When are our peak and
-- trough hours, and does that differ by product?
--
-- This is the most defensible "behaviour" chart the dataset supports: 743 hours
-- across ~31 days give a genuine, repeated 24-hour cycle. Unlike the account
-- metrics, nothing here depends on accounts recurring.
--
-- Averaged per hour-of-day across all days, so the numbers are "a typical hour".
-- =============================================================================
CREATE OR REPLACE VIEW vw_growth_hourly_profile AS
WITH hourly_totals AS (
    -- One row per (day, hour): the raw activity in that specific simulated hour.
    SELECT
        d.day_number,
        d.hour_of_day,
        COUNT(*)      AS txn_count,
        SUM(f.amount) AS total_value
    FROM fact_transactions f
    JOIN dim_date d ON d.date_key = f.date_key
    GROUP BY d.day_number, d.hour_of_day
),
averaged AS (
    -- Collapse the days: what does hour 3 look like on an average day?
    SELECT
        hour_of_day,
        COUNT(*)          AS days_observed,
        AVG(txn_count)    AS avg_txns,
        AVG(total_value)  AS avg_value,
        SUM(txn_count)    AS total_txns
    FROM hourly_totals
    GROUP BY hour_of_day
)
SELECT
    hour_of_day,
    days_observed,
    ROUND(avg_txns, 1)              AS avg_txns_per_hour,
    ROUND(avg_value / 1e6, 2)       AS avg_value_millions_per_hour,
    total_txns,
    ROUND(100.0 * total_txns / SUM(total_txns) OVER (), 2) AS pct_of_all_txns,
    -- Ranks the busiest hours; 1 = busiest.
    RANK() OVER (ORDER BY total_txns DESC)                 AS busiest_hour_rank
FROM averaged
ORDER BY hour_of_day;


-- =============================================================================
-- vw_growth_top_destinations
--
-- BUSINESS QUESTION: Where does money concentrate? Which destination accounts
-- receive the most value, and are they merchants or customers?
--
-- This is the ONLY honest place to tell a repeat-behaviour story. Destinations
-- genuinely recur (up to 113 transactions), unlike originators.
--
-- Limited to the top 500 by value received: a BI tool does not need 2.7M rows,
-- and this view is meant to feed a leaderboard visual.
-- =============================================================================
CREATE OR REPLACE VIEW vw_growth_top_destinations AS
WITH destination_activity AS (
    SELECT
        f.dest_account_key,
        COUNT(*)                          AS txns_received,
        SUM(f.amount)                     AS value_received,
        COUNT(DISTINCT d.day_number)      AS active_days,
        COUNT(*) FILTER (WHERE f.is_fraud) AS fraud_txns_received
    FROM fact_transactions f
    JOIN dim_date d ON d.date_key = f.date_key
    GROUP BY f.dest_account_key
)
SELECT
    a.account_id,
    a.party_type,
    da.txns_received,
    ROUND(da.value_received / 1e6, 2) AS value_received_millions,
    da.active_days,
    da.fraud_txns_received,
    ROUND(da.value_received / da.txns_received, 2) AS avg_value_per_txn
FROM destination_activity da
JOIN dim_accounts a ON a.account_key = da.dest_account_key
ORDER BY da.value_received DESC
LIMIT 500;


-- =============================================================================
-- vw_growth_account_recurrence
--
-- BUSINESS QUESTION: Do accounts come back? (The metric that decides whether
-- retention analysis is possible at all.)
--
-- This view exists to be SHOWN, not hidden. It is the evidence for why this
-- project reports no MAU and no cohort retention. Putting it on the dashboard
-- turns a limitation into a demonstrated finding.
-- =============================================================================
CREATE OR REPLACE VIEW vw_growth_account_recurrence AS
WITH originator_activity AS (
    SELECT
        f.orig_account_key,
        COUNT(*)                     AS txn_count,
        COUNT(DISTINCT d.day_number) AS active_days
    FROM fact_transactions f
    JOIN dim_date d ON d.date_key = f.date_key
    GROUP BY f.orig_account_key
),
destination_activity AS (
    SELECT
        f.dest_account_key,
        COUNT(*)                     AS txn_count,
        COUNT(DISTINCT d.day_number) AS active_days
    FROM fact_transactions f
    JOIN dim_date d ON d.date_key = f.date_key
    GROUP BY f.dest_account_key
)
SELECT
    'ORIGINATOR' AS account_role,
    COUNT(*)                                                        AS distinct_accounts,
    COUNT(*) FILTER (WHERE txn_count = 1)                           AS single_txn_accounts,
    ROUND(100.0 * COUNT(*) FILTER (WHERE txn_count = 1) / COUNT(*), 2)
                                                                    AS pct_single_txn,
    COUNT(*) FILTER (WHERE active_days > 1)                         AS multi_day_accounts,
    ROUND(100.0 * COUNT(*) FILTER (WHERE active_days > 1) / COUNT(*), 2)
                                                                    AS pct_multi_day,
    MAX(txn_count)                                                  AS max_txns,
    ROUND(AVG(txn_count), 3)                                        AS avg_txns
FROM originator_activity

UNION ALL

SELECT
    'DESTINATION',
    COUNT(*),
    COUNT(*) FILTER (WHERE txn_count = 1),
    ROUND(100.0 * COUNT(*) FILTER (WHERE txn_count = 1) / COUNT(*), 2),
    COUNT(*) FILTER (WHERE active_days > 1),
    ROUND(100.0 * COUNT(*) FILTER (WHERE active_days > 1) / COUNT(*), 2),
    MAX(txn_count),
    ROUND(AVG(txn_count), 3)
FROM destination_activity;
