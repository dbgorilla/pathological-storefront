-- Cross River Trading Co. -- ticket freezing, claims, supplier log, VAT, events
-- author: P. Adeyemi
-- postgres: 18
--
-- Support desk hardening, the supplier change log purchasing asked for after the
-- lead time dispute, the VAT breakdown finance wanted on the order screen, and
-- the integration event store.

-- DEFECT before-update-trigger-returns-old-and-discards-the-change
--
-- Closed tickets are not supposed to change. The rule was agreed after an agent
-- reopened and edited a ticket that was already part of a chargeback, and it was
-- implemented in the obvious place, as a BEFORE UPDATE trigger.
--
-- A BEFORE row trigger returning OLD does not reject the update. It replaces the
-- proposed row with the existing one, so the write is applied and changes
-- nothing. No error is raised, no exception is available to catch, and the
-- command tag still counts the row as updated, because it was.
--
-- Measured: a bulk repriorisation set every ticket to priority 3. 600 rows were
-- reported updated and 120 closed tickets still hold their old priority. The
-- application read 600 back from the driver and logged a successful migration.
--
-- Raising an exception would have told the caller. Returning OLD tells nobody,
-- and every tool that checks the row count agrees the write succeeded. This is
-- the failure mode that makes a retry loop run forever without progressing.
CREATE FUNCTION support.fn_freeze_closed_tickets()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    IF OLD.status = 'closed' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_tickets_freeze_closed
    BEFORE UPDATE ON support.tickets
    FOR EACH ROW EXECUTE FUNCTION support.fn_freeze_closed_tickets();

COMMENT ON FUNCTION support.fn_freeze_closed_tickets() IS
    'Closed tickets are immutable. CRT-1980.';

-- The repriorisation that ran the week the trigger shipped.
UPDATE support.tickets SET priority = 3;

-- DEFECT partial-unique-index-allows-duplicates-outside-its-predicate
--
-- A ticket may be claimed by one agent at a time. The index enforces that, and
-- it is partial because a released claim is kept for the audit trail rather than
-- deleted, so the constraint can only apply to live ones.
--
-- The predicate names one state and the application has two. A claim being
-- handed between agents is written as 'reassigning', which the index does not
-- see, so two agents can hold a ticket at once provided at least one of them is
-- mid-handover. The index is doing exactly what it was asked; the rule it was
-- meant to enforce is wider than the predicate somebody wrote.
--
-- Measured: 30 tickets carry two live claims. Every one of them has an 'active'
-- claim and a 'reassigning' claim held by different agents, which the index
-- permits and the rule does not.
--
-- A partial unique index is the right tool here. The predicate has to match the
-- rule, and this one matched the rule as it stood in 2024, before handover was
-- added.
CREATE TABLE support.ticket_claims (
    claim_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_id  integer NOT NULL REFERENCES support.tickets(ticket_id),
    agent_id   integer NOT NULL REFERENCES support.agents(agent_id),
    state      varchar(20) NOT NULL CHECK (state IN ('active', 'reassigning', 'released')),
    claimed_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX ux_ticket_claims_one_active
    ON support.ticket_claims (ticket_id)
    WHERE state = 'active';

COMMENT ON INDEX support.ux_ticket_claims_one_active IS
    'One live claim per ticket.';

-- One active claim on 120 tickets.
INSERT INTO support.ticket_claims (ticket_id, agent_id, state)
SELECT t.ticket_id,
       1 + (t.ticket_id % 2),
       'active'
FROM support.tickets t
WHERE t.ticket_id % 5 = 0;

-- A handover in flight on a quarter of them, which the index does not cover.
INSERT INTO support.ticket_claims (ticket_id, agent_id, state)
SELECT t.ticket_id,
       1 + ((t.ticket_id + 1) % 2),
       'reassigning'
FROM support.tickets t
WHERE t.ticket_id % 20 = 0;

-- DEFECT trigger-fires-on-every-column-update
--
-- Purchasing wanted lead time changes recorded, after a supplier disputed one
-- and nobody could say when it had last moved. The log stores the old and new
-- lead time, which is exactly what was asked for.
--
-- The trigger has no UPDATE OF clause, so it fires for every update of every
-- column. A change of email address writes a lead time change row in which the
-- lead time did not change. The log is correct about what it recorded and wrong
-- about what it means, and it grows at the rate of all writes rather than the
-- rate of the writes anybody cares about.
--
-- Measured: an email normalisation touched all 40 suppliers and produced 40 log
-- rows, every one of them with old_lead_time_days equal to new_lead_time_days.
-- The whole log is currently noise.
--
-- UPDATE OF lead_time_days in the trigger definition is the fix and costs
-- nothing. The WHEN clause would also work. Neither was known to the author,
-- who tested by changing a lead time, which works perfectly.
CREATE TABLE supply.supplier_change_log (
    change_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id        integer NOT NULL,
    old_lead_time_days integer,
    new_lead_time_days integer,
    changed_at         timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION supply.fn_log_supplier_change()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO supply.supplier_change_log (supplier_id, old_lead_time_days, new_lead_time_days)
    VALUES (OLD.supplier_id, OLD.lead_time_days, NEW.lead_time_days);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_suppliers_log_change
    AFTER UPDATE ON supply.suppliers
    FOR EACH ROW EXECUTE FUNCTION supply.fn_log_supplier_change();

-- The email normalisation that ran the day after.
UPDATE supply.suppliers SET contact_email = lower(contact_email);

-- DEFECT vat-rounded-per-line-not-per-invoice
--
-- VAT at 20%, rounded to the penny. The view rounds each line and adds the
-- rounded figures up, which is what the order screen shows line by line, so the
-- lines and the total agree on screen.
--
-- They do not agree with the invoice. Rounding before summing and rounding after
-- summing are different operations, and the difference is a penny per order in
-- whichever direction the fractions happen to fall. Both are defensible
-- individually. Using one on the screen and the other on the invoice is not.
--
-- Measured: 925 of 13,880 orders have a per-line VAT total that differs from VAT
-- on the order total, and the drift across the whole table is 925 pennies, all
-- in the same direction.
--
-- HMRC permits either method, provided one is used consistently. Cross River
-- uses both, and the reconciliation between the order screen and the VAT return
-- has an unexplained line called "rounding" that grows with order volume.
CREATE VIEW analytics.v_order_vat AS
SELECT oi.order_id,
       sum(oi.line_total_cents)               AS net_cents,
       sum(round(oi.line_total_cents * 0.20)) AS vat_cents
FROM storefront.order_items oi
GROUP BY oi.order_id;

-- DEFECT jsonb-path-ops-index-cannot-answer-key-existence
--
-- The event store is queried two ways: by containment, to find events matching a
-- shape, and by key existence, to find events carrying a field at all. The index
-- was built with jsonb_path_ops because a benchmark showed it smaller and faster
-- than the default, which it is.
--
-- jsonb_path_ops indexes only the paths to values. It supports @> and it does
-- not support ?, ?| or ?&, so every key existence query falls back to a
-- sequential scan of the whole table. The index is present, it is used, and it
-- is used for half the workload.
--
-- Measured: the payload index is the only jsonb_path_ops index in the database.
-- The default jsonb_ops opclass serves both operator families and would cost
-- more space.
--
-- Nothing reports this. The queries return correct answers, the index shows as
-- used in the statistics because the containment queries use it, and the slow
-- half is invisible unless somebody reads a plan for the right query.
CREATE TABLE ops.integration_events (
    event_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source       varchar(40) NOT NULL,
    payload      jsonb NOT NULL,
    received_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO ops.integration_events (source, payload)
SELECT CASE WHEN g % 3 = 0 THEN 'carrier' ELSE 'payments' END,
       jsonb_build_object(
           'event', CASE WHEN g % 3 = 0 THEN 'dispatch' ELSE 'settlement' END,
           'ref', 'E' || lpad(g::text, 6, '0'),
           'attempts', 1 + (g % 3)
       ) || CASE WHEN g % 7 = 0 THEN jsonb_build_object('retry_after', 300) ELSE '{}'::jsonb END
FROM generate_series(1, 800) AS g;

CREATE INDEX ix_integration_events_payload
    ON ops.integration_events USING gin (payload jsonb_path_ops);

-- DEFECT numeric-scale-rounds-on-insert-without-warning
--
-- Suppliers quote tax at four decimal places and the column holds two. The
-- column was sized from the rates in use at the time, which were whole
-- percentages, and nobody revisited it when the reduced and reverse-charge rates
-- arrived.
--
-- numeric(4,2) does not reject a value with more precision. It rounds it and
-- stores the result, silently, on every insert. There is no warning, no error
-- and no record of the original, so the loss is undetectable from inside the
-- database once the statement has committed.
--
-- Measured: five distinct rates were loaded, 0.175 through 0.179, and the column
-- holds one value. Every invoice in the register now claims the same tax rate.
--
-- The rates differ by a twentieth of a percent, which is small until it is
-- applied to a year of purchasing and reconciled against what the suppliers
-- actually charged. That reconciliation is done by hand and has never matched.
ALTER TABLE supply.supplier_invoices
    ADD COLUMN tax_rate numeric(4,2);

UPDATE supply.supplier_invoices
   SET tax_rate = 0.175 + (invoice_id % 5) * 0.001;

COMMENT ON COLUMN supply.supplier_invoices.tax_rate IS
    'Supplier tax rate. Sized for whole percentages in 2019.';
