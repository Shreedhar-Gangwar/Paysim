-- =============================================================================
-- 02_inspect_staging.sql
-- Stage A: profile the raw PaySim load BEFORE designing the star schema.
--
-- Business purpose: verify what the synthetic data can honestly support —
-- especially whether accounts recur enough for MAU/cohort-style metrics,
-- and whether fraud really concentrates in TRANSFER / CASH_OUT.
-- Each query below is self-contained.
-- =============================================================================

-- 1) Row count — must reconcile with the CSV (~6.36M rows).
SELECT COUNT(*) AS total_rows
FROM stg_transactions;

-- 2) Transaction-type distribution — volume and value share per type.
SELECT
    type,
    COUNT(*)                                          AS txn_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_rows,
    ROUND(SUM(amount), 2)                             AS total_value
FROM stg_transactions
GROUP BY type
ORDER BY txn_count DESC;

-- 3) Fraud rate — overall, and by type (confirm TRANSFER/CASH_OUT concentration).
SELECT
    'ALL' AS type,
    COUNT(*)                                    AS txn_count,
    SUM(is_fraud)                               AS fraud_count,
    ROUND(100.0 * SUM(is_fraud) / COUNT(*), 4)  AS fraud_pct,
    SUM(is_flagged_fraud)                       AS flagged_count
FROM stg_transactions
UNION ALL
SELECT
    type,
    COUNT(*),
    SUM(is_fraud),
    ROUND(100.0 * SUM(is_fraud) / COUNT(*), 4),
    SUM(is_flagged_fraud)
FROM stg_transactions
GROUP BY type
ORDER BY fraud_count DESC;

-- 4) Step range — confirms the simulated time span (1 step = 1 hour).
SELECT
    MIN(step)                        AS min_step,
    MAX(step)                        AS max_step,
    COUNT(DISTINCT step)             AS distinct_steps,
    (MAX(step) - MIN(step) + 1) / 24.0 AS approx_days
FROM stg_transactions;

-- 5) Originator recurrence — how many transactions does each name_orig make?
--    This decides whether MAU / cohort retention is honestly supportable:
--    if almost every originator appears once, there is no repeat behavior
--    to build retention on.
WITH orig_activity AS (
    SELECT name_orig, COUNT(*) AS txn_count
    FROM stg_transactions
    GROUP BY name_orig
)
SELECT
    COUNT(*)                                            AS distinct_originators,
    SUM(CASE WHEN txn_count = 1 THEN 1 ELSE 0 END)      AS one_txn_only,
    ROUND(100.0 * SUM(CASE WHEN txn_count = 1 THEN 1 ELSE 0 END) / COUNT(*), 2)
                                                        AS pct_one_txn_only,
    MAX(txn_count)                                      AS max_txns_per_account,
    ROUND(AVG(txn_count), 3)                            AS avg_txns_per_account
FROM orig_activity;

-- 5b) Full distribution of transactions-per-originator (small table).
WITH orig_activity AS (
    SELECT name_orig, COUNT(*) AS txn_count
    FROM stg_transactions
    GROUP BY name_orig
)
SELECT txn_count AS txns_per_account, COUNT(*) AS n_accounts
FROM orig_activity
GROUP BY txn_count
ORDER BY txn_count;

-- 5c) Do originators recur across DAYS (not just multiple rows in one hour)?
--     Retention needs activity on more than one distinct day.
WITH orig_days AS (
    SELECT name_orig, COUNT(DISTINCT step / 24) AS active_days
    FROM stg_transactions
    GROUP BY name_orig
)
SELECT
    COUNT(*)                                       AS distinct_originators,
    SUM(CASE WHEN active_days > 1 THEN 1 ELSE 0 END) AS active_on_multiple_days,
    ROUND(100.0 * SUM(CASE WHEN active_days > 1 THEN 1 ELSE 0 END) / COUNT(*), 2)
                                                   AS pct_multi_day
FROM orig_days;

-- 6) Destination recurrence — destinations are expected to recur far more
--    (merchants M... receive many payments; C... accounts receive transfers).
WITH dest_activity AS (
    SELECT name_dest, COUNT(*) AS txn_count
    FROM stg_transactions
    GROUP BY name_dest
)
SELECT
    COUNT(*)                                            AS distinct_destinations,
    SUM(CASE WHEN txn_count = 1 THEN 1 ELSE 0 END)      AS one_txn_only,
    ROUND(100.0 * SUM(CASE WHEN txn_count = 1 THEN 1 ELSE 0 END) / COUNT(*), 2)
                                                        AS pct_one_txn_only,
    MAX(txn_count)                                      AS max_txns_per_account,
    ROUND(AVG(txn_count), 3)                            AS avg_txns_per_account
FROM dest_activity;

-- 6b) Destination account-id prefix: C = customer, M = merchant.
SELECT LEFT(name_dest, 1) AS dest_prefix, COUNT(*) AS txn_count
FROM stg_transactions
GROUP BY LEFT(name_dest, 1)
ORDER BY txn_count DESC;
