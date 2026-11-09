-- Cross River Trading Co. -- adjustment totals, consignment matching,
-- commission rounding, email suppression, goods in notes, contractor records
-- author: R. Okonjo
-- postgres: 18
--
-- The adjustments report finance reconciles against, the consignment chase
-- list, the agent commission run, the marketing suppression list, the goods in
-- note the warehouse writes, and the contractor register.

-- DEFECT union-instead-of-union-all-drops-the-matching-adjustments
--
-- Credit and debit adjustments live in separate tables, which is reasonable,
-- and the reconciliation view stacks them with UNION.
--
-- UNION removes duplicate rows. Two adjustments are the same row when they
-- carry the same order, amount, date and reason, and that is exactly what a
-- correction pair looks like: a debit raised in error and the credit that
-- reversed it, entered the same day for the same money. The view keeps one of
-- the two and the report balances for the wrong reason.
--
-- Measured: 900 credits and 900 debits, and the view returns 1,740 rows. The
-- 60 that vanished are the correction pairs, which is the set finance most
-- needs to see.
--
-- UNION ALL is what stacking two ledgers means. Nothing here fails and the
-- totals look tidier than they should, so the view has never been questioned.
CREATE TABLE payments.credit_adjustments (
    adjustment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref     varchar(16) NOT NULL,
    amount        numeric(12,2) NOT NULL,
    adjusted_on   date NOT NULL,
    reason        varchar(24) NOT NULL
);

CREATE TABLE payments.debit_adjustments (
    adjustment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref     varchar(16) NOT NULL,
    amount        numeric(12,2) NOT NULL,
    adjusted_on   date NOT NULL,
    reason        varchar(24) NOT NULL
);

INSERT INTO payments.credit_adjustments (order_ref, amount, adjusted_on, reason)
SELECT 'ORD-' || lpad(g::text, 8, '0'),
       (5 + (g % 400))::numeric(12,2),
       DATE '2026-05-01' + (g % 90),
       CASE WHEN g % 15 = 0 THEN 'correction'
            ELSE (ARRAY['goodwill', 'shortage', 'price query'])[1 + (g % 3)]
       END
FROM generate_series(1, 900) AS g;

INSERT INTO payments.debit_adjustments (order_ref, amount, adjusted_on, reason)
SELECT 'ORD-' || lpad((g + 500000)::text, 8, '0'),
       (5 + (g % 400))::numeric(12,2),
       DATE '2026-05-01' + (g % 90),
       (ARRAY['carriage', 'restock fee', 'late payment'])[1 + (g % 3)]
FROM generate_series(1, 840) AS g;

-- The correction pairs: a debit raised in error and reversed the same day.
INSERT INTO payments.debit_adjustments (order_ref, amount, adjusted_on, reason)
SELECT c.order_ref, c.amount, c.adjusted_on, c.reason
FROM payments.credit_adjustments c
WHERE c.reason = 'correction';

CREATE VIEW analytics.v_all_adjustments AS
SELECT order_ref, amount, adjusted_on, reason FROM payments.credit_adjustments
UNION
SELECT order_ref, amount, adjusted_on, reason FROM payments.debit_adjustments;

-- DEFECT not-in-against-a-nullable-column-returns-nothing-at-all
--
-- The chase list is the consignments with no receipt against them, written as
-- NOT IN over the receipt references.
--
-- Receipt references are nullable, because a receipt booked in by hand at the
-- gate sometimes has no consignment to hang off. A single NULL anywhere in a
-- NOT IN subquery makes the whole condition unknown for every row, so the
-- chase list is empty. Not short: empty.
--
-- Measured: 800 consignments, 200 of them with no receipt, 12 receipts with a
-- null reference, and a chase list showing 0.
--
-- NOT EXISTS gives the 200. The buying desk reads an empty chase list as good
-- news and has done for as long as anyone remembers, which is why the missing
-- consignments surface as supplier queries instead.
CREATE TABLE supply.consignments (
    consignment_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    consignment_ref varchar(16) NOT NULL UNIQUE,
    supplier_ref    varchar(12) NOT NULL,
    despatched_on   date NOT NULL
);

CREATE TABLE supply.consignment_receipts (
    receipt_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    consignment_ref varchar(16),
    received_on     date NOT NULL,
    received_by     varchar(24) NOT NULL
);

INSERT INTO supply.consignments (consignment_ref, supplier_ref, despatched_on)
SELECT 'CNS-' || lpad(g::text, 8, '0'),
       'SUP-' || lpad((1 + (g % 70))::text, 3, '0'),
       DATE '2026-06-01' + (g % 45)
FROM generate_series(1, 800) AS g;

INSERT INTO supply.consignment_receipts (consignment_ref, received_on, received_by)
SELECT 'CNS-' || lpad(g::text, 8, '0'),
       DATE '2026-06-03' + (g % 45),
       'goods in ' || (1 + (g % 9))::text
FROM generate_series(1, 600) AS g;

-- Booked in by hand at the gate, with no consignment to hang off.
INSERT INTO supply.consignment_receipts (consignment_ref, received_on, received_by)
SELECT NULL,
       DATE '2026-06-10' + g,
       'gatehouse'
FROM generate_series(1, 12) AS g;

CREATE VIEW analytics.v_unmatched_consignments AS
SELECT c.consignment_id, c.consignment_ref, c.supplier_ref, c.despatched_on
FROM supply.consignments c
WHERE c.consignment_ref NOT IN (SELECT r.consignment_ref
                                FROM supply.consignment_receipts r);

-- DEFECT money-column-rounds-every-commission-line-to-the-penny
--
-- Agent commission arrives from the sales feed at four decimal places, because
-- it is a percentage of a line value and that is what a percentage gives you.
-- The column it lands in is the money type.
--
-- The money type holds two decimal places and rounds on the way in. Every line
-- with a third or fourth decimal is rounded at the point it is stored, so the
-- rounding is done once per line instead of once per payment, and the agent's
-- total is out by however those roundings fell. The source figure is kept
-- alongside, which is the only reason this can be seen at all.
--
-- Measured: 600 commission lines, 450 of them stored at a value that differs
-- from the feed. The money type also formats in dollars here, on a business
-- that has only ever traded in sterling.
--
-- numeric(12,4) holds what the feed sends and rounds once, at the end. Agents
-- query their statements by a few pence every month and are told it is
-- rounding, which is true and is not an explanation.
CREATE TABLE payments.commission_lines (
    line_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_ref     varchar(12) NOT NULL,
    order_ref     varchar(16) NOT NULL,
    source_amount numeric(12,4) NOT NULL,
    amount        money NOT NULL,
    earned_on     date NOT NULL
);

INSERT INTO payments.commission_lines (agent_ref, order_ref, source_amount, amount, earned_on)
SELECT 'AGT-' || lpad((1 + (g % 40))::text, 3, '0'),
       'ORD-' || lpad((700000 + g)::text, 8, '0'),
       (5.0 + (g * 0.0025))::numeric(12,4),
       (5.0 + (g * 0.0025))::numeric(12,4)::money,
       DATE '2026-07-01' + (g % 30)
FROM generate_series(1, 600) AS g;

-- DEFECT partial-unique-index-excludes-the-rows-that-need-it
--
-- Contact addresses carry a unique index, so the suppression list cannot hold
-- the same address twice. The index has a WHERE clause on it: it applies only
-- to subscribed contacts.
--
-- Unsubscribed contacts are precisely the rows the uniqueness matters for,
-- because the suppression check is what stops a mailing going to somebody who
-- asked to be left alone. Under the partial index the same address can be
-- unsubscribed any number of times, and each of those rows carries its own
-- unsubscribe date and its own reason.
--
-- Measured: 1,800 contacts. 360 of the unsubscribed rows hold an address that
-- is unsubscribed more than once, and 600 of them hold an address that appears
-- more than once somewhere in the table.
--
-- Two consequences, and they pull in opposite directions. Resubscribing a
-- duplicated address violates the index the moment the status changes, in the
-- middle of a preference update. And a suppression check written with a single
-- row in mind reads one of the duplicates and can find the one that says the
-- contact is still contactable.
CREATE TABLE marketing.contact_emails (
    contact_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email          varchar(120) NOT NULL,
    status         varchar(16) NOT NULL,
    added_on       date NOT NULL,
    unsubscribed_on date
);

CREATE UNIQUE INDEX contact_emails_live_email
    ON marketing.contact_emails (lower(email))
    WHERE status = 'subscribed';

INSERT INTO marketing.contact_emails (email, status, added_on, unsubscribed_on)
SELECT 'contact' || g || '@example.invalid',
       'subscribed',
       DATE '2024-01-01' + (g % 700),
       NULL
FROM generate_series(1, 1200) AS g;

INSERT INTO marketing.contact_emails (email, status, added_on, unsubscribed_on)
SELECT 'contact' || (600 + g) || '@example.invalid',
       'unsubscribed',
       DATE '2024-06-01' + (g % 400),
       DATE '2026-01-01' + (g % 200)
FROM generate_series(1, 420) AS g;

-- The same addresses again, unsubscribed a second time on a later mailing.
INSERT INTO marketing.contact_emails (email, status, added_on, unsubscribed_on)
SELECT 'contact' || (600 + g) || '@example.invalid',
       'unsubscribed',
       DATE '2025-02-01' + (g % 300),
       DATE '2026-04-01' + (g % 120)
FROM generate_series(1, 180) AS g;

-- DEFECT writer-role-can-insert-but-cannot-use-the-sequence
--
-- The goods in role was granted what it needs to write a goods in note: usage
-- on the schema, and select and insert on the table.
--
-- The key column is a serial, so an insert that leaves it out reads the
-- sequence, and the role has no privilege on the sequence. Every insert from
-- that role fails on permission denied for sequence, naming an object the
-- grant script never mentions and nobody thinks of as a thing with its own
-- permissions.
--
-- Measured: the role holds insert on supply.goods_in_notes and does not hold
-- usage on supply.goods_in_notes_note_id_seq.
--
-- An identity column takes the privilege from the table and removes the trap.
-- The warehouse works around this by booking goods in under a shared account
-- that has more privileges than it should, which is how a permission gap turns
-- into an audit finding.
CREATE TABLE supply.goods_in_notes (
    note_id      serial PRIMARY KEY,
    consignment_ref varchar(16) NOT NULL,
    depot_code   varchar(12) NOT NULL,
    booked_at    timestamptz NOT NULL,
    booked_by    varchar(24) NOT NULL
);

INSERT INTO supply.goods_in_notes (consignment_ref, depot_code, booked_at, booked_by)
SELECT 'CNS-' || lpad(g::text, 8, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-06-01 07:00:00+01' + (g * INTERVAL '35 minutes'),
       'goods in ' || (1 + (g % 9))::text
FROM generate_series(1, 500) AS g;

CREATE ROLE goods_in_writer NOLOGIN;
GRANT USAGE ON SCHEMA supply TO goods_in_writer;
GRANT SELECT, INSERT ON supply.goods_in_notes TO goods_in_writer;

-- DEFECT unique-constraint-treats-every-null-as-distinct
--
-- A contractor is identified by a national insurance number, and the column
-- carries a unique constraint so the register cannot hold the same person
-- twice.
--
-- The number is not always known on the day a contractor starts, so the column
-- is nullable, and a unique constraint treats every null as distinct from
-- every other. The rows without a number are the ones most likely to be
-- entered twice, because the agency sends the person back through the same
-- sign up, and those are exactly the rows the constraint lets through.
--
-- Measured: 900 contractor records, 300 with no number, and 120 people held
-- twice under the same agency and the same name.
--
-- UNIQUE NULLS NOT DISTINCT would allow one unknown per register, which is not
-- what is wanted either; the register wants a key it can actually fill in. The
-- duplicates are found when a contractor is paid twice, which happens about
-- once a quarter and is treated as a payroll error each time.
CREATE TABLE support.contractor_records (
    record_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agency_ref      varchar(12) NOT NULL,
    contractor_name varchar(60) NOT NULL,
    national_id     varchar(12) UNIQUE,
    started_on      date NOT NULL
);

INSERT INTO support.contractor_records (agency_ref, contractor_name, national_id, started_on)
SELECT 'AGY-' || lpad((1 + (g % 18))::text, 3, '0'),
       'Contractor ' || g,
       'NI' || lpad(g::text, 9, '0'),
       DATE '2025-09-01' + (g % 300)
FROM generate_series(1, 600) AS g;

INSERT INTO support.contractor_records (agency_ref, contractor_name, national_id, started_on)
SELECT 'AGY-' || lpad((1 + (g % 18))::text, 3, '0'),
       'Contractor ' || (600 + g),
       NULL,
       DATE '2026-02-01' + (g % 150)
FROM generate_series(1, 180) AS g;

-- Sent back through the same sign up, still without a number.
INSERT INTO support.contractor_records (agency_ref, contractor_name, national_id, started_on)
SELECT r.agency_ref, r.contractor_name, NULL, r.started_on + 21
FROM support.contractor_records r
WHERE r.national_id IS NULL AND r.record_id % 3 <> 0;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE marketing.contact_emails ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('marketing.contact_emails:' || concat_ws('|', x.email, x.status))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.contact_emails x
)
UPDATE marketing.contact_emails t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.contact_emails ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE marketing.contact_emails ADD CONSTRAINT contact_emails_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_contact_emails_customer_id ON marketing.contact_emails (customer_id);

ALTER TABLE payments.commission_lines ADD COLUMN run_id integer;

WITH p AS (
    SELECT run_id AS v, row_number() OVER (ORDER BY run_id) - 1 AS k
      FROM payments.commission_runs
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.commission_runs)
                 * power((abs(hashtext('payments.commission_lines:' || concat_ws('|', x.agent_ref, x.order_ref, x.source_amount, x.amount))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.commission_lines x
)
UPDATE payments.commission_lines t
   SET run_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.commission_lines ALTER COLUMN run_id SET NOT NULL;
ALTER TABLE payments.commission_lines ADD CONSTRAINT commission_lines_run_id_fkey FOREIGN KEY (run_id) REFERENCES payments.commission_runs (run_id);
CREATE INDEX ix_commission_lines_run_id ON payments.commission_lines (run_id);

ALTER TABLE payments.credit_adjustments ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.credit_adjustments:' || concat_ws('|', x.order_ref, x.amount, x.reason))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.credit_adjustments x
)
UPDATE payments.credit_adjustments t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.credit_adjustments ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.credit_adjustments ADD CONSTRAINT credit_adjustments_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_credit_adjustments_transaction_id ON payments.credit_adjustments (transaction_id);

ALTER TABLE payments.debit_adjustments ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.debit_adjustments:' || concat_ws('|', x.order_ref, x.amount, x.reason))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.debit_adjustments x
)
UPDATE payments.debit_adjustments t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.debit_adjustments ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.debit_adjustments ADD CONSTRAINT debit_adjustments_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_debit_adjustments_transaction_id ON payments.debit_adjustments (transaction_id);

ALTER TABLE supply.consignment_receipts ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.consignment_receipts:' || concat_ws('|', x.consignment_ref, x.received_by))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.consignment_receipts x
)
UPDATE supply.consignment_receipts t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.consignment_receipts ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.consignment_receipts ADD CONSTRAINT consignment_receipts_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_consignment_receipts_purchase_order_id ON supply.consignment_receipts (purchase_order_id);

ALTER TABLE supply.consignments ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.consignments:' || concat_ws('|', x.consignment_ref, x.supplier_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.consignments x
)
UPDATE supply.consignments t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.consignments ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.consignments ADD CONSTRAINT consignments_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_consignments_purchase_order_id ON supply.consignments (purchase_order_id);

ALTER TABLE supply.goods_in_lines ADD COLUMN note_id integer;

WITH p AS (
    SELECT note_id AS v, row_number() OVER (ORDER BY note_id) - 1 AS k
      FROM supply.goods_in_notes
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.goods_in_notes)
                 * power((abs(hashtext('supply.goods_in_lines:' || concat_ws('|', x.po_ref, x.batch_code, x.qty))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.goods_in_lines x
)
UPDATE supply.goods_in_lines t
   SET note_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.goods_in_lines ALTER COLUMN note_id SET NOT NULL;
ALTER TABLE supply.goods_in_lines ADD CONSTRAINT goods_in_lines_note_id_fkey FOREIGN KEY (note_id) REFERENCES supply.goods_in_notes (note_id);
CREATE INDEX ix_goods_in_lines_note_id ON supply.goods_in_lines (note_id);

ALTER TABLE supply.goods_in_notes ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.goods_in_notes:' || concat_ws('|', x.consignment_ref, x.depot_code, x.booked_by))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.goods_in_notes x
)
UPDATE supply.goods_in_notes t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.goods_in_notes ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.goods_in_notes ADD CONSTRAINT goods_in_notes_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_goods_in_notes_purchase_order_id ON supply.goods_in_notes (purchase_order_id);

ALTER TABLE support.contractor_records ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.contractor_records:' || concat_ws('|', x.agency_ref, x.contractor_name, x.national_id))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.contractor_records x
)
UPDATE support.contractor_records t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.contractor_records ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.contractor_records ADD CONSTRAINT contractor_records_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_contractor_records_ticket_id ON support.contractor_records (ticket_id);
-- <<< relationships
