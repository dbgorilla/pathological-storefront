-- Cross River Trading Co. -- stored procedures written alongside catalogue search
-- author: D. Achebe
-- postgres: 9.4
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 3. Dynamic SQL built by string concatenation
-- ===========================================================================

-- DEFECT proc-sql-injection-find-products
-- p_term is concatenated straight into the statement text. A caller passing
-- an apostrophe changes the statement. This is a SQL injection hole reachable
-- from the search box, and it has been here since 2015.
--
-- format() with %L, or a parameter passed through USING, fixes it.
--
-- The leading wildcard is a second, smaller problem: LIKE '%x%' cannot use a
-- B-tree index, so every call scans the products table.
CREATE OR REPLACE FUNCTION storefront.fn_find_products(p_term text)
RETURNS TABLE (product_id integer, name varchar, price_cents integer)
LANGUAGE plpgsql
AS $$
DECLARE
    v_sql text;
BEGIN
    v_sql := 'SELECT product_id, name, price_cents
                FROM storefront.products
               WHERE name LIKE ''%' || p_term || '%''
               ORDER BY name';

    RETURN QUERY EXECUTE v_sql;
END;
$$;
