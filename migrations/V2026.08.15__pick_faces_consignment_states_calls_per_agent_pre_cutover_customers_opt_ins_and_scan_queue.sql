-- Cross River Trading Co. -- pick faces, consignment states, calls per agent,
-- pre cutover customers, marketing opt ins, scan queue
-- author: T. Marchetti
-- postgres: 18
--
-- The face a picker picks from, the state a consignment is in, the calls an
-- agent took, the customer table kept from the last cutover, the marketing
-- permission a customer gave, and the queue the scanners write into.

-- DEFECT the-function-loops-a-query-per-row-instead-of-one-set-query
--
-- The pick face rebuild walks the pick faces one at a time and runs a query
-- inside the loop for each one.
--
-- It was written that way because the first version had to log a line per face
-- and a loop was the obvious shape. The logging was removed and the loop was
-- not. The body is now a single UPDATE against a single row, repeated once per
-- face, so a job that could be one statement is eight thousand statements,
-- each with its own plan, its own snapshot and its own round trip through the
-- executor.
--
-- Measured: 8,000 pick faces and 8,000 statements executed by one call of the
-- rebuild, which the function records as it goes.
--
-- One UPDATE with a join against the source table does the same work in one
-- statement. The job runs overnight and finishes before anybody arrives, so
-- the only sign of it is a warehouse that cannot rebuild pick faces during
-- trading hours and has stopped asking to.
CREATE TABLE ops.pick_faces (
    face_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code   varchar(12) NOT NULL,
    sku          varchar(20) NOT NULL,
    capacity     integer NOT NULL,
    rebuilt_at   timestamptz
);

CREATE TABLE ops.pick_face_rebuild_log (
    run_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ran_at        timestamptz NOT NULL DEFAULT now(),
    statement_count integer NOT NULL
);

INSERT INTO ops.pick_faces (depot_code, sku, capacity)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       10 + (g % 90)
FROM generate_series(1, 8000) AS g;

CREATE FUNCTION ops.fn_rebuild_pick_faces() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    r       record;
    n       integer := 0;
BEGIN
    FOR r IN SELECT face_id FROM ops.pick_faces ORDER BY face_id LOOP
        UPDATE ops.pick_faces
        SET rebuilt_at = now()
        WHERE face_id = r.face_id;
        n := n + 1;
    END LOOP;

    INSERT INTO ops.pick_face_rebuild_log (statement_count) VALUES (n);
    RETURN n;
END;
$$;

SELECT ops.fn_rebuild_pick_faces();

-- DEFECT the-status-column-holds-a-value-the-application-no-longer-knows
--
-- The consignment status is a text column with no constraint on it. One of the
-- values in it was retired from the application three years ago.
--
-- The status was 'held_customs', used when consignments were routed through a
-- third country. That route was dropped and the application stopped writing and
-- stopped reading the value. The rows that held it were never migrated, because
-- migrating them meant deciding what they had become and nobody could. They are
-- still there, still saying held_customs, and every screen that switches on the
-- status falls through to its default branch and shows them as unknown.
--
-- Measured: 5,600 consignment states across 5 distinct statuses, of which 700
-- hold a status the application no longer knows.
--
-- A lookup table with a foreign key, or an enum, makes retiring a value a
-- migration rather than a decision nobody takes. The rows are old and closed,
-- so they appear on no worklist, and the only place they show up is a total
-- that does not match the sum of the statuses beneath it.
CREATE TABLE fulfilment.consignment_states (
    state_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    consignment_ref varchar(16) NOT NULL,
    status          varchar(20) NOT NULL,
    changed_on      date NOT NULL
);

INSERT INTO fulfilment.consignment_states (consignment_ref, status, changed_on)
SELECT 'CON-' || lpad(g::text, 8, '0'),
       (ARRAY['booked', 'in_transit', 'delivered', 'refused'])[1 + (g % 4)],
       DATE '2024-01-02' + (g % 900)
FROM generate_series(1, 4900) AS g;

-- The route that was dropped, and the rows nobody could decide about.
INSERT INTO fulfilment.consignment_states (consignment_ref, status, changed_on)
SELECT 'CON-' || lpad((500000 + g)::text, 8, '0'),
       'held_customs',
       DATE '2023-02-01' + (g % 300)
FROM generate_series(1, 700) AS g;

-- DEFECT count-star-over-a-left-join-counts-the-parents-with-no-children
--
-- The calls per agent view left joins agents to calls and counts with count(*).
--
-- A left join gives an agent with no calls one row, with every call column
-- null, and count(*) counts rows. So an agent who took no calls is reported as
-- having taken one. The agents who took none are the new starters and the ones
-- on long term leave, which is exactly the population the report is opened to
-- look at, and every one of them reads as having taken a single call.
--
-- Measured: 120 agents, 20 of whom took no calls, every one of them reported by
-- the view as having taken 1.
--
-- count(c.call_id) counts calls rather than rows and gives zero, which is the
-- answer. One call is a plausible number for a new starter, so the report has
-- never looked obviously wrong to the person reading it.
CREATE TABLE support.call_agents (
    agent_ref  varchar(12) PRIMARY KEY,
    agent_name varchar(60) NOT NULL,
    started_on date NOT NULL
);

CREATE TABLE support.agent_calls (
    call_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_ref  varchar(12) NOT NULL REFERENCES support.call_agents (agent_ref),
    taken_at   timestamptz NOT NULL,
    seconds    integer NOT NULL
);

INSERT INTO support.call_agents (agent_ref, agent_name, started_on)
SELECT 'AGT-' || lpad(g::text, 5, '0'),
       'Agent ' || g,
       DATE '2019-01-07' + (g % 2500)
FROM generate_series(1, 120) AS g;

-- The new starters and the agents on long term leave take no calls.
INSERT INTO support.agent_calls (agent_ref, taken_at, seconds)
SELECT 'AGT-' || lpad((1 + (g % 100))::text, 5, '0'),
       TIMESTAMPTZ '2026-05-01 08:00:00+01' + (g * INTERVAL '11 minutes'),
       30 + (g % 900)
FROM generate_series(1, 3000) AS g;

CREATE VIEW analytics.v_calls_per_agent AS
SELECT a.agent_ref,
       a.agent_name,
       count(*) AS calls_taken
FROM support.call_agents AS a
LEFT JOIN support.agent_calls AS c ON c.agent_ref = a.agent_ref
GROUP BY a.agent_ref, a.agent_name;

-- DEFECT the-table-was-copied-for-a-migration-and-the-copy-was-kept
--
-- The customer table was copied before the last cutover so that the old
-- application could be rolled back to. The rollback window closed two years
-- ago. The copy is still here.
--
-- It is a full copy, rows and all, frozen at the moment it was taken. Nothing
-- reads it, nothing writes it, and nothing references it. It is backed up every
-- night, restored into every environment, and its rows are two years out of
-- date, which matters because somebody looking for a customer who is not in the
-- live table will find them in this one and believe what it says. It has the
-- word customers in its name and it is not the customers.
--
-- Measured: 4,400 rows in the pre cutover copy, 0 objects in the database
-- referencing it, and 0 grants on it beyond the owner.
--
-- Dropping it is one statement and the only argument against is that nobody
-- wants to be the person who dropped a table with customers in the name. It
-- costs storage in every environment and it is the reason two reports about
-- customer counts have never agreed.
CREATE TABLE legacy.customers_pre_cutover (
    customer_id  integer PRIMARY KEY,
    account_ref  varchar(12) NOT NULL,
    display_name varchar(80) NOT NULL,
    email        varchar(120) NOT NULL,
    copied_on    date NOT NULL
);

INSERT INTO legacy.customers_pre_cutover (customer_id, account_ref, display_name, email, copied_on)
SELECT g,
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       'Customer ' || g,
       'customer' || g || '@example.invalid',
       DATE '2024-05-18'
FROM generate_series(1, 4400) AS g;

-- DEFECT the-flag-column-is-text-so-it-holds-yes-y-true-and-1
--
-- The marketing opt in is a text column. It holds four different ways of saying
-- yes and three of saying no.
--
-- The column started as text because the first import had the word Yes in it,
-- and every later source wrote whatever it had: the web form wrote true, the
-- till wrote Y, the call centre wrote 1, and an import from a bought list wrote
-- YES in capitals. Every query that filters on this column picks some of the
-- opted in customers and misses the rest, and which ones depends on which
-- values the person writing the query happened to know about.
--
-- Measured: 6,000 opt in rows holding 7 distinct values, of which 4 mean yes
-- and cover 3,429 rows.
--
-- A boolean column, NOT NULL, with the import normalising on the way in, makes
-- the question answerable. Every query returns a number and no query returns
-- the same number, which is why this is a long standing argument rather than a
-- bug.
CREATE TABLE storefront.marketing_opt_ins (
    opt_in_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    opted_in    varchar(8) NOT NULL,
    source      varchar(20) NOT NULL,
    recorded_on date NOT NULL
);

INSERT INTO storefront.marketing_opt_ins (account_ref, opted_in, source, recorded_on)
SELECT 'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       (ARRAY['Yes', 'true', 'Y', '1', 'No', 'false', 'N'])[1 + (g % 7)],
       (ARRAY['import', 'web', 'till', 'call_centre', 'bought_list'])[1 + (g % 5)],
       DATE '2021-09-01' + (g % 1700)
FROM generate_series(1, 6000) AS g;

-- DEFECT autovacuum-is-turned-off-on-the-table-that-churns-the-most
--
-- The scan queue is the highest churn table in the database and autovacuum is
-- disabled on it.
--
-- It was disabled during an incident, because autovacuum was running during the
-- evening peak and the warehouse blamed it for the scanners timing out. The
-- incident was something else. The setting stayed. The table takes a row per
-- scan and deletes it when the scan is processed, so it is almost entirely dead
-- rows, and nothing is reclaiming them. The planner's statistics are from the
-- day it was turned off, so every query against the queue is planned for a
-- table that no longer resembles this one.
--
-- Measured: autovacuum_enabled is off on the scan queue, 24,000 rows have been
-- written to it and 21,600 deleted, leaving 2,400 live rows in the space of
-- twenty four thousand.
--
-- Re-enabling it, with a cost delay if the peak really is tight, is one ALTER
-- TABLE. Nobody will re-enable it because the last person who touched
-- autovacuum on this table was blamed for an outage.
CREATE TABLE ops.scan_queue (
    queue_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    scan_ref   varchar(20) NOT NULL,
    depot_code varchar(12) NOT NULL,
    queued_at  timestamptz NOT NULL
) WITH (autovacuum_enabled = false);

INSERT INTO ops.scan_queue (scan_ref, depot_code, queued_at)
SELECT 'SCN-' || lpad(g::text, 10, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-08-01 06:00:00+01' + (g * INTERVAL '35 seconds')
FROM generate_series(1, 24000) AS g;

-- The scans that have been processed.
DELETE FROM ops.scan_queue WHERE queue_id % 10 <> 0;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.pick_faces ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.pick_faces:' || concat_ws('|', x.depot_code, x.sku, x.capacity))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.pick_faces x
)
UPDATE ops.pick_faces t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.pick_faces ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.pick_faces ADD CONSTRAINT pick_faces_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_pick_faces_warehouse_id ON ops.pick_faces (warehouse_id);

ALTER TABLE storefront.marketing_opt_ins ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('storefront.marketing_opt_ins:' || concat_ws('|', x.account_ref, x.opted_in, x.source))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.marketing_opt_ins x
)
UPDATE storefront.marketing_opt_ins t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.marketing_opt_ins ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE storefront.marketing_opt_ins ADD CONSTRAINT marketing_opt_ins_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_marketing_opt_ins_customer_id ON storefront.marketing_opt_ins (customer_id);
-- <<< relationships
