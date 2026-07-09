-- =============================================================================
-- 05_validate_star_schema.sql
-- Stage B: prove the star schema is correct before any analysis is built on it.
--
-- What this step is: a set of checks that must ALL pass. The point is to catch
-- a silently-dropped row or a broken join now, rather than discover it later as
-- a wrong number on a dashboard. Every check prints PASS or FAIL.
-- =============================================================================

\echo '=== 1. Row count reconciliation: fact vs staging ==='
-- The fact grain is one row per transaction, so these MUST be equal.
-- An inner join that dropped rows would show up here and nowhere else.
SELECT
    (SELECT COUNT(*) FROM stg_transactions)  AS staging_rows,
    (SELECT COUNT(*) FROM fact_transactions) AS fact_rows,
    CASE WHEN (SELECT COUNT(*) FROM stg_transactions)
            = (SELECT COUNT(*) FROM fact_transactions)
         THEN 'PASS' ELSE 'FAIL' END AS result;


\echo '=== 2. Measure reconciliation: total amount and fraud count ==='
-- Row counts matching is necessary but not sufficient — the join could have
-- matched the wrong rows. Summing the measures catches that.
SELECT
    (SELECT ROUND(SUM(amount), 2) FROM stg_transactions)  AS staging_total_amount,
    (SELECT ROUND(SUM(amount), 2) FROM fact_transactions) AS fact_total_amount,
    (SELECT SUM(is_fraud) FROM stg_transactions)          AS staging_fraud_rows,
    (SELECT COUNT(*) FROM fact_transactions WHERE is_fraud) AS fact_fraud_rows,
    CASE WHEN (SELECT ROUND(SUM(amount),2) FROM stg_transactions)
            = (SELECT ROUND(SUM(amount),2) FROM fact_transactions)
         AND  (SELECT SUM(is_fraud) FROM stg_transactions)
            = (SELECT COUNT(*) FROM fact_transactions WHERE is_fraud)
         THEN 'PASS' ELSE 'FAIL' END AS result;


\echo '=== 3. Grain check: transaction_key is unique and complete ==='
SELECT
    COUNT(*)                        AS total_rows,
    COUNT(DISTINCT transaction_key) AS distinct_keys,
    CASE WHEN COUNT(*) = COUNT(DISTINCT transaction_key)
         THEN 'PASS' ELSE 'FAIL' END AS result
FROM fact_transactions;


\echo '=== 4. Referential integrity: no orphaned dimension keys ==='
-- FK constraints already enforce this at write time; we re-check explicitly
-- because a validation script that trusts the constraint proves nothing.
SELECT
    (SELECT COUNT(*) FROM fact_transactions f
       LEFT JOIN dim_date d ON d.date_key = f.date_key
      WHERE d.date_key IS NULL)                     AS orphaned_date_keys,
    (SELECT COUNT(*) FROM fact_transactions f
       LEFT JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
      WHERE t.transaction_type_key IS NULL)         AS orphaned_type_keys,
    (SELECT COUNT(*) FROM fact_transactions f
       LEFT JOIN dim_accounts a ON a.account_key = f.orig_account_key
      WHERE a.account_key IS NULL)                  AS orphaned_orig_keys,
    (SELECT COUNT(*) FROM fact_transactions f
       LEFT JOIN dim_accounts a ON a.account_key = f.dest_account_key
      WHERE a.account_key IS NULL)                  AS orphaned_dest_keys;


\echo '=== 5. Dimension row counts ==='
SELECT 'dim_date'             AS dimension, COUNT(*) AS rows FROM dim_date
UNION ALL
SELECT 'dim_transaction_type', COUNT(*) FROM dim_transaction_type
UNION ALL
SELECT 'dim_accounts',         COUNT(*) FROM dim_accounts
UNION ALL
SELECT 'fact_transactions',    COUNT(*) FROM fact_transactions;


\echo '=== 6. dim_date covers every step present in the fact, with no gaps ==='
SELECT
    MIN(date_key)        AS min_step,
    MAX(date_key)        AS max_step,
    COUNT(*)             AS dim_date_rows,
    MAX(date_key) - MIN(date_key) + 1 AS expected_rows_if_dense,
    CASE WHEN COUNT(*) = MAX(date_key) - MIN(date_key) + 1
         THEN 'PASS (dense, no gaps)' ELSE 'FAIL (gaps present)' END AS result
FROM dim_date;


\echo '=== 7. Account dimension: conformed coverage and party_type split ==='
-- Proves the dimension really is conformed: some accounts play BOTH roles.
WITH originators AS (SELECT DISTINCT orig_account_key AS k FROM fact_transactions),
     destinations AS (SELECT DISTINCT dest_account_key AS k FROM fact_transactions)
SELECT
    (SELECT COUNT(*) FROM dim_accounts)                       AS dim_account_rows,
    (SELECT COUNT(*) FROM originators)                        AS distinct_originators,
    (SELECT COUNT(*) FROM destinations)                       AS distinct_destinations,
    (SELECT COUNT(*) FROM originators i JOIN destinations d ON d.k = i.k)
                                                              AS accounts_in_both_roles;

SELECT party_type, COUNT(*) AS account_rows
FROM dim_accounts
GROUP BY party_type
ORDER BY account_rows DESC;


\echo '=== 8. Balance-error profile (quantify BEFORE Stage C relies on it) ==='
-- The residuals are direction-aware (see dim_transaction_type.orig/dest_balance_sign).
-- We measure how often each side fails its ledger identity, split by whether the
-- row is fraudulent. This tells Stage C whether balance_error is a usable fraud
-- signal or just simulator noise.
--
-- dest_balance_error IS NULL for PAYMENT (merchant balances untracked). Those
-- rows are EXCLUDED from the destination percentage rather than counted as
-- consistent — the denominator is rows where the check is defined at all.
--
-- A tolerance of 0.01 absorbs cent-level rounding in the source CSV.
SELECT
    is_fraud,
    COUNT(*)                                                          AS rows,
    SUM(CASE WHEN ABS(orig_balance_error) > 0.01 THEN 1 ELSE 0 END)   AS orig_inconsistent,
    ROUND(100.0 * SUM(CASE WHEN ABS(orig_balance_error) > 0.01 THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                              AS pct_orig_inconsistent,
    COUNT(dest_balance_error)                                         AS dest_checkable_rows,
    SUM(CASE WHEN ABS(dest_balance_error) > 0.01 THEN 1 ELSE 0 END)   AS dest_inconsistent,
    ROUND(100.0 * SUM(CASE WHEN ABS(dest_balance_error) > 0.01 THEN 1 ELSE 0 END)
          / NULLIF(COUNT(dest_balance_error), 0), 2)                  AS pct_dest_inconsistent
FROM fact_transactions
GROUP BY is_fraud
ORDER BY is_fraud;

\echo '--- 8b. Same, broken out by type (shows where the inconsistency lives) ---'
SELECT
    t.type_name,
    COUNT(*)                                                            AS rows,
    ROUND(100.0 * SUM(CASE WHEN ABS(f.orig_balance_error) > 0.01 THEN 1 ELSE 0 END)
          / COUNT(*), 2)                                                AS pct_orig_inconsistent,
    ROUND(100.0 * SUM(CASE WHEN ABS(f.dest_balance_error) > 0.01 THEN 1 ELSE 0 END)
          / NULLIF(COUNT(f.dest_balance_error), 0), 2)                  AS pct_dest_inconsistent
FROM fact_transactions f
JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
GROUP BY t.type_name
ORDER BY rows DESC;


\echo '=== 9. Fraud by type via the star schema (must match Stage A staging figures) ==='
-- Re-derives the Stage A headline through the joins. If the model is wired
-- correctly these numbers are identical to the staging profile.
SELECT
    t.type_name,
    t.is_fraud_bearing,
    COUNT(*)                                       AS txn_count,
    SUM(CASE WHEN f.is_fraud THEN 1 ELSE 0 END)    AS fraud_count,
    ROUND(100.0 * SUM(CASE WHEN f.is_fraud THEN 1 ELSE 0 END) / COUNT(*), 4) AS fraud_pct
FROM fact_transactions f
JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
GROUP BY t.type_name, t.is_fraud_bearing
ORDER BY fraud_count DESC;
