-- Cross River Trading Co. -- gate bookings, depot billing, SLA breaches,
-- depot headcount, reorder points, consent events
-- author: T. Marchetti
-- postgres: 18
--
-- A slot booked on a gate, what a depot is charged, a service level that was
-- missed, how many people a depot has, the level at which a line is reordered,
-- and the record of a customer giving or withdrawing consent.

-- DEFECT the-natural-key-is-spread-across-three-tables-and-declared-in-none
--
-- A gate booking is one depot, one gate and one slot. Those three columns
-- identify a booking and there is no constraint on them, so the same slot has
-- been booked twice.
--
-- The booking screen checks for a clash before it writes, which is why this is
-- rare rather than constant. Two users booking the same slot within the same
-- second both pass the check and both write. The double booking surfaces on the
-- morning of the slot, when two vehicles arrive for the same gate, and it is
-- resolved on the yard by whoever is standing there. Nothing goes back into the
-- table, so the same two rows are still there.
--
-- Measured: 6,064 gate bookings over 5,760 distinct depot, gate and slot
-- combinations, of which 304 combinations are booked twice, with no unique
-- constraint on the three columns.
--
-- A unique constraint on the three columns turns the race into a failed insert
-- the screen can retry. Adding it needs the 304 duplicate slots resolved first,
-- and resolving them means telling somebody their booking is gone.
CREATE TABLE ops.gate_bookings (
    booking_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    gate_no    integer NOT NULL,
    slot_start timestamptz NOT NULL,
    carrier_ref varchar(16) NOT NULL
);

INSERT INTO ops.gate_bookings (depot_code, gate_no, slot_start, carrier_ref)
SELECT 'DEP-' || lpad(d::text, 3, '0'),
       gate,
       TIMESTAMPTZ '2026-07-06 06:00:00+01' + (slot * INTERVAL '1 hour'),
       'CAR-' || lpad((1 + ((d * 7 + gate * 3 + slot) % 320))::text, 6, '0')
FROM generate_series(1, 40) AS d
CROSS JOIN generate_series(1, 6) AS gate
CROSS JOIN generate_series(0, 23) AS slot;

-- The bookings that passed the clash check at the same moment as another.
INSERT INTO ops.gate_bookings (depot_code, gate_no, slot_start, carrier_ref)
SELECT depot_code, gate_no, slot_start, 'CAR-' || lpad((900000 + booking_id)::text, 6, '0')
FROM ops.gate_bookings
WHERE booking_id % 19 = 3;

-- DEFECT the-depot-code-prefix-decides-the-billing-rate-and-nothing-says-so
--
-- A cost centre beginning with T is a transfer and must be left out of the
-- depot's charge. That rule lives in one query and in one person's head.
--
-- The prefix was chosen when transfers were added because it did not need a
-- schema change, and it has worked for six years. It is not a constraint, not a
-- comment, not a lookup table and not documented anywhere a new analyst would
-- find it. Every report written since by somebody who did not know it charges
-- the depots for moving their own stock between themselves, and the numbers are
-- plausible, so the reports have been signed off.
--
-- Measured: 4,800 billing lines, of which 960 have a cost centre beginning with
-- T, on a column carrying no comment and no constraint that mentions the rule.
--
-- A boolean column, or a cost centre type table, puts the rule in the schema
-- where it can be read. The convention is reliable, which is exactly what makes
-- it dangerous: it has never failed, so nobody has ever had to learn it.
CREATE TABLE ops.depot_billing (
    line_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code  varchar(12) NOT NULL,
    cost_centre varchar(10) NOT NULL,
    amount_p    integer NOT NULL,
    billed_on   date NOT NULL
);

INSERT INTO ops.depot_billing (depot_code, cost_centre, amount_p, billed_on)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       CASE WHEN g % 5 = 0 THEN 'T' ELSE 'C' END || lpad((1 + (g % 24))::text, 4, '0'),
       500 + (g % 40000),
       DATE '2025-10-01' + (g % 350)
FROM generate_series(1, 4800) AS g;

-- DEFECT the-audit-trigger-runs-before-the-validation-trigger-rejects-the-row
--
-- Two before-insert triggers on the SLA breach table. The audit trigger fires
-- first and the validation trigger, which drops invalid rows, fires second.
--
-- Auditing before validating means the audit records attempts and the table
-- records breaches, and the two were always going to differ. Nobody intended
-- that: the audit trigger was named trg_a_write_audit so that it would be the
-- first thing anybody saw in a listing, and that is also the order Postgres
-- fires them in. The validation trigger returns null for a breach whose
-- resolved time is before its raised time, so those rows never land, and the
-- audit already has them.
--
-- Measured: 3,000 attempted SLA breaches, of which 2,400 were stored and 600
-- were dropped by validation, against 3,000 audit rows.
--
-- Validating in a before trigger and auditing in an after trigger puts them in
-- the right order. Both tables are internally consistent, so the difference is
-- only visible when the two are counted against each other, which happens in no
-- report.
CREATE TABLE support.sla_breaches (
    breach_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref    varchar(16) NOT NULL,
    raised_at   timestamptz NOT NULL,
    resolved_at timestamptz NOT NULL
);

CREATE TABLE support.sla_breach_audit (
    audit_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref   varchar(16) NOT NULL,
    written_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION support.fn_write_breach_audit() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO support.sla_breach_audit (case_ref) VALUES (NEW.case_ref);
    RETURN NEW;
END;
$$;

CREATE FUNCTION support.fn_reject_invalid_breach() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.resolved_at < NEW.raised_at THEN
        RETURN NULL;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_a_write_audit BEFORE INSERT ON support.sla_breaches
    FOR EACH ROW EXECUTE FUNCTION support.fn_write_breach_audit();

CREATE TRIGGER trg_b_reject_invalid BEFORE INSERT ON support.sla_breaches
    FOR EACH ROW EXECUTE FUNCTION support.fn_reject_invalid_breach();

INSERT INTO support.sla_breaches (case_ref, raised_at, resolved_at)
SELECT 'CAS-' || lpad(g::text, 8, '0'),
       TIMESTAMPTZ '2026-03-02 08:00:00+00' + (g * INTERVAL '29 minutes'),
       TIMESTAMPTZ '2026-03-02 08:00:00+00' + (g * INTERVAL '29 minutes')
           + CASE WHEN g % 5 = 0 THEN INTERVAL '-3 hours' ELSE INTERVAL '4 hours' END
FROM generate_series(1, 3000) AS g;

-- DEFECT the-view-selects-a-column-that-is-now-populated-by-nothing
--
-- The depot headcount view adds the agency headcount to the permanent one. The
-- agency feed stopped eighteen months ago and the column has been null ever
-- since.
--
-- The agency supplied a nightly file of who was on site. The contract ended,
-- the file stopped, and the column was left in place because removing it meant
-- changing the view and the view belongs to another team. Permanent plus agency
-- is null on every row since the feed stopped, and sum skips nulls, so those
-- rows are dropped from the total entirely. The view returns a number, it is
-- not flagged, and it covers eight months out of thirty.
--
-- Measured: 1,200 depot months over 40 depots, of which 880 have a null agency
-- headcount and are silently left out of every depot's total.
--
-- coalesce in the view is the one-line version and dropping the column is the
-- honest one. The view returns a plausible number for every depot and the
-- permanent headcount is correct and present on every row,
-- which is why the source table passes every completeness check run against it.
CREATE TABLE ops.depot_staff_counts (
    depot_code        varchar(12) NOT NULL,
    month_start       date NOT NULL,
    permanent_headcount integer NOT NULL,
    agency_headcount  integer,
    PRIMARY KEY (depot_code, month_start)
);

INSERT INTO ops.depot_staff_counts (depot_code, month_start, permanent_headcount, agency_headcount)
SELECT 'DEP-' || lpad(d::text, 3, '0'),
       (DATE '2024-04-01' + (n || ' months')::interval)::date,
       18 + ((d + n) % 40),
       CASE WHEN n < 8 THEN 3 + ((d + n) % 12) ELSE NULL END
FROM generate_series(1, 40) AS d
CROSS JOIN generate_series(0, 29) AS n;

CREATE VIEW analytics.v_depot_headcount AS
SELECT depot_code,
       sum(permanent_headcount + agency_headcount) AS headcount
FROM ops.depot_staff_counts
GROUP BY depot_code;

-- DEFECT the-function-reads-the-table-it-is-rebuilding-halfway-through
--
-- The reorder point rebuild loops over the lines and reads the whole demand
-- history once per line.
--
-- The history has no index on the line, so each read is a full scan, and there
-- are two hundred lines. The rebuild therefore scans one point two million rows
-- to produce two hundred numbers. It was written when there were twelve lines
-- and a thousand rows of history, where it was fine, and it has been scaled by
-- adding lines rather than by changing the shape of the query.
--
-- Measured: one rebuild run scanning 1,200,000 rows of demand history to write
-- 200 reorder points, recorded by the function as it goes.
--
-- One grouped query over the history writes all two hundred in a single scan.
-- The rebuild runs weekly at two in the morning and finishes, so its cost has
-- never appeared on anything anybody watches.
CREATE TABLE supply.demand_history (
    history_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku        varchar(20) NOT NULL,
    demand_on  date NOT NULL,
    units      integer NOT NULL
);

CREATE TABLE supply.reorder_points (
    sku          varchar(20) PRIMARY KEY,
    reorder_at   integer NOT NULL,
    rebuilt_on   date
);

CREATE TABLE supply.reorder_rebuild_log (
    run_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ran_at       timestamptz NOT NULL DEFAULT now(),
    lines_written integer NOT NULL,
    rows_scanned bigint NOT NULL
);

INSERT INTO supply.demand_history (sku, demand_on, units)
SELECT 'SKU-' || lpad((1 + (g % 200))::text, 6, '0'),
       DATE '2026-01-05' + (g % 250),
       1 + (g % 60)
FROM generate_series(1, 6000) AS g;

INSERT INTO supply.reorder_points (sku, reorder_at)
SELECT 'SKU-' || lpad(g::text, 6, '0'), 0
FROM generate_series(1, 200) AS g;

CREATE FUNCTION supply.fn_rebuild_reorder_points() RETURNS integer
LANGUAGE plpgsql AS $$
DECLARE
    r        record;
    n        integer := 0;
    scanned  bigint := 0;
    avg_units numeric;
BEGIN
    FOR r IN SELECT sku FROM supply.reorder_points ORDER BY sku LOOP
        SELECT coalesce(avg(units), 0) INTO avg_units
        FROM supply.demand_history
        WHERE sku = r.sku;

        UPDATE supply.reorder_points
        SET reorder_at = ceil(avg_units * 7)::integer,
            rebuilt_on = DATE '2026-09-13'
        WHERE sku = r.sku;

        scanned := scanned + (SELECT count(*) FROM supply.demand_history);
        n := n + 1;
    END LOOP;

    INSERT INTO supply.reorder_rebuild_log (lines_written, rows_scanned)
    VALUES (n, scanned);
    RETURN n;
END;
$$;

SELECT supply.fn_rebuild_reorder_points();

-- DEFECT the-backfill-used-the-run-date-instead-of-the-event-date
--
-- The consent events table was backfilled from an older system and every
-- backfilled row carries the date the backfill ran.
--
-- The source had the consent date in it. The backfill script wrote now() into
-- the recorded_at column, because that is what the column default was and the
-- script inserted without naming it. So two fifths of the consent history
-- happened, as far as this table is concerned, on one afternoon in November
-- 2025. Any question about when consent was given, which is the question the
-- regulator asks, is answered wrongly for those rows, and the answer is
-- confidently wrong rather than null.
--
-- Measured: 9,000 consent events, of which 3,600 carry the identical timestamp
-- the backfill ran at.
--
-- The source file still exists and the dates can be restored from it, which is
-- a day of work nobody has been given. The rows are present, complete and
-- correctly ordered relative to each other, so every check of the backfill
-- passed.
CREATE TABLE marketing.consent_events (
    event_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    channel     varchar(20) NOT NULL,
    granted     boolean NOT NULL,
    recorded_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO marketing.consent_events (account_ref, channel, granted, recorded_at)
SELECT 'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       (ARRAY['email', 'sms', 'post', 'phone'])[1 + (g % 4)],
       g % 3 <> 0,
       TIMESTAMPTZ '2025-12-01 09:00:00+00' + (g * INTERVAL '41 minutes')
FROM generate_series(1, 5400) AS g;

-- The backfill from the older system, which wrote the run time.
INSERT INTO marketing.consent_events (account_ref, channel, granted, recorded_at)
SELECT 'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       (ARRAY['email', 'sms', 'post', 'phone'])[1 + (g % 4)],
       g % 3 <> 0,
       TIMESTAMPTZ '2025-11-12 16:41:09.226471+00'
FROM generate_series(1, 3600) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.gate_bookings ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.gate_bookings:' || concat_ws('|', x.depot_code, x.gate_no, x.carrier_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.gate_bookings x
)
UPDATE ops.gate_bookings t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.gate_bookings ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.gate_bookings ADD CONSTRAINT gate_bookings_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_gate_bookings_store_id ON ops.gate_bookings (store_id);

ALTER TABLE ops.gate_passes ADD COLUMN booking_id integer;

WITH p AS (
    SELECT booking_id AS v, row_number() OVER (ORDER BY booking_id) - 1 AS k
      FROM ops.gate_bookings
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.gate_bookings)
                 * power((abs(hashtext('ops.gate_passes:' || concat_ws('|', x.pass_ref, x.vehicle_reg, x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.gate_passes x
)
UPDATE ops.gate_passes t
   SET booking_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.gate_passes ALTER COLUMN booking_id SET NOT NULL;
ALTER TABLE ops.gate_passes ADD CONSTRAINT gate_passes_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES ops.gate_bookings (booking_id);
CREATE INDEX ix_gate_passes_booking_id ON ops.gate_passes (booking_id);

ALTER TABLE ops.gatehouse_checkins ADD COLUMN booking_id integer;

WITH p AS (
    SELECT booking_id AS v, row_number() OVER (ORDER BY booking_id) - 1 AS k
      FROM ops.gate_bookings
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.gate_bookings)
                 * power((abs(hashtext('ops.gatehouse_checkins:' || concat_ws('|', x.vehicle_reg, x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.gatehouse_checkins x
)
UPDATE ops.gatehouse_checkins t
   SET booking_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.gatehouse_checkins ALTER COLUMN booking_id SET NOT NULL;
ALTER TABLE ops.gatehouse_checkins ADD CONSTRAINT gatehouse_checkins_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES ops.gate_bookings (booking_id);
CREATE INDEX ix_gatehouse_checkins_booking_id ON ops.gatehouse_checkins (booking_id);

ALTER TABLE support.sla_breaches ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.sla_breaches:' || concat_ws('|', x.case_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.sla_breaches x
)
UPDATE support.sla_breaches t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.sla_breaches ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.sla_breaches ADD CONSTRAINT sla_breaches_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_sla_breaches_ticket_id ON support.sla_breaches (ticket_id);
-- <<< relationships
