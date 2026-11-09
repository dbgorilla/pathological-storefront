-- Cross River Trading Co. -- gatehouse check-in times, collection note status,
-- colour codes, scan events, doorstep deliveries, basket size reporting
-- author: P. Adeyemi
-- postgres: 18
--
-- The gatehouse log the yard manager reads, the collection notes the carrier
-- desk chases, the two letter colour codes the buying desk allocates, the scan
-- events the throughput report reads, the doorstep delivery record, and the
-- median basket size on the trading summary.

-- DEFECT at-time-zone-applied-twice-converts-the-timestamp-and-then-converts-it-back
--
-- Gatehouse check-ins are stored with a time zone, which is right. The
-- reporting view renders them in London time, which is also right, and gives a
-- timestamp without a zone: a wall clock reading.
--
-- The view then puts a zone back on that wall clock reading, and the zone it
-- uses is UTC. A London wall clock is not a UTC one for seven months of the
-- year, so every check-in recorded during British Summer Time is reported an
-- hour later than it happened. Winter check-ins are exact, which is what makes
-- this so hard to see: the report is right for five months and wrong for seven.
--
-- Measured: 1,200 check-ins across the year, 720 of them an hour late in the
-- reported column, 480 exact.
--
-- AT TIME ZONE converts in both directions depending on the type it is given,
-- so applying it twice reverses the first conversion or compounds it, and here
-- it compounds. The yard manager's complaint is that the gate log runs an hour
-- fast in the summer, which sounds like a clock on the barrier.
CREATE TABLE ops.gatehouse_checkins (
    checkin_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_reg varchar(10) NOT NULL,
    depot_code  varchar(12) NOT NULL,
    checkin_at  timestamptz NOT NULL
);

INSERT INTO ops.gatehouse_checkins (vehicle_reg, depot_code, checkin_at)
SELECT 'CR' || lpad((1 + (g % 90))::text, 2, '0') || ' XYZ',
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-01-01 06:00:00+00' + (g * INTERVAL '7 hours')
FROM generate_series(1, 1200) AS g;

CREATE VIEW analytics.v_gatehouse_times AS
SELECT c.checkin_id,
       c.vehicle_reg,
       c.depot_code,
       c.checkin_at,
       (c.checkin_at AT TIME ZONE 'Europe/London') AT TIME ZONE 'UTC' AS reported_at
FROM ops.gatehouse_checkins c;

-- DEFECT dispatch-timestamp-is-set-while-the-status-still-says-pending
--
-- A collection note gets its dispatch timestamp from the carrier's scan, which
-- arrives over the carrier feed within the hour. The status is moved to
-- dispatched by a nightly job that runs Monday to Friday.
--
-- Anything scanned on a Friday evening or over the weekend therefore carries a
-- dispatch time and a status of pending until Monday night, and anything
-- scanned in a week the job failed carries them for longer. The two columns
-- describe the same event and disagree, and every screen and report in the
-- business picks whichever one its author happened to trust.
--
-- Measured: 900 collection notes, 240 of them with a dispatch timestamp and a
-- status of pending. The carrier desk chases those 240 every Monday.
--
-- The status belongs with the timestamp, in the same statement that writes it.
-- Nobody reads this as a bug because the notes do clear eventually, which makes
-- it look like a queue rather than a contradiction.
CREATE TABLE fulfilment.collection_notes (
    note_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    note_ref      varchar(16) NOT NULL,
    carrier_ref   varchar(12) NOT NULL,
    status        varchar(12) NOT NULL,
    dispatched_at timestamptz
);

INSERT INTO fulfilment.collection_notes (note_ref, carrier_ref, status, dispatched_at)
SELECT 'COL-' || lpad(g::text, 6, '0'),
       'CAR-' || lpad((1 + (g % 12))::text, 3, '0'),
       CASE WHEN g % 15 IN (0, 1, 2, 3) THEN 'pending' ELSE 'dispatched' END,
       TIMESTAMPTZ '2026-07-01 17:40:00+01' + (g * INTERVAL '11 minutes')
FROM generate_series(1, 900) AS g;

-- DEFECT three-letter-code-space-is-nearly-exhausted
--
-- Colour codes are two uppercase letters, enforced by a check constraint. The
-- convention was set when the catalogue carried about eighty colours.
--
-- Two letters is six hundred and seventy-six codes. The buying desk allocates
-- roughly twenty a month across the ranges it has added since, and the free
-- codes are nearly gone. When the last one is taken, the allocation routine
-- will not fail gracefully: it will violate the check constraint on the next
-- insert, in the middle of a supplier load.
--
-- Measured: 640 codes allocated of the 676 the constraint permits, so 36
-- remain, which is under two months of allocations.
--
-- Widening the code means touching every system that has the two letters
-- hardcoded, which is why it has not been done. There is no alert on this and
-- no report showing it; the number of free codes is not written down anywhere
-- except in the arithmetic above.
CREATE TABLE catalog.colour_codes (
    code        char(2) PRIMARY KEY,
    colour_name varchar(40) NOT NULL,
    created_on  date NOT NULL,
    CONSTRAINT colour_codes_two_letters CHECK (code ~ '^[A-Z]{2}$')
);

INSERT INTO catalog.colour_codes (code, colour_name, created_on)
SELECT chr(65 + (g / 26)) || chr(65 + (g % 26)),
       'Colour ' || (g + 1)::text,
       DATE '2012-03-01' + (g * 8)
FROM generate_series(0, 639) AS g;

-- DEFECT parallel-workers-set-to-zero-on-the-largest-table
--
-- Scan events are the largest table the throughput report touches. During an
-- incident two years ago, parallel workers were set to zero on it to stop a
-- report from saturating the box, and the setting stayed.
--
-- Nothing else limits parallelism on this database, so the setting is invisible
-- unless somebody reads the table's storage options. Every sequential scan of
-- the table runs on one worker, including the overnight aggregation, which is
-- now the longest job in the schedule and the reason the morning figures are
-- late twice a week.
--
-- Measured: parallel_workers = 0 in the storage options of ops.scan_events, and
-- it is the only table in the database carrying that setting.
--
-- The fix is to reset the option and let the planner decide. A table-level
-- storage option survives every restore and every failover, and is not in any
-- of the places an engineer looks when a query is slow.
CREATE TABLE ops.scan_events (
    scan_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scanned_at  timestamptz NOT NULL,
    depot_code  varchar(12) NOT NULL,
    parcel_ref  varchar(20) NOT NULL,
    scan_type   varchar(12) NOT NULL
);

INSERT INTO ops.scan_events (scanned_at, depot_code, parcel_ref, scan_type)
SELECT TIMESTAMPTZ '2026-06-01 05:00:00+01' + (g * INTERVAL '4 minutes'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       'PCL-' || lpad(g::text, 8, '0'),
       (ARRAY['inbound','sorted','loaded','delivered'])[1 + (g % 4)]
FROM generate_series(1, 6000) AS g;

ALTER TABLE ops.scan_events SET (parallel_workers = 0);

-- DEFECT date-only-column-cannot-order-two-deliveries-on-the-same-day
--
-- A doorstep delivery records the day it happened and not the time, because
-- the original round sheet was a paper one and had a date at the top.
--
-- A driver often calls twice at the same address on the same day: carded in
-- the morning, delivered in the afternoon, or the other way round when the
-- customer telephones. With only a date there is no way to tell which attempt
-- came last, so the outcome shown against the address is whichever row the
-- query happens to return, and the outcome the customer is told about is not
-- reliably the final one.
--
-- Measured: 1,800 deliveries covering 300 address and date pairs that carry
-- more than one attempt, and in each of them the two attempts have different
-- outcomes.
--
-- The column wants to be a timestamp, and the round sheet has been an app for
-- six years. Support resolves these by telephoning the driver, which works, and
-- so the data has never been the thing that got fixed.
CREATE TABLE fulfilment.doorstep_deliveries (
    delivery_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    address_ref  varchar(16) NOT NULL,
    delivered_on date NOT NULL,
    courier_ref  varchar(12) NOT NULL,
    outcome      varchar(12) NOT NULL
);

INSERT INTO fulfilment.doorstep_deliveries (address_ref, delivered_on, courier_ref, outcome)
SELECT 'ADDR-' || lpad((1 + (g % 1500))::text, 6, '0'),
       DATE '2026-07-01' + (g % 20),
       'CUR-' || lpad((1 + (g % 60))::text, 3, '0'),
       'delivered'
FROM generate_series(1, 1500) AS g;

INSERT INTO fulfilment.doorstep_deliveries (address_ref, delivered_on, courier_ref, outcome)
SELECT d.address_ref, d.delivered_on, d.courier_ref, 'carded'
FROM fulfilment.doorstep_deliveries d
WHERE d.delivery_id % 5 = 0;

-- DEFECT percentile-cont-reports-a-basket-size-no-basket-has
--
-- The trading summary reports a median basket size, worked out with
-- percentile_cont.
--
-- percentile_cont interpolates between the two middle values, which is correct
-- for a continuous measure and wrong for a count of items. The median basket
-- is reported as a number of items that no basket in the business has ever
-- contained, and it moves by a fraction whenever a single basket is added,
-- which reads as a sensitive, responsive metric rather than an artefact.
--
-- Measured: 2,000 baskets, a reported median of 3.5 items, and 0 baskets
-- containing 3.5 items.
--
-- percentile_disc returns an actual value from the data, which is what a median
-- basket size means. A figure ending in a half looks deliberate enough that it
-- has been quoted in a board pack.
CREATE TABLE storefront.basket_sizes (
    basket_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    basket_ref  varchar(16) NOT NULL,
    item_count  integer NOT NULL,
    basketed_on date NOT NULL
);

INSERT INTO storefront.basket_sizes (basket_ref, item_count, basketed_on)
SELECT 'BSK-' || lpad(g::text, 6, '0'),
       CASE WHEN g <= 1000 THEN (ARRAY[1, 2, 3])[1 + (g % 3)]
            ELSE (ARRAY[4, 6, 9])[1 + (g % 3)]
       END,
       DATE '2026-06-01' + (g % 60)
FROM generate_series(1, 2000) AS g;

CREATE VIEW analytics.v_basket_median AS
SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY b.item_count) AS median_items,
       count(*) AS baskets
FROM storefront.basket_sizes b;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE fulfilment.collection_notes ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('fulfilment.collection_notes:' || concat_ws('|', x.note_ref, x.carrier_ref, x.status))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.collection_notes x
)
UPDATE fulfilment.collection_notes t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.collection_notes ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE fulfilment.collection_notes ADD CONSTRAINT collection_notes_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_collection_notes_shipment_id ON fulfilment.collection_notes (shipment_id);

ALTER TABLE fulfilment.doorstep_deliveries ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('fulfilment.doorstep_deliveries:' || concat_ws('|', x.address_ref, x.courier_ref, x.outcome))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.doorstep_deliveries x
)
UPDATE fulfilment.doorstep_deliveries t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.doorstep_deliveries ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE fulfilment.doorstep_deliveries ADD CONSTRAINT doorstep_deliveries_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_doorstep_deliveries_shipment_id ON fulfilment.doorstep_deliveries (shipment_id);

ALTER TABLE storefront.basket_sizes ADD COLUMN order_id integer;

WITH p AS (
    SELECT order_id AS v, row_number() OVER (ORDER BY order_id) - 1 AS k
      FROM storefront.orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.orders)
                 * power((abs(hashtext('storefront.basket_sizes:' || concat_ws('|', x.basket_ref, x.item_count))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.basket_sizes x
)
UPDATE storefront.basket_sizes t
   SET order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.basket_sizes ALTER COLUMN order_id SET NOT NULL;
ALTER TABLE storefront.basket_sizes ADD CONSTRAINT basket_sizes_order_id_fkey FOREIGN KEY (order_id) REFERENCES storefront.orders (order_id);
CREATE INDEX ix_basket_sizes_order_id ON storefront.basket_sizes (order_id);
-- <<< relationships
