-- Cross River Trading Co. -- stored procedures written alongside catalog schema
-- author: S. Okonjo
-- postgres: 10
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 6. IMMUTABLE that reads a table
-- ===========================================================================

-- DEFECT proc-immutable-reads-tables
-- Declared IMMUTABLE, which promises the same answer for the same argument
-- forever. It reads a table whose contents change every day.
--
-- The planner takes the promise at face value: it may evaluate this once and
-- cache the result, and an index built on an expression using it holds values
-- that were true when the row was inserted and are not true now. Reindexing
-- silently changes query results.
CREATE OR REPLACE FUNCTION catalog.fn_current_price(p_product_id integer)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
    v_price integer;
BEGIN
    SELECT price_cents INTO v_price
      FROM storefront.products
     WHERE product_id = p_product_id;

    RETURN v_price;
END;
$$;

-- ===========================================================================
-- 20. An index built on the IMMUTABLE lie
-- ===========================================================================

-- DEFECT index-on-non-immutable-function
--
-- The purchasing screen sorts supplier lines by what the product currently
-- sells for, and the sort was slow, so an expression index was created on
-- catalog.fn_current_price. PostgreSQL permits an expression index only on an
-- immutable expression, and this function is declared IMMUTABLE, which is the
-- only thing it checks.
--
-- The function reads storefront.products, and prices change. An expression
-- index stores the value the expression had when the row was written and never
-- recomputes it, so this index holds each product's price as it stood when its
-- supplier line was last touched. A query the planner answers from the index
-- and the same query forced to read the table give different answers, and
-- neither reports anything wrong.
--
-- REINDEX rebuilds it from today's prices, so a routine reindex silently
-- changes what the purchasing screen shows. So does a restore, which builds the
-- index from whatever the price list holds at restore time. Two copies of this
-- database, loaded from the same dump on different days, disagree.
DROP INDEX IF EXISTS supply.ix_supplier_products_current_price;
CREATE INDEX ix_supplier_products_current_price
    ON supply.supplier_products (catalog.fn_current_price(product_id));

-- ---------------------------------------------------------------------------
-- 29. Counting search results
-- ---------------------------------------------------------------------------
--
-- DEFECT like-pattern-injection-in-a-search-routine
--
-- How many products match what the customer typed, for the result count above
-- the grid. The term is passed as a parameter, so there is no SQL injection
-- here and a review looking for one finds nothing.
--
-- The term is concatenated into a LIKE pattern, and a LIKE pattern has its own
-- metacharacters. A term containing % or _ is not searched for, it is
-- interpreted: a single % matches everything, and an underscore matches any
-- one character, so a search for a part code written with underscores returns
-- far more than it should.
--
-- Measured: searching for a single percent sign returns all 2,000 products.
-- The grid below the count uses the same pattern, so the two agree and neither
-- looks wrong; the count is simply the wrong number for what was typed.
-- Escaping the term, or replace(p_term, '%', '\%') and the same for the
-- underscore, fixes it.
CREATE OR REPLACE FUNCTION catalog.fn_product_search_count(p_term text)
RETURNS bigint
LANGUAGE sql
STABLE
AS $$
    SELECT count(*) FROM storefront.products WHERE name ILIKE '%' || p_term || '%';
$$;
