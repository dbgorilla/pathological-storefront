-- Cross River Trading Co. -- order status rows, reconciliation working table,
-- delivery notes, belt reads, hazard sheets, gift wraps
-- author: J. Whitcombe
-- postgres: 18
--
-- The order status the old system writes, the working table from a
-- reconciliation that finished two years ago, the supplier delivery note, the
-- belt read log, the hazard data sheet, and the gift wrap charge.

-- DEFECT status-code-ninety-nine-means-test-and-two-people-know
--
-- Order status is a number. One is taken, two is picked, three is despatched,
-- nine is cancelled, and ninety-nine means the order is a test.
--
-- Ninety-nine is written nowhere. There is no lookup table, no constraint and
-- no comment on the column; it is a convention two people in the warehouse
-- agreed to when the system went in, and one of them has retired. Every report
-- written since counts those orders as real, because nothing in the database
-- suggests they are anything else, and they are indistinguishable from real
-- orders in every other column.
--
-- Measured: 3,000 order status rows, 300 of them at status ninety-nine.
--
-- A lookup table with a name against each code makes the convention readable,
-- and a boolean for test orders makes it enforceable. The test orders are
-- spread evenly through the history, so they inflate every period by about the
-- same amount and no trend looks wrong.
CREATE TABLE legacy.order_status_rows (
    status_row_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref     varchar(16) NOT NULL,
    status_code   smallint NOT NULL,
    set_at        timestamptz NOT NULL,
    set_by        varchar(24) NOT NULL
);

INSERT INTO legacy.order_status_rows (order_ref, status_code, set_at, set_by)
SELECT 'ORD-' || lpad((900000 + g)::text, 8, '0'),
       CASE WHEN g % 10 = 0 THEN 99
            WHEN g % 10 = 1 THEN 9
            ELSE 1 + (g % 3)
       END,
       TIMESTAMPTZ '2026-01-05 08:00:00+00' + (g * INTERVAL '17 minutes'),
       'operator ' || (1 + (g % 18))::text
FROM generate_series(1, 3000) AS g;

-- DEFECT reconciliation-working-table-was-never-dropped
--
-- A reconciliation in 2024 needed somewhere to put its working rows, so it made
-- a table in the archive schema and filled it.
--
-- The reconciliation finished. The table did not go anywhere. Nothing reads it,
-- nothing writes to it, no foreign key points at it and no view mentions it,
-- and it is backed up, vacuumed and replicated every day along with everything
-- else. Its name says 2024 and its contents are a snapshot of a problem that
-- was solved, which makes it exactly the kind of object nobody is willing to
-- drop without asking somebody who no longer works here.
--
-- Measured: 8,000 rows in the working table and nothing in the database
-- depending on it.
--
-- Dropping it is the fix and the obstacle is confidence, not effort. A working
-- table created in a schema that is backed up, rather than as a temporary
-- table, is what turns a scratch pad into an artefact.
CREATE TABLE archive.tmp_reconcile_2024 (
    row_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    left_ref     varchar(20) NOT NULL,
    right_ref    varchar(20),
    left_amount  numeric(12,2) NOT NULL,
    right_amount numeric(12,2),
    matched      boolean NOT NULL
);

INSERT INTO archive.tmp_reconcile_2024 (left_ref, right_ref, left_amount, right_amount, matched)
SELECT 'L-' || lpad(g::text, 10, '0'),
       CASE WHEN g % 7 = 0 THEN NULL ELSE 'R-' || lpad(g::text, 10, '0') END,
       (10 + (g % 5000))::numeric(12,2),
       CASE WHEN g % 7 = 0 THEN NULL ELSE (10 + (g % 5000))::numeric(12,2) END,
       g % 7 <> 0
FROM generate_series(1, 8000) AS g;

-- DEFECT delivery-note-numbers-restart-each-year-and-the-key-does-not
--
-- Supplier delivery notes are keyed by their note number. The supplier restarts
-- its note numbers at one every January.
--
-- The note number is unique within a year and the key treats it as unique for
-- all time. The loader inserts what it can and skips what collides, so the
-- first year loaded is complete and every year after it silently loses every
-- note whose number was used before. The loader counts what it read, which is
-- the only reason the loss is countable at all.
--
-- Measured: 2,400 delivery note lines read across two years and 1,200 notes in
-- the table, the missing 1,200 being the second year's.
--
-- The key is the year and the number together, which is what the supplier's own
-- paperwork means. The second year's notes are simply absent, so nothing in the
-- table looks wrong: it looks like a year of trading that did not happen.
CREATE TABLE supply.delivery_notes (
    note_no      integer PRIMARY KEY,
    note_year    integer NOT NULL,
    supplier_ref varchar(12) NOT NULL,
    received_on  date NOT NULL,
    lines        integer NOT NULL
);

CREATE TABLE supply.delivery_note_loads (
    load_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    load_year  integer NOT NULL,
    notes_read integer NOT NULL
);

INSERT INTO supply.delivery_notes (note_no, note_year, supplier_ref, received_on, lines)
SELECT g, 2025,
       'SUP-' || lpad((1 + (g % 70))::text, 3, '0'),
       DATE '2025-01-01' + (g % 360),
       1 + (g % 25)
FROM generate_series(1, 1200) AS g;

-- The second year, loaded by a loader that skips what collides.
INSERT INTO supply.delivery_notes (note_no, note_year, supplier_ref, received_on, lines)
SELECT g, 2026,
       'SUP-' || lpad((1 + (g % 70))::text, 3, '0'),
       DATE '2026-01-01' + (g % 360),
       1 + (g % 25)
FROM generate_series(1, 1200) AS g
ON CONFLICT (note_no) DO NOTHING;

INSERT INTO supply.delivery_note_loads (load_year, notes_read)
VALUES (2025, 1200), (2026, 1200);

-- DEFECT nine-indexes-on-the-table-that-takes-the-most-inserts
--
-- The belt read log is the busiest table in the building. It has nine indexes.
--
-- Each one was added for a query somebody needed once, and none was ever
-- removed. Every insert now writes the row and then writes nine index entries,
-- so the table takes ten times the write work of the row itself, and the
-- indexes are most of its size on disc. Reads are excellent. The belt does not
-- read anything; it writes, several times a second, all day.
--
-- Measured: 12,000 belt reads under 9 indexes, not counting the primary key.
--
-- Two or three indexes covering the queries that actually run is the fix, and
-- deciding which those are needs the statistics nobody has looked at. Adding an
-- index is always a local improvement and removing one always feels like a
-- risk, which is how a table gets to nine.
CREATE TABLE ops.belt_reads (
    read_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    belt_code   integer NOT NULL,
    parcel_ref  varchar(16) NOT NULL,
    depot_code  varchar(12) NOT NULL,
    read_at     timestamptz NOT NULL,
    weight_g    integer NOT NULL,
    length_mm   integer NOT NULL,
    operator    varchar(24) NOT NULL,
    shift_code  varchar(8) NOT NULL,
    outcome     varchar(12) NOT NULL
);

INSERT INTO ops.belt_reads (belt_code, parcel_ref, depot_code, read_at, weight_g, length_mm, operator, shift_code, outcome)
SELECT 1 + (g % 8),
       'PCL-' || lpad((900000 + g)::text, 8, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-07-01 05:00:00+01' + (g * INTERVAL '37 seconds'),
       200 + (g % 24000),
       80 + (g % 900),
       'operator ' || (1 + (g % 18))::text,
       'SH-' || (1 + (g % 3))::text,
       (ARRAY['read', 'no read', 'reject'])[1 + (g % 3)]
FROM generate_series(1, 12000) AS g;

CREATE INDEX belt_reads_belt_idx ON ops.belt_reads (belt_code);
CREATE INDEX belt_reads_parcel_idx ON ops.belt_reads (parcel_ref);
CREATE INDEX belt_reads_depot_idx ON ops.belt_reads (depot_code);
CREATE INDEX belt_reads_read_at_idx ON ops.belt_reads (read_at);
CREATE INDEX belt_reads_weight_idx ON ops.belt_reads (weight_g);
CREATE INDEX belt_reads_length_idx ON ops.belt_reads (length_mm);
CREATE INDEX belt_reads_operator_idx ON ops.belt_reads (operator);
CREATE INDEX belt_reads_shift_idx ON ops.belt_reads (shift_code);
CREATE INDEX belt_reads_outcome_idx ON ops.belt_reads (outcome);

-- DEFECT hazard-sheet-is-required-by-law-and-nullable-in-the-schema
--
-- Every hazardous product must have a data sheet on file. The column that holds
-- the reference to it is nullable.
--
-- Nothing at the point of entry makes it mandatory either, so a product can be
-- set up, listed and sold with the sheet left empty, and it is: the sheet
-- arrives from the supplier days or weeks after the product is set up, and
-- nothing comes back to fill it in. The obligation is real and the schema
-- treats it as optional, which is exactly the kind of gap that is discovered by
-- an inspection rather than by a report.
--
-- Measured: 1,200 hazardous products and 400 with no data sheet reference.
--
-- NOT NULL is the fix if the sheet can be insisted on at setup, and a status
-- column with a deadline is the fix if it cannot. Products without a sheet
-- trade normally and look exactly like products with one everywhere except the
-- column itself.
CREATE TABLE supply.hazard_sheets (
    product_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku          varchar(20) NOT NULL,
    hazard_class varchar(16) NOT NULL,
    sheet_ref    varchar(40),
    listed_on    date NOT NULL
);

INSERT INTO supply.hazard_sheets (sku, hazard_class, sheet_ref, listed_on)
SELECT 'SKU-' || lpad(((g * 31) % 900000)::text, 8, '0'),
       (ARRAY['flammable', 'corrosive', 'oxidiser', 'irritant'])[1 + (g % 4)],
       CASE WHEN g % 3 = 0 THEN NULL ELSE 'DS-' || lpad(g::text, 8, '0') END,
       DATE '2024-01-01' + (g % 900)
FROM generate_series(1, 1200) AS g;

-- DEFECT null-gift-wrap-charge-means-free-and-also-means-not-recorded
--
-- The gift wrap charge is null when the wrapping was free, and null when the
-- charge was never recorded.
--
-- One column, two meanings, and nothing to tell them apart. The promotion that
-- gave free wrapping through December wrote nulls, and the counter terminal
-- that was misconfigured for three weeks in February wrote nulls, and both look
-- identical now. Sum skips nulls, so the wrapping revenue is understated by the
-- February rows and correctly excludes the December ones, in one figure that
-- cannot be decomposed.
--
-- Measured: 2,000 gift wraps, 600 with a null charge, of which 400 were free
-- and 200 were never recorded, distinguishable only by the date.
--
-- Zero means free and null means unknown, and that is the whole distinction
-- this column needs. The wrapping revenue is a small number that nobody
-- forecasts, so being understated has never raised a question.
CREATE TABLE storefront.gift_wraps (
    wrap_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref  varchar(16) NOT NULL,
    wrap_style varchar(16) NOT NULL,
    charge     numeric(8,2),
    wrapped_on date NOT NULL
);

INSERT INTO storefront.gift_wraps (order_ref, wrap_style, charge, wrapped_on)
SELECT 'ORD-' || lpad((950000 + g)::text, 8, '0'),
       (ARRAY['plain', 'ribbon', 'boxed', 'seasonal'])[1 + (g % 4)],
       CASE WHEN g % 10 IN (0, 1, 2) THEN NULL
            ELSE (2 + (g % 8))::numeric(8,2)
       END,
       CASE WHEN g % 10 IN (0, 1) THEN DATE '2025-12-01' + (g % 30)
            WHEN g % 10 = 2 THEN DATE '2026-02-03' + (g % 21)
            ELSE DATE '2026-03-01' + (g % 200)
       END
FROM generate_series(1, 2000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE legacy.order_status_rows ADD COLUMN order_id uuid;

WITH p AS (
    SELECT id AS v, row_number() OVER (ORDER BY id) - 1 AS k
      FROM legacy.orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM legacy.orders)
                 * power((abs(hashtext('legacy.order_status_rows:' || concat_ws('|', x.order_ref, x.status_code, x.set_by))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM legacy.order_status_rows x
)
UPDATE legacy.order_status_rows t
   SET order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE legacy.order_status_rows ALTER COLUMN order_id SET NOT NULL;
ALTER TABLE legacy.order_status_rows ADD CONSTRAINT order_status_rows_order_id_fkey FOREIGN KEY (order_id) REFERENCES legacy.orders (id);
CREATE INDEX ix_order_status_rows_order_id ON legacy.order_status_rows (order_id);

ALTER TABLE storefront.gift_wraps ADD COLUMN order_id integer;

WITH p AS (
    SELECT order_id AS v, row_number() OVER (ORDER BY order_id) - 1 AS k
      FROM storefront.orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.orders)
                 * power((abs(hashtext('storefront.gift_wraps:' || concat_ws('|', x.order_ref, x.wrap_style, x.charge))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.gift_wraps x
)
UPDATE storefront.gift_wraps t
   SET order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.gift_wraps ALTER COLUMN order_id SET NOT NULL;
ALTER TABLE storefront.gift_wraps ADD CONSTRAINT gift_wraps_order_id_fkey FOREIGN KEY (order_id) REFERENCES storefront.orders (order_id);
CREATE INDEX ix_gift_wraps_order_id ON storefront.gift_wraps (order_id);

ALTER TABLE supply.delivery_note_loads ADD COLUMN note_no integer;

WITH p AS (
    SELECT note_no AS v, row_number() OVER (ORDER BY note_no) - 1 AS k
      FROM supply.delivery_notes
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.delivery_notes)
                 * power((abs(hashtext('supply.delivery_note_loads:' || concat_ws('|', x.load_year, x.notes_read))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.delivery_note_loads x
)
UPDATE supply.delivery_note_loads t
   SET note_no = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.delivery_note_loads ALTER COLUMN note_no SET NOT NULL;
ALTER TABLE supply.delivery_note_loads ADD CONSTRAINT delivery_note_loads_note_no_fkey FOREIGN KEY (note_no) REFERENCES supply.delivery_notes (note_no);
CREATE INDEX ix_delivery_note_loads_note_no ON supply.delivery_note_loads (note_no);

ALTER TABLE supply.delivery_notes ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.delivery_notes:' || concat_ws('|', x.note_no, x.note_year, x.supplier_ref, x.lines))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.delivery_notes x
)
UPDATE supply.delivery_notes t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.delivery_notes ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.delivery_notes ADD CONSTRAINT delivery_notes_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_delivery_notes_purchase_order_id ON supply.delivery_notes (purchase_order_id);
-- <<< relationships
