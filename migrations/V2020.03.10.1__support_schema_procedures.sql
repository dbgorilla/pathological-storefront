-- Cross River Trading Co. -- stored procedures written alongside support schema
-- author: A. Fenwick
-- postgres: 12
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 11. Recursion with no cycle guard
-- ===========================================================================

-- DEFECT proc-unguarded-recursion-merge-chain
-- Follows merged_into_ticket_id until it finds a ticket that was not merged.
-- Three pairs of tickets in this database are merged into each other, so for
-- those inputs this recurses until PostgreSQL raises "stack depth limit
-- exceeded", which takes several seconds and leaves nothing behind to say why.
--
-- Tickets 101, 102, 203, 204, 305 and 306 are the ones that do it.
--
-- A visited-set, a depth counter, or a recursive CTE with CYCLE detection all
-- fix it. This has none of the three.
CREATE OR REPLACE FUNCTION support.fn_surviving_ticket(p_ticket_id integer)
RETURNS integer
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_next integer;
BEGIN
    SELECT merged_into_ticket_id INTO v_next
      FROM support.tickets
     WHERE ticket_id = p_ticket_id;

    IF v_next IS NULL THEN
        RETURN p_ticket_id;
    END IF;

    RETURN support.fn_surviving_ticket(v_next);
END;
$$;

-- ---------------------------------------------------------------------------
-- 31. A page of the ticket queue
-- ---------------------------------------------------------------------------
--
-- DEFECT offset-pagination-over-a-non-unique-order
--
-- A page of tickets, oldest first, for the queue screen's paging. LIMIT and
-- OFFSET are how paging is written and the ordering is the one the screen
-- shows.
--
-- opened_at is not unique, and OFFSET counts rows in an order that is only
-- partly determined. Rows tied on opened_at may come back in a different
-- arrangement on the query for page two than they did on page one, so a ticket
-- can appear on both pages and another can appear on neither. Nothing errors
-- and each page is individually correct.
--
-- Measured: 390 of the 600 tickets share an opened_at with another ticket, so
-- more than half of the queue sits on a tie. Agents have reported tickets
-- vanishing from the queue and being worked twice, which has been put down to
-- the other agent. Adding ticket_id as a second sort key makes the order total
-- and the paging exact.
CREATE OR REPLACE FUNCTION support.fn_ticket_page(p_offset integer)
RETURNS TABLE (ticket_id integer, opened_at timestamptz)
LANGUAGE sql
STABLE
AS $$
    SELECT t.ticket_id, t.opened_at
      FROM support.tickets t
     ORDER BY t.opened_at
     LIMIT 50 OFFSET p_offset;
$$;
