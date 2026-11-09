-- Cross River Trading Co. -- stored procedures written alongside analytics rollups
-- author: N. Farrell (data)
-- postgres: 15
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 12. COMMIT inside a loop
-- ===========================================================================

-- DEFECT proc-commit-inside-loop
-- A procedure, so it can commit, and it commits once per customer. There is no
-- transaction around the work as a whole: if it fails halfway, half the
-- segments are updated and half are not, and rerunning it is not safe because
-- there is no record of where it stopped.
--
-- Each commit is also a separate WAL flush, which is why this takes eleven
-- minutes to do a few seconds of work.
CREATE OR REPLACE PROCEDURE analytics.pr_rebuild_segments()
LANGUAGE plpgsql
AS $$
DECLARE
    v_customer record;
BEGIN
    FOR v_customer IN SELECT customer_id FROM storefront.customers ORDER BY customer_id
    LOOP
        INSERT INTO analytics.customer_segments (customer_id, segment, score, model_version, scored_at)
        VALUES (v_customer.customer_id, 'unsegmented', 0, 'none', now())
        ON CONFLICT (customer_id) DO NOTHING;

        COMMIT;
    END LOOP;
END;
$$;

-- ===========================================================================
-- 15. SETOF record with no column definitions
-- ===========================================================================

-- DEFECT proc-setof-record-untyped
-- Returns SETOF record, so every caller has to supply a column definition list
-- and every caller has to know the shape by reading the body. Nothing checks
-- that they agree, and a change to the body breaks callers at run time with a
-- type mismatch rather than at deploy time.
CREATE OR REPLACE FUNCTION analytics.fn_report_rows(p_from date, p_to date)
RETURNS SETOF record
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
        SELECT rollup_day, store_id, order_count, revenue_cents
          FROM analytics.daily_sales_rollup
         WHERE rollup_day BETWEEN p_from AND p_to
         ORDER BY rollup_day;
END;
$$;
