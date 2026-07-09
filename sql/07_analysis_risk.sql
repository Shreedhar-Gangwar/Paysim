-- =============================================================================
-- 07_analysis_risk.sql
-- Stage C — RISK pillar. Where does fraud concentrate, and what does it cost?
--
-- The deduplication view below is the foundation for the fraud figures used in
-- every other view, including profitability. Read it first.
-- =============================================================================


-- =============================================================================
-- vw_fraud_loss_attribution
--
-- BUSINESS QUESTION: How much money did fraud actually take from us?
--
-- The naive answer, SUM(amount) WHERE is_fraud, is 12,056.41M. It is WRONG,
-- and overstates the loss by 38%.
--
-- PaySim generates most fraud as a two-step: the victim's account is drained by
-- a TRANSFER, and the same money is then withdrawn by a CASH_OUT. Both rows are
-- flagged is_fraud, so summing them counts the same stolen money twice.
--
-- Evidence (measured, not assumed):
--   * Matching fraudulent TRANSFER to fraudulent CASH_OUT on BOTH amount and
--     originator starting balance yields 3,937 pairs over 3,931 distinct
--     signatures -- effectively one-to-one.
--   * 3,933 of those 3,937 pairs occur in the SAME simulation hour.
--   * In 3,943 of 4,097 fraudulent TRANSFERs, amount = oldbalance_org exactly:
--     fraud drains the victim account to zero.
--
-- The account ids do NOT link the two legs (zero fraudulent CASH_OUTs originate
-- from the account a fraudulent TRANSFER landed in). PaySim relabels the
-- account between legs, so the pair is only detectable via the
-- (amount, starting balance) signature. This means we can identify the
-- duplication statistically but CANNOT trace a fraud chain account-to-account.
--
-- ATTRIBUTION RULE: the loss belongs to the transaction that took the money
-- from the victim.
--   * Every fraudulent TRANSFER is a real theft -> charged to TRANSFER.
--   * A fraudulent CASH_OUT that matches a TRANSFER is the second leg of a
--     theft already counted -> charged to nobody (it is not new money).
--   * A fraudulent CASH_OUT with no matching TRANSFER is an independent theft
--     -> charged to CASH_OUT.
-- =============================================================================
CREATE OR REPLACE VIEW vw_fraud_loss_attribution AS
WITH fraudulent_transfers AS (
    -- The first leg: money leaving the victim's account.
    SELECT f.transaction_key, f.amount, f.oldbalance_org
    FROM fact_transactions f
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    WHERE f.is_fraud
      AND t.type_name = 'TRANSFER'
),
fraudulent_cashouts AS (
    -- The second leg: the same money being withdrawn -- or an independent theft.
    SELECT f.transaction_key, f.amount, f.oldbalance_org
    FROM fact_transactions f
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    WHERE f.is_fraud
      AND t.type_name = 'CASH_OUT'
),
duplicate_cashouts AS (
    -- A cash-out is a duplicate if some fraudulent transfer shares its exact
    -- amount AND originator starting balance. EXISTS (not JOIN) so that a
    -- cash-out is counted once even if several transfers share the signature.
    SELECT c.transaction_key
    FROM fraudulent_cashouts c
    WHERE EXISTS (
        SELECT 1
        FROM fraudulent_transfers t
        WHERE t.amount         = c.amount
          AND t.oldbalance_org = c.oldbalance_org
    )
),
attributed_loss AS (
    SELECT 'TRANSFER' AS attributed_to,
           'First leg of theft: money taken from the victim account' AS basis,
           COUNT(*)     AS fraud_txns,
           SUM(amount)  AS attributed_loss
    FROM fraudulent_transfers

    UNION ALL

    SELECT 'CASH_OUT',
           'Independent theft: fraudulent cash-out with no matching transfer',
           COUNT(*),
           SUM(c.amount)
    FROM fraudulent_cashouts c
    WHERE c.transaction_key NOT IN (SELECT transaction_key FROM duplicate_cashouts)

    UNION ALL

    SELECT 'NOT COUNTED (duplicate leg)',
           'Second leg of a theft already attributed to TRANSFER -- not new money',
           COUNT(*),
           SUM(c.amount)
    FROM fraudulent_cashouts c
    WHERE c.transaction_key IN (SELECT transaction_key FROM duplicate_cashouts)
)
SELECT
    attributed_to,
    basis,
    fraud_txns,
    ROUND(attributed_loss, 2)         AS attributed_loss,
    ROUND(attributed_loss / 1e6, 2)   AS attributed_loss_millions,
    -- Excludes the duplicate row from the "real loss" total.
    attributed_to <> 'NOT COUNTED (duplicate leg)' AS counts_toward_true_loss
FROM attributed_loss
ORDER BY attributed_loss DESC;


-- =============================================================================
-- vw_risk_fraud_by_type
--
-- BUSINESS QUESTION: Which transaction types carry fraud, how often, and how
-- badly does our incumbent detection rule perform on each?
--
-- Note the two different denominators: fraud RATE is per transaction, fraud
-- VALUE SHARE is per currency unit. They rank types differently, which is the
-- point -- TRANSFER is rarer but far more expensive per event.
-- =============================================================================
CREATE OR REPLACE VIEW vw_risk_fraud_by_type AS
WITH per_type AS (
    SELECT
        t.type_name,
        t.is_fraud_bearing,
        COUNT(*)                                                  AS total_txns,
        SUM(f.amount)                                             AS total_value,
        COUNT(*) FILTER (WHERE f.is_fraud)                        AS fraud_txns,
        COALESCE(SUM(f.amount) FILTER (WHERE f.is_fraud), 0)      AS gross_fraud_value,
        COUNT(*) FILTER (WHERE f.is_flagged_fraud)                AS flagged_txns,
        -- True positives of the incumbent rule.
        COUNT(*) FILTER (WHERE f.is_flagged_fraud AND f.is_fraud) AS flagged_and_fraud
    FROM fact_transactions f
    JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
    GROUP BY t.type_name, t.is_fraud_bearing
)
SELECT
    type_name,
    is_fraud_bearing,
    total_txns,
    fraud_txns,
    ROUND(100.0 * fraud_txns / total_txns, 4)               AS fraud_rate_pct,
    ROUND(gross_fraud_value / 1e6, 2)                       AS gross_fraud_value_millions,
    -- Gross: still contains the double-counted second leg. See
    -- vw_fraud_loss_attribution for the deduplicated figure.
    ROUND(100.0 * gross_fraud_value / NULLIF(total_value, 0), 4) AS fraud_pct_of_type_value,
    ROUND(AVG_fraud.avg_fraud_amount, 2)                    AS avg_fraud_amount,
    flagged_txns,
    flagged_and_fraud,
    -- Recall of PaySim's incumbent rule, per type. It is catastrophically bad.
    ROUND(100.0 * flagged_and_fraud / NULLIF(fraud_txns, 0), 4) AS incumbent_rule_recall_pct
FROM per_type
CROSS JOIN LATERAL (
    SELECT CASE WHEN fraud_txns > 0 THEN gross_fraud_value / fraud_txns END AS avg_fraud_amount
) AS AVG_fraud
ORDER BY fraud_txns DESC;


-- =============================================================================
-- vw_risk_fraud_by_amount_band
--
-- BUSINESS QUESTION: At what transaction sizes does fraud concentrate? If fraud
-- clusters in a band, an amount threshold is a cheap first-line control.
--
-- Bands are fixed and documented rather than computed as quantiles, so the view
-- stays stable and comparable if the data is reloaded.
-- =============================================================================
CREATE OR REPLACE VIEW vw_risk_fraud_by_amount_band AS
WITH banded AS (
    SELECT
        CASE
            WHEN f.amount <        10000 THEN '1. under 10K'
            WHEN f.amount <       100000 THEN '2. 10K - 100K'
            WHEN f.amount <       500000 THEN '3. 100K - 500K'
            WHEN f.amount <      1000000 THEN '4. 500K - 1M'
            WHEN f.amount <     10000000 THEN '5. 1M - 10M'
            ELSE                              '6. over 10M'
        END                                             AS amount_band,
        f.amount,
        f.is_fraud
    FROM fact_transactions f
)
SELECT
    amount_band,
    COUNT(*)                                                     AS total_txns,
    COUNT(*) FILTER (WHERE is_fraud)                             AS fraud_txns,
    ROUND(100.0 * COUNT(*) FILTER (WHERE is_fraud) / COUNT(*), 4) AS fraud_rate_pct,
    ROUND(COALESCE(SUM(amount) FILTER (WHERE is_fraud), 0) / 1e6, 2)
                                                                 AS gross_fraud_value_millions,
    -- Share of ALL fraudulent value that sits in this band.
    ROUND(100.0 * COALESCE(SUM(amount) FILTER (WHERE is_fraud), 0)
          / SUM(SUM(amount) FILTER (WHERE is_fraud)) OVER (), 2) AS pct_of_all_fraud_value
FROM banded
GROUP BY amount_band
ORDER BY amount_band;


-- =============================================================================
-- vw_risk_flagged_vs_actual
--
-- BUSINESS QUESTION: How good is the fraud rule we already have?
--
-- Answer: almost useless. It fires 16 times against 8,213 actual frauds.
-- This view exists to QUANTIFY the incumbent rule's failure, not to serve as a
-- baseline worth beating. Precision is perfect and recall is ~0.19% -- the
-- classic signature of a rule tuned to never produce a false positive, at the
-- cost of catching essentially nothing.
-- =============================================================================
CREATE OR REPLACE VIEW vw_risk_flagged_vs_actual AS
WITH confusion AS (
    SELECT
        COUNT(*) FILTER (WHERE is_fraud AND is_flagged_fraud)         AS true_positives,
        COUNT(*) FILTER (WHERE NOT is_fraud AND is_flagged_fraud)     AS false_positives,
        COUNT(*) FILTER (WHERE is_fraud AND NOT is_flagged_fraud)     AS false_negatives,
        COUNT(*) FILTER (WHERE NOT is_fraud AND NOT is_flagged_fraud) AS true_negatives,
        -- Money the rule let through.
        COALESCE(SUM(amount) FILTER (WHERE is_fraud AND NOT is_flagged_fraud), 0)
                                                                      AS value_missed
    FROM fact_transactions
)
SELECT
    true_positives,
    false_positives,
    false_negatives,
    true_negatives,
    ROUND(100.0 * true_positives / NULLIF(true_positives + false_positives, 0), 2) AS precision_pct,
    ROUND(100.0 * true_positives / NULLIF(true_positives + false_negatives, 0), 4) AS recall_pct,
    ROUND(value_missed / 1e6, 2) AS gross_value_missed_millions
FROM confusion;


-- =============================================================================
-- vw_risk_balance_signature
--
-- BUSINESS QUESTION: Does the ledger's internal consistency reveal fraud?
--
-- Finding, and it is COUNTER-INTUITIVE: fraudulent transactions have an almost
-- perfectly CONSISTENT originator ledger (0.55% inconsistent) while ordinary
-- transactions are inconsistent 56.68% of the time. Fraud drains the account
-- exactly; legitimate rows are full of unexplained balance movement.
--
-- IMPORTANT CAVEAT, and it belongs on any chart built from this view:
-- this is descriptive of PaySim's GENERATOR, not a real-world detection rule.
-- The honest claim is "fraudulent rows are ledger-exact on the originator
-- side", NOT "ledger-exactness predicts fraud".
--
-- dest_balance_error IS NULL for PAYMENT (merchant balances are never populated
-- by PaySim). Those rows are excluded from the destination denominator rather
-- than counted as consistent -- COUNT(col) ignores NULLs, which is exactly what
-- we want here.
-- =============================================================================
CREATE OR REPLACE VIEW vw_risk_balance_signature AS
SELECT
    t.type_name,
    f.is_fraud,
    COUNT(*)                                                                AS txns,
    -- Originator side: defined for every row.
    COUNT(*) FILTER (WHERE ABS(f.orig_balance_error) > 0.01)                AS orig_inconsistent,
    ROUND(100.0 * COUNT(*) FILTER (WHERE ABS(f.orig_balance_error) > 0.01)
          / COUNT(*), 2)                                                    AS pct_orig_inconsistent,
    -- Destination side: NULL rows (PAYMENT) drop out of both numerator and denominator.
    COUNT(f.dest_balance_error)                                             AS dest_checkable_txns,
    COUNT(*) FILTER (WHERE ABS(f.dest_balance_error) > 0.01)                AS dest_inconsistent,
    ROUND(100.0 * COUNT(*) FILTER (WHERE ABS(f.dest_balance_error) > 0.01)
          / NULLIF(COUNT(f.dest_balance_error), 0), 2)                      AS pct_dest_inconsistent
FROM fact_transactions f
JOIN dim_transaction_type t ON t.transaction_type_key = f.transaction_type_key
GROUP BY t.type_name, f.is_fraud
ORDER BY t.type_name, f.is_fraud;
