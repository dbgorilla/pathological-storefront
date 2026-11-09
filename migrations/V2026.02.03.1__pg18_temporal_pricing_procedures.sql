-- Cross River Trading Co. -- stored procedures written alongside pg18 temporal pricing
-- author: K. Ardelean (platform)
-- postgres: 18
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 21. The same function name in two schemas
-- ===========================================================================

-- DEFECT function-shadowed-by-search-path
--
-- The 2026 pricing rewrite moved the current-price lookup into storefront,
-- next to the tables it reads, and gave it the behaviour the pricing team
-- wanted: the last price the pricing job recorded, falling back to the
-- catalogue price for products that have never been repriced. The old one in
-- catalog was left alone because the purchasing screen still calls it by name.
--
-- Both are called fn_current_price and both take one integer. Nothing collides,
-- because they are in different schemas, and an unqualified call is resolved
-- against search_path at parse time. The database-level search_path puts
-- storefront first, so every unqualified call in every application query now
-- reaches this one, including the calls written years before it existed.
--
-- Measured: the two functions return different prices for 333 of the 2,000
-- products. A query that names catalog.fn_current_price and one that names
-- fn_current_price are different queries on those products, and the difference
-- is a schema name that is not written in either of them. Changing the
-- search_path back, on one connection or in one session, moves the answer
-- again without any code changing.
CREATE OR REPLACE FUNCTION storefront.fn_current_price(p_product_id integer)
RETURNS integer
LANGUAGE sql
STABLE
AS $$
    SELECT coalesce(
        (SELECT h.price_cents
           FROM storefront.price_history h
          WHERE h.product_id = p_product_id
          ORDER BY lower(h.in_force) DESC
          LIMIT 1),
        (SELECT p.price_cents
           FROM storefront.products p
          WHERE p.product_id = p_product_id));
$$;
