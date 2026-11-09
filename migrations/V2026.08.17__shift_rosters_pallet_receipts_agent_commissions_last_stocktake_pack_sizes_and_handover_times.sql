-- Cross River Trading Co. -- shift rosters, pallet receipts, agent
-- commissions, last stocktake, pack sizes, handover times
-- author: T. Marchetti
-- postgres: 18
--
-- Who is on shift, where a pallet came from, what an agent is owed, when a
-- depot was last counted, how many units are in a pack, and the moment a
-- delivery changed hands.

-- DEFECT the-composite-key-is-the-right-columns-in-the-wrong-grain
--
-- The shift roster is keyed on (depot, shift date). One row per depot per day.
--
-- The depot runs two shifts a day and has done since the warehouse went to
-- extended hours. The key allows one. The loader writes the day shift, then
-- writes the night shift, and the second write replaces the first because the
-- loader uses ON CONFLICT DO UPDATE. So every extended hours depot holds only
-- its night shift, and the day shift has never been in the table at all.
--
-- Measured: 3,600 roster rows across 40 depots and 90 days, where 24 of those
-- depots run two shifts and hold one row a day.
--
-- The key wants the shift code in it, which makes it (depot, date, shift) and
-- turns the loader's upsert into two inserts. Every depot has a roster and the
-- roster it has is a real one, so the table passes every check that asks
-- whether a depot is covered.
CREATE TABLE ops.shift_rosters (
    depot_code varchar(12) NOT NULL,
    shift_date date NOT NULL,
    shift_code varchar(8) NOT NULL,
    headcount  integer NOT NULL,
    PRIMARY KEY (depot_code, shift_date)
);

INSERT INTO ops.shift_rosters (depot_code, shift_date, shift_code, headcount)
SELECT 'DEP-' || lpad(d::text, 3, '0'),
       DATE '2026-06-01' + n,
       'day',
       6 + ((d + n) % 14)
FROM generate_series(1, 40) AS d
CROSS JOIN generate_series(0, 89) AS n;

-- The night shift, written second by the same loader.
INSERT INTO ops.shift_rosters (depot_code, shift_date, shift_code, headcount)
SELECT 'DEP-' || lpad(d::text, 3, '0'),
       DATE '2026-06-01' + n,
       'night',
       3 + ((d + n) % 8)
FROM generate_series(1, 24) AS d
CROSS JOIN generate_series(0, 89) AS n
ON CONFLICT (depot_code, shift_date) DO UPDATE
SET shift_code = EXCLUDED.shift_code,
    headcount  = EXCLUDED.headcount;

-- DEFECT the-foreign-key-points-at-a-unique-index-that-was-later-dropped
--
-- Pallet receipts referenced the pallet source by its source code, which had a
-- unique index on it. The index was dropped during a rebuild and the foreign
-- key went with it.
--
-- Dropping a unique index that a foreign key depends on takes the foreign key
-- too, and Postgres says so at the time. The rebuild script ran overnight, the
-- message went into a log nobody reads, and the index was recreated afterwards
-- without the constraint. The column is still there, still populated, still
-- joined on everywhere, and nothing checks it any more. Receipts have since
-- been loaded against source codes that do not exist.
--
-- Measured: 4,800 pallet receipts against 400 pallet sources, of which 720
-- receipts name a source that is not in the source table, and 0 foreign keys
-- on the receipts table.
--
-- Recreating the constraint takes a validation scan and a decision about the
-- 720 rows, which is the reason it has not been done. The join is a left join
-- in every report, so the bad rows come back with nulls in the source columns
-- and are read as receipts from a source that was not recorded.
CREATE TABLE supply.pallet_sources (
    source_code varchar(12) PRIMARY KEY,
    source_name varchar(60) NOT NULL,
    added_on    date NOT NULL
);

CREATE TABLE supply.pallet_receipts (
    receipt_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_code varchar(12) NOT NULL,
    pallets     integer NOT NULL,
    received_on date NOT NULL
);

CREATE INDEX pallet_receipts_source_idx ON supply.pallet_receipts (source_code);

INSERT INTO supply.pallet_sources (source_code, source_name, added_on)
SELECT 'PSR-' || lpad(g::text, 6, '0'),
       'Pallet source ' || g,
       DATE '2019-04-01' + (g % 2400)
FROM generate_series(1, 400) AS g;

INSERT INTO supply.pallet_receipts (source_code, pallets, received_on)
SELECT 'PSR-' || lpad((1 + (g % 400))::text, 6, '0'),
       1 + (g % 33),
       DATE '2026-01-08' + (g % 250)
FROM generate_series(1, 4080) AS g;

-- Loaded after the constraint went, against sources that do not exist.
INSERT INTO supply.pallet_receipts (source_code, pallets, received_on)
SELECT 'PSR-' || lpad((900 + (g % 90))::text, 6, '0'),
       1 + (g % 33),
       DATE '2026-05-01' + (g % 140)
FROM generate_series(1, 720) AS g;

-- DEFECT the-row-policy-is-defined-and-the-table-never-enabled-it
--
-- There is a row security policy on the agent commissions table restricting
-- each agent to their own rows. Row security was never enabled on the table.
--
-- A policy without ENABLE ROW LEVEL SECURITY is inert: it is stored, it shows
-- up in the catalogue, it reads correctly, and it is not applied to anything.
-- The migration that added it did the policy and not the enable, and the test
-- that was supposed to prove the restriction worked was written as the owner,
-- who bypasses row security anyway. Every agent can read every agent's
-- commission.
--
-- Measured: 1 policy on the commissions table, row security not enabled on it,
-- and 3,000 commission rows visible to every role that can select the table.
--
-- ALTER TABLE ... ENABLE ROW LEVEL SECURITY is the missing line. The policy
-- exists and is correct, which is why every review that looked for one found
-- it and stopped there.
CREATE TABLE payments.agent_commissions (
    commission_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_ref     varchar(12) NOT NULL,
    period_end    date NOT NULL,
    amount        numeric(12,2) NOT NULL
);

INSERT INTO payments.agent_commissions (agent_ref, period_end, amount)
SELECT 'AGT-' || lpad((1 + (g % 60))::text, 5, '0'),
       DATE '2026-01-31' + ((g % 8) * 30),
       (200 + (g % 4000))::numeric(12,2)
FROM generate_series(1, 3000) AS g;

CREATE POLICY agent_commissions_own_rows ON payments.agent_commissions
    FOR ALL
    USING (agent_ref = current_setting('app.agent_ref', true));

-- DEFECT the-max-over-a-nullable-date-returns-null-for-a-whole-depot
--
-- The last stocktake view takes the maximum stocktake date per depot. The
-- stocktake date is nullable, and a depot whose every stocktake has a null date
-- gets a null back.
--
-- The null means the stocktake was booked and never completed, which is a real
-- and different thing from never having been counted. max ignores nulls, so a
-- depot with one completed count and four incomplete ones correctly reports the
-- completed one. A depot whose counts were all abandoned reports null, and the
-- screen that shows the overdue depots sorts nulls last and puts the worst
-- depots at the bottom of the list.
--
-- Measured: 40 depots and 8 of them reported with no last stocktake date at
-- all, every one of which has booked stocktakes that were never completed.
--
-- Counting the completed stocktakes alongside the maximum date tells the two
-- apart in the view rather than in the head of whoever reads it. Null sorts
-- last, so the depots that most need counting are the ones nobody scrolls to.
CREATE TABLE ops.stocktakes (
    stocktake_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code   varchar(12) NOT NULL,
    booked_on    date NOT NULL,
    counted_on   date
);

INSERT INTO ops.stocktakes (depot_code, booked_on, counted_on)
SELECT 'DEP-' || lpad(d::text, 3, '0'),
       DATE '2025-01-06' + (n * 90),
       CASE WHEN d % 5 = 0 THEN NULL
            ELSE DATE '2025-01-06' + (n * 90) + 3
       END
FROM generate_series(1, 40) AS d
CROSS JOIN generate_series(0, 5) AS n;

CREATE VIEW analytics.v_last_stocktake AS
SELECT depot_code,
       max(counted_on) AS last_counted_on
FROM ops.stocktakes
GROUP BY depot_code;

-- DEFECT the-check-constraint-was-added-not-valid-and-the-old-rows-break-it
--
-- The pack size must be at least one. The check constraint that says so was
-- added NOT VALID, so it applies to new rows and was never checked against the
-- old ones.
--
-- NOT VALID was the right call at the time, because validating it would have
-- taken a table lock during trading hours. The VALIDATE CONSTRAINT that was
-- supposed to follow that evening was never run. The constraint reads as a
-- guarantee in every schema dump and in every review, and there are rows in the
-- table that break it, including pack sizes of zero that make the cost per unit
-- a division by zero.
--
-- Measured: 2,400 pack sizes under a NOT VALID check that units_per_pack >= 1,
-- of which 240 hold zero.
--
-- VALIDATE CONSTRAINT takes a share update exclusive lock and no table rewrite,
-- and it will fail on the 240 rows, which is the point. The constraint is in
-- the dump and looks enforced, so nothing has ever asked whether it is.
CREATE TABLE catalog.pack_sizes (
    pack_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku            varchar(20) NOT NULL,
    units_per_pack integer NOT NULL,
    set_on         date NOT NULL
);

INSERT INTO catalog.pack_sizes (sku, units_per_pack, set_on)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       CASE WHEN g % 10 = 0 THEN 0 ELSE 1 + (g % 48) END,
       DATE '2022-02-01' + (g % 1500)
FROM generate_series(1, 2400) AS g;

ALTER TABLE catalog.pack_sizes
    ADD CONSTRAINT pack_sizes_units_positive CHECK (units_per_pack >= 1) NOT VALID;

-- DEFECT the-two-timestamps-are-stored-in-different-types-on-the-same-row
--
-- The handover row holds the time the driver arrived and the time the customer
-- signed. One is a timestamptz and the other is a plain timestamp.
--
-- The arrival is written by the vehicle tracker, which sends an instant, and
-- the signature is written by the handheld, which sends a wall clock reading
-- with no zone on it. Subtracting one from the other makes Postgres read the
-- plain timestamp as being in the session's time zone, which is UTC on the
-- reporting connection and London on the application's. The same two rows give
-- a handover duration that differs by an hour depending on who asks, for half
-- the year.
--
-- Measured: 3,000 handover rows, of which 3,000 fall in British Summer Time,
-- and every one gives a duration an hour longer when the signature is read as
-- UTC than when it is read as London time.
--
-- One type for both, timestamptz, with the handheld's zone applied where the
-- reading is taken. Both columns hold plausible times and the difference
-- between them is plausible too, which is why the discrepancy is argued about
-- rather than investigated.
CREATE TABLE fulfilment.handover_times (
    handover_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    drop_ref    varchar(16) NOT NULL,
    arrived_at  timestamptz NOT NULL,
    signed_at   timestamp NOT NULL
);

INSERT INTO fulfilment.handover_times (drop_ref, arrived_at, signed_at)
SELECT 'DRP-' || lpad(g::text, 8, '0'),
       TIMESTAMPTZ '2026-06-01 08:00:00+01' + (g * INTERVAL '13 minutes'),
       TIMESTAMP '2026-06-01 08:09:00' + (g * INTERVAL '13 minutes')
FROM generate_series(1, 3000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE fulfilment.handover_times ADD COLUMN round_id integer;

WITH p AS (
    SELECT round_id AS v, row_number() OVER (ORDER BY round_id) - 1 AS k
      FROM fulfilment.van_rounds
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.van_rounds)
                 * power((abs(hashtext('fulfilment.handover_times:' || concat_ws('|', x.drop_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.handover_times x
)
UPDATE fulfilment.handover_times t
   SET round_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.handover_times ALTER COLUMN round_id SET NOT NULL;
ALTER TABLE fulfilment.handover_times ADD CONSTRAINT handover_times_round_id_fkey FOREIGN KEY (round_id) REFERENCES fulfilment.van_rounds (round_id);
CREATE INDEX ix_handover_times_round_id ON fulfilment.handover_times (round_id);

ALTER TABLE ops.shift_rosters ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.shift_rosters:' || concat_ws('|', x.depot_code, x.shift_code, x.headcount))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.shift_rosters x
)
UPDATE ops.shift_rosters t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.shift_rosters ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.shift_rosters ADD CONSTRAINT shift_rosters_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_shift_rosters_store_id ON ops.shift_rosters (store_id);

ALTER TABLE ops.stocktakes ADD COLUMN count_id integer;

WITH p AS (
    SELECT count_id AS v, row_number() OVER (ORDER BY count_id) - 1 AS k
      FROM ops.stock_counts
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.stock_counts)
                 * power((abs(hashtext('ops.stocktakes:' || concat_ws('|', x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.stocktakes x
)
UPDATE ops.stocktakes t
   SET count_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.stocktakes ALTER COLUMN count_id SET NOT NULL;
ALTER TABLE ops.stocktakes ADD CONSTRAINT stocktakes_count_id_fkey FOREIGN KEY (count_id) REFERENCES ops.stock_counts (count_id);
CREATE INDEX ix_stocktakes_count_id ON ops.stocktakes (count_id);

ALTER TABLE payments.agent_commissions ADD COLUMN run_id integer;

WITH p AS (
    SELECT run_id AS v, row_number() OVER (ORDER BY run_id) - 1 AS k
      FROM payments.commission_runs
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.commission_runs)
                 * power((abs(hashtext('payments.agent_commissions:' || concat_ws('|', x.agent_ref, x.amount))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.agent_commissions x
)
UPDATE payments.agent_commissions t
   SET run_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.agent_commissions ALTER COLUMN run_id SET NOT NULL;
ALTER TABLE payments.agent_commissions ADD CONSTRAINT agent_commissions_run_id_fkey FOREIGN KEY (run_id) REFERENCES payments.commission_runs (run_id);
CREATE INDEX ix_agent_commissions_run_id ON payments.agent_commissions (run_id);
-- <<< relationships
