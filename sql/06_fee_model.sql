-- =============================================================================
-- 06_fee_model.sql
-- Stage C: the simulated fee model. THIS FILE IS ASSUMPTIONS, NOT DATA.
--
-- What this step is: PaySim contains no revenue, cost, or fee information at
-- all. Every number in this file is invented by us to make a profitability
-- question askable. It is isolated in its own table (rather than bolted onto
-- dim_transaction_type) for exactly that reason: dimensions describe what the
-- data IS, this table describes what we ASSUME. Change a rate here and re-run
-- the analysis views; the star schema never needs rebuilding.
--
-- -----------------------------------------------------------------------------
-- WHY A HYBRID (percentage, with a floor and a cap) RATHER THAN FLAT OR PURE %
-- -----------------------------------------------------------------------------
-- A flat per-transaction fee is economically invisible here. 6.36M transactions
-- at any plausible flat rate yields single-digit millions, against ~7.49bn of
-- fraud loss. Every segment would drown and the comparison would say nothing.
--
-- A pure percentage is hostage to outliers. TRANSFER's mean amount is 910,647
-- against a median of 486,308, with a maximum of 92,445,516. An uncapped 1%
-- charges 924,455 on that single transaction. A handful of rows would set the
-- profitability headline.
--
-- The hybrid is also what real mobile-money operators (M-Pesa, Airtel Money)
-- actually charge: a percentage, bounded by a minimum and a maximum. The cap
-- removes the outlier sensitivity; the floor stops micro-transactions being free.
--
-- -----------------------------------------------------------------------------
-- UNITS
-- -----------------------------------------------------------------------------
-- PaySim's amounts are unitless. We treat them as a generic currency unit and
-- state every rate relative to the observed amount distribution rather than to
-- any real-world tariff. The RANKING of segments is the deliverable; the
-- absolute currency values are illustrative.
--
-- -----------------------------------------------------------------------------
-- THE RULES, AND WHY EACH ONE
-- -----------------------------------------------------------------------------
-- CASH_IN   0.00%  — deposits are free. Universal in mobile money: providers
--                    want money to enter the float. It is a pure cost centre,
--                    and showing it as loss-making is a CORRECT finding, not a
--                    modelling failure.
-- CASH_OUT  1.50%  — withdrawals carry the highest rate; they remove float and
--                    require an agent to hand over physical cash.
-- TRANSFER  1.00%  — the core P2P product.
-- PAYMENT   0.50%  — merchant-funded, low rate to drive acceptance. High volume
--                    (33.81% of transactions), tiny value (2.45%).
-- DEBIT     0.75%  — bank rails cost more than internal ledger moves.
--
-- Costs are per-transaction and reflect where real cost is incurred:
-- CASH_IN/CASH_OUT are expensive because a human agent handles physical cash.
-- PAYMENT and TRANSFER are ledger entries and cost almost nothing.
-- =============================================================================

DROP TABLE IF EXISTS fee_model;

CREATE TABLE fee_model (
    transaction_type_key SMALLINT PRIMARY KEY
        REFERENCES dim_transaction_type (transaction_type_key),

    fee_rate             NUMERIC(6,5)  NOT NULL,  -- proportion of amount, e.g. 0.01500 = 1.5%
    fee_min              NUMERIC(12,2) NOT NULL,  -- floor: charged even on tiny amounts
    fee_max              NUMERIC(12,2) NOT NULL,  -- cap: protects against outlier amounts
    cost_per_txn         NUMERIC(12,2) NOT NULL,  -- our processing cost to serve one transaction
    rationale            TEXT          NOT NULL,

    CONSTRAINT fee_rate_sane CHECK (fee_rate >= 0 AND fee_rate <= 0.10),
    CONSTRAINT fee_bounds_sane CHECK (fee_max >= fee_min)
);

INSERT INTO fee_model (transaction_type_key, fee_rate, fee_min, fee_max, cost_per_txn, rationale)
SELECT d.transaction_type_key, v.fee_rate, v.fee_min, v.fee_max, v.cost_per_txn, v.rationale
FROM (VALUES
    ('CASH_IN',  0.00000,   0.00,      0.00, 3.00,
     'Deposits are free to encourage float inflow. Pure cost centre: an agent handles physical cash.'),
    ('CASH_OUT', 0.01500,  10.00,   5000.00, 3.00,
     'Highest rate: withdrawals drain float and require an agent to dispense cash.'),
    ('TRANSFER', 0.01000,  10.00,  10000.00, 1.00,
     'Core P2P product. Ledger-only, so cheap to serve. Cap set high as transfers are large.'),
    ('PAYMENT',  0.00500,   1.00,   1000.00, 0.50,
     'Merchant-funded and low, to drive acceptance. High volume, low value per transaction.'),
    ('DEBIT',    0.00750,   5.00,   2000.00, 1.00,
     'Bank rails cost more than an internal ledger move.')
) AS v(type_name, fee_rate, fee_min, fee_max, cost_per_txn, rationale)
JOIN dim_transaction_type d ON d.type_name = v.type_name;


-- -----------------------------------------------------------------------------
-- fn_transaction_fee — the hybrid rule in one place.
--
-- fee = clamp(amount * rate, floor, cap)
--
-- CASH_IN is the special case: rate, floor and cap are all 0, so the clamp
-- returns 0 without needing a branch. That is why the floor is 0 there and not
-- 10 — a floor above zero would silently start charging for deposits.
--
-- PERFORMANCE: IMMUTABLE and PARALLEL SAFE so the planner inlines the body into
-- the calling query and evaluates it as a plain expression across 6.36M rows.
--
-- It is deliberately NOT declared STRICT, and that matters more than it looks.
-- PostgreSQL refuses to inline a STRICT SQL function whose body is non-strict --
-- and LEAST/GREATEST are non-strict, because they ignore NULL arguments rather
-- than returning NULL. Declared STRICT, this function is called 6,362,620 times
-- through the executor: measured at 40.2 SECONDS. Inlined, the identical
-- aggregate runs in 0.88 seconds -- a 45x difference for one keyword.
--
-- The arguments are never NULL in practice: amount is NOT NULL on the fact table
-- and every fee_model column is NOT NULL.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_transaction_fee(
    p_amount   NUMERIC,
    p_fee_rate NUMERIC,
    p_fee_min  NUMERIC,
    p_fee_max  NUMERIC
) RETURNS NUMERIC
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT LEAST(GREATEST(p_amount * p_fee_rate, p_fee_min), p_fee_max);
$$;

-- Sanity check on the clamp: verifies floor, cap, and the CASH_IN zero case.
DO $$
BEGIN
    ASSERT fn_transaction_fee(100,      0.01, 10, 5000) = 10,    'floor not applied';
    ASSERT fn_transaction_fee(100000,   0.01, 10, 5000) = 1000,  'rate not applied';
    ASSERT fn_transaction_fee(90000000, 0.01, 10, 5000) = 5000,  'cap not applied';
    ASSERT fn_transaction_fee(90000000, 0.00,  0,    0) = 0,     'CASH_IN zero case broken';
    RAISE NOTICE 'Assertion passed: hybrid fee clamp behaves correctly.';
END $$;
