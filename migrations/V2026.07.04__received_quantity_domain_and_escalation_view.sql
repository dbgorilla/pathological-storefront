-- Cross River Trading Co. -- received quantity domain, escalation volume view
-- author: P. Halloran
-- postgres: 18
--
-- Two pieces of the 2026 supply and support clean-up: a domain that was
-- meant to make "quantity received" a type rather than a convention, and the
-- view behind the escalation dashboard.

-- DEFECT domain-not-null-defeated-by-an-outer-join
--
-- The domain was created so that a received quantity carries its own rules
-- wherever it goes: an integer, never negative, never unknown. NOT NULL is
-- in the type, not on the column, which was the point -- every column of
-- this type gets the rule without anyone having to remember it, and the
-- design note says NULL is now impossible for a received quantity anywhere
-- in the database.
--
-- A domain's NOT NULL is checked when a value is stored. It is not a
-- guarantee about values of that type in a result set, and an outer join
-- manufactures one out of nothing: the columns of the unmatched side come
-- back NULL, typed as the domain, with nothing checking them. The same is
-- true of a full join, a grouping set, and a scalar subquery that finds no
-- row.
--
-- Measured: the coverage view below returns 2,600 rows, of which 800 have a
-- NULL quantity_received -- one for each catalogue product that has never
-- appeared on a purchase order line. The type of that column says it cannot
-- happen.
--
-- The consumer is the reordering report, which keeps a line when
-- quantity_received > 0 and drops it otherwise. NULL > 0 is NULL, which is
-- not true, so all 800 products that have never been ordered are dropped
-- from the report that exists to find products that have never been
-- ordered. Nobody wrote a coalesce, because the type says there is nothing
-- to coalesce.
CREATE DOMAIN supply.received_quantity AS integer NOT NULL CHECK (VALUE >= 0);

ALTER TABLE supply.purchase_order_lines
    ALTER COLUMN quantity_received TYPE supply.received_quantity;

CREATE VIEW supply.v_product_receipt_coverage AS
SELECT p.product_id,
       p.sku,
       l.purchase_order_id,
       l.quantity_received
FROM storefront.products p
LEFT JOIN supply.purchase_order_lines l ON l.product_id = p.product_id;

-- DEFECT function-cost-understated-so-it-runs-first
--
-- The escalation dashboard shows priority-one tickets that have had a reply.
-- "Has had a reply" comes from a function, so the same definition can be
-- reused by the agent screen.
--
-- COST is how the planner is told what a function is worth. The default for
-- a SQL or plpgsql function is 100 units, which is already an understatement
-- for a function that runs a query. This one was given 0.0001 by someone
-- tuning a different query, where the function was in the SELECT list and
-- the low cost stopped the planner materialising a subquery.
--
-- In a WHERE clause, cost decides the order the conditions are evaluated
-- in: PostgreSQL sorts the qualifiers and applies the cheapest first. At
-- 0.0001 this function is, as far as the planner knows, cheaper than
-- comparing a smallint to a constant, so it runs before the priority
-- filter.
--
-- Measured: the plan puts the function first, and it is called 600 times --
-- once for every ticket in the table -- to return the 120 that are priority
-- one. Each call runs its own query against support.ticket_messages.
--
-- Nothing in the view is wrong. The dashboard returns the right tickets and
-- does five times the work it needs to, and the multiple is the ratio of
-- the table to the filter, so it grows as the ticket table does. Raising
-- the cost to the default 100 changes no result and reorders the plan.
--
-- plpgsql is what makes it stick: a one-statement SQL function is inlined
-- during planning and costed on what it actually does, which is how the
-- same mistake in a SQL function comes to nothing.
CREATE FUNCTION support.fn_ticket_has_replies(p_ticket_id integer)
RETURNS boolean
LANGUAGE plpgsql STABLE COST 0.0001 AS $$
DECLARE
    v_count integer;
BEGIN
    SELECT count(*) INTO v_count
      FROM support.ticket_messages
     WHERE ticket_id = p_ticket_id;
    RETURN v_count > 1;
END;
$$;

CREATE VIEW support.v_escalated_tickets AS
SELECT t.ticket_id,
       t.customer_id,
       t.opened_at
FROM support.tickets t
WHERE t.priority = 1
  AND support.fn_ticket_has_replies(t.ticket_id);
