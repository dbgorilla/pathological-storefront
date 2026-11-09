-- Cross River Trading Co. -- stored procedures written alongside supply schema
-- author: S. Okonjo
-- postgres: 10
--
-- Each procedure here was written once the tables it reads existed and
-- has not been revisited since.

-- ===========================================================================
-- 24. A validation that validates nothing
-- ===========================================================================

-- DEFECT raise-notice-instead-of-exception
--
-- Goods-in calls this before writing a receipt, to stop a line being received
-- in a larger quantity than it was ordered in. It was written by somebody
-- debugging the receipt flow, who wanted to see the over-receipts go past
-- before deciding what to do about them, and the decision was never taken.
--
-- RAISE NOTICE prints and continues. RAISE EXCEPTION stops the transaction.
-- The two words are one line apart in the manual and nothing about a NOTICE
-- makes the function refuse anything: it returns true whatever it was given,
-- so the caller writes the receipt.
--
-- Measured: an over-receipt returns true. The notice reaches the client, where
-- the driver discards it, and the server log, where it is one line among the
-- day's several thousand with no error level on it and nothing watching for
-- it. Goods-in have never seen it and have no reason to think the check does
-- anything other than pass.
CREATE OR REPLACE FUNCTION supply.fn_check_receipt(p_line_id integer, p_received integer)
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
    v_ordered integer;
BEGIN
    SELECT quantity_ordered INTO v_ordered
      FROM supply.purchase_order_lines
     WHERE purchase_order_line_id = p_line_id;

    IF p_received > v_ordered THEN
        RAISE NOTICE 'receipt of % exceeds the % ordered on line %',
            p_received, v_ordered, p_line_id;
    END IF;

    RETURN true;
END;
$$;

-- ---------------------------------------------------------------------------
-- 32. The supplier feed loader
-- ---------------------------------------------------------------------------
--
-- DEFECT insert-select-without-a-column-list-swaps-two-columns
--
-- Loads new suppliers from the procurement feed. The INSERT has no column
-- list, so the columns are matched by position. The feed exports code, then
-- contact address, then trading name, and the SELECT was written in the order
-- the feed arrives. The table declares name before contact_email.
--
-- Both are character varying and neither carries a constraint, so nothing
-- objects. The contact address is written into name and the trading name into
-- contact_email. Every screen that shows a supplier shows an email address
-- where the name goes, and every mail sent to a new supplier is addressed to
-- a string that is not an address.
--
-- A positional INSERT is also how this breaks a second time: adding a column
-- to supply.suppliers shifts every value one place to the right. Naming the
-- columns fixes both and is a one-line change.
CREATE OR REPLACE FUNCTION supply.fn_load_supplier_feed(p_code text, p_email text, p_name text)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_supplier_id integer;
BEGIN
    INSERT INTO supply.suppliers
    SELECT nextval('supply.suppliers_supplier_id_seq'),
           p_code,
           p_email,
           p_name,
           7,
           true,
           NULL
    RETURNING supplier_id INTO v_supplier_id;

    RETURN v_supplier_id;
END;
$$;

-- ---------------------------------------------------------------------------
-- 38. Outstanding purchase order value
-- ---------------------------------------------------------------------------
--
-- DEFECT return-inside-the-loop-stops-after-the-first-row
--
-- Adds up what has been ordered from suppliers and not yet received. The loop
-- is right, the accumulator is right, and the arithmetic is right.
--
-- The RETURN is inside the loop. PL/pgSQL returns from the function at the
-- first RETURN it reaches, so the loop runs exactly one iteration and the
-- function hands back the first line's value as though it were the total.
--
-- There is no warning: a RETURN inside a loop is legal and common, and the
-- indentation puts it in line with the accumulation. The number that comes
-- back is a real number of the right magnitude for a single line, which is
-- what has kept it from being questioned. Moving the RETURN below the END
-- LOOP is the whole fix.
--
-- Measured: the function returns 10,040. The real outstanding value is
-- 25,936,200, so the purchasing dashboard shows about four hundredths of one
-- per cent of the commitment it is there to report.
CREATE OR REPLACE FUNCTION supply.fn_outstanding_order_value()
RETURNS bigint LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_total bigint := 0;
    r       record;
BEGIN
    FOR r IN
        SELECT (quantity_ordered - quantity_received) * unit_cost_cents AS line_value
          FROM supply.purchase_order_lines
         WHERE quantity_received < quantity_ordered
         ORDER BY purchase_order_line_id
    LOOP
        v_total := v_total + coalesce(r.line_value, 0);
        RETURN v_total;
    END LOOP;

    RETURN v_total;
END;
$$;

-- ---------------------------------------------------------------------------
-- 42. Receipt batch
-- ---------------------------------------------------------------------------
--
-- DEFECT set-constraints-all-deferred-in-a-routine
--
-- Applies a delivery to a purchase order, line by line. The first version
-- failed halfway through a delivery and left the order half-received, so the
-- author reached for SET CONSTRAINTS ALL DEFERRED to push the checks to the
-- end and let the whole batch stand or fall together.
--
-- It does not do that, in either direction.
--
-- SET CONSTRAINTS only moves constraints that were declared DEFERRABLE. A
-- CHECK constraint can never be one, and neither can NOT NULL, and every
-- foreign key in this schema but one was created without the word. So the
-- constraints that actually reject a bad receipt line -- quantity_ordered > 0
-- and the receipt sanity check -- still fire on the statement that breaks
-- them, exactly as before, and the statement is still the thing that fails.
--
-- Measured: a check violation raised inside a transaction that had already
-- run this function failed on the statement, not at commit, exactly as it
-- would have anywhere else.
--
-- And every deferrable constraint this statement can reach is already
-- INITIALLY DEFERRED, so today the line changes nothing whatsoever. It is a
-- no-op that reads, to everyone who has looked at this function since, as the
-- thing making the batch atomic. The batch is not atomic and never was.
--
-- What it will do is leak. SET CONSTRAINTS is transaction-scoped, not
-- function-scoped, and it does not end when the function returns. The first
-- constraint anyone adds as DEFERRABLE INITIALLY IMMEDIATE -- which is how a
-- constraint meant to be deferred on request is normally written -- stops
-- being checked per statement for the rest of any transaction that called
-- this function, in callers that never asked for deferral and have no
-- handler for an error arriving at COMMIT with no statement attached to it.
CREATE OR REPLACE FUNCTION supply.fn_apply_receipt_batch(p_purchase_order_id integer)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
    v_lines integer;
BEGIN
    SET CONSTRAINTS ALL DEFERRED;

    UPDATE supply.purchase_order_lines
       SET quantity_received = quantity_ordered
     WHERE purchase_order_id = p_purchase_order_id;

    GET DIAGNOSTICS v_lines = ROW_COUNT;
    RETURN v_lines;
END;
$$;
