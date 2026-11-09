-- Cross River Trading Co. -- depot routes, contact cards, reprint queue,
-- freight bands, pallet notes, intake rows
-- author: T. Marchetti
-- postgres: 18
--
-- Which depot and region each route leg runs between, how customers are
-- contacted, which labels are waiting to reprint, how products are banded for
-- freight, what was noted against a pallet, and what each intake file brought.

-- DEFECT the-planner-has-no-statistics-for-two-columns-that-move-together
--
-- Every depot sits in exactly one region, and the planner has nothing that
-- tells it so, so a query naming both a depot and its region is estimated at
-- a fraction of a fraction and comes out near zero.
--
-- PostgreSQL keeps statistics per column. Given a filter on two columns it
-- multiplies the two selectivities, which is right when the columns are
-- independent and badly wrong when one determines the other. Here one depot
-- in forty and one region in eight multiply to one row in three hundred and
-- twenty, and the true answer is one in forty, because naming the region
-- after the depot excludes nothing. The reports name both, always, because
-- the screen has both boxes and the region is filled in from the depot when
-- the depot is picked. An estimate near zero makes the planner choose a
-- nested loop and a plan that assumes a handful of rows, and it gets four
-- hundred, on every leg of every route, in a join that is then executed four
-- hundred times. CREATE STATISTICS ... (dependencies) on the two columns is
-- one statement and ANALYZE picks the relationship up from the data.
--
-- Measured: 16,000 route legs across 40 depot codes and 8 region codes,
-- where the 40 distinct depots yield exactly 40 distinct depot and region
-- pairs, on a table carrying no extended statistics object.
--
-- Every leg names a real depot in its real region, the distances are right,
-- and the table is analysed on the usual schedule.
CREATE TABLE ops.depot_routes (
    leg_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code      text NOT NULL,
    region_code     text NOT NULL,
    carrier_ref     text NOT NULL,
    leg_km          numeric(7,1) NOT NULL
);

INSERT INTO ops.depot_routes (depot_code, region_code, carrier_ref, leg_km)
SELECT
    'DEP-' || lpad(((g % 40) + 1)::text, 3, '0'),
    'REG-' || lpad((((g % 40) / 5) + 1)::text, 2, '0'),
    'CAR-' || lpad(((g % 12) + 1)::text, 3, '0'),
    ((g % 400) + 12) / 10.0
FROM generate_series(1, 16000) g;

CREATE INDEX idx_depot_routes_depot ON ops.depot_routes (depot_code, region_code);

ANALYZE ops.depot_routes;

-- DEFECT the-type-gained-an-attribute-and-every-row-that-was-there-holds-nothing-in-it
--
-- The contact card is a composite type, a mobile number was added to that
-- type, and the four thousand cards already stored kept the shape they were
-- written in, so every one of them holds nothing where the mobile number
-- goes.
--
-- Adding an attribute to a composite type rewrites the tables that use it
-- and fills the new attribute with null, which is the only thing it can do.
-- Nothing else happens: there is no default to apply, no constraint to
-- violate, and no error. The cards captured since are complete, because the
-- form that writes them was changed in the same piece of work. So the column
-- is half populated along a line drawn on the day the type changed, and the
-- line is invisible from the data, because a card with no mobile number
-- looks exactly like a customer who did not give one. The dispatch text
-- message goes to everyone with a mobile number on file, which is a query
-- that returns the newer half of the book and looks entirely reasonable.
--
-- Measured: 6,000 contact cards of which 4,000 hold no mobile number in the
-- composite value, all of them captured before the attribute was added.
--
-- The numbers are in the older contact table the cards were built from and
-- can be backfilled from it. Every card names a real customer, every
-- landline and email is correct, and the cards captured after the change
-- carry the mobile number they were given.
CREATE TYPE support.contact_card AS (
    full_name    text,
    email        text,
    landline     text
);

CREATE TABLE support.contact_cards (
    card_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_ref text NOT NULL,
    card         support.contact_card NOT NULL,
    captured_on  date NOT NULL
);

INSERT INTO support.contact_cards (customer_ref, card, captured_on)
SELECT
    'CUS-' || lpad(g::text, 6, '0'),
    ROW(
        'Contact ' || g,
        'contact' || g || '@example.invalid',
        '020 7946 ' || lpad((g % 10000)::text, 4, '0')
    )::support.contact_card,
    DATE '2026-01-04' + ((g % 120) || ' days')::interval
FROM generate_series(1, 4000) g;

ALTER TYPE support.contact_card ADD ATTRIBUTE mobile text CASCADE;

-- Everything captured after the type changed carries a mobile number. Nothing went back
-- for the four thousand that were already stored.
INSERT INTO support.contact_cards (customer_ref, card, captured_on)
SELECT
    'CUS-' || lpad((4000 + g)::text, 6, '0'),
    ROW(
        'Contact ' || (4000 + g),
        'contact' || (4000 + g) || '@example.invalid',
        '020 7946 ' || lpad(((4000 + g) % 10000)::text, 4, '0'),
        '07700 ' || lpad(((4000 + g) % 1000000)::text, 6, '0')
    )::support.contact_card,
    DATE '2026-05-05' + ((g % 90) || ' days')::interval
FROM generate_series(1, 2000) g;

-- DEFECT index-cleanup-was-turned-off-so-vacuum-never-tidies-the-index
--
-- The reprint queue has index cleanup switched off, so vacuum reclaims the
-- table and leaves the index alone, and the index grows without bound on a
-- table whose whole content is replaced several times a day.
--
-- vacuum_index_cleanup = off tells vacuum to skip the index pass. It exists
-- for the case where a vacuum must finish quickly, usually to stop
-- transaction ids wrapping around, and it is meant to be set for that vacuum
-- and taken off again. It was set here during exactly such an incident, in
-- the ALTER TABLE that was the fastest way to apply it, and an ALTER TABLE
-- is permanent. Every vacuum since has been a partial one. The table stays
-- small, which is the number anyone looks at, and the index does not, so the
-- queue screen gets slower every week on a table of twelve thousand rows.
-- Reindexing fixes it for a month and it has been done twice.
--
-- Measured: 12,000 reprints on a table whose storage options carry
-- vacuum_index_cleanup switched off.
--
-- Resetting the option returns vacuum to its normal behaviour and one
-- REINDEX recovers what has already been lost. Every reprint names a real
-- consignment and printer, the printed timestamps are right, and the queue
-- is emptied correctly.
CREATE TABLE ops.reprint_queue (
    reprint_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    consignment   text NOT NULL,
    requested_at  timestamptz NOT NULL,
    printed_at    timestamptz,
    printer_ref   text NOT NULL
);

ALTER TABLE ops.reprint_queue SET (vacuum_index_cleanup = off);

INSERT INTO ops.reprint_queue (consignment, requested_at, printed_at, printer_ref)
SELECT
    'CON-' || lpad(g::text, 7, '0'),
    TIMESTAMPTZ '2026-06-01 06:00:00+01' + ((g % 20000) || ' minutes')::interval,
    CASE WHEN g % 10 = 0 THEN NULL
         ELSE TIMESTAMPTZ '2026-06-01 06:02:00+01' + ((g % 20000) || ' minutes')::interval END,
    'PRN-' || lpad(((g % 24) + 1)::text, 2, '0')
FROM generate_series(1, 12000) g;

-- DEFECT the-second-branch-of-the-case-is-unreachable-so-the-band-is-never-assigned
--
-- The banding rule tests for heavy before it tests for bulk, and heavy is
-- the wider test, so the bulk branch can never be reached and the band has
-- never once been assigned.
--
-- A CASE takes the first branch that matches. Over ten is checked first and
-- over twenty is checked second, and everything over twenty is already over
-- ten, so the second branch is dead code that the database will not warn
-- about, because it is a perfectly legal expression. The bulk band was added
-- later, appended below the rule that was there, which is where a new branch
-- naturally goes and is the one place it cannot go. Bulk carries a different
-- carrier and a different rate, so six thousand products are quoted at the
-- heavy rate and shipped on the heavy contract, which is cheaper per
-- consignment and wrong for the pallet space they take. The carrier invoices
-- for the space. The difference has been absorbed as a surcharge for a year.
--
-- Measured: 9,000 freight bands of which 6,000 weigh more than twenty kilos
-- and carry the heavy band, and 0 carry bulk.
--
-- Reordering the branches heaviest first fixes every future row, and the six
-- thousand can be rebanded in one update. Every weight is correct, every
-- product reference is real, and the light and heavy boundary at ten kilos
-- is applied exactly as the tariff states.
CREATE TABLE catalog.freight_bands (
    band_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_ref   text NOT NULL,
    weight_kg     numeric(7,2) NOT NULL,
    band_code     text NOT NULL
);

INSERT INTO catalog.freight_bands (product_ref, weight_kg, band_code)
SELECT
    'PRD-' || lpad(g::text, 6, '0'),
    w,
    CASE
        WHEN w > 10 THEN 'heavy'
        WHEN w > 20 THEN 'bulk'
        ELSE 'light'
    END
FROM (
    SELECT g, ((g % 60) + 0.5)::numeric(7,2) AS w
    FROM generate_series(1, 9000) g
) s;

-- DEFECT the-column-was-widened-and-the-check-that-caps-it-was-left-behind
--
-- The pallet note column was widened from a hundred and twenty characters to
-- four hundred and the check constraint that caps it at a hundred and twenty
-- was left in place, so the extra room does not exist and every long note is
-- cut to fit.
--
-- Widening a varchar is one statement and it is the statement everybody
-- remembers. The check was added separately, years earlier, to make the
-- limit explicit for a client that read constraints rather than types, and
-- it is not part of the column's type, so nothing about the widening touched
-- it. The loader was changed at the same time to allow the longer note, and
-- it truncates rather than fails, because a rejected pallet note stops a
-- goods receipt and a truncated one does not. So the schema says four
-- hundred, the type says four hundred, and the rows stop dead at a hundred
-- and twenty, which is exactly where a damage description stops being
-- useful.
--
-- Measured: 1,800 pallet notes exactly 120 characters long, on a column
-- declared to hold 400, under 1 check constraint that caps the length at
-- 120.
--
-- Dropping the constraint is the whole fix, and the full notes are still in
-- the goods receipt files they were loaded from. Every note is against the
-- right pallet and every note under the limit is stored in full.
CREATE TABLE supply.pallet_notes (
    note_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pallet_ref   text NOT NULL,
    note         varchar(120) NOT NULL,
    CONSTRAINT pallet_notes_length CHECK (length(note) <= 120)
);

ALTER TABLE supply.pallet_notes ALTER COLUMN note TYPE varchar(400);

INSERT INTO supply.pallet_notes (pallet_ref, note)
SELECT
    'PAL-' || lpad(g::text, 6, '0'),
    CASE WHEN g % 5 = 0
         THEN left(repeat('damage noted on the outer wrap at the corner nearest the label ', 8), 120)
         ELSE 'pallet ' || g || ' checked and wrapped' END
FROM generate_series(1, 9000) g;

-- DEFECT the-header-row-of-every-file-was-loaded-as-data
--
-- Every intake file starts with a row of column headings and the loader was
-- pointed at the whole file, so each file contributed one row whose supplier
-- reference is the words supplier ref and whose quantity is the words qty
-- text.
--
-- A COPY that is not told the file has a header treats the first line as
-- data, and it will succeed whenever the columns it lands in accept text,
-- which these do because the quantity is stored as text and parsed later.
-- Storing the quantity as text was itself a decision to survive bad files,
-- and it is what lets the bad row through. Nothing fails at load and nothing
-- fails afterwards either: the quantity parse is wrapped so an unparseable
-- value is skipped, so the header rows are counted in the row count of the
-- intake, reported to the supplier as received, and silently dropped from
-- the quantity total. The intake report and the quantity report therefore
-- disagree by one row per file, every day, which reads as a rounding
-- difference.
--
-- Measured: 9,000 intake rows across 300 files, of which 300 are the header
-- line of their file.
--
-- HEADER on the COPY skips it, and the three hundred rows already stored can
-- be removed by the value they hold. Every real row is against the right
-- supplier and file, the quantities parse correctly, and the received dates
-- are right.
CREATE TABLE supply.intake_rows (
    intake_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    file_ref      text NOT NULL,
    supplier_ref  text NOT NULL,
    qty_text      text NOT NULL,
    received_on   date NOT NULL
);

INSERT INTO supply.intake_rows (file_ref, supplier_ref, qty_text, received_on)
SELECT
    'INTAKE-' || lpad(f::text, 4, '0'),
    CASE WHEN r = 0 THEN 'supplier_ref' ELSE 'SUP-' || lpad(((f * 29 + r) % 500 + 1)::text, 4, '0') END,
    CASE WHEN r = 0 THEN 'qty_text' ELSE (((f * 7 + r) % 400) + 1)::text END,
    DATE '2026-07-01' + ((f % 30) || ' days')::interval
FROM generate_series(1, 300) f, generate_series(0, 29) r;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.depot_routes ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.depot_routes:' || concat_ws('|', x.depot_code, x.region_code, x.carrier_ref, x.leg_km))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.depot_routes x
)
UPDATE ops.depot_routes t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.depot_routes ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.depot_routes ADD CONSTRAINT depot_routes_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_depot_routes_store_id ON ops.depot_routes (store_id);

ALTER TABLE supply.intake_rows ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.intake_rows:' || concat_ws('|', x.file_ref, x.supplier_ref, x.qty_text))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.intake_rows x
)
UPDATE supply.intake_rows t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.intake_rows ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.intake_rows ADD CONSTRAINT intake_rows_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_intake_rows_purchase_order_id ON supply.intake_rows (purchase_order_id);

ALTER TABLE supply.pallet_notes ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.pallet_notes:' || concat_ws('|', x.pallet_ref, x.note))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.pallet_notes x
)
UPDATE supply.pallet_notes t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.pallet_notes ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.pallet_notes ADD CONSTRAINT pallet_notes_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_pallet_notes_purchase_order_id ON supply.pallet_notes (purchase_order_id);

ALTER TABLE support.contact_cards ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.contact_cards:' || concat_ws('|', x.customer_ref, x.card))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.contact_cards x
)
UPDATE support.contact_cards t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.contact_cards ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.contact_cards ADD CONSTRAINT contact_cards_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_contact_cards_ticket_id ON support.contact_cards (ticket_id);
-- <<< relationships
