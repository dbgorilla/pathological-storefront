-- Cross River Trading Co. -- trading week report, case note access, rate card
-- archive, manufacturer index, depot code import, till event rollup
-- author: P. Adeyemi
-- postgres: 18
--
-- The weekly counter sales figure the board sees, the case notes the regional
-- clerks write, the rate card history the buying desk keeps, the A to Z index
-- on the trade site, the depot list the third party sends, and the till
-- rollup that feeds the daily cash position.

-- DEFECT date-trunc-week-starts-monday-but-the-trading-week-starts-sunday
--
-- Counter sales are reported by trading week. The trading week at Cross River
-- runs Sunday to Saturday and always has, because the tills are cashed up on
-- Saturday night.
--
-- The report buckets by date_trunc on week, which is an ISO week and starts on
-- Monday. Every Sunday's takings are therefore reported against the week that
-- has just finished rather than the week that has just started. The weekly
-- totals are all plausible and the annual total is right, so nothing looks
-- wrong until a Sunday promotion is judged against the wrong week.
--
-- Measured: 53 week buckets in the report and all 53 start on a Monday. 1,500
-- counter sales, of which 214 fall on a Sunday and are reported a week early.
--
-- The bucket wants working out from the day of week directly, since PostgreSQL
-- has no Sunday-start week truncation. A report that is wrong by one day at the
-- boundary survives review because reviewers check totals, not boundaries.
CREATE TABLE payments.counter_sales (
    sale_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sold_on      date NOT NULL,
    till_no      integer NOT NULL,
    amount_cents integer NOT NULL
);

INSERT INTO payments.counter_sales (sold_on, till_no, amount_cents)
SELECT DATE '2026-01-04' + (g % 364),
       1 + (g % 5),
       350 + (g * 91) % 18000
FROM generate_series(1, 1500) AS g;

CREATE VIEW analytics.v_trading_week_sales AS
SELECT date_trunc('week', s.sold_on)::date AS week_start,
       count(*) AS sale_count,
       sum(s.amount_cents) AS sales_cents
FROM payments.counter_sales s
GROUP BY date_trunc('week', s.sold_on)::date;

-- DEFECT insert-policy-with-check-true-defeats-the-team-policy
--
-- Case notes are restricted by team. The policy on the table is FOR ALL, and
-- it reads and writes only the northern team's notes.
--
-- A second policy was added for INSERT when a bulk import needed to run, and
-- its check is simply true. Permissive policies are combined with OR, so the
-- second policy is enough on its own: the clerk can insert a note against any
-- team at all. The restriction on reading still holds, so a note written
-- against the wrong team disappears from the clerk's own screen the moment it
-- is saved, which reads as the save having failed.
--
-- Measured: 600 case notes written by the clerk role, of which 180 carry a
-- team the clerk cannot read back.
--
-- The import policy wants restricting to the import role, or expressing as a
-- RESTRICTIVE policy, which is combined with AND. The clerks re-type the notes
-- that vanished, which is where the duplicates in the northern team come from.
CREATE ROLE case_clerk NOLOGIN;

CREATE TABLE support.case_notes (
    note_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    team      varchar(10) NOT NULL,
    case_ref  varchar(16) NOT NULL,
    body      text NOT NULL,
    written_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE support.case_notes ENABLE ROW LEVEL SECURITY;

CREATE POLICY case_notes_team ON support.case_notes
    FOR ALL TO case_clerk
    USING (team = 'north') WITH CHECK (team = 'north');

CREATE POLICY case_notes_import ON support.case_notes
    FOR INSERT TO case_clerk
    WITH CHECK (true);

GRANT USAGE ON SCHEMA support TO case_clerk;
GRANT SELECT, INSERT, UPDATE ON support.case_notes TO case_clerk;

SET ROLE case_clerk;
INSERT INTO support.case_notes (team, case_ref, body)
SELECT (ARRAY['north','north','north','north','south','midlands','south','north','north','north'])[1 + (g % 10)],
       'CASE-' || lpad(g::text, 6, '0'),
       'Follow up call logged by the counter team.'
FROM generate_series(1, 600) AS g;
RESET ROLE;

-- DEFECT truncate-cascade-reaches-a-table-that-is-not-staging
--
-- The rate card loader clears its staging table at the start of every run. The
-- archive table keeps every rate card version the buying desk has ever loaded,
-- and carries a foreign key back to the staging row it came from, which is how
-- the loader ties a version to its source file.
--
-- TRUNCATE cannot run against a table another table references, so the loader
-- was changed to TRUNCATE ... CASCADE and the error went away. CASCADE on
-- TRUNCATE does not mean "delete the referencing rows that match", it means
-- "truncate the referencing tables too". Every run empties the archive.
--
-- Measured: 2,400 archive rows loaded historically, 0 left after the nightly
-- run, and 300 written by the run that followed it. The archive holds one
-- night of history and reads as though the desk only started using it
-- yesterday.
--
-- The foreign key does not belong on an archive table, and a DELETE with a
-- WHERE is what the loader wanted in the first place. The archive is never
-- read except at audit, which is once a year.
CREATE TABLE supply.rate_card_staging (
    staging_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    source_file varchar(60) NOT NULL,
    supplier_ref varchar(20) NOT NULL,
    rate_cents integer NOT NULL
);

CREATE TABLE supply.rate_card_archive (
    archive_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    staging_id  integer NOT NULL REFERENCES supply.rate_card_staging (staging_id),
    supplier_ref varchar(20) NOT NULL,
    rate_cents  integer NOT NULL,
    archived_on date NOT NULL
);

INSERT INTO supply.rate_card_staging (source_file, supplier_ref, rate_cents)
SELECT 'rates-2026-06-' || lpad((1 + (g % 28))::text, 2, '0') || '.csv',
       'SUP-' || lpad((1 + (g % 120))::text, 4, '0'),
       1200 + (g * 17) % 9000
FROM generate_series(1, 800) AS g;

INSERT INTO supply.rate_card_archive (staging_id, supplier_ref, rate_cents, archived_on)
SELECT s.staging_id, s.supplier_ref, s.rate_cents + v.bump, DATE '2026-06-01' + v.bump
FROM supply.rate_card_staging s
CROSS JOIN (VALUES (0), (1), (2)) AS v(bump);

CREATE FUNCTION supply.fn_load_rate_cards() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE supply.rate_card_staging CASCADE;
END;
$$;

SELECT supply.fn_load_rate_cards();

INSERT INTO supply.rate_card_staging (source_file, supplier_ref, rate_cents)
SELECT 'rates-2026-07-01.csv',
       'SUP-' || lpad((1 + (g % 120))::text, 4, '0'),
       1300 + (g * 19) % 9000
FROM generate_series(1, 300) AS g;

INSERT INTO supply.rate_card_archive (staging_id, supplier_ref, rate_cents, archived_on)
SELECT s.staging_id, s.supplier_ref, s.rate_cents, DATE '2026-07-01'
FROM supply.rate_card_staging s;

-- DEFECT explicit-collate-c-reorders-punctuated-names-away-from-the-index-order
--
-- The A to Z manufacturer index on the trade site is ordered with an explicit
-- COLLATE "C", which was added to make the ordering stable between the
-- developer's machine and the server.
--
-- The C collation sorts by byte value, so every capital letter sorts before
-- every lowercase one. A manufacturer whose name begins lowercase, and there
-- are plenty in this trade, lands after the whole alphabet rather than under
-- its own letter. The index on the column carries the database collation, so
-- the ordering cannot use it either and the page sorts from scratch.
--
-- Measured: 400 manufacturers, 23 of them with a lowercase first letter, and
-- all 23 sit at the end of the index, positions 378 to 400. The first of them
-- is a de la Roche, which belongs in the D section and is below Yarrow.
--
-- The stability wanted was a tie-break on the primary key, not a different
-- collation. Nobody reports a missing manufacturer from an A to Z page; they
-- report that the supplier is not listed, and support tells them to search.
CREATE TABLE catalog.manufacturer_names (
    manufacturer_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name            varchar(60) NOT NULL,
    country_code    char(2) NOT NULL
);

INSERT INTO catalog.manufacturer_names (name, country_code)
SELECT CASE WHEN g % 17 = 0
            THEN (ARRAY['de la Roche Cycles','van Dyke Fixings','ten Broek Tools',
                        'du Pré Castings','van Houten Belting'])[1 + (g % 5)]
                 || ' ' || g::text
            ELSE (ARRAY['Ashgrove','Bracken','Calder','Dunmore','Eastgate','Fenwick',
                        'Garrick','Halstead','Ingleby','Jarrow','Kelsall','Langton',
                        'Marchmont','Netherby','Ormskirk','Pendle','Quarrington',
                        'Ravenscar','Standish','Thurlow','Ullswater','Verity',
                        'Wharton','Yarrow'])[1 + (g % 24)]
                 || ' ' || (ARRAY['Engineering','Supplies','Works','Castings'])[1 + (g % 4)]
                 || ' ' || g::text
       END,
       (ARRAY['GB','NL','BE','FR'])[1 + (g % 4)]
FROM generate_series(1, 400) AS g;

CREATE INDEX ix_manufacturer_names_name ON catalog.manufacturer_names (name);

CREATE VIEW analytics.v_manufacturer_index AS
SELECT m.manufacturer_id,
       m.name,
       row_number() OVER (ORDER BY m.name COLLATE "C") AS list_position
FROM catalog.manufacturer_names m;

-- DEFECT carriage-return-left-on-imported-codes-defeats-the-join
--
-- The haulier sends a depot list every morning. The file is written on
-- Windows, the import splits it on the newline, and the carriage return before
-- each newline stays on the end of every value but the last one.
--
-- A depot code with a carriage return on the end is not equal to the same
-- depot code without one, so the join to the depot register matches nothing
-- for those rows. The import does not fail and the codes look right in every
-- screen that shows them, because a carriage return is invisible.
--
-- Measured: 500 imported rows against 40 registered depots. 20 rows match, the
-- 480 with a trailing carriage return match none. The register is correct and
-- the import is correct; only the comparison between them is not.
--
-- The import wants trimming, and the check wants writing against the byte
-- length rather than against what the value looks like. The one row per file
-- that does match is the last line, which is why the import has always been
-- thought to be working.
CREATE TABLE ops.depot_register (
    depot_code varchar(12) PRIMARY KEY,
    depot_name varchar(40) NOT NULL
);

INSERT INTO ops.depot_register (depot_code, depot_name)
SELECT 'DEP-' || lpad(g::text, 3, '0'),
       'Depot ' || g::text
FROM generate_series(1, 40) AS g;

CREATE TABLE ops.depot_code_import (
    import_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raw_code   varchar(14) NOT NULL,
    pallets    integer NOT NULL,
    matched_depot varchar(12)
);

INSERT INTO ops.depot_code_import (raw_code, pallets)
SELECT CASE WHEN g % 25 = 0
            THEN 'DEP-' || lpad((1 + (g % 40))::text, 3, '0')
            ELSE 'DEP-' || lpad((1 + (g % 40))::text, 3, '0') || E'\r'
       END,
       1 + (g % 26)
FROM generate_series(1, 500) AS g;

UPDATE ops.depot_code_import i
   SET matched_depot = d.depot_code
  FROM ops.depot_register d
 WHERE d.depot_code = i.raw_code;

-- DEFECT watermark-set-from-the-clock-not-from-the-rows-read-skips-late-writes
--
-- The till rollup runs every few hours. It reads every till event newer than
-- the stored watermark, writes the rollup rows, and then stores the current
-- time as the new watermark.
--
-- The current time at the end of the run is later than the newest event the
-- run actually read, by however long the run took. Every event recorded during
-- the run itself falls between the two, and the next run starts after it. Those
-- events are never rolled up by any run, and because each run reports the
-- number of rows it wrote, every run looks healthy.
--
-- Measured: 3,000 till events over three runs, 2,916 rolled up and 84 in the
-- gaps between what a run read and where it set its watermark. The cash
-- position is short by those events and stays short.
--
-- The watermark wants setting to the newest event the run actually read, not
-- to the clock. The shortfall is a fraction of a percent, which is inside the
-- tolerance the cash position is reconciled to.
CREATE TABLE ops.till_events (
    event_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    recorded_at  timestamptz NOT NULL,
    till_no      integer NOT NULL,
    amount_cents integer NOT NULL
);

INSERT INTO ops.till_events (recorded_at, till_no, amount_cents)
SELECT TIMESTAMPTZ '2026-07-01 06:00:00+01' + (g * INTERVAL '30 seconds'),
       1 + (g % 8),
       120 + (g * 53) % 9000
FROM generate_series(1, 3000) AS g;

CREATE TABLE analytics.rollup_watermarks (
    job_name     varchar(40) PRIMARY KEY,
    watermark_at timestamptz NOT NULL
);

INSERT INTO analytics.rollup_watermarks (job_name, watermark_at)
VALUES ('till_event_rollup', TIMESTAMPTZ '2026-07-01 05:00:00+01');

CREATE TABLE analytics.till_event_rollup (
    event_id     integer PRIMARY KEY,
    till_no      integer NOT NULL,
    amount_cents integer NOT NULL,
    rolled_up_at timestamptz NOT NULL
);

-- p_read_to is the newest event the run manages to read; p_finished_at is the
-- clock when the run finishes writing, which is what it stores.
CREATE FUNCTION analytics.fn_roll_up_till_events(p_read_to timestamptz,
                                                 p_finished_at timestamptz)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_from timestamptz;
BEGIN
    SELECT watermark_at INTO v_from
      FROM analytics.rollup_watermarks
     WHERE job_name = 'till_event_rollup';

    INSERT INTO analytics.till_event_rollup (event_id, till_no, amount_cents, rolled_up_at)
    SELECT e.event_id, e.till_no, e.amount_cents, p_finished_at
    FROM ops.till_events e
    WHERE e.recorded_at > v_from
      AND e.recorded_at <= p_read_to;

    UPDATE analytics.rollup_watermarks
       SET watermark_at = p_finished_at
     WHERE job_name = 'till_event_rollup';
END;
$$;

SELECT analytics.fn_roll_up_till_events(TIMESTAMPTZ '2026-07-01 12:00:00+01',
                                        TIMESTAMPTZ '2026-07-01 12:21:00+01');
SELECT analytics.fn_roll_up_till_events(TIMESTAMPTZ '2026-07-01 18:00:00+01',
                                        TIMESTAMPTZ '2026-07-01 18:21:00+01');
SELECT analytics.fn_roll_up_till_events(TIMESTAMPTZ '2026-07-02 07:00:00+01',
                                        TIMESTAMPTZ '2026-07-02 07:21:00+01');

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.manufacturer_names ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.manufacturer_names:' || concat_ws('|', x.name, x.country_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.manufacturer_names x
)
UPDATE catalog.manufacturer_names t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.manufacturer_names ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.manufacturer_names ADD CONSTRAINT manufacturer_names_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_manufacturer_names_product_id ON catalog.manufacturer_names (product_id);

ALTER TABLE payments.counter_sales ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.counter_sales:' || concat_ws('|', x.till_no, x.amount_cents))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.counter_sales x
)
UPDATE payments.counter_sales t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.counter_sales ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.counter_sales ADD CONSTRAINT counter_sales_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_counter_sales_transaction_id ON payments.counter_sales (transaction_id);

ALTER TABLE support.case_notes ADD COLUMN case_id integer;

WITH p AS (
    SELECT case_id AS v, row_number() OVER (ORDER BY case_id) - 1 AS k
      FROM support.case_records
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.case_records)
                 * power((abs(hashtext('support.case_notes:' || concat_ws('|', x.team, x.case_ref, x.body))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.case_notes x
)
UPDATE support.case_notes t
   SET case_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.case_notes ALTER COLUMN case_id SET NOT NULL;
ALTER TABLE support.case_notes ADD CONSTRAINT case_notes_case_id_fkey FOREIGN KEY (case_id) REFERENCES support.case_records (case_id);
CREATE INDEX ix_case_notes_case_id ON support.case_notes (case_id);
-- <<< relationships
