-- Cross River Trading Co. -- gate tickets, charge lines, weigh events,
-- depot contracts, leaflet text, cycle counts
-- author: T. Marchetti
-- postgres: 18
--
-- Who came through the gate, what the card files charged, what crossed the
-- weighbridge, which depots are under contract, what the product leaflets say,
-- and what the cycle counts found.

-- DEFECT overriding-system-value-left-the-identity-sequence-behind
--
-- The gate tickets were loaded with their old numbers using OVERRIDING
-- SYSTEM VALUE, which tells the identity column to accept the supplied
-- value, and nothing moved the sequence afterwards, so the column that is
-- supposed to generate the number has never generated one and still begins
-- at one.
--
-- OVERRIDING SYSTEM VALUE exists for exactly this load: a table is being
-- migrated and the keys must come across unchanged. It does the job and it
-- does nothing else. The sequence is only advanced when the column is
-- allowed to generate, so after a load of nine thousand rows it is exactly
-- where it was. Two things follow. Every ticket issued from now is numbered
-- from one, so the printed ticket number is in a range the gate staff have
-- not seen since the old system, and a ticket number is how a driver is
-- identified at the barrier and on the paperwork. And when the sequence
-- eventually reaches the range that was loaded, every insert fails on the
-- primary key until somebody intervenes, with no warning before the first
-- failure.
--
-- Measured: 9,000 gate tickets, all of them numbered at or above the value
-- the identity sequence would next hand out.
--
-- setval on the identity sequence to just above the highest ticket is the
-- fix and takes one statement. Every ticket is unique, carries the vehicle
-- and gate it was issued at, and is stamped with the right arrival time.
CREATE TABLE ops.gate_tickets (
    ticket_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_reg  text NOT NULL,
    gate_code    text NOT NULL,
    arrived_at   timestamptz NOT NULL
);

INSERT INTO ops.gate_tickets (ticket_id, vehicle_reg, gate_code, arrived_at)
OVERRIDING SYSTEM VALUE
SELECT
    500000 + g,
    'REG' || lpad((g % 4000)::text, 5, '0'),
    'GATE-' || lpad(((g % 8) + 1)::text, 2, '0'),
    TIMESTAMPTZ '2026-05-04 05:30:00+01' + ((g % 30000) || ' minutes')::interval
FROM generate_series(1, 9000) g;

-- DEFECT union-instead-of-union-all-collapsed-identical-charge-lines
--
-- The day file and the late file are combined with UNION rather than UNION
-- ALL, so fifteen hundred charges that are genuinely separate and happen to
-- be identical in every stored column were folded into one row each and are
-- not billed.
--
-- UNION removes duplicate rows. That is its definition and it is why it is
-- slower than UNION ALL, and it is the wrong operator whenever the rows
-- carry no key. These rows carry no key: the combined table holds an
-- account, a date and an amount, because that is all the acquirer's file
-- gives and nothing was added to tell one line from another. Two charges to
-- the same account on the same day for the same amount are ordinary for a
-- customer with two deliveries, and there is no column that distinguishes
-- them, so the database cannot tell them apart and neither can anyone
-- reading the table. The loss is invisible from the combined table and the
-- daily total is short by the amount of the folded lines, which is why the
-- reconciliation against the acquirer is out by a few hundred pounds a
-- month.
--
-- Measured: 9,000 charges across the two source files and 7,500 in the
-- combined table, so 1,500 lost.
--
-- UNION ALL keeps every line, and a line identifier from the source file
-- makes the pair distinguishable for good. Both source files are complete,
-- every account reference is real, and every amount is correct as sent.
CREATE TABLE payments.charge_lines_day (
    account_ref  text NOT NULL,
    charged_on   date NOT NULL,
    amount_p     integer NOT NULL
);

CREATE TABLE payments.charge_lines_late (
    account_ref  text NOT NULL,
    charged_on   date NOT NULL,
    amount_p     integer NOT NULL
);

INSERT INTO payments.charge_lines_day (account_ref, charged_on, amount_p)
SELECT
    'ACC-' || lpad(g::text, 6, '0'),
    DATE '2026-06-01' + ((g % 30) || ' days')::interval,
    ((g % 900) + 100)
FROM generate_series(1, 6000) g;

-- The late file re-sends 1,500 charges that are genuinely separate from the ones
-- in the day file and identical to them in every stored column.
INSERT INTO payments.charge_lines_late (account_ref, charged_on, amount_p)
SELECT account_ref, charged_on, amount_p
FROM payments.charge_lines_day
ORDER BY account_ref
LIMIT 1500;

INSERT INTO payments.charge_lines_late (account_ref, charged_on, amount_p)
SELECT
    'ACC-' || lpad((6000 + g)::text, 6, '0'),
    DATE '2026-06-01' + ((g % 30) || ' days')::interval,
    ((g % 900) + 100)
FROM generate_series(1, 1500) g;

CREATE TABLE payments.charge_lines_combined (
    account_ref  text NOT NULL,
    charged_on   date NOT NULL,
    amount_p     integer NOT NULL
);

INSERT INTO payments.charge_lines_combined (account_ref, charged_on, amount_p)
SELECT account_ref, charged_on, amount_p FROM payments.charge_lines_day
UNION
SELECT account_ref, charged_on, amount_p FROM payments.charge_lines_late;

-- DEFECT the-brin-index-is-on-a-column-the-rows-are-not-stored-in-order-of
--
-- The weigh events carry a BRIN index on the time they were weighed, and the
-- rows are not stored in time order, so the index can exclude almost nothing
-- and every query that uses it reads the whole table anyway.
--
-- A BRIN index stores the smallest and largest value in each block range and
-- skips a range when the value being looked for falls outside it. That is
-- enormously cheap and it works only when the physical order of the rows
-- follows the indexed column, which is the normal case for an append-only
-- log. This table is not append-only: it is loaded from the six weighbridges
-- in the order their files arrive, so every block range spans nearly the
-- whole period and none of them can be skipped. The index is tiny, which is
-- what makes it attractive and what stops anyone noticing it: it costs
-- almost nothing to build, it is reported as used, and it returns the right
-- answer. It just returns it after reading everything.
--
-- Measured: 20,000 weigh events on a column whose statistical correlation
-- with physical order is under 0.01, behind 1 BRIN index.
--
-- A btree index on the same column answers the same queries properly, and
-- BRIN becomes right again if the table is ever clustered on the timestamp
-- and kept that way. Every event names a real weighbridge, the weights are
-- correct, and the timestamps are right to the second.
CREATE TABLE ops.weigh_events (
    event_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bridge_code  text NOT NULL,
    weighed_at   timestamptz NOT NULL,
    gross_kg     integer NOT NULL
);

INSERT INTO ops.weigh_events (bridge_code, weighed_at, gross_kg)
SELECT
    'WB-' || lpad(((g % 6) + 1)::text, 2, '0'),
    TIMESTAMPTZ '2026-04-01 06:00:00+01' + (((g * 7919) % 20000) || ' minutes')::interval,
    2000 + ((g * 37) % 28000)
FROM generate_series(1, 20000) g;

CREATE INDEX idx_weigh_events_weighed_at ON ops.weigh_events USING brin (weighed_at);

ANALYZE ops.weigh_events;

-- DEFECT the-composite-foreign-key-matches-simple-so-one-null-lets-the-row-through
--
-- The contracts reference the depot terms by depot and term together, and
-- the foreign key is MATCH SIMPLE, which is the default, so a row with one
-- of the two columns null is not checked at all and twelve hundred contracts
-- name a depot that has never existed.
--
-- MATCH SIMPLE means the key is checked only when every column in it is non-
-- null. MATCH FULL means it is checked unless every column is null. The
-- difference matters only for composite keys and only when one column can be
-- null, which is why it is almost never thought about, and the default is
-- the permissive one. The term column is nullable because a contract can be
-- signed before its terms are agreed, which is a real case and happens on
-- about one contract in five. So one contract in five is admitted with no
-- check on the depot either, and the depot code on those rows came from a
-- spreadsheet column that was never validated. The contract list joins to
-- the terms and those rows simply do not appear, which reads as contracts
-- awaiting terms rather than contracts naming nothing.
--
-- Measured: 6,000 depot contracts of which 1,200 have no term code and name
-- a depot that appears nowhere in the terms table.
--
-- MATCH FULL on the key rejects the mixed rows outright, and the twelve
-- hundred depot codes can be corrected from the signed contracts. Every
-- contract reference is unique, every signing date is right, and the 4,800
-- contracts with both columns filled reference terms that exist.
CREATE TABLE supply.depot_terms (
    depot_code   text NOT NULL,
    term_code    text NOT NULL,
    notice_days  smallint NOT NULL,
    PRIMARY KEY (depot_code, term_code)
);

INSERT INTO supply.depot_terms (depot_code, term_code, notice_days)
SELECT
    'DEP-' || lpad(d::text, 3, '0'),
    'TRM-' || lpad(t::text, 2, '0'),
    ((d + t) % 90) + 30
FROM generate_series(1, 40) d, generate_series(1, 6) t;

CREATE TABLE supply.depot_contracts (
    contract_ref text PRIMARY KEY,
    depot_code   text,
    term_code    text,
    signed_on    date NOT NULL,
    FOREIGN KEY (depot_code, term_code)
        REFERENCES supply.depot_terms (depot_code, term_code) MATCH SIMPLE
);

INSERT INTO supply.depot_contracts (contract_ref, depot_code, term_code, signed_on)
SELECT
    'CTR-' || lpad(g::text, 6, '0'),
    CASE WHEN g % 5 = 0
         THEN 'DEP-' || lpad((900 + (g % 40))::text, 3, '0')
         ELSE 'DEP-' || lpad(((g % 40) + 1)::text, 3, '0') END,
    CASE WHEN g % 5 = 0 THEN NULL
         ELSE 'TRM-' || lpad(((g % 6) + 1)::text, 2, '0') END,
    DATE '2026-01-06' + ((g % 240) || ' days')::interval
FROM generate_series(1, 6000) g;

-- DEFECT the-full-text-index-and-the-query-use-different-configurations
--
-- The leaflet text is indexed with the simple text search configuration and
-- the search screen queries it with the english one, so the index holds
-- whole words where the query holds stems and the two never meet on any word
-- that inflects.
--
-- A text search configuration decides how a document is cut into searchable
-- words, and the english one reduces a word to its stem, so returns and
-- returning and returned all become return. The simple configuration does no
-- stemming at all and stores returns as returns. The index was created with
-- simple because simple was the example in the note the work was copied
-- from, and the query uses english because english is the default
-- configuration of the database. Searching for return therefore finds
-- nothing in the index, and worse, the planner cannot use the index for that
-- query at all, so it falls back to a sequential scan that recomputes the
-- vector with english on every row and returns the right answer slowly. The
-- index is never wrong; it is simply never used.
--
-- Measured: 6,000 leaflets of which 2,400 match a stemmed english search
-- that the simple vector does not match.
--
-- Rebuilding the index with the english configuration, which is what the
-- query uses, is the whole fix. Every leaflet names a real product, the text
-- is stored intact, and the search returns the correct rows today.
CREATE TABLE catalog.leaflet_text (
    leaflet_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_ref  text NOT NULL,
    body         text NOT NULL
);

INSERT INTO catalog.leaflet_text (product_ref, body)
SELECT
    'PRD-' || lpad(g::text, 6, '0'),
    CASE WHEN g % 5 IN (0, 1)
         THEN 'This item accepts returns within twenty eight days of delivery.'
         ELSE 'This item is supplied with a twelve month guarantee from purchase.' END
FROM generate_series(1, 6000) g;

CREATE INDEX idx_leaflet_text_body ON catalog.leaflet_text
    USING gin (to_tsvector('simple', body));

-- DEFECT the-default-is-a-literal-date-that-was-current-when-the-table-was-made
--
-- The count date has a fixed date as its default rather than CURRENT_DATE,
-- so every count from the handheld, which does not send a date, is filed on
-- the day the table was created.
--
-- A default is an expression evaluated at insert. CURRENT_DATE evaluates to
-- the day the row is written; a written-out date evaluates to itself,
-- forever. The literal was put there during the build to make the first day
-- of counts land somewhere sensible, and it reads as a sensible default to
-- anyone scanning the table definition, because it is a real date in the
-- right format and it is in the past. The stock system supplies its own date
-- and is unaffected, which is two thirds of the rows and all of the rows
-- anyone looked at. The handheld counts are a third of the table and they
-- all claim to have happened on one day in February. Stock variance is
-- measured by comparing consecutive counts of the same location, and three
-- thousand counts stacked on a single date make that comparison meaningless
-- for every location the handheld covers.
--
-- Measured: 9,000 cycle counts of which 3,000 carry the default date while
-- the row itself was created on a different day.
--
-- DEFAULT CURRENT_DATE is the fix, and the three thousand can be re-dated
-- from the creation timestamp, which is correct on every row. Every count
-- names a real depot and counter, and the 6,000 counts that carry their own
-- date are right.
CREATE TABLE ops.cycle_counts (
    count_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code   text NOT NULL,
    counted_on   date NOT NULL DEFAULT DATE '2026-02-02',
    created_at   timestamptz NOT NULL,
    counted_by   text NOT NULL
);

-- The stock system supplies a date. The handheld does not, and takes the default.
INSERT INTO ops.cycle_counts (depot_code, counted_on, created_at, counted_by)
SELECT
    'DEP-' || lpad(((g % 40) + 1)::text, 3, '0'),
    DATE '2026-02-02' + ((g % 200) || ' days')::interval,
    TIMESTAMPTZ '2026-02-02 07:00:00+00' + ((g % 200) || ' days')::interval,
    'COUNTER-' || lpad(((g % 25) + 1)::text, 3, '0')
FROM generate_series(1, 6000) g;

INSERT INTO ops.cycle_counts (depot_code, created_at, counted_by)
SELECT
    'DEP-' || lpad(((g % 40) + 1)::text, 3, '0'),
    TIMESTAMPTZ '2026-02-03 07:00:00+00' + ((g % 199) || ' days')::interval,
    'HANDHELD-' || lpad(((g % 25) + 1)::text, 3, '0')
FROM generate_series(1, 3000) g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.leaflet_text ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.leaflet_text:' || concat_ws('|', x.product_ref, x.body))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.leaflet_text x
)
UPDATE catalog.leaflet_text t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.leaflet_text ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.leaflet_text ADD CONSTRAINT leaflet_text_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_leaflet_text_product_id ON catalog.leaflet_text (product_id);

ALTER TABLE ops.gate_tickets ADD COLUMN booking_id integer;

WITH p AS (
    SELECT booking_id AS v, row_number() OVER (ORDER BY booking_id) - 1 AS k
      FROM ops.gate_bookings
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.gate_bookings)
                 * power((abs(hashtext('ops.gate_tickets:' || concat_ws('|', x.vehicle_reg, x.gate_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.gate_tickets x
)
UPDATE ops.gate_tickets t
   SET booking_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.gate_tickets ALTER COLUMN booking_id SET NOT NULL;
ALTER TABLE ops.gate_tickets ADD CONSTRAINT gate_tickets_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES ops.gate_bookings (booking_id);
CREATE INDEX ix_gate_tickets_booking_id ON ops.gate_tickets (booking_id);

ALTER TABLE payments.charge_lines_combined ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.charge_lines_combined:' || concat_ws('|', x.account_ref, x.amount_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.charge_lines_combined x
)
UPDATE payments.charge_lines_combined t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.charge_lines_combined ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.charge_lines_combined ADD CONSTRAINT charge_lines_combined_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_charge_lines_combined_transaction_id ON payments.charge_lines_combined (transaction_id);

ALTER TABLE payments.charge_lines_day ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.charge_lines_day:' || concat_ws('|', x.account_ref, x.amount_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.charge_lines_day x
)
UPDATE payments.charge_lines_day t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.charge_lines_day ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.charge_lines_day ADD CONSTRAINT charge_lines_day_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_charge_lines_day_transaction_id ON payments.charge_lines_day (transaction_id);

ALTER TABLE payments.charge_lines_late ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.charge_lines_late:' || concat_ws('|', x.account_ref, x.amount_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.charge_lines_late x
)
UPDATE payments.charge_lines_late t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.charge_lines_late ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.charge_lines_late ADD CONSTRAINT charge_lines_late_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_charge_lines_late_transaction_id ON payments.charge_lines_late (transaction_id);
-- <<< relationships
