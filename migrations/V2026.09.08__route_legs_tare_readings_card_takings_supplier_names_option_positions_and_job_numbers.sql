-- Cross River Trading Co. -- route legs, tare readings, card takings,
-- supplier names, option positions, job numbers
-- author: T. Marchetti
-- postgres: 18
--
-- How far each leg of a route runs, what came over the weighbridge, what the
-- card machines took, what the suppliers are called, which options a product
-- lists, and how the works orders are numbered.

-- DEFECT the-planner-was-told-the-column-holds-one-value
--
-- The route code column carries an n_distinct override of one, so the planner
-- believes every leg is on the same route, and it plans as though any filter
-- on the route returns the whole table.
--
-- n_distinct can be set per column to tell the planner what ANALYZE cannot
-- work out for itself, and it is the right tool on a column whose sampled
-- estimate swings. It was set here during a tuning session on a table that had
-- one route in it at the time, to stop the estimate collapsing to nothing, and
-- it was never revisited when the other three hundred and ninety nine routes
-- arrived. An override is not a hint, it is an assertion, and ANALYZE will not
-- correct it: the value is taken as given every time the table is planned. So
-- a query for one route is estimated at twelve thousand rows and gets a
-- sequential scan and a hash join, when it returns thirty rows and wanted an
-- index. The estimate is visible in every plan, and it is the one number in a
-- plan that people assume ANALYZE keeps honest.
--
-- Measured: 12,000 route legs across 400 route codes on a column whose
-- declared n_distinct is 1.
--
-- Resetting the option to zero returns the column to the sampled estimate, and
-- ANALYZE does the rest. Every leg is on a real route, the distances are
-- right, and the table is analysed on the usual schedule.
CREATE TABLE ops.route_legs (
    leg_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    route_code  varchar(10) NOT NULL,
    leg_seq     smallint NOT NULL,
    distance_km numeric(6,1) NOT NULL
);

INSERT INTO ops.route_legs (route_code, leg_seq, distance_km)
SELECT 'RTE-' || lpad((1 + (g % 400))::text, 5, '0'),
       1 + (g % 12),
       (5 + (g % 180))::numeric / 2
FROM generate_series(1, 12000) AS g;

ALTER TABLE ops.route_legs ALTER COLUMN route_code SET (n_distinct = 1);

-- DEFECT the-check-was-declared-no-inherit-so-the-child-carries-nothing
--
-- The weighbridge check that a net weight is positive was declared NO INHERIT,
-- so the northern depot's table, which inherits from it, is under no check at
-- all and holds six hundred readings at or below zero.
--
-- NO INHERIT means the constraint applies to this table and to nothing that
-- inherits from it. It exists for the case where the parent is a real table
-- with rules of its own that the children do not share, and it was written
-- here because the constraint was added while the parent was being backfilled
-- and the child was in the middle of a load that would have failed. The
-- clause was a way to get the constraint on without stopping the load, and the
-- follow-up never happened. Selecting from the parent reads the child as well,
-- so the bad readings are in every report the parent feeds, and the constraint
-- is right there in the parent's definition for anyone who checks whether such
-- a rule exists. It does exist. It just does not reach where the rows are.
--
-- Measured: 5,000 tare readings visible through the parent, of which 600 are
-- at or below zero, all of them in the inheriting table, under one check
-- constraint marked as not inherited.
--
-- Re-declaring the constraint without NO INHERIT, after correcting the six
-- hundred, puts both tables under it. Every reading is stamped with the right
-- depot and time, the parent's own rows all satisfy the rule, and the
-- inheritance is set up correctly in every other respect.
CREATE TABLE supply.tare_readings (
    reading_id  integer NOT NULL,
    depot_code  varchar(12) NOT NULL,
    weighed_at  timestamptz NOT NULL,
    net_kg      numeric(8,1) NOT NULL,
    CONSTRAINT tare_readings_net_positive CHECK (net_kg > 0) NO INHERIT
);

CREATE TABLE supply.tare_readings_north () INHERITS (supply.tare_readings);

INSERT INTO supply.tare_readings (reading_id, depot_code, weighed_at, net_kg)
SELECT g, 'DEP-' || lpad((1 + (g % 20))::text, 3, '0'),
       TIMESTAMPTZ '2026-07-06 05:00:00+01' + (g * INTERVAL '3 minutes'),
       (200 + (g % 9000))::numeric / 10
FROM generate_series(1, 2000) AS g;

-- The northern depot, whose loader has never had anything to satisfy.
INSERT INTO supply.tare_readings_north (reading_id, depot_code, weighed_at, net_kg)
SELECT 100000 + g, 'DEP-N' || lpad((1 + (g % 5))::text, 2, '0'),
       TIMESTAMPTZ '2026-07-06 05:00:00+01' + (g * INTERVAL '2 minutes'),
       CASE WHEN g % 5 = 0
            THEN 0 - ((g % 40))::numeric / 10
            ELSE (300 + (g % 8000))::numeric / 10
       END
FROM generate_series(1, 3000) AS g;

-- DEFECT the-day-is-cut-at-midnight-utc-for-a-business-that-trades-in-london
--
-- The business day on every card taking is cut at midnight UTC, and the shops
-- trade in London, so through the summer every taking in the first hour after
-- midnight is filed under the day before.
--
-- The timestamp is a timestamptz and is exactly right. The business day was
-- derived from it by reading it at UTC, which is what you get if you cast
-- without saying a zone, and for half the year UTC and London are the same, so
-- the derivation was correct when it was written in February and tested the
-- same week. From the last Sunday in March it is an hour out, and only for the
-- takings between midnight and one, which is a quiet hour everywhere except
-- the two sites with a late licence. The daily banking reconciles against the
-- acquirer, whose day is London, and it has been out by a handful of
-- transactions every night since spring, small enough that the difference is
-- carried forward rather than investigated.
--
-- Measured: 12,000 card takings of which 500 carry a business day that is not
-- the London day they were taken on, summarised into 31 daily totals.
--
-- Deriving the day with AT TIME ZONE 'Europe/London' is the fix, and it is
-- correct in both halves of the year. Every taking is stamped to the second
-- with the right instant, every amount is right, and the totals are the
-- correct sum of the rows filed under each day.
CREATE TABLE payments.card_takings (
    taking_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    site_code    varchar(10) NOT NULL,
    taken_at     timestamptz NOT NULL,
    business_day date NOT NULL,
    amount_p     integer NOT NULL
);

CREATE TABLE analytics.card_day_totals (
    total_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    business_day date NOT NULL,
    amount_p     bigint NOT NULL,
    takings      integer NOT NULL
);

INSERT INTO payments.card_takings (site_code, taken_at, business_day, amount_p)
SELECT 'SITE-' || lpad((1 + (g % 30))::text, 3, '0'),
       (TIMESTAMP '2026-07-01 00:00' + ((g % 30) * INTERVAL '1 day')
            + ((g % 24) * INTERVAL '1 hour') + ((g % 60) * INTERVAL '1 minute'))
           AT TIME ZONE 'Europe/London',
       (((TIMESTAMP '2026-07-01 00:00' + ((g % 30) * INTERVAL '1 day')
            + ((g % 24) * INTERVAL '1 hour') + ((g % 60) * INTERVAL '1 minute'))
           AT TIME ZONE 'Europe/London') AT TIME ZONE 'UTC')::date,
       150 + (g % 26000)
FROM generate_series(1, 12000) AS g;

INSERT INTO analytics.card_day_totals (business_day, amount_p, takings)
SELECT business_day, sum(amount_p), count(*)
FROM payments.card_takings
GROUP BY business_day;

-- DEFECT the-feed-was-read-as-one-encoding-and-stored-as-another
--
-- The supplier feed is UTF-8 and one loader reads it as Latin-1, so eight
-- hundred supplier names hold two characters where an accented letter belongs.
--
-- Reading UTF-8 as Latin-1 never fails, because every byte is a valid Latin-1
-- character. An accented letter is two bytes in UTF-8 and becomes two letters,
-- so the name is longer than it was and looks like a typing accident rather
-- than an encoding one. The database is correct: it was handed those
-- characters and stored them faithfully. The loader in question is the older
-- of the two and is used for the European suppliers, which is precisely where
-- the accents are. Search is the visible damage: the buyer types the supplier
-- name as it is spelled and finds nothing, then raises a second supplier
-- record, which is how the same firm comes to be in the system twice.
--
-- Measured: 4,000 supplier names of which 800 contain the byte sequence a
-- UTF-8 accented letter takes when it is read as Latin-1.
--
-- Re-reading those names from the feed as UTF-8 corrects them, and the loader
-- wants its encoding declared rather than assumed. Every supplier reference is
-- right, every name is against the right supplier, and the names without an
-- accent came through both loaders identically.
CREATE TABLE supply.supplier_names (
    name_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref  varchar(12) NOT NULL,
    supplier_name varchar(60) NOT NULL,
    loaded_on     date NOT NULL
);

INSERT INTO supply.supplier_names (supplier_ref, supplier_name, loaded_on)
SELECT 'SUP-' || lpad(g::text, 6, '0'),
       CASE WHEN g % 5 = 0
            THEN convert_from(convert_to('Crème Frères ' || g, 'UTF8'), 'LATIN1')
            ELSE 'Riverside Supplies ' || g
       END,
       DATE '2026-03-02' + (g % 190)
FROM generate_series(1, 4000) AS g;

-- DEFECT the-position-was-taken-from-the-order-unnest-happened-to-return
--
-- The option positions were written by numbering the rows an unnest produced,
-- sorted by the option name, and the position that matters is the position in
-- the array, so half of them are wrong.
--
-- unnest returns the elements of an array in order, and WITH ORDINALITY is how
-- you keep that order. The routine that filled this table did not use it. It
-- ordered by the option text instead, because the output looked tidier that
-- way in the ticket that asked for it, and numbered the rows. For the products
-- whose options were already entered alphabetically the two agree exactly,
-- which is what made it look right in testing, and those are the products in
-- the sample. For the rest the position is alphabetical and the array is the
-- order the merchandiser chose, which is the order the size chart is printed
-- in. So half the products show their sizes sorted by name, and the array on
-- the same row says otherwise.
--
-- Measured: 6,000 option positions of which 3,000 disagree with the position
-- the option holds in the array stored beside them.
--
-- unnest(options) WITH ORDINALITY gives the position directly and cannot drift
-- from the array. Every option belongs to its product, every array is
-- complete, and the products whose options were entered alphabetically are
-- numbered correctly.
CREATE TABLE catalog.option_positions (
    entry_id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku               varchar(16) NOT NULL,
    options           text[] NOT NULL,
    option_code       text NOT NULL,
    recorded_position integer NOT NULL
);

INSERT INTO catalog.option_positions (sku, options, option_code, recorded_position)
SELECT p.sku, p.options, o.option_code, o.recorded_position
FROM (
    SELECT 'SKU-' || lpad(g::text, 8, '0') AS sku,
           CASE WHEN g % 2 = 0
                THEN ARRAY['Blue', 'Cotton', 'Large']
                ELSE ARRAY['Large', 'Blue', 'Cotton']
           END AS options
    FROM generate_series(1, 2000) AS g
) p
CROSS JOIN LATERAL (
    SELECT u AS option_code,
           row_number() OVER (ORDER BY u) AS recorded_position
    FROM unnest(p.options) AS u
) o;

-- DEFECT the-sequence-was-detached-from-the-column-it-feeds
--
-- The works order numbers come from a sequence that belongs to nothing, so
-- nothing ties it to the column it feeds: it is not dropped with the table,
-- not dumped with it, and not reset by anything that rebuilds it.
--
-- A serial or identity column owns its sequence, and that ownership is what
-- makes the pair behave as one object. This sequence was created on its own
-- and named in a column default, which works perfectly and is how the column
-- was converted off serial during a migration that wanted the sequence to
-- survive the table being rebuilt. It did survive, and it has been unattached
-- ever since. Restoring this schema on its own gives a table whose default
-- calls a sequence that is not there, and every insert fails at once, which is
-- at least loud. The quiet version is worse: a rebuild that recreates the
-- sequence separately starts it at one and hands out numbers that are already
-- on works orders in the field.
--
-- Measured: 9,000 works orders numbered from 1 sequence that has no owning
-- column, reached through a column default that does depend on it.
--
-- ALTER SEQUENCE ... OWNED BY ops.job_numbers.job_no restores the link and
-- changes nothing about how the numbers are handed out. Every works order has
-- a unique number, the sequence is ahead of every number issued, and the
-- default works exactly as intended.
CREATE SEQUENCE ops.job_number_seq;

CREATE TABLE ops.job_numbers (
    job_no     integer PRIMARY KEY DEFAULT nextval('ops.job_number_seq'),
    depot_code varchar(12) NOT NULL,
    raised_on  date NOT NULL,
    job_kind   varchar(12) NOT NULL
);

INSERT INTO ops.job_numbers (depot_code, raised_on, job_kind)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-02-16' + (g % 200),
       CASE WHEN g % 3 = 0 THEN 'REPAIR' WHEN g % 3 = 1 THEN 'SERVICE' ELSE 'INSPECT' END
FROM generate_series(1, 9000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.option_positions ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.option_positions:' || concat_ws('|', x.sku, x.options, x.option_code, x.recorded_position))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.option_positions x
)
UPDATE catalog.option_positions t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.option_positions ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.option_positions ADD CONSTRAINT option_positions_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_option_positions_product_id ON catalog.option_positions (product_id);

ALTER TABLE payments.card_takings ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.card_takings:' || concat_ws('|', x.site_code, x.amount_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.card_takings x
)
UPDATE payments.card_takings t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.card_takings ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.card_takings ADD CONSTRAINT card_takings_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_card_takings_transaction_id ON payments.card_takings (transaction_id);

ALTER TABLE supply.supplier_names ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.supplier_names:' || concat_ws('|', x.supplier_ref, x.supplier_name))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.supplier_names x
)
UPDATE supply.supplier_names t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.supplier_names ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.supplier_names ADD CONSTRAINT supplier_names_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_supplier_names_supplier_id ON supply.supplier_names (supplier_id);
-- <<< relationships
