-- Cross River Trading Co. -- stored procedures written alongside product specs jsonb
-- author: S. Okonjo
-- postgres: 11
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 13. A trigger that rewrites the whole table
-- ===========================================================================

-- DEFECT proc-trigger-full-table-update
-- Written to keep a "last stock change" marker current. It updates every row
-- in storefront.inventory on every single inventory change, which is a
-- 2000-row rewrite per sale.
--
-- inventory is also the table pinned at fillfactor 100, so none of those
-- rewrites can be a heap-only tuple update and each one touches every index.
--
-- The function is defined here but deliberately not attached to the table. A
-- fixture that takes minutes to load teaches nobody anything. The defect is
-- the code, and it is findable in pg_proc.
CREATE OR REPLACE FUNCTION storefront.fn_touch_all_inventory()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE storefront.inventory
       SET quantity_available = quantity_available;

    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION storefront.fn_touch_all_inventory() IS
    'Not attached to any table. Left here because it was attached for three weeks in 2019.';
