-- Cross River Trading Co. -- credit note screen, tariff feed loader, payout
-- runs, schema change log, loading bay bookings, usage sampling
-- author: P. Adeyemi
-- postgres: 18
--
-- The credit notes the depot managers look at, the tariff file the customs
-- broker sends every Monday, the weekly payout run finance signs off, the
-- change log the auditors asked for, the loading bay diary the yard uses, and
-- the usage samples the capacity report is built from.

-- DEFECT view-with-an-inner-limit-truncates-before-the-filter-is-applied
--
-- The credit note screen reads a view that was written to keep the screen
-- quick: the most recent two hundred credits, newest first.
--
-- The limit is inside the view, so it is applied before anything the screen
-- adds. A manager who filters the view down to their own depot does not get
-- that depot's most recent two hundred credits. They get whatever share of the
-- global two hundred happens to be theirs, and the rest of their depot's
-- credits are not in the view at all to be filtered.
--
-- Measured: 1,200 credit notes across 6 depots. The view holds 200 rows.
-- Filtering it to one depot returns 34 of that depot's 200 credit notes.
--
-- The fix is to take the LIMIT out of the view and let the caller apply it
-- after its own WHERE. The screen looks right, because 34 recent credits for
-- one depot is a plausible number and nothing marks the rows that are missing.
CREATE TABLE fulfilment.credit_notes (
    credit_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code   varchar(8) NOT NULL,
    raised_on    date NOT NULL,
    amount_cents integer NOT NULL
);

INSERT INTO fulfilment.credit_notes (depot_code, raised_on, amount_cents)
SELECT 'DEP-' || chr(65 + (g % 6)),
       DATE '2025-10-01' + (g / 4),
       500 + (g * 37) % 24000
FROM generate_series(1, 1200) AS g;

CREATE VIEW analytics.v_recent_credits AS
SELECT c.credit_id, c.depot_code, c.raised_on, c.amount_cents
FROM fulfilment.credit_notes c
ORDER BY c.raised_on DESC, c.credit_id DESC
LIMIT 200;

-- DEFECT regexp-split-on-an-unescaped-metacharacter-returns-empty-fields
--
-- The customs broker sends a pipe separated tariff file. The loader splits
-- each line into fields and writes them out one field per row.
--
-- The split is a regular expression split, and the pattern is a bare full
-- stop. In a regular expression a full stop matches any character, so every
-- character in the line is treated as a separator and every field between two
-- separators is the empty string. The loader does not fail: it writes a great
-- many rows, all of them blank.
--
-- Measured: 600 feed lines produce 11,331 field rows, of which 0 are non-empty.
-- The commodity codes the broker sent are nowhere in the database.
--
-- The delimiter wanted escaping, or split_part, or string_to_array, which
-- takes a literal delimiter rather than a pattern. The row count coming out of
-- the loader is larger than the row count going in, which reads as a loader
-- that is working hard rather than one that has lost every value it was given.
CREATE TABLE ops.tariff_feed_lines (
    line_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    line_text varchar(60) NOT NULL
);

INSERT INTO ops.tariff_feed_lines (line_text)
SELECT 'HS' || (8400000 + g)::text || '|GBP|' || (100 + (g * 13) % 9000)::text
FROM generate_series(1, 600) AS g;

CREATE TABLE ops.tariff_feed_fields (
    line_id     integer NOT NULL REFERENCES ops.tariff_feed_lines (line_id),
    field_no    integer NOT NULL,
    field_value varchar(60) NOT NULL,
    PRIMARY KEY (line_id, field_no)
);

INSERT INTO ops.tariff_feed_fields (line_id, field_no, field_value)
SELECT l.line_id, f.ordinality, f.field_value
FROM ops.tariff_feed_lines l
CROSS JOIN LATERAL unnest(regexp_split_to_array(l.line_text, '.'))
     WITH ORDINALITY AS f(field_value, ordinality);

-- DEFECT deferred-constraint-trigger-fires-after-the-report-row-is-written
--
-- A payout run is inserted gross, and a constraint trigger works out the net
-- amount after the processor's fee. It was made DEFERRABLE INITIALLY DEFERRED
-- so that a run could be corrected within the same transaction before the net
-- was fixed.
--
-- A second trigger writes the finance report row. That one is an ordinary
-- AFTER INSERT trigger, so it runs immediately, while the deferred one does
-- not run until commit. The report row is therefore written from the net
-- amount as it stands at insert time, which is the column default of zero.
-- The runs table is right by the end of the transaction and the report is not.
--
-- Measured: 400 payout runs, all with a net amount above zero, and 400 report
-- rows all reading zero. Nothing in the transaction errors.
--
-- Both triggers need the same timing, and the report one should be the later
-- of the two. Deferring a trigger moves it past every other AFTER trigger on
-- the table, which is not what "deferred until commit" sounds like it means.
CREATE TABLE payments.payout_runs (
    run_id      integer PRIMARY KEY,
    run_week    date NOT NULL,
    gross_cents integer NOT NULL,
    net_cents   integer NOT NULL DEFAULT 0
);

CREATE TABLE payments.payout_report (
    run_id    integer NOT NULL,
    run_week  date NOT NULL,
    net_cents integer NOT NULL
);

CREATE FUNCTION payments.fn_payout_net() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE payments.payout_runs
       SET net_cents = NEW.gross_cents - (NEW.gross_cents / 50)
     WHERE run_id = NEW.run_id;
    RETURN NULL;
END;
$$;

CREATE FUNCTION payments.fn_payout_report() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO payments.payout_report (run_id, run_week, net_cents)
    VALUES (NEW.run_id, NEW.run_week, NEW.net_cents);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_payout_report
    AFTER INSERT ON payments.payout_runs
    FOR EACH ROW EXECUTE FUNCTION payments.fn_payout_report();

CREATE CONSTRAINT TRIGGER trg_payout_net
    AFTER INSERT ON payments.payout_runs
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION payments.fn_payout_net();

INSERT INTO payments.payout_runs (run_id, run_week, gross_cents)
SELECT g, DATE '2026-01-05' + (7 * (g % 26)), 120000 + (g * 311) % 80000
FROM generate_series(1, 400) AS g;

-- DEFECT event-trigger-scoped-to-one-command-tag-records-nothing
--
-- The auditors asked for a record of every schema change. An event trigger
-- was added to write one, and it has been in place ever since.
--
-- Its tag filter lists the commands from the example the pattern was copied
-- from, which is about foreign data wrappers: CREATE SERVER and CREATE FOREIGN
-- TABLE. This database has never had either. Every ALTER TABLE, every CREATE
-- INDEX and every CREATE TABLE goes unrecorded, and the trigger is present and
-- enabled, so a check that the audit exists passes.
--
-- Measured: 0 rows in the change log, against 3 ALTER TABLE statements in this
-- migration alone that the log was meant to carry.
--
-- The filter wants the tags that actually occur, or no tag filter at all with
-- the filtering done in the function. An empty audit table reads as a quiet
-- quarter rather than as an audit that has never once fired.
CREATE TABLE ops.ddl_change_log (
    change_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    command_tag varchar(40) NOT NULL,
    object_identity text,
    changed_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION ops.fn_log_ddl_change() RETURNS event_trigger
LANGUAGE plpgsql AS $$
DECLARE
    r record;
BEGIN
    FOR r IN SELECT * FROM pg_event_trigger_ddl_commands() LOOP
        INSERT INTO ops.ddl_change_log (command_tag, object_identity)
        VALUES (r.command_tag, r.object_identity);
    END LOOP;
END;
$$;

-- Creating an event trigger needs a superuser, or a managed service's admin
-- role where the service allows it. Where the role cannot, the build skips this
-- one defect rather than stopping partway.
DO $$
BEGIN
    CREATE EVENT TRIGGER trg_ddl_change_log
        ON ddl_command_end
        WHEN TAG IN ('CREATE SERVER', 'CREATE FOREIGN TABLE')
        EXECUTE FUNCTION ops.fn_log_ddl_change();
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE 'no privilege to create an event trigger; trg_ddl_change_log is skipped';
END $$;

ALTER TABLE ops.tariff_feed_lines ADD COLUMN received_on date;
ALTER TABLE ops.tariff_feed_lines ALTER COLUMN received_on SET DEFAULT CURRENT_DATE;
ALTER TABLE fulfilment.credit_notes ADD COLUMN reason_code varchar(12);

-- DEFECT exclude-constraint-with-inclusive-bounds-rejects-back-to-back-bookings
--
-- Loading bay bookings must not overlap, which is an exclusion constraint over
-- the bay and the booked period.
--
-- The period is built with inclusive bounds on both ends, so a booking that
-- ends at ten and a booking that starts at ten share the instant of ten
-- o'clock and count as overlapping. The yard books bays back to back all day.
-- The nightly load runs with ON CONFLICT DO NOTHING, so the rejected bookings
-- are not reported anywhere; they are simply not in the diary the next
-- morning.
--
-- Measured: 900 staged bookings, 450 loaded, 450 dropped. Every dropped
-- booking is one that starts at the exact minute another ends.
--
-- The range wants half-open bounds, which is what tstzrange gives by default
-- and what every other period in this schema uses. The yard telephones the
-- office about the bookings that vanished, and the office re-enters them,
-- which works because by then the neighbouring booking has been moved.
CREATE TABLE ops.bay_reservation_staging (
    staging_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bay_id     integer NOT NULL,
    starts_at  timestamptz NOT NULL,
    ends_at    timestamptz NOT NULL,
    haulier    varchar(40) NOT NULL
);

INSERT INTO ops.bay_reservation_staging (bay_id, starts_at, ends_at, haulier)
SELECT 1 + (g % 6),
       TIMESTAMPTZ '2026-07-06 06:00:00+01' + ((g / 6) * INTERVAL '1 hour'),
       TIMESTAMPTZ '2026-07-06 07:00:00+01' + ((g / 6) * INTERVAL '1 hour'),
       'HAULIER-' || lpad((1 + (g % 40))::text, 3, '0')
FROM generate_series(0, 899) AS g;

CREATE TABLE ops.bay_reservations (
    reservation_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bay_id         integer NOT NULL,
    starts_at      timestamptz NOT NULL,
    ends_at        timestamptz NOT NULL,
    haulier        varchar(40) NOT NULL,
    EXCLUDE USING gist (
        bay_id WITH =,
        tstzrange(starts_at, ends_at, '[]') WITH &&
    )
);

INSERT INTO ops.bay_reservations (bay_id, starts_at, ends_at, haulier)
SELECT s.bay_id, s.starts_at, s.ends_at, s.haulier
FROM ops.bay_reservation_staging s
ORDER BY s.staging_id
ON CONFLICT DO NOTHING;

-- DEFECT partitioned-parent-never-analysed-has-no-statistics-of-its-own
--
-- Usage samples are partitioned by quarter, and the maintenance job analyses
-- each partition after it is loaded.
--
-- Analysing the partitions does not give the partitioned table any statistics
-- of its own, and autovacuum never analyses a partitioned parent either. Any
-- plan for a query written against the parent, which is every query the
-- capacity report runs, is made from the planner's defaults rather than from
-- the data. The row estimate for the parent is not a stale number, it is no
-- number at all.
--
-- Measured: 4 partitions carry column statistics and the parent carries none,
-- and the parent's estimated row count is -1 against 4,000 rows present.
--
-- ANALYZE on the parent is the fix, and it has to be asked for by name; the
-- job's loop over the partitions will never do it. The report is correct, it
-- is only planned badly, so this shows up as a report that got slow rather
-- than as a report that is wrong.
CREATE TABLE analytics.usage_samples (
    sample_id   integer NOT NULL,
    sampled_on  date NOT NULL,
    account_ref varchar(20) NOT NULL,
    calls       integer NOT NULL
) PARTITION BY RANGE (sampled_on);

CREATE TABLE analytics.usage_samples_2026q1 PARTITION OF analytics.usage_samples
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');
CREATE TABLE analytics.usage_samples_2026q2 PARTITION OF analytics.usage_samples
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');
CREATE TABLE analytics.usage_samples_2026q3 PARTITION OF analytics.usage_samples
    FOR VALUES FROM ('2026-07-01') TO ('2026-10-01');
CREATE TABLE analytics.usage_samples_2026q4 PARTITION OF analytics.usage_samples
    FOR VALUES FROM ('2026-10-01') TO ('2027-01-01');

INSERT INTO analytics.usage_samples (sample_id, sampled_on, account_ref, calls)
SELECT g,
       DATE '2026-01-01' + (g % 364),
       'ACC-' || lpad((1 + (g % 120))::text, 4, '0'),
       10 + (g * 7) % 900
FROM generate_series(1, 4000) AS g;

ANALYZE analytics.usage_samples_2026q1;
ANALYZE analytics.usage_samples_2026q2;
ANALYZE analytics.usage_samples_2026q3;
ANALYZE analytics.usage_samples_2026q4;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE fulfilment.credit_notes ADD COLUMN return_id integer;

WITH p AS (
    SELECT return_id AS v, row_number() OVER (ORDER BY return_id) - 1 AS k
      FROM fulfilment.returns
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.returns)
                 * power((abs(hashtext('fulfilment.credit_notes:' || concat_ws('|', x.depot_code, x.amount_cents))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.credit_notes x
)
UPDATE fulfilment.credit_notes t
   SET return_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.credit_notes ALTER COLUMN return_id SET NOT NULL;
ALTER TABLE fulfilment.credit_notes ADD CONSTRAINT credit_notes_return_id_fkey FOREIGN KEY (return_id) REFERENCES fulfilment.returns (return_id);
CREATE INDEX ix_credit_notes_return_id ON fulfilment.credit_notes (return_id);

ALTER TABLE payments.payout_runs ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.payout_runs:' || concat_ws('|', x.run_id, x.gross_cents, x.net_cents))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.payout_runs x
)
UPDATE payments.payout_runs t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.payout_runs ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.payout_runs ADD CONSTRAINT payout_runs_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_payout_runs_transaction_id ON payments.payout_runs (transaction_id);
-- <<< relationships
