-- =============================================================================
-- 03_create_star_schema.sql
-- Stage B: dimensional model DDL.
--
-- What this step is: define the star schema that all analysis sits on. Nothing
-- is populated here (see 04_populate_star_schema.sql) — this file is pure
-- structure, so it can be read on its own as the model's specification.
--
-- GRAIN of fact_transactions: exactly one row per PaySim transaction.
-- The staging table has 6,362,620 rows and the fact table must have exactly
-- 6,362,620 rows. No aggregation, no filtering, no grain mixing.
--
-- Dimensions (three, all conformed):
--   dim_date              — one row per simulated hour (step)
--   dim_transaction_type  — one row per transaction type (5)
--   dim_accounts          — one row per distinct account id
-- =============================================================================

DROP TABLE IF EXISTS fact_transactions;
DROP TABLE IF EXISTS dim_date;
DROP TABLE IF EXISTS dim_transaction_type;
DROP TABLE IF EXISTS dim_accounts;


-- -----------------------------------------------------------------------------
-- dim_date — the synthetic time dimension.
--
-- PaySim has NO real calendar. `step` is an hour counter running 1..743
-- (~30.96 days). We map it as:
--     day_number  = (step - 1) / 24     -- 0-based, so step 1 -> day 0
--     hour_of_day = (step - 1) % 24     -- 0..23, so step 1 -> hour 0
--
-- The -1 offset matters: without it, step 1 would land on hour 1 and the
-- first "day" would only contain 23 hours, quietly skewing every daily average.
--
-- day_of_week is derived from day_number, NOT from any real calendar. It is a
-- convenience bucket for weekday/weekend style slicing only. We do not claim
-- day 0 is a Monday — there is no basis for that. It is labelled Day_0..Day_6
-- precisely to stop anyone reading real weekday semantics into it.
--
-- The surrogate key IS the step value. Normally a dimension gets a meaningless
-- surrogate, but here `step` is already a clean, dense, immutable integer
-- identifying the grain exactly. Inventing a second key would add a join hop
-- and buy nothing.
-- -----------------------------------------------------------------------------
CREATE TABLE dim_date (
    date_key     INTEGER PRIMARY KEY,          -- = step (1..743)
    day_number   SMALLINT NOT NULL,            -- 0..30, simulated day
    hour_of_day  SMALLINT NOT NULL,            -- 0..23
    day_of_week  TEXT     NOT NULL,            -- Day_0..Day_6 (synthetic, NOT a real weekday)
    is_weekend   BOOLEAN  NOT NULL,            -- day_of_week in (Day_5, Day_6); synthetic convention
    CONSTRAINT dim_date_hour_valid CHECK (hour_of_day BETWEEN 0 AND 23),
    CONSTRAINT dim_date_day_valid  CHECK (day_number >= 0)
);


-- -----------------------------------------------------------------------------
-- dim_transaction_type — five rows, one per PaySim transaction type.
--
-- Small, but it earns its place: it is where the Stage C fee model hangs, and
-- it lets the fact table carry a compact SMALLINT key instead of repeating a
-- text label 6.36M times.
--
-- `is_fraud_bearing` records a fact we PROVED in Stage A: fraud occurs only in
-- TRANSFER and CASH_OUT — zero rows elsewhere, not merely rare. Storing it
-- makes that finding explicit in the model rather than folklore in a comment.
-- -----------------------------------------------------------------------------
-- orig_balance_sign / dest_balance_sign encode the DIRECTION of the expected
-- ledger movement, so the balance residuals in the fact table can be computed
-- correctly per type. Verified empirically against the data in Stage B:
--
--   originator:  CASH_IN is a CREDIT (+1); every other type is a DEBIT (-1).
--   destination: CASH_IN is a DEBIT (-1); CASH_OUT/TRANSFER/DEBIT are CREDITs (+1).
--                PAYMENT is NULL — merchant destination balances are never
--                populated by PaySim (all 2,151,495 PAYMENT rows carry
--                oldbalance_dest = newbalance_dest = 0), so no ledger identity
--                holds and the residual is undefined, not zero.
--
-- Applying a single debit identity to all types (the naive approach) makes 100%
-- of CASH_IN rows look corrupt when only 33 actually are.
CREATE TABLE dim_transaction_type (
    transaction_type_key SMALLINT PRIMARY KEY,
    type_name            TEXT    NOT NULL UNIQUE,   -- CASH_IN | CASH_OUT | DEBIT | PAYMENT | TRANSFER
    type_description     TEXT    NOT NULL,
    is_fraud_bearing     BOOLEAN NOT NULL,          -- true only for TRANSFER, CASH_OUT (verified in Stage A)
    orig_balance_sign    SMALLINT NOT NULL,         -- +1 credit / -1 debit, applied to the originator
    dest_balance_sign    SMALLINT,                  -- +1 / -1; NULL = destination balance not tracked
    CONSTRAINT dim_txn_type_orig_sign_valid CHECK (orig_balance_sign IN (-1, 1)),
    CONSTRAINT dim_txn_type_dest_sign_valid CHECK (dest_balance_sign IN (-1, 1))
);


-- -----------------------------------------------------------------------------
-- dim_accounts — one conformed account dimension.
--
-- Conformed, NOT split into originator/destination dimensions. The same account
-- id can appear as originator on one transaction and destination on another, so
-- a single dimension is what lets us ask "what did this account do overall".
-- The fact table therefore carries TWO foreign keys into this one table
-- (orig_account_key, dest_account_key) — a classic role-playing dimension.
--
-- This dimension is large (~9M rows, comparable to the fact table). That is
-- unusual and worth defending: PaySim's originators are ~99.85% single-use, so
-- the dimension is nearly 1:1 with the fact on the originator side. We keep it
-- anyway because it is the correct model and it is what makes party_type and
-- the account-role analysis possible.
--
-- party_type is derived from a rule Stage A PROVED, not assumed:
--   ids beginning 'M' are merchants; they appear ONLY as the destination of a
--   PAYMENT (2,151,495 such rows — exactly the PAYMENT count). All other ids
--   begin 'C' and are customers.
-- -----------------------------------------------------------------------------
CREATE TABLE dim_accounts (
    account_key  BIGINT PRIMARY KEY,     -- surrogate; assigned in populate step
    account_id   TEXT   NOT NULL UNIQUE, -- natural key, e.g. C1231006815 / M1979787155
    party_type   TEXT   NOT NULL,        -- CUSTOMER | MERCHANT
    CONSTRAINT dim_accounts_party_type_valid
        CHECK (party_type IN ('CUSTOMER', 'MERCHANT'))
);


-- -----------------------------------------------------------------------------
-- fact_transactions — grain: one row per transaction.
--
-- Measures kept additive where possible. The two "balance_error" columns are
-- the exception and deserve explanation:
--
--   The expected ledger identity is DIRECTION-DEPENDENT. Using the signs stored
--   on dim_transaction_type:
--       expected_new = old + (sign * amount)
--       residual     = actual_new - expected_new      -- zero when consistent
--
--   The sign matters. CASH_IN credits the originator while every other type
--   debits it; on the destination side CASH_IN debits while CASH_OUT, TRANSFER
--   and DEBIT credit. Applying one debit identity to all types would mark all
--   1,399,284 CASH_IN rows corrupt when only 33 are.
--
--   dest_balance_error is NULLABLE. For PAYMENT, PaySim never populates the
--   merchant's balance (old = new = 0 on all 2,151,495 rows), so the residual is
--   undefined, not zero. Storing 0 there would be a lie that quietly inflates
--   any "consistent destinations" count by a third of the table.
--
--   We store the residual rather than a boolean, so Stage C can quantify the
--   violation instead of just counting it. We do NOT assume a nonzero residual
--   means fraud — Stage B measures it; Stage C interprets it.
--
-- is_fraud / is_flagged_fraud become BOOLEAN here (they were 0/1 SMALLINT in
-- staging). is_flagged_fraud is PaySim's naive incumbent rule; Stage A showed
-- it catches 16 of 8,213 frauds (0.19% recall). It is retained to quantify how
-- poor that rule is, not as a baseline worth beating.
-- -----------------------------------------------------------------------------
CREATE TABLE fact_transactions (
    transaction_key      BIGINT        PRIMARY KEY,   -- surrogate, assigned in populate

    -- Foreign keys to the conformed dimensions -------------------------------
    date_key             INTEGER       NOT NULL REFERENCES dim_date (date_key),
    transaction_type_key SMALLINT      NOT NULL REFERENCES dim_transaction_type (transaction_type_key),
    orig_account_key     BIGINT        NOT NULL REFERENCES dim_accounts (account_key),
    dest_account_key     BIGINT        NOT NULL REFERENCES dim_accounts (account_key),

    -- Core measure ------------------------------------------------------------
    amount               NUMERIC(18,2) NOT NULL,

    -- Balance state (semi-additive: snapshots, do not SUM these across rows) ---
    oldbalance_org       NUMERIC(18,2) NOT NULL,
    newbalance_orig      NUMERIC(18,2) NOT NULL,
    oldbalance_dest      NUMERIC(18,2) NOT NULL,
    newbalance_dest      NUMERIC(18,2) NOT NULL,

    -- Derived balance movement (additive) ------------------------------------
    orig_balance_delta   NUMERIC(18,2) NOT NULL,  -- newbalance_orig - oldbalance_org (negative = funds left)
    dest_balance_delta   NUMERIC(18,2) NOT NULL,  -- newbalance_dest - oldbalance_dest (positive = funds arrived)

    -- Derived integrity residuals (see note above). Zero = ledger consistent.
    orig_balance_error   NUMERIC(18,2) NOT NULL,  -- newbalance_orig - (oldbalance_org + orig_sign * amount)
    dest_balance_error   NUMERIC(18,2),           -- NULL for PAYMENT: merchant balances not tracked

    -- Fraud flags -------------------------------------------------------------
    is_fraud             BOOLEAN       NOT NULL,  -- ground truth
    is_flagged_fraud     BOOLEAN       NOT NULL   -- PaySim's incumbent rule (0.19% recall)
);
