-- Cross River Trading Co. -- framework contracts, api imports, callback
-- slots, depot stock lines, case histories, seal numbers
-- author: T. Marchetti
-- postgres: 18
--
-- What we have committed to buy, what the overnight import brought back, when
-- somebody asked to be rung, what each depot says it holds, everything that
-- has happened on a case, and the seal on a trailer door.

-- DEFECT the-contract-value-column-stops-at-ninety-nine-million
--
-- Framework contract values are held in numeric(10,2), which stops at
-- 99,999,999.99. Two hundred contracts are already above ninety million.
--
-- Ten digits with two after the point was chosen when the largest framework
-- was eleven million, and it is a sensible shape for money: exact, no
-- rounding, no floating point. What it is not is open ended. Numeric with a
-- declared precision raises an error on overflow rather than rounding, so the
-- day a framework is signed at a hundred million the insert fails, in the
-- contract management screen, with a message about field overflow that means
-- nothing to the buyer typing it. Group turnover has trebled since the column
-- was declared and frameworks are being consolidated deliberately.
--
-- Measured: 1,200 framework contracts of which 200 exceed ninety million
-- pounds, in a column declared numeric(10,2).
--
-- Widening to numeric(14,2) is a rewrite of a small table and nothing else
-- changes. Every value in the column is exact and correct, and no contract has
-- ever been refused.
CREATE TABLE supply.framework_contracts (
    contract_ref varchar(16) PRIMARY KEY,
    supplier_ref varchar(12) NOT NULL,
    value_gbp    numeric(10,2) NOT NULL,
    signed_on    date NOT NULL
);

INSERT INTO supply.framework_contracts (contract_ref, supplier_ref, value_gbp, signed_on)
SELECT 'FWK-' || lpad(g::text, 8, '0'),
       'SUP-' || lpad((1 + (g % 600))::text, 6, '0'),
       CASE WHEN g % 6 = 0
            THEN 90000000 + (g * 1000)
            ELSE 250000 + (g * 900)
       END,
       DATE '2021-11-03' + (g % 1700)
FROM generate_series(1, 1200) AS g;

-- DEFECT the-import-stops-at-the-first-page-the-api-returns
--
-- The supplier portal import reads the first page of the API's response and
-- stops. Every daily import holds exactly one thousand rows.
--
-- The API pages at a thousand and returns a continuation token beside the
-- rows. The client reads the rows, ignores the token, and reports the number
-- of rows it loaded, which is a number that looks like a healthy import and is
-- the same every day, which looks like a stable feed. It went unnoticed
-- because for the first year the supplier portal held fewer than a thousand
-- records a day. The rows that are missing are the ones the API sorts last,
-- which is by supplier reference, so the back half of the alphabet has been
-- invisible to the buying report since the volume crossed the page size.
--
-- Measured: 30 daily imports of which every one holds exactly 1,000 rows, the
-- page size of the source API.
--
-- Following the continuation token is a small change to the client and will
-- multiply the table by an unknown factor, which is the point. Every row that
-- was loaded is correct, and the import has never failed or reported an error.
CREATE TABLE analytics.api_imports (
    import_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    imported_on  date NOT NULL,
    supplier_ref varchar(12) NOT NULL,
    record_ref   varchar(24) NOT NULL,
    payload_size integer NOT NULL
);

INSERT INTO analytics.api_imports (imported_on, supplier_ref, record_ref, payload_size)
SELECT DATE '2026-08-01' + d,
       'SUP-' || lpad((1 + (g % 300))::text, 6, '0'),
       'REC-' || lpad(((d * 1000) + g)::text, 12, '0'),
       800 + (g % 3000)
FROM generate_series(0, 29) AS d CROSS JOIN generate_series(1, 1000) AS g;

-- DEFECT setval-was-called-with-is-called-false-so-the-next-key-repeats
--
-- The callback slot sequence was reset to the highest key in the table with
-- the is_called flag set to false, which means the next value it hands out is
-- that same key.
--
-- Resetting a sequence after a restore is routine and the shape of the call is
-- setval(sequence, max(id)). The third argument defaults to true, meaning the
-- value has been used and the next one will be one higher. Passing false makes
-- the sequence hand out the value itself, which is the right thing after
-- setval(sequence, 1, false) on an empty table and is wrong after a restore.
-- The restore was a rehearsal that was kept, so this is the live sequence. The
-- next callback booked collides with the newest row in the table, and the
-- insert fails on the primary key, which will read as the booking screen being
-- broken.
--
-- Measured: 6,000 callback slots whose highest key is 6,000, against a
-- sequence sitting at 6,000 with is_called false.
--
-- One setval with the default third argument puts it right, before the next
-- booking rather than after it. The sequence is owned, attached and working,
-- and the table is intact.
CREATE SEQUENCE support.callback_slot_seq;

CREATE TABLE support.callback_slots (
    slot_id     integer PRIMARY KEY DEFAULT nextval('support.callback_slot_seq'),
    case_ref    varchar(16) NOT NULL,
    phone_no    varchar(20) NOT NULL,
    ring_after  timestamptz NOT NULL
);

ALTER SEQUENCE support.callback_slot_seq OWNED BY support.callback_slots.slot_id;

INSERT INTO support.callback_slots (case_ref, phone_no, ring_after)
SELECT 'CAS-' || lpad((1 + (g % 3200))::text, 10, '0'),
       '020 7' || lpad((100000 + (g % 800000))::text, 6, '0'),
       TIMESTAMPTZ '2026-09-07 09:00:00+01' + (g * INTERVAL '7 minutes')
FROM generate_series(1, 6000) AS g;

-- The reset that was done after the restore rehearsal.
SELECT setval('support.callback_slot_seq', (SELECT max(slot_id) FROM support.callback_slots), false);

-- DEFECT only-half-the-composite-reference-has-a-foreign-key
--
-- A depot stock line names a depot and a product. The product has a foreign
-- key and the pair has nothing, so a line can name a product the depot has
-- never stocked.
--
-- The stock profile, which says which products a depot holds, is keyed on the
-- pair. The stock line was built first, against the product catalogue, and the
-- profile arrived a year later when depots started specialising. Declaring the
-- foreign key on the pair would mean the profile row has to exist before the
-- stock line, which is true of the real process and was not true of the
-- overnight load, so it was left off "for now". Replenishment reads the stock
-- line, orders against it, and the goods arrive at a depot with no bay set up
-- to receive them.
--
-- Measured: 9,000 depot stock lines of which 900 name a depot and product pair
-- that is not in the 8,000 row stock profile table.
--
-- The foreign key wants declaring on the pair and the nine hundred lines want
-- resolving first. Every line names a real depot and a real product, and every
-- single column foreign key on the table is satisfied.
CREATE TABLE supply.depot_stock_profiles (
    depot_code varchar(12) NOT NULL,
    sku        varchar(16) NOT NULL,
    bay_code   varchar(10) NOT NULL,
    PRIMARY KEY (depot_code, sku)
);

CREATE TABLE supply.depot_stock_lines (
    line_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    sku        varchar(16) NOT NULL,
    on_hand    integer NOT NULL,
    counted_on date NOT NULL
);

INSERT INTO supply.depot_stock_profiles (depot_code, sku, bay_code)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       'SKU-' || lpad((1 + (g / 40))::text, 8, '0'),
       'BAY-' || lpad((1 + (g % 220))::text, 4, '0')
FROM generate_series(0, 7999) AS g;

INSERT INTO supply.depot_stock_lines (depot_code, sku, on_hand, counted_on)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       CASE WHEN g % 10 = 0
            THEN 'SKU-' || lpad((900000 + g)::text, 8, '0')
            ELSE 'SKU-' || lpad((1 + ((g / 40) % 200))::text, 8, '0')
       END,
       g % 400,
       DATE '2026-08-24' + (g % 20)
FROM generate_series(1, 9000) AS g;

-- DEFECT the-whole-case-history-is-rewritten-on-every-note
--
-- The case history is one text column holding every event on the case. Adding
-- an event reads the column, appends to it and writes the whole thing back.
--
-- It was built that way so that the case screen is one row read, which it is,
-- and it is the fastest case screen in the estate. Writing is the other half
-- of the trade and nobody measured it. A case with two hundred events has had
-- its history column written two hundred times, at an average of half the
-- final size, so a twelve kilobyte history has cost well over a megabyte of
-- writes and two hundred TOAST round trips. It is also not concurrent: two
-- agents adding a note at once means one of the notes is not there.
--
-- Measured: 1,200 case histories each holding 200 appended events in a single
-- 12,200 character column.
--
-- An events table with one row per event makes the write a single insert and
-- the read a cheap ordered scan. Every history is complete, in order, and
-- renders correctly on the case screen.
CREATE TABLE support.case_histories (
    case_ref     varchar(16) PRIMARY KEY,
    event_count  integer NOT NULL,
    history_text text NOT NULL,
    updated_at   timestamptz NOT NULL
);

INSERT INTO support.case_histories (case_ref, event_count, history_text, updated_at)
SELECT 'CAS-' || lpad(g::text, 10, '0'),
       200,
       repeat('2026-01-01 agent note: customer called, call back requested; ', 200),
       TIMESTAMPTZ '2026-09-10 12:00:00+01' + (g * INTERVAL '2 minutes')
FROM generate_series(1, 1200) AS g;

-- DEFECT the-unique-key-is-on-the-first-eight-characters-of-the-reference
--
-- The seal number is unique on its first eight characters. Seal numbers are
-- fourteen characters and the first eight are the manufacturer and batch.
--
-- The index was written as an expression over a substring because the loader
-- was matching on a truncated reference printed on the old paper log, and
-- making that match unique seemed like the way to stop the same seal being
-- entered twice. It stops far more than that: every seal in a batch shares its
-- first eight characters, so the second seal from any batch is refused. The
-- loader catches the error, writes the row to a rejects table, and carries on,
-- which is why nothing has ever alerted. A trailer with no seal recorded
-- cannot be signed off at the far end.
--
-- Measured: 1,800 seal numbers loaded against 1,200 rejected by a unique index
-- declared over the first eight characters of the reference.
--
-- The index wants to be on the whole reference. It is valid, it is enforced,
-- and it does exactly what it was declared to do.
CREATE TABLE ops.seal_numbers (
    seal_no    varchar(14) PRIMARY KEY,
    trailer_no varchar(10) NOT NULL,
    applied_at timestamptz NOT NULL
);

CREATE UNIQUE INDEX seal_numbers_prefix_idx
    ON ops.seal_numbers (substr(seal_no, 1, 8));

CREATE TABLE ops.seal_number_rejects (
    reject_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seal_no   varchar(14) NOT NULL,
    reason    varchar(60) NOT NULL,
    seen_at   timestamptz NOT NULL
);

-- One seal per batch gets in.
INSERT INTO ops.seal_numbers (seal_no, trailer_no, applied_at)
SELECT 'CRS' || lpad(g::text, 5, '0') || lpad((1 + (g % 3))::text, 6, '0'),
       'TRL-' || lpad((1 + (g % 300))::text, 5, '0'),
       TIMESTAMPTZ '2026-07-13 04:00:00+01' + (g * INTERVAL '9 minutes')
FROM generate_series(1, 1800) AS g;

-- The rest of every batch, which the loader wrote aside.
INSERT INTO ops.seal_number_rejects (seal_no, reason, seen_at)
SELECT 'CRS' || lpad(g::text, 5, '0') || lpad((4 + (g % 3))::text, 6, '0'),
       'duplicate key value violates unique constraint',
       TIMESTAMPTZ '2026-07-13 04:00:00+01' + (g * INTERVAL '9 minutes')
FROM generate_series(1, 1200) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.seal_number_rejects ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('ops.seal_number_rejects:' || concat_ws('|', x.seal_no, x.reason))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.seal_number_rejects x
)
UPDATE ops.seal_number_rejects t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.seal_number_rejects ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE ops.seal_number_rejects ADD CONSTRAINT seal_number_rejects_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_seal_number_rejects_shipment_id ON ops.seal_number_rejects (shipment_id);

ALTER TABLE ops.seal_numbers ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('ops.seal_numbers:' || concat_ws('|', x.seal_no, x.trailer_no))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.seal_numbers x
)
UPDATE ops.seal_numbers t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.seal_numbers ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE ops.seal_numbers ADD CONSTRAINT seal_numbers_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_seal_numbers_shipment_id ON ops.seal_numbers (shipment_id);

ALTER TABLE supply.framework_contracts ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.framework_contracts:' || concat_ws('|', x.contract_ref, x.supplier_ref, x.value_gbp))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.framework_contracts x
)
UPDATE supply.framework_contracts t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.framework_contracts ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.framework_contracts ADD CONSTRAINT framework_contracts_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_framework_contracts_supplier_id ON supply.framework_contracts (supplier_id);

ALTER TABLE support.callback_slots ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.callback_slots:' || concat_ws('|', x.case_ref, x.phone_no))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.callback_slots x
)
UPDATE support.callback_slots t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.callback_slots ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.callback_slots ADD CONSTRAINT callback_slots_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_callback_slots_ticket_id ON support.callback_slots (ticket_id);

ALTER TABLE support.case_histories ADD COLUMN case_id integer;

WITH p AS (
    SELECT case_id AS v, row_number() OVER (ORDER BY case_id) - 1 AS k
      FROM support.case_records
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.case_records)
                 * power((abs(hashtext('support.case_histories:' || concat_ws('|', x.case_ref, x.event_count, x.history_text))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.case_histories x
)
UPDATE support.case_histories t
   SET case_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.case_histories ALTER COLUMN case_id SET NOT NULL;
ALTER TABLE support.case_histories ADD CONSTRAINT case_histories_case_id_fkey FOREIGN KEY (case_id) REFERENCES support.case_records (case_id);
CREATE INDEX ix_case_histories_case_id ON support.case_histories (case_id);
-- <<< relationships
