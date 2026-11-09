-- Cross River Trading Co. -- stored procedures written alongside subscription box
-- author: J. Toomey (new products team)
-- postgres: 11
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 17. A reference to a column that no longer exists
-- ===========================================================================

-- DEFECT proc-references-dropped-column
-- storefront.customers.subscription_tier survived the 2021 teardown, but
-- subscriptions.box_shipments did not: the schema was dropped whole.
--
-- plpgsql resolves names when the statement first runs, not when the function
-- is created, so this compiles cleanly, deploys cleanly, passes a smoke test
-- that never calls it, and raises "relation subscriptions.box_shipments does
-- not exist" the first time anyone does.
--
-- Nothing in pg_proc, information_schema or pg_dump reports this. Only calling
-- it finds it.
CREATE OR REPLACE FUNCTION storefront.fn_customer_box_history(p_customer_id integer)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
    v_count integer;
BEGIN
    SELECT count(*) INTO v_count
      FROM subscriptions.box_shipments b
      JOIN subscriptions.customer_subscriptions s USING (customer_subscription_id)
     WHERE s.customer_id = p_customer_id;

    RETURN v_count;
END;
$$;
