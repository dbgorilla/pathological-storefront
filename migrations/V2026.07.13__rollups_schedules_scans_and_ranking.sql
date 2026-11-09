-- Cross River Trading Co. -- returns rollup, job schedule, scans, ranking
-- author: P. Adeyemi
-- postgres: 18
--
-- The returns rollup the store managers read, the overnight job schedule moved
-- off cron, the handheld scan feed, the service visit history from the 1990s
-- system, and the homepage ranking.

-- DEFECT grouping-sets-null-is-indistinguishable-from-a-real-null
--
-- Returns by store, with a total row, written with ROLLUP so the total comes
-- back from the same query. ROLLUP marks the total row by putting null in the
-- grouped column.
--
-- The grouped column is already nullable: an order placed before the second
-- store opened has no store. So the view returns two rows with a null store,
-- one meaning the original store and one meaning every store, and nothing in
-- the result distinguishes them. Anything reading the null row reads whichever
-- of the two it happened to get, and anything summing the column counts every
-- return twice.
--
-- Measured: the two null rows hold 347 and 49 returns, so a filter on
-- store_id IS NULL adds up to 396 returns from a table that holds 347.
--
-- GROUPING(o.store_id) is the function that tells them apart and is the reason
-- it exists. Without it the total row is data, and the store with no id is
-- indistinguishable from the whole company.
CREATE VIEW analytics.v_returns_rollup AS
SELECT o.store_id,
       count(*) AS returns
FROM fulfilment.returns r
JOIN storefront.orders o ON o.order_id = r.order_id
GROUP BY ROLLUP (o.store_id);

-- DEFECT timestamp-in-the-daylight-saving-gap-is-shifted-silently
--
-- The overnight schedule came off cron, which ran on local time, so the times
-- are kept as local wall clock text and converted on load with AT TIME ZONE.
-- That conversion is correct for 363 days of the year.
--
-- On the night the clocks go forward, local time jumps from 00:59 to 02:00 and
-- the hour between does not exist. AT TIME ZONE does not reject a time in that
-- hour and does not raise anything: it resolves it forward, so 01:30 becomes
-- 02:30. The stored instant no longer matches the text it was built from, and
-- the text is what the schedule screen shows.
--
-- Measured: 1 of the 61 scheduled runs does not round trip back to the local
-- time it was loaded from. It is the run on 2026-03-29, and it is an hour
-- later than the screen says.
--
-- A job that reconciles the day's takings at 01:30 runs at 02:30 on that date,
-- after the daily cutover it was supposed to precede. Nothing in the database
-- records that the time moved, because from the database's point of view the
-- time it was given never existed.
CREATE TABLE ops.scheduled_jobs (
    job_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_name    varchar(60) NOT NULL,
    local_text  varchar(19) NOT NULL,
    run_at      timestamptz NOT NULL
);

COMMENT ON COLUMN ops.scheduled_jobs.local_text IS
    'Wall clock time from the cron table this schedule replaced.';

INSERT INTO ops.scheduled_jobs (job_name, local_text, run_at)
SELECT 'nightly-reconcile-' || to_char(d, 'MMDD'),
       to_char(d, 'YYYY-MM-DD') || ' 01:30:00',
       ((to_char(d, 'YYYY-MM-DD') || ' 01:30:00')::timestamp AT TIME ZONE 'Europe/London')
FROM generate_series(DATE '2026-03-01', DATE '2026-04-30', INTERVAL '1 day') AS d;

-- DEFECT composite-index-leading-column-is-never-filtered
--
-- Dispatch notes are looked up by their reference, which is unique and is what
-- the carrier quotes back when something goes missing. The index was created
-- on carrier and reference, in that order, because the notes are listed per
-- carrier on the operations screen.
--
-- A btree can only use a column if every column to its left is constrained.
-- The lookup supplies the reference and not the carrier, so the index cannot
-- be used for it at all. There are three carriers and 1,200 notes, so
-- the leading column divides the table into three and the one query that
-- matters reads one of those thirds end to end.
--
-- Measured: the leading column of ix_dispatch_notes_ref is carrier_id, which
-- takes three distinct values across 1,200 rows.
--
-- Swapping the columns serves both queries, because a prefix of a composite
-- index is itself usable. The index is reported as used, because the listing
-- screen uses it, so every tool that looks for unused indexes passes over it.
CREATE TABLE fulfilment.dispatch_notes (
    note_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    carrier_id    integer NOT NULL REFERENCES fulfilment.carriers(carrier_id),
    note_ref      varchar(16) NOT NULL UNIQUE,
    dispatched_on date NOT NULL
);

INSERT INTO fulfilment.dispatch_notes (carrier_id, note_ref, dispatched_on)
SELECT c.carrier_id,
       'DN' || lpad((c.carrier_id * 10000 + g)::text, 8, '0'),
       DATE '2026-01-02' + (g % 180)
FROM fulfilment.carriers c,
     generate_series(1, 400) AS g;

CREATE INDEX ix_dispatch_notes_ref
    ON fulfilment.dispatch_notes (carrier_id, note_ref);

-- DEFECT default-partition-absorbs-rows-meant-for-a-missing-partition
--
-- The handheld scan feed is partitioned by month. A default partition was added
-- after a night when the next month's partition had not been created and the
-- inserts failed, which stopped the warehouse working.
--
-- The default partition fixed that and hid the thing it was fixing. Rows for
-- months with no partition are accepted silently and land there, so nothing
-- fails and nothing reports that a partition is missing. Queries for one of
-- those months have to scan the default partition, which holds every month
-- that was ever missed.
--
-- Measured: 900 of the 1,800 scans are in the default partition, covering
-- April, May and June. Only January to March have partitions of their own.
--
-- Creating April's partition now fails: ATTACH scans the default and refuses
-- while rows that belong in the new partition are still in it. Fixing this
-- costs a lock and a move, and it gets more expensive every month nobody
-- notices, which is the trade the default partition made on the night it was
-- added.
CREATE TABLE ops.delivery_scans (
    scan_id    bigint GENERATED ALWAYS AS IDENTITY,
    shipment_id integer NOT NULL,
    scanned_on date NOT NULL,
    scan_type  varchar(20) NOT NULL
) PARTITION BY RANGE (scanned_on);

CREATE TABLE ops.delivery_scans_2026_01 PARTITION OF ops.delivery_scans
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE ops.delivery_scans_2026_02 PARTITION OF ops.delivery_scans
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE ops.delivery_scans_2026_03 PARTITION OF ops.delivery_scans
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE ops.delivery_scans_default PARTITION OF ops.delivery_scans DEFAULT;

-- The feed is replicated to the warehouse and the table has no key of its own,
-- so the whole old row is sent for an update. Set per partition, because
-- REPLICA IDENTITY does not recurse.
ALTER TABLE ops.delivery_scans            REPLICA IDENTITY FULL;
ALTER TABLE ops.delivery_scans_2026_01    REPLICA IDENTITY FULL;
ALTER TABLE ops.delivery_scans_2026_02    REPLICA IDENTITY FULL;
ALTER TABLE ops.delivery_scans_2026_03    REPLICA IDENTITY FULL;
ALTER TABLE ops.delivery_scans_default    REPLICA IDENTITY FULL;

INSERT INTO ops.delivery_scans (shipment_id, scanned_on, scan_type)
SELECT 1 + (g % 500),
       DATE '2026-01-01' + (g % 180),
       CASE WHEN g % 3 = 0 THEN 'collected' ELSE 'delivered' END
FROM generate_series(1, 1800) AS g;

-- DEFECT integer-date-difference-crosses-a-month-boundary
--
-- Service visits from the system that ran until 2001, which stored a date as
-- the eight digit number a human would write it as. The gap between visits is
-- computed by subtracting one from the other, which is right within a month
-- and reads correctly on every screen it appears on.
--
-- 20260301 minus 20260228 is 73. The number is an integer that looks like a
-- date, so subtraction produces an integer that looks like a number of days
-- and is not one. Every gap that crosses a month end is wrong by the width of
-- the gap between the encodings, which is 72 or more.
--
-- Measured: 171 of the 200 gaps cross a month end and are overstated. Every
-- visit in the table is 26 days after the one before it, and the largest gap
-- the view reports is 98 days.
--
-- Casting through to_date and subtracting dates is exact. The column holds an
-- integer because the 1990s system did, and every report that reads it has to
-- know that, which is the part that was not written down.
CREATE TABLE legacy.service_visits (
    visit_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_ref varchar(12) NOT NULL,
    visit_date   integer NOT NULL
);

COMMENT ON COLUMN legacy.service_visits.visit_date IS
    'YYYYMMDD as an integer, as the 1998 system wrote it.';

INSERT INTO legacy.service_visits (customer_ref, visit_date)
SELECT 'C' || lpad(cust::text, 5, '0'),
       to_char(DATE '2026-01-06' + (cust * 3 + visit * 26), 'YYYYMMDD')::integer
FROM generate_series(1, 40) AS cust,
     generate_series(0, 5) AS visit;

CREATE VIEW analytics.v_service_visit_gaps AS
SELECT v.visit_id,
       v.customer_ref,
       v.visit_date,
       lag(v.visit_date) OVER (PARTITION BY v.customer_ref ORDER BY v.visit_date)
           AS previous_visit_date,
       v.visit_date
         - lag(v.visit_date) OVER (PARTITION BY v.customer_ref ORDER BY v.visit_date)
           AS days_since_last_visit
FROM legacy.service_visits v;

-- DEFECT row-number-from-a-matview-used-as-a-stable-key
--
-- The homepage features products by their position in the ranking, and the
-- ranking is a materialised view with a row_number on it. The slots store that
-- number, which is stable for as long as nothing is refreshed.
--
-- row_number() is a position in a result, not an identity. A refresh computes
-- it again from whatever the data says that day, so a product that moves up
-- takes the number of the product that was there before. The slots did not
-- change and now point at different products. Nothing is orphaned, no
-- constraint is violated, and there is nothing to violate: the number is not a
-- key and no foreign key could be declared on it.
--
-- Measured: after one score revision and one refresh, 19 of the 20 slots point
-- at a product other than the one captured in them.
--
-- The slot should hold product_id, which is the identity, and read the rank
-- when it needs it. Storing the rank was faster to write and is wrong from the
-- first refresh, and the homepage has no way to tell it is showing the wrong
-- thing, because every slot resolves to a product.
CREATE TABLE marketing.feature_scores (
    product_id integer PRIMARY KEY REFERENCES storefront.products(product_id),
    score      integer NOT NULL
);

INSERT INTO marketing.feature_scores (product_id, score)
SELECT p.product_id, 100 + (p.product_id * 37) % 500
FROM storefront.products p
WHERE p.product_id % 5 = 0;

CREATE MATERIALIZED VIEW analytics.mv_product_ranking AS
SELECT row_number() OVER (ORDER BY fs.score DESC, fs.product_id) AS rank_id,
       fs.product_id,
       fs.score
FROM marketing.feature_scores fs;

CREATE TABLE marketing.featured_slots (
    slot_id               integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    position              integer NOT NULL,
    rank_id               bigint NOT NULL,
    product_id_at_capture integer NOT NULL REFERENCES storefront.products(product_id)
);

COMMENT ON COLUMN marketing.featured_slots.product_id_at_capture IS
    'What the slot showed when it was set. Kept for the merchandising audit.';

INSERT INTO marketing.featured_slots (position, rank_id, product_id_at_capture)
SELECT r.rank_id, r.rank_id, r.product_id
FROM analytics.mv_product_ranking r
WHERE r.rank_id <= 20;

-- The quarterly score revision, and the refresh that followed it.
UPDATE marketing.feature_scores
   SET score = score + 200
 WHERE product_id % 3 = 0;

REFRESH MATERIALIZED VIEW analytics.mv_product_ranking;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE legacy.service_visits ADD COLUMN customer_id uuid;

WITH p AS (
    SELECT id AS v, row_number() OVER (ORDER BY id) - 1 AS k
      FROM legacy.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM legacy.customers)
                 * power((abs(hashtext('legacy.service_visits:' || concat_ws('|', x.customer_ref, x.visit_date))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM legacy.service_visits x
)
UPDATE legacy.service_visits t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE legacy.service_visits ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE legacy.service_visits ADD CONSTRAINT service_visits_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES legacy.customers (id);
CREATE INDEX ix_service_visits_customer_id ON legacy.service_visits (customer_id);
-- <<< relationships
