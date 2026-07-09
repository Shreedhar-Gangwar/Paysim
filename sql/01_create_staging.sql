-- =============================================================================
-- 01_create_staging.sql
-- Stage A: staging table for the raw PaySim CSV.
--
-- Purpose: a faithful 1:1 landing zone for the CSV — same columns, same
-- values, no transformation. The star schema (Stage B) is built FROM this
-- table, so the raw load stays auditable and re-runnable.
--
-- Notes on types:
--   * step is an hour counter (1 unit = 1 simulated hour, ~30 days total).
--   * amounts/balances use NUMERIC(18,2) — exact decimal money, never FLOAT.
--   * isfraud / isflaggedfraud arrive as 0/1 integers; kept as SMALLINT here,
--     converted to BOOLEAN in the star schema.
--   * No indexes/keys on staging: it is written once via COPY and read
--     sequentially, so indexes would only slow the bulk load.
-- =============================================================================

DROP TABLE IF EXISTS stg_transactions;

CREATE TABLE stg_transactions (
    step            INTEGER       NOT NULL,  -- simulation hour (1..~744)
    type            TEXT          NOT NULL,  -- CASH_IN | CASH_OUT | DEBIT | PAYMENT | TRANSFER
    amount          NUMERIC(18,2) NOT NULL,
    name_orig       TEXT          NOT NULL,  -- originating account id
    oldbalance_org  NUMERIC(18,2) NOT NULL,  -- originator balance before
    newbalance_orig NUMERIC(18,2) NOT NULL,  -- originator balance after
    name_dest       TEXT          NOT NULL,  -- destination account id
    oldbalance_dest NUMERIC(18,2) NOT NULL,  -- destination balance before
    newbalance_dest NUMERIC(18,2) NOT NULL,  -- destination balance after
    is_fraud        SMALLINT      NOT NULL,  -- 1 = actual fraud (ground truth)
    is_flagged_fraud SMALLINT     NOT NULL   -- 1 = flagged by PaySim's naive rule
);
