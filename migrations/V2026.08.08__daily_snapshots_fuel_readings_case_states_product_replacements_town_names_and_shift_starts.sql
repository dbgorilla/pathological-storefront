-- Cross River Trading Co. -- daily snapshots, fuel readings, case states,
-- product replacements, town names, shift starts
-- author: J. Whitcombe
-- postgres: 18
--
-- The nightly snapshot the board pack is built from, the fuel pump reading at
-- the depot, the case state behind the service level clock, the replacement
-- product the catalogue offers, the town list the delivery zones are cut from,
-- and the shift start time payroll reads.

-- DEFECT daily-snapshot-table-has-no-key-and-the-job-reran
--
-- The nightly snapshot job writes one row per depot per day into a table with
-- no primary key and no unique index.
--
-- The job is not idempotent because nothing makes it so. It was rerun by hand
-- on five nights when the first run looked wrong, and each rerun appended a
-- second row for every depot on that day. Both rows are plausible, the later
-- one is the corrected figure, and the board pack sums the column, so those
-- five days are reported at roughly twice the truth.
--
-- Measured: 4,000 snapshot rows covering 100 days and 40 depots, with 200 rows
-- duplicating a depot and day already in the table.
--
-- A primary key over the depot and the day turns the rerun into an upsert, or
-- into a failure loud enough to notice. The double counted days are spread
-- across a quarter and each one reads as a strong day rather than as an error.
CREATE TABLE analytics.daily_snapshots (
    depot_code   varchar(12) NOT NULL,
    snapshot_on  date NOT NULL,
    orders_taken integer NOT NULL,
    takings      numeric(12,2) NOT NULL,
    written_at   timestamptz NOT NULL
);

INSERT INTO analytics.daily_snapshots (depot_code, snapshot_on, orders_taken, takings, written_at)
SELECT 'DEP-' || lpad(d::text, 3, '0'),
       DATE '2026-04-01' + s,
       20 + ((d * s) % 400),
       (500 + ((d * s * 7) % 9000))::numeric(12,2),
       TIMESTAMPTZ '2026-04-02 02:00:00+01' + (s * INTERVAL '1 day')
FROM generate_series(1, 40) AS d,
     generate_series(0, 99) AS s;

-- The five nights somebody reran it because the first run looked wrong.
INSERT INTO analytics.daily_snapshots (depot_code, snapshot_on, orders_taken, takings, written_at)
SELECT depot_code, snapshot_on, orders_taken + 3, takings + 40, written_at + INTERVAL '90 minutes'
FROM analytics.daily_snapshots
WHERE snapshot_on IN (DATE '2026-04-08', DATE '2026-04-22', DATE '2026-05-06',
                      DATE '2026-05-27', DATE '2026-06-17');

-- DEFECT one-fuel-reading-per-pump-per-day-is-a-rule-nothing-declares
--
-- A fuel pump is read once a day at each depot, and the pair of the pump and
-- the day is what every query treats as the identity of a reading.
--
-- No unique index says so. The rule is enforced by the handheld, which only
-- lets an operator submit one reading per pump per day, and by nothing in the
-- database. The consumption report subtracts yesterday's reading from today's
-- and assumes it will find exactly one of each; it is written with a scalar
-- subquery, so the day a second reading arrives the report fails outright
-- rather than reporting the wrong number.
--
-- Measured: 1,800 fuel readings over 1,800 distinct pump and day pairs, with
-- no unique index over the two columns.
--
-- The unique index is the rule written down where the next query can rely on
-- it. The handheld is being replaced this year, which is the event that ends
-- this. Nothing in the schema will notice when it does.
CREATE TABLE ops.fuel_readings (
    reading_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    pump_no    integer NOT NULL,
    read_on    date NOT NULL,
    litres     numeric(10,1) NOT NULL
);

INSERT INTO ops.fuel_readings (depot_code, pump_no, read_on, litres)
SELECT 'DEP-' || lpad((1 + ((p - 1) / 3))::text, 3, '0'),
       1 + ((p - 1) % 3),
       DATE '2026-05-01' + d,
       (1000 + ((p * d * 13) % 40000))::numeric(10,1)
FROM generate_series(1, 30) AS p,
     generate_series(0, 59) AS d;

-- DEFECT after-insert-trigger-updates-a-row-the-later-trigger-creates
--
-- A new case gets two AFTER INSERT triggers: one creates the case state row,
-- the other sets the service level due date on it.
--
-- Triggers at the same timing fire in name order. The trigger that sets the due
-- date sorts first, so it runs an UPDATE against a state row that does not
-- exist yet. An UPDATE that matches nothing is not an error; it reports zero
-- rows and the trigger returns happily. The state row is then created by the
-- second trigger with the due date left null, and every case in the system has
-- had a null service level date since the pair were written.
--
-- Measured: 1,000 case states and 1,000 of them with no service level due date.
--
-- One trigger that inserts the state with its due date already on it removes
-- the ordering question entirely. The service level report treats a null due
-- date as not yet due, so every case is inside its target and the dashboard has
-- been green since the day it was built.
CREATE TABLE support.case_states (
    case_id    integer PRIMARY KEY,
    state      varchar(16) NOT NULL,
    sla_due_at timestamptz,
    opened_at  timestamptz NOT NULL
);

CREATE TABLE support.case_openings (
    case_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    priority    varchar(8) NOT NULL,
    opened_at   timestamptz NOT NULL
);

CREATE FUNCTION support.fn_a_set_case_sla() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE support.case_states
    SET sla_due_at = NEW.opened_at + CASE NEW.priority WHEN 'high' THEN INTERVAL '4 hours'
                                                       WHEN 'medium' THEN INTERVAL '1 day'
                                                       ELSE INTERVAL '3 days' END
    WHERE case_id = NEW.case_id;
    RETURN NULL;
END;
$$;

CREATE FUNCTION support.fn_b_create_case_state() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO support.case_states (case_id, state, opened_at)
    VALUES (NEW.case_id, 'open', NEW.opened_at);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_a_set_case_sla
    AFTER INSERT ON support.case_openings
    FOR EACH ROW EXECUTE FUNCTION support.fn_a_set_case_sla();

CREATE TRIGGER trg_b_create_case_state
    AFTER INSERT ON support.case_openings
    FOR EACH ROW EXECUTE FUNCTION support.fn_b_create_case_state();

INSERT INTO support.case_openings (account_ref, priority, opened_at)
SELECT 'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       (ARRAY['high', 'medium', 'low'])[1 + (g % 3)],
       TIMESTAMPTZ '2026-06-01 08:00:00+01' + (g * INTERVAL '23 minutes')
FROM generate_series(1, 1000) AS g;

-- DEFECT two-products-each-replace-the-other
--
-- A discontinued product names the product that replaces it, so the catalogue
-- can send a shopper on to the current line.
--
-- Forty pairs name each other. Each was discontinued in favour of the other,
-- on different days, by different buyers, and nothing checks the other
-- direction before writing the row. The catalogue follows replacements until it
-- finds a product that is not discontinued, which for these pairs is never, so
-- the request runs until the timeout cuts it off.
--
-- Measured: 900 product replacements, 80 of them in a pair that points back at
-- itself in two steps.
--
-- Refusing a replacement that is reachable from the product being replaced
-- keeps the chain a chain. Both products in each pair are discontinued and
-- neither is orderable, so the only symptom is a slow page on a dead product.
CREATE TABLE catalog.product_replacements (
    sku             varchar(20) PRIMARY KEY,
    replaced_by_sku varchar(20) NOT NULL,
    discontinued_on date NOT NULL
);

INSERT INTO catalog.product_replacements (sku, replaced_by_sku, discontinued_on)
SELECT 'SKU-R' || lpad(g::text, 7, '0'),
       'SKU-R' || lpad((g + 1)::text, 7, '0'),
       DATE '2025-01-01' + (g % 500)
FROM generate_series(1, 820) AS g;

-- The forty pairs, each buyer replacing the other buyer's line.
INSERT INTO catalog.product_replacements (sku, replaced_by_sku, discontinued_on)
SELECT 'SKU-P' || lpad(p::text, 7, '0'),
       'SKU-Q' || lpad(p::text, 7, '0'),
       DATE '2025-03-01' + (p % 200)
FROM generate_series(1, 40) AS p;

INSERT INTO catalog.product_replacements (sku, replaced_by_sku, discontinued_on)
SELECT 'SKU-Q' || lpad(p::text, 7, '0'),
       'SKU-P' || lpad(p::text, 7, '0'),
       DATE '2025-09-01' + (p % 200)
FROM generate_series(1, 40) AS p;

-- DEFECT town-range-filter-misses-the-towns-the-c-collation-sorts-elsewhere
--
-- The delivery zones are cut from the town list by a range of names, which is
-- how the rounds were described on paper and how they were written in SQL.
--
-- The town column is declared COLLATE "C" and the database collates as en_US.
-- Under C the comparison is byte by byte, so a town whose name begins with a
-- lower case letter, or carries an accent, falls outside a range that the same
-- comparison under the database's own collation would include. The zone query
-- returns fewer towns than the paper round covers, and the towns it drops are
-- the ones with unusual names rather than the ones on the edge of the map.
--
-- Measured: 1,200 towns, and 320 that fall inside the round's name range under
-- the database's collation and outside it under the column's.
--
-- Leaving the column to the database's collation makes the range mean what the
-- round means. Cutting a delivery zone by name range is the deeper problem and
-- the collation is what makes it fail invisibly.
CREATE TABLE legacy.town_names (
    town_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    town      varchar(60) COLLATE "C" NOT NULL,
    county    varchar(40) NOT NULL,
    listed_on date NOT NULL
);

INSERT INTO legacy.town_names (town, county, listed_on)
SELECT CASE WHEN g % 15 = 0 THEN 'upper ' || lpad(g::text, 4, '0')
            WHEN g % 15 = 1 THEN 'nether ' || lpad(g::text, 4, '0')
            WHEN g % 15 = 2 THEN 'little ' || lpad(g::text, 4, '0')
            WHEN g % 15 = 3 THEN 'great ' || lpad(g::text, 4, '0')
            ELSE 'Cross ' || lpad(g::text, 4, '0')
       END,
       'County ' || (1 + (g % 12))::text,
       DATE '2020-01-01' + (g % 1800)
FROM generate_series(1, 1200) AS g;

-- DEFECT local-times-were-converted-as-though-they-were-utc
--
-- Shift start times were recorded for years as plain timestamps, in the local
-- time of the depot. A column with a time zone was added and the old values
-- were converted across.
--
-- The conversion read every stored value as though it were UTC, because that is
-- what a bare cast does when the session is set to UTC. The stored values were
-- British local time, so every shift recorded during British Summer Time is now
-- an hour earlier than it happened. Winter shifts converted correctly, which is
-- why the conversion was signed off in February.
--
-- Measured: 3,000 shift starts, 1,680 of them in British Summer Time and each
-- an hour earlier in the converted column than the local time it was taken
-- from.
--
-- AT TIME ZONE 'Europe/London' reads a local timestamp as local, which is the
-- whole fix and has to be applied to the stored values rather than the reads.
-- Payroll rounds shifts to the nearest quarter hour, so an hour is a real
-- difference and still lands on a plausible start time.
CREATE TABLE ops.shift_starts (
    shift_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code    varchar(12) NOT NULL,
    staff_ref     varchar(12) NOT NULL,
    started_local timestamp NOT NULL,
    started_at    timestamptz NOT NULL
);

INSERT INTO ops.shift_starts (depot_code, staff_ref, started_local, started_at)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       'STF-' || lpad((1 + (g % 700))::text, 5, '0'),
       TIMESTAMP '2025-11-01 06:00:00' + (g * INTERVAL '3 hours'),
       (TIMESTAMP '2025-11-01 06:00:00' + (g * INTERVAL '3 hours')) AT TIME ZONE 'UTC'
FROM generate_series(1, 3000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.product_replacements ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.product_replacements:' || concat_ws('|', x.sku, x.replaced_by_sku))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.product_replacements x
)
UPDATE catalog.product_replacements t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.product_replacements ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.product_replacements ADD CONSTRAINT product_replacements_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_product_replacements_product_id ON catalog.product_replacements (product_id);

ALTER TABLE ops.shift_starts ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.shift_starts:' || concat_ws('|', x.depot_code, x.staff_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.shift_starts x
)
UPDATE ops.shift_starts t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.shift_starts ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.shift_starts ADD CONSTRAINT shift_starts_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_shift_starts_store_id ON ops.shift_starts (store_id);
-- <<< relationships
