-- Cross River Trading Co. -- stored procedures written alongside payments schema
-- author: T. Brennan
-- postgres: 10
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 18. Code after the return
-- ===========================================================================

-- DEFECT proc-unreachable-code
-- The validation below the RETURN never runs. It was added in response to an
-- incident, reviewed, approved and merged, and it has never executed once.
--
-- The incident it was written to prevent has happened twice since.
CREATE OR REPLACE FUNCTION payments.fn_refund_allowed(p_transaction_id bigint, p_amount_cents integer)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_amount double precision;
BEGIN
    SELECT amount INTO v_amount
      FROM payments.transactions
     WHERE transaction_id = p_transaction_id;

    RETURN v_amount IS NOT NULL;

    IF p_amount_cents > (v_amount * 100) THEN
        RAISE EXCEPTION 'refund of % exceeds transaction total', p_amount_cents;
    END IF;

    RETURN false;
END;
$$;

-- ---------------------------------------------------------------------------
-- 25. What is still owed on an order
-- ---------------------------------------------------------------------------
--
-- DEFECT sum-over-no-rows-returns-null
--
-- Order total minus everything refunded against it. The subquery is correct
-- and the arithmetic is correct on any order that has been refunded.
--
-- sum() over no rows returns null, not zero. An order with no refunds -- which
-- is almost every order -- makes the subquery null, and anything minus null is
-- null, so the function returns null for the orders that are fully owed and a
-- number for the ones that are not. coalesce around the sum is the fix and is
-- the thing everybody forgets, because it only shows up on the empty case.
--
-- Measured: 13,638 of the 13,880 orders return null here. The billing job
-- treats a null balance as nothing outstanding, so those orders are never
-- chased. The 242 that were partly refunded are chased correctly, which is why
-- the function has never looked broken.
CREATE OR REPLACE FUNCTION payments.fn_order_balance(p_order_id integer)
RETURNS bigint
LANGUAGE sql
AS $$
    SELECT o.total_cents - (
               SELECT sum(r.amount_cents)
                 FROM payments.transactions t
                 JOIN payments.refunds r ON r.transaction_id = t.transaction_id
                WHERE t.order_id = o.order_id
           )
      FROM storefront.orders o
     WHERE o.order_id = p_order_id;
$$;
