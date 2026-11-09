-- Cross River Trading Co. -- route nodes, rollup rows, delivery flags,
-- refund entries, pick queue, stock levels
-- author: T. Marchetti
-- postgres: 18
--
-- What order a delivery round calls at its stops in, what the nightly rollup
-- came to, why a delivery is being held, what has been refunded, what is
-- waiting to be picked, and how much of each product is on the shelf.

-- DEFECT the-route-points-back-at-itself-and-the-walk-never-ends
--
-- Each route is a chain of nodes where every node points at the next one,
-- and one route in ten was joined up into a circuit, so the last node points
-- back at the first and the chain has no end.
--
-- A self referencing foreign key guarantees that whatever a node points at
-- exists. It says nothing at all about whether following the pointers ever
-- stops, and there is no constraint in PostgreSQL that can say so. The loops
-- are not a mistake in the data: the depots genuinely asked for circuits
-- rather than out and back runs, and a circuit is a loop. The mistake is
-- that everything reading the table assumes a chain. The route walker
-- follows next node until it finds a null, so on a circuit it runs until the
-- recursion limit, and the driver app that calls it times out rather than
-- failing, which reads as a network problem. The route printout for a
-- circuit is the first ten stops repeated.
--
-- Measured: 6,000 route nodes of which 600 lie on a cycle that returns to
-- where it started within 12 steps.
--
-- A recursive walk with a CYCLE clause, or an explicit circuit flag on the
-- route so the reader knows to stop after one pass, both work. Every node
-- names a real depot, every pointer names a node that exists, and the 5,400
-- nodes on ordinary chains walk correctly.
CREATE TABLE ops.route_nodes (
    node_id      integer PRIMARY KEY,
    depot_code   text NOT NULL,
    next_node_id integer REFERENCES ops.route_nodes (node_id)
);

INSERT INTO ops.route_nodes (node_id, depot_code, next_node_id)
SELECT g, 'DEP-' || lpad((((g - 1) / 5 % 40) + 1)::text, 3, '0'), NULL
FROM generate_series(1, 6000) g;

-- Each run of five nodes is one route. Every tenth route was joined up into a
-- loop when the depot asked for a circuit rather than a there and back.
UPDATE ops.route_nodes r
SET next_node_id = CASE
        WHEN (r.node_id - 1) % 5 < 4 THEN r.node_id + 1
        WHEN ((r.node_id - 1) / 5) % 10 = 0 THEN (((r.node_id - 1) / 5) * 5) + 1
        ELSE NULL
    END;

-- DEFECT the-backfill-stamped-every-row-with-the-moment-it-ran
--
-- Two thirds of the rollups carry an identical timestamp, to the second,
-- because the backfill that created them stamped every row with the clock at
-- the moment it ran rather than the time the rollup covers.
--
-- A default of now inside a single transaction returns the transaction's
-- start time, the same value for every row, which is usually what you want
-- and is exactly wrong for a column that is supposed to say when each thing
-- happened. So nine thousand rollups spanning months of history all say they
-- were computed at seventeen minutes past two on the fourth of May. The
-- column is what the incremental job reads to decide where to resume, so it
-- resumes from the backfill date and recomputes everything after it, every
-- night. It is also what the staleness alert reads, so the alert has fired
-- continuously since the backfill and has been muted.
--
-- Measured: 14,000 rollups of which 9,000 share one single timestamp value.
--
-- Deriving the stamp from the period each rollup covers, and keeping the run
-- time in a separate column if it is wanted, separates the two facts that
-- were collapsed into one. Every metric code is real and every value is the
-- correct rollup of its period.
CREATE TABLE analytics.rollup_rows (
    rollup_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    metric_code  text NOT NULL,
    metric_value integer NOT NULL,
    rolled_at    timestamptz NOT NULL
);

INSERT INTO analytics.rollup_rows (metric_code, metric_value, rolled_at)
SELECT
    'MET-' || lpad(((g % 300) + 1)::text, 4, '0'),
    ((g % 90000) + 1),
    CASE WHEN g % 14 < 9
         THEN TIMESTAMPTZ '2026-05-04 02:17:33+01'
         ELSE TIMESTAMPTZ '2026-05-05 02:00:00+01' + ((g % 5000) || ' minutes')::interval END
FROM generate_series(1, 14000) g;

-- DEFECT the-trigger-that-enforces-the-rule-is-switched-off
--
-- The trigger that lowercases and trims every delivery flag is disabled, so
-- three thousand flags are stored in upper case and every comparison against
-- the lowercase form misses them.
--
-- A disabled trigger is still there. It is listed, it has a function, its
-- definition is correct, and it does nothing. DISABLE TRIGGER was run during
-- a bulk load, because the per row trigger made the load take hours, and
-- that is a reasonable thing to do; re-enabling it afterwards is the step
-- that was missed, and nothing marks the difference except a single
-- character in the system catalogue. The flag is what the hold report
-- filters on, and it filters on the lowercase value, so a fifth of the held
-- deliveries are not on the hold report and are released. The rows are not
-- invalid by any constraint, because the rule was only ever expressed as a
-- trigger.
--
-- Measured: 15,000 delivery flags of which 3,000 differ from their own
-- lowercase form, behind 1 trigger whose enabled state is D.
--
-- Enabling the trigger and normalising the three thousand rows that came in
-- while it was off restores both. Every delivery reference is unique and
-- real, and the 12,000 flags written before the load are correct.
CREATE TABLE supply.delivery_flags (
    flag_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    delivery_ref text NOT NULL,
    flag_text    text NOT NULL
);

CREATE FUNCTION supply.fn_normalise_delivery_flag() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.flag_text := lower(btrim(NEW.flag_text));
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_normalise_delivery_flag BEFORE INSERT OR UPDATE ON supply.delivery_flags
    FOR EACH ROW EXECUTE FUNCTION supply.fn_normalise_delivery_flag();

ALTER TABLE supply.delivery_flags DISABLE TRIGGER trg_normalise_delivery_flag;

INSERT INTO supply.delivery_flags (delivery_ref, flag_text)
SELECT
    'DLV-' || lpad(g::text, 7, '0'),
    CASE WHEN g % 5 = 0 THEN 'HELD' ELSE 'held' END
FROM generate_series(1, 15000) g;

-- DEFECT the-definer-function-has-no-fixed-search-path
--
-- The refund total function runs as its owner and has no search path fixed
-- on it, and its body names the refund table without a schema, so the table
-- it reads is whichever one the caller's search path finds first.
--
-- SECURITY DEFINER means the function runs with the owner's privileges
-- rather than the caller's, which is the entire point: a reporting role can
-- get a refund total without being able to read the refund table. Resolving
-- an unqualified name, though, happens at run time against the caller's
-- search path. A caller who can create a table in any schema on that path
-- can put their own refund table in front of the real one, and the function
-- will read it, as the owner, with the owner's privileges. That turns a read
-- only report into a way of running the owner's code against attacker chosen
-- data. Nothing flags it: the function is correct, the grant is narrow, and
-- the danger is in a setting that is absent rather than wrong.
--
-- Measured: 7,000 refund lines behind 1 security definer function with no
-- search path configuration set on it.
--
-- SET search_path = pg_catalog, payments on the function, and schema
-- qualifying the table in the body, closes it. Every refund names a real
-- order, every amount is right, and the function returns the correct total
-- when the path is honest.
CREATE TABLE payments.refund_entries (
    refund_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref    text NOT NULL,
    amount_p     integer NOT NULL,
    refunded_on  date NOT NULL
);

INSERT INTO payments.refund_entries (order_ref, amount_p, refunded_on)
SELECT
    'ORD-' || lpad(g::text, 7, '0'),
    ((g % 40000) + 50),
    DATE '2026-04-01' + ((g % 150) || ' days')::interval
FROM generate_series(1, 7000) g;

CREATE FUNCTION payments.fn_refund_total(p_order text) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
    v_total bigint;
BEGIN
    SELECT coalesce(sum(amount_p), 0) INTO v_total
    FROM refund_entries WHERE order_ref = p_order;
    RETURN v_total;
END;
$$;

REVOKE EXECUTE ON FUNCTION payments.fn_refund_total(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION payments.fn_refund_total(text) TO report_reader;

-- DEFECT the-function-takes-the-first-row-it-finds-with-nothing-deciding-which
--
-- The next pick function orders the queue by the pick reference and takes
-- the first one, and the pick reference counts downwards, so every zone is
-- handed its most recent job and its oldest job is never handed out at all.
--
-- The function is deterministic and it is wrong, which is the harder kind to
-- find. An ORDER BY that returns the same answer every time reads as
-- correct, and the ordering column looks like a sequence number because it
-- is one, so the reference ordering was taken for the queue ordering without
-- checking which way it runs. The references were generated downwards so
-- that the newest job would sort first in the picker's own list, which was a
-- deliberate choice made somewhere else and never written down. The effect
-- is a queue that is serviced newest first, so the oldest job in each zone
-- is never picked while any newer one exists, and the twelve thousand item
-- backlog has a floor that never moves.
--
-- Measured: 120 pick zones, in all 120 of which the assigned pick is not the
-- oldest queued one.
--
-- Ordering by the queued time, which is the column that means what the
-- function needs, fixes it in one word. Every pick names a real zone, every
-- queue time is right, and the backlog is complete.
CREATE TABLE ops.pick_queue (
    pick_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    zone_code    text NOT NULL,
    pick_ref     text NOT NULL,
    queued_at    timestamptz NOT NULL
);

INSERT INTO ops.pick_queue (zone_code, pick_ref, queued_at)
SELECT
    'ZON-' || lpad(((g % 120) + 1)::text, 4, '0'),
    'PK-' || lpad((100000 - g)::text, 7, '0'),
    TIMESTAMPTZ '2026-09-12 06:00:00+01' + (g || ' seconds')::interval
FROM generate_series(1, 12000) g;

CREATE FUNCTION ops.fn_next_pick(p_zone text) RETURNS text
LANGUAGE sql STABLE AS $$
    SELECT pick_ref
    FROM ops.pick_queue
    WHERE zone_code = p_zone
    ORDER BY pick_ref
    LIMIT 1;
$$;

CREATE TABLE ops.pick_assignments (
    zone_code    text PRIMARY KEY,
    chosen_ref   text NOT NULL
);

INSERT INTO ops.pick_assignments (zone_code, chosen_ref)
SELECT z.zone_code, ops.fn_next_pick(z.zone_code)
FROM (SELECT DISTINCT zone_code FROM ops.pick_queue) z;

-- DEFECT minus-one-means-not-counted-and-every-sum-adds-it-as-a-number
--
-- A quarter of the stock lines hold minus one in the on hand column, which
-- does not mean minus one unit, it means the line was not counted, and
-- nothing in the schema says so.
--
-- The column is a plain integer with no check constraint, no comment and no
-- companion flag. The convention exists entirely in the heads of the people
-- who wrote the stocktake import, where minus one was chosen because null
-- was not allowed by a column that had been made mandatory years earlier for
-- a different reason. Every arithmetic use of the column is therefore wrong
-- by the count of uncounted lines: a sum of stock on hand is two and a half
-- thousand units light, an average is dragged down, and a check for negative
-- stock reports two and a half thousand impossible rows that are then
-- ignored as known noise, which is how a genuine negative would also be
-- ignored. The value is out of range for what the column claims to hold, and
-- the database has no way to know that.
--
-- Measured: 10,000 stock lines of which 2,500 hold minus one in a column
-- that counts units.
--
-- A nullable column, or a separate counted flag, states the fact the magic
-- number is standing in for. Every product reference is real, every count
-- date is right, and the 7,500 lines that were counted hold the correct
-- quantity.
CREATE TABLE catalog.stock_levels (
    level_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_ref  text NOT NULL,
    on_hand      integer NOT NULL,
    counted_on   date NOT NULL
);

INSERT INTO catalog.stock_levels (product_ref, on_hand, counted_on)
SELECT
    'PRD-' || lpad(g::text, 6, '0'),
    CASE WHEN g % 4 = 0 THEN -1 ELSE ((g % 900) + 1) END,
    DATE '2026-09-01' + ((g % 20) || ' days')::interval
FROM generate_series(1, 10000) g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.stock_levels ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.stock_levels:' || concat_ws('|', x.product_ref, x.on_hand))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.stock_levels x
)
UPDATE catalog.stock_levels t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.stock_levels ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.stock_levels ADD CONSTRAINT stock_levels_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_stock_levels_product_id ON catalog.stock_levels (product_id);

ALTER TABLE ops.pick_assignments ADD COLUMN wave_id integer;

WITH p AS (
    SELECT wave_id AS v, row_number() OVER (ORDER BY wave_id) - 1 AS k
      FROM fulfilment.picking_waves
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.picking_waves)
                 * power((abs(hashtext('ops.pick_assignments:' || concat_ws('|', x.zone_code, x.chosen_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.pick_assignments x
)
UPDATE ops.pick_assignments t
   SET wave_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.pick_assignments ALTER COLUMN wave_id SET NOT NULL;
ALTER TABLE ops.pick_assignments ADD CONSTRAINT pick_assignments_wave_id_fkey FOREIGN KEY (wave_id) REFERENCES fulfilment.picking_waves (wave_id);
CREATE INDEX ix_pick_assignments_wave_id ON ops.pick_assignments (wave_id);

ALTER TABLE payments.refund_entries ADD COLUMN request_id integer;

WITH p AS (
    SELECT request_id AS v, row_number() OVER (ORDER BY request_id) - 1 AS k
      FROM payments.refund_requests
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.refund_requests)
                 * power((abs(hashtext('payments.refund_entries:' || concat_ws('|', x.order_ref, x.amount_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.refund_entries x
)
UPDATE payments.refund_entries t
   SET request_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.refund_entries ALTER COLUMN request_id SET NOT NULL;
ALTER TABLE payments.refund_entries ADD CONSTRAINT refund_entries_request_id_fkey FOREIGN KEY (request_id) REFERENCES payments.refund_requests (request_id);
CREATE INDEX ix_refund_entries_request_id ON payments.refund_entries (request_id);
-- <<< relationships
