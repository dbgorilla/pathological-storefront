-- Cross River Trading Co. -- line totals as generated columns
-- author: J. Toomey
-- postgres: 18
--
-- Order lines compute their own total instead of the application doing it.
-- Tested against a 17 container locally, then deployed to the 18 estate.

-- DEFECT generated-column-virtual-by-omission
--
-- This is the important one.
--
-- The statement says GENERATED ALWAYS AS (...) with neither STORED nor
-- VIRTUAL. On PostgreSQL 17 and earlier that is a syntax error: STORED was
-- mandatory. The author wrote it, got an error locally on 17, added STORED,
-- and then removed it again while resolving a merge conflict.
--
-- On 18, VIRTUAL is the default. So the column was accepted, and it is not
-- stored. It is recomputed on every read, it cannot be indexed, and the
-- nightly report that scans this table now recomputes six million
-- multiplications every time it runs.
--
-- Nothing about the DDL looks wrong. pg_attribute.attgenerated is 'v' rather
-- than 's', and that single character is the entire difference.
ALTER TABLE storefront.order_items
    ADD COLUMN line_total_cents integer
        GENERATED ALWAYS AS (quantity * unit_price_cents);

-- The same expression on the sibling table, written correctly, so the two can
-- be compared directly in one database.
ALTER TABLE catalog.product_variants
    ADD COLUMN price_with_vat_cents integer
        GENERATED ALWAYS AS ((price_cents * 120) / 100) STORED;

COMMENT ON COLUMN storefront.order_items.line_total_cents IS
    'Generated. VIRTUAL, because the keyword was omitted on PostgreSQL 18.';
COMMENT ON COLUMN catalog.product_variants.price_with_vat_cents IS
    'Generated STORED. The same pattern done deliberately.';
