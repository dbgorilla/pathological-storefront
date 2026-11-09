-- Cross River Trading Co. -- stored procedures written alongside archive and partitions
-- author: N. Farrell (data)
-- postgres: 16
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 45. The purge that reaches past the table it names
-- ===========================================================================
--
-- DEFECT delete-without-only-reaches-the-children
--
-- archive.orders_base is the top of an inheritance tree. It is also, in its
-- own right, the landing table the order archiver writes into before the
-- rows are moved into the year tables underneath it. Two jobs therefore
-- touch it: the archiver, which inserts, and this one, which clears out
-- whatever the archiver left behind after a run that did not finish.
--
-- A query naming a parent reads and writes its children too. That is what
-- inheritance is for, it is the behaviour every SELECT in this schema
-- depends on, and ONLY is the one word that turns it off. DELETE follows the
-- same rule as SELECT, which is the part that does not occur to anyone
-- writing a clean-up job: the statement names the staging table and empties
-- the archive.
--
-- Measured: archive.orders_base holds no rows of its own. Its children,
-- archive.orders_2023 and archive.orders_2024, hold 1,460 and 1,464 --
-- every order Cross River took in those two years, and the only copy, since
-- the point of the archive was to take them out of storefront.orders. This
-- function deletes from all three and the cut-off date is the archive's own
-- retention boundary, so on any date after 2024 the predicate matches every
-- archived row: called with 2026-01-01 it reports 2,924 rows deleted and
-- leaves both year tables empty.
--
-- It reports what it deleted, and the number it returns is correct. Nobody
-- reads it, because a staging clean-up that reports a large number reads as
-- a staging table that had a lot in it.
CREATE OR REPLACE FUNCTION archive.fn_purge_staged_orders(p_before date)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_deleted integer;
BEGIN
    DELETE FROM archive.orders_base
     WHERE placed_at < p_before;

    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    RETURN v_deleted;
END;
$$;
