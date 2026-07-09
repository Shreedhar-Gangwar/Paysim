-- =============================================================================
-- 04_populate_star_schema.sql
-- Stage B: transform staging -> star schema, then build analytical indexes.
--
-- What this step is: a single set-based ETL pass. Dimensions are built first
-- (the fact's foreign keys need them to exist), then the fact table is loaded
-- in one INSERT ... SELECT, then indexes are created.
--
-- ORDERING RATIONALE — indexes are built AFTER the bulk insert, not before.
-- Maintaining a b-tree during a 6.36M-row insert is markedly slower than
-- building it once over the finished table. The only indexes that exist during
-- the fact load are dim_accounts' and dim_date's unique/primary keys, which the
-- join and the FK checks genuinely need.
-- =============================================================================

-- Give the session room for the large hash joins and index builds below.
-- Session-scoped only; does not change server config.
SET work_mem = '256MB';
SET maintenance_work_mem = '512MB';


-- -----------------------------------------------------------------------------
-- 1. dim_date — generate one row per simulated hour actually present in the data.
--
-- We generate from the observed MIN/MAX step rather than hardcoding 1..743, so
-- the script stays correct if a different PaySim extract is loaded. Stage A
-- confirmed the range is dense (743 distinct steps over 1..743, no gaps), so a
-- generate_series is faithful and no step is invented.
-- -----------------------------------------------------------------------------
INSERT INTO dim_date (date_key, day_number, hour_of_day, day_of_week, is_weekend)
WITH step_bounds AS (
    SELECT MIN(step) AS min_step, MAX(step) AS max_step
    FROM stg_transactions
),
all_steps AS (
    SELECT generate_series(min_step, max_step) AS step
    FROM step_bounds
),
derived AS (
    SELECT
        step,
        -- -1 offset: step 1 must land on day 0, hour 0. Without it the first
        -- simulated day would hold only 23 hours and skew daily averages.
        ((step - 1) / 24)::SMALLINT AS day_number,
        ((step - 1) % 24)::SMALLINT AS hour_of_day
    FROM all_steps
)
SELECT
    step                                   AS date_key,
    day_number,
    hour_of_day,
    'Day_' || (day_number % 7)             AS day_of_week,  -- synthetic bucket, NOT a real weekday
    (day_number % 7) IN (5, 6)             AS is_weekend    -- synthetic convention only
FROM derived;


-- -----------------------------------------------------------------------------
-- 2. dim_transaction_type — five rows, enumerated explicitly.
--
-- Hardcoded rather than derived from DISTINCT type, because type_description,
-- is_fraud_bearing and the balance signs are knowledge we add to the model.
-- is_fraud_bearing reflects what Stage A measured: fraud appears ONLY in
-- TRANSFER and CASH_OUT. Assertions below re-verify both the fraud flags and
-- the balance signs against the data, so the hardcoded values can never
-- silently drift from reality.
--
-- Balance signs: +1 = the party is credited, -1 = debited, NULL = balance not
-- tracked. CASH_IN is the odd one out on BOTH sides (customer receives cash,
-- so the originator is credited and the destination debited). PAYMENT's
-- destination is a merchant, whose balance PaySim never populates.
-- -----------------------------------------------------------------------------
INSERT INTO dim_transaction_type
    (transaction_type_key, type_name, type_description, is_fraud_bearing, orig_balance_sign, dest_balance_sign)
VALUES
    (1, 'CASH_IN',  'Customer deposits cash into their account via a merchant.',  FALSE,  1,   -1),
    (2, 'CASH_OUT', 'Customer withdraws cash from their account via a merchant.', TRUE,  -1,    1),
    (3, 'DEBIT',    'Funds moved from a mobile-money account to a bank account.', FALSE, -1,    1),
    (4, 'PAYMENT',  'Customer pays a merchant for goods or services.',            FALSE, -1, NULL),
    (5, 'TRANSFER', 'Funds sent from one customer account to another.',           TRUE,  -1,    1);

-- Assertion: PAYMENT destination balances really are entirely untracked. If a
-- future PaySim extract ever populates them, dest_balance_sign must stop being
-- NULL and this fails loudly rather than silently discarding a real signal.
DO $$
DECLARE
    populated_payment_dest INTEGER;
BEGIN
    SELECT COUNT(*) INTO populated_payment_dest
    FROM stg_transactions
    WHERE type = 'PAYMENT'
      AND (oldbalance_dest <> 0 OR newbalance_dest <> 0);

    IF populated_payment_dest > 0 THEN
        RAISE EXCEPTION 'PAYMENT destination balances are populated on % rows; dest_balance_sign must not be NULL', populated_payment_dest;
    END IF;
    RAISE NOTICE 'Assertion passed: PAYMENT destination balances are untracked (all zero).';
END $$;

-- Assertion: the is_fraud_bearing flags above must match the data exactly.
-- Fails loudly (division by zero) if a type marked non-fraud-bearing contains
-- fraud, or a type marked fraud-bearing contains none.
DO $$
DECLARE
    mismatches INTEGER;
BEGIN
    SELECT COUNT(*) INTO mismatches
    FROM (
        SELECT s.type, MAX(s.is_fraud) > 0 AS has_fraud
        FROM stg_transactions s
        GROUP BY s.type
    ) actual
    JOIN dim_transaction_type d ON d.type_name = actual.type
    WHERE actual.has_fraud <> d.is_fraud_bearing;

    IF mismatches > 0 THEN
        RAISE EXCEPTION 'dim_transaction_type.is_fraud_bearing disagrees with staging for % type(s)', mismatches;
    END IF;
    RAISE NOTICE 'Assertion passed: is_fraud_bearing matches the data for all types.';
END $$;


-- -----------------------------------------------------------------------------
-- 3. dim_accounts — one conformed row per distinct account id.
--
-- Accounts are collected from BOTH sides of the transaction (originator and
-- destination) and de-duplicated. This is what makes the dimension conformed:
-- an id that appears as an originator on one row and a destination on another
-- gets exactly one dimension row, one surrogate key, and one identity.
--
-- party_type uses the rule Stage A proved: 'M' prefix = merchant (appears only
-- as the destination of a PAYMENT), everything else = customer. A post-insert
-- assertion re-verifies the merchant rule rather than trusting the prefix.
--
-- Surrogate keys are assigned with ROW_NUMBER over the sorted id. Sorting makes
-- the assignment deterministic: re-running this script yields identical keys,
-- which keeps the fact table reproducible.
-- -----------------------------------------------------------------------------
INSERT INTO dim_accounts (account_key, account_id, party_type)
WITH all_account_ids AS (
    SELECT name_orig AS account_id FROM stg_transactions
    UNION                                    -- UNION (not UNION ALL): de-duplicates across both sides
    SELECT name_dest AS account_id FROM stg_transactions
)
SELECT
    ROW_NUMBER() OVER (ORDER BY account_id) AS account_key,
    account_id,
    CASE WHEN LEFT(account_id, 1) = 'M' THEN 'MERCHANT' ELSE 'CUSTOMER' END AS party_type
FROM all_account_ids;

-- Assertion: the merchant rule must hold. Every 'M' account must appear only as
-- a PAYMENT destination, and never as an originator.
DO $$
DECLARE
    m_as_originator      INTEGER;
    m_as_non_payment_dest INTEGER;
BEGIN
    SELECT COUNT(*) INTO m_as_originator
    FROM stg_transactions WHERE LEFT(name_orig, 1) = 'M';

    SELECT COUNT(*) INTO m_as_non_payment_dest
    FROM stg_transactions WHERE LEFT(name_dest, 1) = 'M' AND type <> 'PAYMENT';

    IF m_as_originator > 0 THEN
        RAISE EXCEPTION 'Merchant rule broken: % rows have an M-prefixed originator', m_as_originator;
    END IF;
    IF m_as_non_payment_dest > 0 THEN
        RAISE EXCEPTION 'Merchant rule broken: % rows send non-PAYMENT to an M-prefixed destination', m_as_non_payment_dest;
    END IF;
    RAISE NOTICE 'Assertion passed: merchants appear only as PAYMENT destinations.';
END $$;


-- -----------------------------------------------------------------------------
-- 4. fact_transactions — one row per staging row, in a single set-based INSERT.
--
-- The surrogate key is assigned by ROW_NUMBER over (step, name_orig, amount) to
-- be deterministic across re-runs. Staging has no natural primary key — PaySim
-- rows are not individually identified — so a surrogate is genuinely required
-- rather than merely conventional.
--
-- dim_accounts is joined TWICE (role-playing dimension): once for the
-- originator, once for the destination. Both joins are inner joins and cannot
-- drop rows, because dim_accounts was built from the union of exactly these two
-- columns. The validation script proves the row count is preserved regardless.
-- -----------------------------------------------------------------------------
INSERT INTO fact_transactions (
    transaction_key,
    date_key, transaction_type_key, orig_account_key, dest_account_key,
    amount,
    oldbalance_org, newbalance_orig, oldbalance_dest, newbalance_dest,
    orig_balance_delta, dest_balance_delta,
    orig_balance_error, dest_balance_error,
    is_fraud, is_flagged_fraud
)
SELECT
    ROW_NUMBER() OVER (ORDER BY s.step, s.name_orig, s.amount) AS transaction_key,

    s.step                     AS date_key,           -- dim_date's key IS the step
    dtt.transaction_type_key,
    acct_orig.account_key      AS orig_account_key,
    acct_dest.account_key      AS dest_account_key,

    s.amount,

    s.oldbalance_org,
    s.newbalance_orig,
    s.oldbalance_dest,
    s.newbalance_dest,

    -- Actual observed movement on each side.
    s.newbalance_orig - s.oldbalance_org  AS orig_balance_delta,
    s.newbalance_dest - s.oldbalance_dest AS dest_balance_delta,

    -- Residual vs. what a well-formed ledger would show: actual - expected,
    -- where expected = old + (sign * amount). Zero = consistent.
    -- The sign comes from the type dimension because direction differs by type
    -- (CASH_IN credits the originator; everything else debits it).
    -- Stored, not thresholded: Stage C decides what a nonzero value means.
    s.newbalance_orig - (s.oldbalance_org + dtt.orig_balance_sign * s.amount)
        AS orig_balance_error,

    -- NULL for PAYMENT (dest_balance_sign IS NULL): the merchant's balance is
    -- never populated, so "consistent" is not a meaningful claim about it.
    CASE WHEN dtt.dest_balance_sign IS NOT NULL
         THEN s.newbalance_dest - (s.oldbalance_dest + dtt.dest_balance_sign * s.amount)
    END AS dest_balance_error,

    (s.is_fraud = 1)         AS is_fraud,
    (s.is_flagged_fraud = 1) AS is_flagged_fraud

FROM stg_transactions s
JOIN dim_transaction_type dtt ON dtt.type_name  = s.type
JOIN dim_accounts acct_orig   ON acct_orig.account_id = s.name_orig
JOIN dim_accounts acct_dest   ON acct_dest.account_id = s.name_dest;


-- -----------------------------------------------------------------------------
-- 5. Indexes — built after the load. Each one is justified below.
-- -----------------------------------------------------------------------------

-- Growth pillar: every activity-over-time query groups or filters on date_key.
CREATE INDEX idx_fact_date ON fact_transactions (date_key);

-- Risk + Profitability: nearly every query slices by transaction type.
CREATE INDEX idx_fact_type ON fact_transactions (transaction_type_key);

-- PARTIAL index on fraud. Fraud is 0.1291% of rows (8,213 of 6,362,620), so an
-- index restricted to the true rows is ~8k entries instead of 6.36M — tiny, and
-- it turns the whole Risk pillar into an index scan. A full index on a boolean
-- this skewed would be near-useless (the planner would seq-scan for is_fraud =
-- false anyway) and would waste ~140MB.
CREATE INDEX idx_fact_is_fraud_true ON fact_transactions (transaction_key)
    WHERE is_fraud;

-- Same reasoning, even more extreme: only 16 flagged rows in the entire table.
CREATE INDEX idx_fact_is_flagged_true ON fact_transactions (transaction_key)
    WHERE is_flagged_fraud;

-- Destination-side analysis (top destinations by value, merchant vs customer
-- flows). Stage A showed destinations DO recur (up to 113x), so this index is
-- earned. The mirror index on orig_account_key is deliberately NOT created:
-- 99.85% of originators appear exactly once, so grouping by originator is
-- effectively grouping by row, and the index would be ~6.35M near-unique
-- entries serving no query we intend to run.
CREATE INDEX idx_fact_dest_account ON fact_transactions (dest_account_key);

-- Composite for the most common Risk roll-up: fraud exposure by type over time.
CREATE INDEX idx_fact_type_date ON fact_transactions (transaction_type_key, date_key);

-- dim_accounts.party_type is low-cardinality (2 values) over ~9M rows, so a
-- plain b-tree would not be used. No index created here on purpose.

-- Refresh planner statistics so the first analytical queries get good plans.
ANALYZE dim_date;
ANALYZE dim_transaction_type;
ANALYZE dim_accounts;
ANALYZE fact_transactions;
