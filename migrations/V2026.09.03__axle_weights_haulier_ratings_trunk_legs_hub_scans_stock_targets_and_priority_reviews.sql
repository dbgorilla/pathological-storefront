-- Cross River Trading Co. -- axle weights, haulier ratings, trunk legs, hub
-- scans, stock targets, priority reviews
-- author: T. Marchetti
-- postgres: 18
--
-- What the weighbridge recorded axle by axle, how the hauliers score, the legs
-- of a trunk run, every scan at the hub, what each depot is meant to hold, and
-- the reviews the service desk is measured on.

-- DEFECT the-audit-trigger-was-created-on-one-partition-and-not-on-the-parent
--
-- The axle weight audit trigger was created on one partition instead of on the
-- partitioned table, so three quarters of the tickets are written with nothing
-- recorded.
--
-- The trigger was added during an overload investigation that only concerned
-- the quarter then open, and CREATE TRIGGER was pointed at that quarter's
-- table because that is the table the investigator was reading. A trigger on
-- the partitioned parent is cloned onto every partition, including the ones
-- created later, which is what was wanted and is one word different to write.
-- Routing an insert through the parent fires the triggers belonging to the
-- partition the row lands in, so the audit runs for one quarter and stops
-- dead at the quarter boundary. Nothing announces this: the audit table keeps
-- growing while that quarter is open and simply stops when it closes, which
-- reads as a quiet quarter.
--
-- Measured: 12,000 axle weight tickets across four quarterly partitions, of
-- which 3,000 are audited and 9,000 are not, under one trigger that exists on
-- a single partition and not on the parent.
--
-- Dropping the partition trigger and creating the same trigger on the parent
-- covers every partition, present and future. The trigger function is correct,
-- the audit rows it did write are complete, and the partitioning itself is
-- sound.
CREATE TABLE ops.axle_weights (
    ticket_no  varchar(14) NOT NULL,
    weighed_on date NOT NULL,
    vehicle_no varchar(10) NOT NULL,
    axle_kg    integer NOT NULL,
    PRIMARY KEY (ticket_no, weighed_on)
) PARTITION BY RANGE (weighed_on);

CREATE TABLE ops.axle_weights_2026_q1 PARTITION OF ops.axle_weights
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');
CREATE TABLE ops.axle_weights_2026_q2 PARTITION OF ops.axle_weights
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');
CREATE TABLE ops.axle_weights_2026_q3 PARTITION OF ops.axle_weights
    FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');
CREATE TABLE ops.axle_weights_2026_q4 PARTITION OF ops.axle_weights
    FOR VALUES FROM ('2026-10-01') TO ('2027-01-01');

CREATE TABLE ops.axle_weight_audit (
    audit_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_no varchar(14) NOT NULL,
    axle_kg   integer NOT NULL,
    seen_at   timestamptz NOT NULL
);

CREATE FUNCTION ops.fn_audit_axle_weight()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.axle_weight_audit (ticket_no, axle_kg, seen_at)
    VALUES (NEW.ticket_no, NEW.axle_kg, now());
    RETURN NULL;
END;
$$;

-- Created against the quarter that was open at the time.
CREATE TRIGGER trg_audit_axle_weight
    AFTER INSERT ON ops.axle_weights_2026_q1
    FOR EACH ROW EXECUTE FUNCTION ops.fn_audit_axle_weight();

INSERT INTO ops.axle_weights (ticket_no, weighed_on, vehicle_no, axle_kg)
SELECT 'AXW-' || lpad(g::text, 10, '0'),
       DATE '2026-01-15' + ((g % 4) * 91) + (g % 60),
       'VEH-' || lpad((1 + (g % 400))::text, 5, '0'),
       4000 + (g % 7000)
FROM generate_series(1, 12000) AS g;

-- DEFECT the-lookup-function-is-parallel-unsafe-so-every-query-that-calls-it-runs-serially
--
-- The haulier rating function does nothing but arithmetic on its arguments and
-- is marked parallel unsafe, which is what a function is when nobody says
-- otherwise. Every query that calls it is planned without parallelism.
--
-- PARALLEL UNSAFE is the default, and it is the right default, because the
-- planner cannot know that a function is safe to run in a worker. The cost of
-- leaving it is not local to the function: one unsafe call anywhere in a query
-- makes the whole plan serial, including the sequential scan underneath it
-- that would otherwise have used six workers. The rating is selected in the
-- haulier performance view, which is the slowest report in the estate and has
-- been explained several times without anybody looking at the function's
-- markings, because the plan shows a sequential scan and not a reason.
--
-- Measured: 6,000 haulier ratings read through a function that is immutable in
-- fact and marked parallel unsafe in the catalogue.
--
-- Adding PARALLEL SAFE is one word, and the function is genuinely safe: it
-- reads no table, writes nothing and touches no setting. It is already marked
-- IMMUTABLE, takes typed arguments and returns the right answer every time.
CREATE TABLE analytics.haulier_ratings (
    haulier_ref  varchar(12) NOT NULL,
    rated_on     date NOT NULL,
    on_time_pct  integer NOT NULL,
    damage_count integer NOT NULL,
    PRIMARY KEY (haulier_ref, rated_on)
);

INSERT INTO analytics.haulier_ratings (haulier_ref, rated_on, on_time_pct, damage_count)
SELECT 'HAU-' || lpad((1 + (g % 200))::text, 6, '0'),
       DATE '2026-03-01' + (g / 200),
       60 + (g % 40),
       g % 9
FROM generate_series(0, 5999) AS g;

CREATE FUNCTION analytics.fn_haulier_rating(p_on_time integer, p_damage integer)
RETURNS integer
LANGUAGE sql IMMUTABLE AS $$
    SELECT greatest(0, p_on_time - (p_damage * 4));
$$;

CREATE VIEW analytics.v_haulier_scores AS
SELECT haulier_ref, rated_on,
       analytics.fn_haulier_rating(on_time_pct, damage_count) AS score
FROM analytics.haulier_ratings;

-- DEFECT the-table-was-clustered-once-and-the-order-it-records-is-long-gone
--
-- The trunk leg table was clustered on the depot index once, and the catalogue
-- still records that index as the clustering one. Nothing has re-clustered it
-- since and every row written afterwards was appended wherever there was room.
--
-- CLUSTER rewrites the table in index order and marks the index it used. It is
-- a one time rearrangement, not a property the table keeps: the next insert
-- goes wherever the free space map points. The mark it leaves is the trap,
-- because it reads as a table that is clustered, and it is quoted as such in
-- the tuning notes for the depot report. The report's plan assumed a
-- correlated heap and chose an index scan, which was right the week after the
-- cluster ran and is wrong now that a quarter of the table was written after
-- it, each row landing in a page unrelated to its depot.
--
-- Measured: 12,000 trunk legs on a table whose catalogue still marks
-- trunk_legs_depot_idx as the clustering index, 3,000 of them written after
-- the one and only CLUSTER.
--
-- Either re-cluster on a schedule and say so, or clear the mark so nobody
-- reads it as a standing property. Every row is present, the index is valid,
-- and the cluster that ran did exactly what it was asked to do.
CREATE TABLE ops.trunk_legs (
    leg_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    run_date   date NOT NULL,
    miles      integer NOT NULL
);

INSERT INTO ops.trunk_legs (depot_code, run_date, miles)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-04-06' + (g % 120),
       20 + (g % 400)
FROM generate_series(1, 9000) AS g;

CREATE INDEX trunk_legs_depot_idx ON ops.trunk_legs (depot_code);

CLUSTER ops.trunk_legs USING trunk_legs_depot_idx;

-- Everything written since, in arrival order.
INSERT INTO ops.trunk_legs (depot_code, run_date, miles)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-08-04' + (g % 40),
       20 + (g % 400)
FROM generate_series(1, 3000) AS g;

-- DEFECT the-partition-carries-its-own-default-and-the-load-writes-straight-to-it
--
-- One hub scan partition carries its own default for the scan source, and the
-- overnight load inserts straight into that partition rather than through the
-- parent, so three thousand scans are recorded as coming from nowhere.
--
-- A partition may hold column defaults of its own, and they win for an insert
-- addressed to the partition. This one was set during a cutover, when the
-- handheld fleet was being swapped and the source genuinely was not known, and
-- it was never cleared. The load targets the partition by name because the
-- loader builds the table name from the date, which is faster and which was
-- the recommendation at the time. A scan routed through the parent takes the
-- parent's default and the same scan written directly takes the partition's,
-- so the same handheld produces two different answers depending on which door
-- the row came in.
--
-- Measured: 9,000 hub scans of which 3,000 carry a source of UNKNOWN, under a
-- column whose default is declared twice, on the parent and on one partition,
-- and reads two different ways.
--
-- Dropping the partition's default and writing through the parent are both one
-- statement. Every scan is present, every timestamp is right, and the rows are
-- in the partition the date says they belong to.
CREATE TABLE fulfilment.hub_scans (
    scan_ref    varchar(16) NOT NULL,
    scanned_on  date NOT NULL,
    parcel_ref  varchar(18) NOT NULL,
    scan_source varchar(12) NOT NULL DEFAULT 'HANDHELD',
    PRIMARY KEY (scan_ref, scanned_on)
) PARTITION BY RANGE (scanned_on);

CREATE TABLE fulfilment.hub_scans_2026_07 PARTITION OF fulfilment.hub_scans
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE fulfilment.hub_scans_2026_08 PARTITION OF fulfilment.hub_scans
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE fulfilment.hub_scans_2026_09 PARTITION OF fulfilment.hub_scans
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');

-- Set during the handheld cutover and never cleared.
ALTER TABLE fulfilment.hub_scans_2026_08 ALTER COLUMN scan_source SET DEFAULT 'UNKNOWN';

INSERT INTO fulfilment.hub_scans (scan_ref, scanned_on, parcel_ref)
SELECT 'HSC-' || lpad(g::text, 11, '0'),
       DATE '2026-07-01' + (g % 31),
       'PCL-' || lpad((1 + (g % 4000))::text, 13, '0')
FROM generate_series(1, 3000) AS g;

-- The night the loader addressed the partition by name.
INSERT INTO fulfilment.hub_scans_2026_08 (scan_ref, scanned_on, parcel_ref)
SELECT 'HSC-' || lpad((100000 + g)::text, 11, '0'),
       DATE '2026-08-01' + (g % 31),
       'PCL-' || lpad((1 + (g % 4000))::text, 13, '0')
FROM generate_series(1, 3000) AS g;

INSERT INTO fulfilment.hub_scans (scan_ref, scanned_on, parcel_ref)
SELECT 'HSC-' || lpad((200000 + g)::text, 11, '0'),
       DATE '2026-09-01' + (g % 30),
       'PCL-' || lpad((1 + (g % 4000))::text, 13, '0')
FROM generate_series(1, 3000) AS g;

-- DEFECT the-upsert-conflict-target-is-missing-the-depot-so-each-load-overwrites-the-last
--
-- The stock target table is unique on the product alone, and the target is set
-- per depot per product. The nightly upsert names that unique index as its
-- conflict target, so every depot overwrites the depot before it.
--
-- The table began as a group-wide target, one number per product, and the
-- depot column was added when depots started setting their own. The unique
-- index was not widened with it. The load reads a feed of eight thousand depot
-- and product lines and upserts each one, and because the conflict target is
-- the product on its own, each line after the first for a product updates the
-- same row. The table ends the night holding two hundred rows, one per
-- product, each carrying whichever depot the feed happened to visit last. The
-- load reports eight thousand rows applied, which is true, and nobody counts
-- the table afterwards.
--
-- Measured: 8,000 depot and product target lines in the feed against 200 rows
-- in the target table, whose only unique index has one key column.
--
-- Widening the unique index to the depot and the product, and naming both in
-- the conflict target, keeps every line. Every target in the table is a real
-- number that a depot really set, and the feed is complete and correct.
CREATE TABLE supply.stock_target_feed (
    feed_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    sku        varchar(16) NOT NULL,
    target_qty integer NOT NULL,
    sent_on    date NOT NULL
);

CREATE TABLE supply.stock_targets (
    sku        varchar(16) PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    target_qty integer NOT NULL,
    set_on     date NOT NULL
);

INSERT INTO supply.stock_target_feed (depot_code, sku, target_qty, sent_on)
SELECT 'DEP-' || lpad((1 + (g / 200))::text, 3, '0'),
       'SKU-' || lpad((1 + (g % 200))::text, 8, '0'),
       10 + (g % 900),
       DATE '2026-09-15'
FROM generate_series(0, 7999) AS g;

-- The nightly upsert, one statement per depot, in the order the feed lists them.
DO $$
DECLARE
    d record;
BEGIN
    FOR d IN SELECT DISTINCT depot_code FROM supply.stock_target_feed ORDER BY depot_code LOOP
        INSERT INTO supply.stock_targets (sku, depot_code, target_qty, set_on)
        SELECT f.sku, f.depot_code, f.target_qty, f.sent_on
        FROM supply.stock_target_feed f
        WHERE f.depot_code = d.depot_code
        ON CONFLICT (sku) DO UPDATE
        SET depot_code = EXCLUDED.depot_code,
            target_qty = EXCLUDED.target_qty,
            set_on     = EXCLUDED.set_on;
    END LOOP;
END;
$$;

-- DEFECT the-partial-index-covers-one-status-and-the-query-asks-for-two
--
-- The priority review index is partial on the open status and the service desk
-- screen asks for open and on hold together, so the index answers neither.
--
-- The index was correct when it was built, because on hold did not exist:
-- reviews were open or they were closed. The status was added a year later,
-- with its own screen, and then the two screens were merged into one queue
-- because the desk works them as one queue. A partial index can only answer a
-- query the planner can prove is inside its predicate, and open or on hold is
-- not inside open, so the merged screen scans the whole table. It is fast
-- enough at twelve thousand rows, which is why it has never been raised, and
-- it is a sequential scan that grows with the table rather than with the
-- queue.
--
-- Measured: 12,000 priority reviews of which 2,400 are on hold and outside the
-- predicate of the only index on the status, and 2,400 are open and inside it.
--
-- Widening the predicate to the two live statuses, or dropping the predicate
-- and indexing the status itself, restores the index scan. The index is valid,
-- it is used by the open-only report that still exists, and every review is
-- correctly statused.
CREATE TABLE support.priority_reviews (
    review_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref  varchar(16) NOT NULL,
    status    varchar(10) NOT NULL,
    opened_on date NOT NULL
);

INSERT INTO support.priority_reviews (case_ref, status, opened_on)
SELECT 'CAS-' || lpad((1 + (g % 3200))::text, 10, '0'),
       CASE WHEN g % 5 = 0 THEN 'OPEN'
            WHEN g % 5 = 1 THEN 'ON_HOLD'
            ELSE 'CLOSED'
       END,
       DATE '2026-05-11' + (g % 130)
FROM generate_series(1, 12000) AS g;

CREATE INDEX priority_reviews_open_idx
    ON support.priority_reviews (opened_on)
    WHERE status = 'OPEN';

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE fulfilment.hub_scans ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('fulfilment.hub_scans:' || concat_ws('|', x.scan_ref, x.parcel_ref, x.scan_source))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.hub_scans x
)
UPDATE fulfilment.hub_scans t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.hub_scans ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE fulfilment.hub_scans ADD CONSTRAINT hub_scans_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_hub_scans_shipment_id ON fulfilment.hub_scans (shipment_id);

ALTER TABLE ops.axle_weights ADD COLUMN plate character varying(10);

WITH p AS (
    SELECT plate AS v, row_number() OVER (ORDER BY plate) - 1 AS k
      FROM ops.vehicle_register
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.vehicle_register)
                 * power((abs(hashtext('ops.axle_weights:' || concat_ws('|', x.ticket_no, x.vehicle_no, x.axle_kg))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.axle_weights x
)
UPDATE ops.axle_weights t
   SET plate = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.axle_weights ALTER COLUMN plate SET NOT NULL;
ALTER TABLE ops.axle_weights ADD CONSTRAINT axle_weights_plate_fkey FOREIGN KEY (plate) REFERENCES ops.vehicle_register (plate);
CREATE INDEX ix_axle_weights_plate ON ops.axle_weights (plate);

ALTER TABLE supply.stock_target_feed ADD COLUMN part_id integer;

WITH p AS (
    SELECT part_id AS v, row_number() OVER (ORDER BY part_id) - 1 AS k
      FROM supply.parts
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.parts)
                 * power((abs(hashtext('supply.stock_target_feed:' || concat_ws('|', x.depot_code, x.sku, x.target_qty))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.stock_target_feed x
)
UPDATE supply.stock_target_feed t
   SET part_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.stock_target_feed ALTER COLUMN part_id SET NOT NULL;
ALTER TABLE supply.stock_target_feed ADD CONSTRAINT stock_target_feed_part_id_fkey FOREIGN KEY (part_id) REFERENCES supply.parts (part_id);
CREATE INDEX ix_stock_target_feed_part_id ON supply.stock_target_feed (part_id);

ALTER TABLE supply.stock_targets ADD COLUMN part_id integer;

WITH p AS (
    SELECT part_id AS v, row_number() OVER (ORDER BY part_id) - 1 AS k
      FROM supply.parts
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.parts)
                 * power((abs(hashtext('supply.stock_targets:' || concat_ws('|', x.sku, x.depot_code, x.target_qty))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.stock_targets x
)
UPDATE supply.stock_targets t
   SET part_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.stock_targets ALTER COLUMN part_id SET NOT NULL;
ALTER TABLE supply.stock_targets ADD CONSTRAINT stock_targets_part_id_fkey FOREIGN KEY (part_id) REFERENCES supply.parts (part_id);
CREATE INDEX ix_stock_targets_part_id ON supply.stock_targets (part_id);

ALTER TABLE support.priority_reviews ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.priority_reviews:' || concat_ws('|', x.case_ref, x.status))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.priority_reviews x
)
UPDATE support.priority_reviews t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.priority_reviews ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.priority_reviews ADD CONSTRAINT priority_reviews_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_priority_reviews_ticket_id ON support.priority_reviews (ticket_id);
-- <<< relationships
