-- Cross River Trading Co. -- price list loads, yard moves, conveyor events,
-- lead sources, meter readings, dispatch days
-- author: N. Farrow
-- postgres: 18
--
-- The supplier price list load, the yard move log, the conveyor event feed,
-- the marketing lead source list, the meter reading import, and the daily
-- dispatch count on the operations board.

-- DEFECT on-conflict-do-nothing-hides-the-rows-the-price-load-rejected
--
-- The supplier price list load inserts every line with ON CONFLICT DO NOTHING,
-- so a file that is sent twice does not fail.
--
-- DO NOTHING does not distinguish between a line that is already loaded and a
-- line that collides with a different line for a different reason. A supplier
-- who sends two prices for the same product in one file has the second one
-- dropped, silently, and the load reports success because the statement did
-- succeed. The load count recorded against the file is the number of lines
-- read, not the number stored, so the two never disagree on paper.
--
-- Measured: 4,000 lines read across 40 files and 3,600 stored, with the loads
-- table recording 4,000.
--
-- ON CONFLICT DO UPDATE takes the later price, and counting the rows actually
-- written makes the gap visible either way. The prices that survive are the
-- first of each pair, which is usually the old one.
CREATE TABLE supply.price_list_loads (
    load_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    file_ref    varchar(24) NOT NULL,
    loaded_on   date NOT NULL,
    lines_read  integer NOT NULL
);

CREATE TABLE supply.price_list_entries (
    entry_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref varchar(12) NOT NULL,
    sku          varchar(20) NOT NULL,
    unit_price   numeric(10,2) NOT NULL,
    effective_on date NOT NULL,
    CONSTRAINT price_list_entries_one_price UNIQUE (supplier_ref, sku, effective_on)
);

INSERT INTO supply.price_list_loads (file_ref, loaded_on, lines_read)
SELECT 'PRICES-' || lpad(g::text, 6, '0'),
       DATE '2026-06-01' + (g % 60),
       100
FROM generate_series(1, 40) AS g;

-- The load: every file carries a hundred lines, and some of them collide.
INSERT INTO supply.price_list_entries (supplier_ref, sku, unit_price, effective_on)
SELECT 'SUP-' || lpad((1 + (f % 70))::text, 3, '0'),
       'SKU-' || lpad((((f * 100) + (l - CASE WHEN l % 10 = 0 THEN 1 ELSE 0 END)) % 900000)::text, 8, '0'),
       (3 + ((f + l) % 200))::numeric(10,2),
       DATE '2026-07-01'
FROM generate_series(1, 40) AS f,
     generate_series(1, 100) AS l
ON CONFLICT DO NOTHING;

-- DEFECT trigger-function-swallows-every-exception-it-raises
--
-- The yard move trigger writes a log row. It is wrapped in an exception
-- handler that catches everything and carries on, so that a problem with the
-- log can never stop a yard move being recorded.
--
-- WHEN OTHERS THEN NULL catches the failure, discards it, and returns as
-- though the log had been written. The handler was added after a week when a
-- full disc stopped the yard, and it does what it was asked to do. It also
-- catches the log failures that are not a full disc: a value too long for its
-- column, and a constraint the log has and the move does not.
--
-- Measured: 3,000 yard moves and 2,400 log rows. The 600 with no log are the
-- moves whose vehicle registration is longer than the log column allows.
--
-- Catching the specific condition, logging the failure somewhere, or letting
-- the write fail are all defensible. Catching everything and saying nothing is
-- the one choice that makes the gap undiscoverable, and the log is what the
-- yard is audited against.
CREATE TABLE ops.yard_moves (
    move_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vehicle_reg varchar(24) NOT NULL,
    depot_code  varchar(12) NOT NULL,
    moved_at    timestamptz NOT NULL
);

CREATE TABLE ops.yard_move_log (
    log_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    move_id     integer NOT NULL,
    vehicle_reg varchar(10) NOT NULL,
    logged_at   timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION ops.fn_record_yard_move() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        INSERT INTO ops.yard_move_log (move_id, vehicle_reg)
        VALUES (NEW.move_id, NEW.vehicle_reg);
    EXCEPTION
        WHEN OTHERS THEN
            NULL;
    END;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_record_yard_move
    AFTER INSERT ON ops.yard_moves
    FOR EACH ROW EXECUTE FUNCTION ops.fn_record_yard_move();

INSERT INTO ops.yard_moves (vehicle_reg, depot_code, moved_at)
SELECT CASE WHEN g % 5 = 0
            THEN 'CR' || lpad((1 + (g % 90))::text, 2, '0') || ' XYZ TRAILER'
            ELSE 'CR' || lpad((1 + (g % 90))::text, 2, '0') || ' XYZ'
       END,
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-07-01 06:00:00+01' + (g * INTERVAL '8 minutes')
FROM generate_series(1, 3000) AS g;

-- DEFECT timestamp-with-second-precision-lets-events-collide
--
-- Conveyor events are stamped to the second, because the column was declared
-- timestamp(0) to save space on a table that was expected to be large.
--
-- The conveyor reads faster than one parcel a second. Two events on the same
-- belt in the same second are indistinguishable by time, and time is what the
-- throughput report and the jam investigation both sort by. Rounding to the
-- second is also rounding, not truncation, so an event can be stamped a second
-- after the event that followed it.
--
-- Measured: 5,000 conveyor events, and 4,994 of them sharing a belt and a
-- second with at least one other.
--
-- Microsecond precision is the default for a reason and costs nothing on disc
-- worth having. The jam investigations are done from the belt's own logs,
-- which is the workaround that has kept this invisible.
CREATE TABLE ops.conveyor_events (
    event_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    belt_code   varchar(8) NOT NULL,
    parcel_ref  varchar(20) NOT NULL,
    event_type  varchar(12) NOT NULL,
    occurred_at timestamp(0) NOT NULL
);

INSERT INTO ops.conveyor_events (belt_code, parcel_ref, event_type, occurred_at)
SELECT 'BELT-' || lpad((1 + ((g / 625) % 8))::text, 2, '0'),
       'PCL-' || lpad(g::text, 8, '0'),
       (ARRAY['on', 'scanned', 'diverted', 'off'])[1 + (g % 4)],
       TIMESTAMP '2026-07-06 05:00:00' + (g * INTERVAL '0.37 seconds')
FROM generate_series(1, 5000) AS g;

-- DEFECT text-key-with-untrimmed-whitespace-holds-the-same-source-twice
--
-- Lead sources are keyed by their name, typed in by whoever set the campaign
-- up.
--
-- Nothing trims the name and nothing folds its case, so the same source
-- arrives as itself, as itself with a trailing space, and as itself with a
-- capital letter in a different place. Each one is a distinct key, each one
-- accumulates its own leads, and the source report lists all of them as
-- separate lines with no indication that they are the same thing.
--
-- Measured: 600 lead sources, and 400 rows, in 200 pairs, differing from each
-- other only by case or by surrounding whitespace.
--
-- Trimming and folding on the way in, with a unique index over the folded
-- value, makes the key mean what people think it means. The report is read as
-- a long tail of small sources, which is a plausible thing for a source report
-- to show.
CREATE TABLE marketing.lead_sources (
    source_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_name varchar(60) NOT NULL UNIQUE,
    added_on    date NOT NULL,
    lead_count  integer NOT NULL
);

INSERT INTO marketing.lead_sources (source_name, added_on, lead_count)
SELECT 'Source ' || g,
       DATE '2024-01-01' + (g % 900),
       10 + (g % 400)
FROM generate_series(1, 400) AS g;

-- The same sources again, typed differently.
INSERT INTO marketing.lead_sources (source_name, added_on, lead_count)
SELECT CASE WHEN g % 2 = 0 THEN 'Source ' || g || ' '
            ELSE 'source ' || g
       END,
       DATE '2025-06-01' + (g % 300),
       5 + (g % 200)
FROM generate_series(1, 200) AS g;

-- DEFECT numeric-reference-kept-as-text-does-not-all-parse
--
-- Meter readings reference their meter by a number held in a text column,
-- because the import file has it in quotes.
--
-- Most of the values are digits. Some of them are not: a meter that was
-- replaced has the old number and the new one in the same field separated by a
-- slash, and a meter nobody could find has the word unknown. Any join that
-- casts the column to an integer fails on those rows, so the reading import
-- either errors on the whole file or is written to skip them, and it was
-- written to skip them.
--
-- Measured: 2,400 meter readings, 160 of them holding a reference that is not
-- a number, and 160 readings that reach no meter.
--
-- The reference belongs in an integer column with the unparseable rows held
-- somewhere they can be worked through. Sixteen hundred pounds of energy
-- billing a year sits in those 160 readings, which is under the threshold
-- anybody investigates.
CREATE TABLE ops.meters (
    meter_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    meter_no   integer NOT NULL UNIQUE,
    depot_code varchar(12) NOT NULL,
    fitted_on  date NOT NULL
);

CREATE TABLE legacy.meter_readings (
    reading_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    meter_ref  varchar(24) NOT NULL,
    read_on    date NOT NULL,
    units      numeric(12,3) NOT NULL
);

INSERT INTO ops.meters (meter_no, depot_code, fitted_on)
SELECT 1000 + g,
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2018-05-01' + (g % 2500)
FROM generate_series(1, 400) AS g;

INSERT INTO legacy.meter_readings (meter_ref, read_on, units)
SELECT CASE WHEN g % 30 = 0 THEN (1000 + (1 + (g % 400)))::text || '/' || (2000 + (g % 400))::text
            WHEN g % 30 = 1 THEN 'unknown'
            ELSE (1000 + (1 + (g % 400)))::text
       END,
       DATE '2026-01-01' + (g % 240),
       (100 + (g % 9000))::numeric(12,3)
FROM generate_series(1, 2400) AS g;

-- DEFECT day-window-inclusive-at-both-ends-counts-midnight-twice
--
-- The daily dispatch count takes everything from midnight to midnight, and it
-- takes both ends inclusively.
--
-- A dispatch stamped at exactly midnight falls in two days: the end of one
-- window and the start of the next. The board's daily figures add up to more
-- than the number of dispatches, and the overlap is small enough that it reads
-- as a good day rather than as the same parcels counted twice. Midnight is not
-- a rare timestamp here, because the overnight trunk run stamps its manifest
-- at exactly midnight.
--
-- Measured: 3,600 dispatch events, 120 of them at exactly midnight, and daily
-- totals adding to 3,720.
--
-- A half open window, from midnight inclusive to the next midnight exclusive,
-- is the only version that tiles. Every calendar in the world is half open and
-- almost every hand written date range is not.
CREATE TABLE fulfilment.dispatch_events (
    event_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    consignment_ref varchar(16) NOT NULL,
    depot_code   varchar(12) NOT NULL,
    dispatched_at timestamp NOT NULL
);

INSERT INTO fulfilment.dispatch_events (consignment_ref, depot_code, dispatched_at)
SELECT 'CNS-' || lpad((200000 + g)::text, 8, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       CASE WHEN g % 30 = 0
            THEN TIMESTAMP '2026-07-01 00:00:00' + ((1 + (g % 25)) * INTERVAL '1 day')
            ELSE TIMESTAMP '2026-07-01 00:00:00' + ((g % 28) * INTERVAL '1 day')
                 + (60 + (g % 1300)) * INTERVAL '1 minute'
       END
FROM generate_series(1, 3600) AS g;

CREATE VIEW analytics.v_daily_dispatch AS
SELECT d.day::date AS dispatch_day,
       (SELECT count(*)
        FROM fulfilment.dispatch_events e
        WHERE e.dispatched_at >= d.day
          AND e.dispatched_at <= d.day + INTERVAL '1 day') AS dispatches
FROM generate_series(TIMESTAMP '2026-07-01', TIMESTAMP '2026-07-30', INTERVAL '1 day') AS d(day);

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.meter_pulses ADD COLUMN meter_id integer;

WITH p AS (
    SELECT meter_id AS v, row_number() OVER (ORDER BY meter_id) - 1 AS k
      FROM ops.meters
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.meters)
                 * power((abs(hashtext('ops.meter_pulses:' || concat_ws('|', x.meter_ref, x.units))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.meter_pulses x
)
UPDATE ops.meter_pulses t
   SET meter_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.meter_pulses ALTER COLUMN meter_id SET NOT NULL;
ALTER TABLE ops.meter_pulses ADD CONSTRAINT meter_pulses_meter_id_fkey FOREIGN KEY (meter_id) REFERENCES ops.meters (meter_id);
CREATE INDEX ix_meter_pulses_meter_id ON ops.meter_pulses (meter_id);

ALTER TABLE ops.yard_moves ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.yard_moves:' || concat_ws('|', x.vehicle_reg, x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.yard_moves x
)
UPDATE ops.yard_moves t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.yard_moves ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.yard_moves ADD CONSTRAINT yard_moves_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_yard_moves_warehouse_id ON ops.yard_moves (warehouse_id);

ALTER TABLE supply.price_list_entries ADD COLUMN load_id integer;

WITH p AS (
    SELECT load_id AS v, row_number() OVER (ORDER BY load_id) - 1 AS k
      FROM supply.price_list_loads
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.price_list_loads)
                 * power((abs(hashtext('supply.price_list_entries:' || concat_ws('|', x.supplier_ref, x.sku, x.unit_price))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.price_list_entries x
)
UPDATE supply.price_list_entries t
   SET load_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.price_list_entries ALTER COLUMN load_id SET NOT NULL;
ALTER TABLE supply.price_list_entries ADD CONSTRAINT price_list_entries_load_id_fkey FOREIGN KEY (load_id) REFERENCES supply.price_list_loads (load_id);
CREATE INDEX ix_price_list_entries_load_id ON supply.price_list_entries (load_id);

ALTER TABLE supply.price_list_loads ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.price_list_loads:' || concat_ws('|', x.file_ref, x.lines_read))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.price_list_loads x
)
UPDATE supply.price_list_loads t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.price_list_loads ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.price_list_loads ADD CONSTRAINT price_list_loads_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_price_list_loads_supplier_id ON supply.price_list_loads (supplier_id);
-- <<< relationships
