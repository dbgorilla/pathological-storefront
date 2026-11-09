-- Cross River Trading Co. -- manifest prints, late scans, levy charges, site
-- passes, case archive, care attributes
-- author: T. Marchetti
-- postgres: 18
--
-- What the loading bay printed, what the late scan report counts, what the
-- levy costs, who holds a site pass, which cases were archived, and what the
-- care label says.

-- DEFECT the-printed-time-is-a-twelve-hour-clock-with-nothing-to-say-which-half
--
-- The manifest is printed with a twelve hour mask and no meridiem, so every
-- load after one o'clock prints an hour that is not the hour it happened.
--
-- HH in a date mask is the twelve hour clock. HH24 is the twenty four hour
-- one, and the difference is two characters nobody reads twice. The mask was
-- copied from a customer facing template, where it sat next to AM, and the AM
-- was dropped here because the paper is narrow. Every morning load prints
-- correctly, which is when the person who checks the manifests is on shift.
-- The afternoon loads print as the morning of the same day, so the printed
-- sheet says a lorry left at three in the morning, and the timestamp on the
-- row, which is right, is not on the paper. The dispute that matters is
-- always about the paper.
--
-- Measured: 6,000 manifest lines of which 3,000 were loaded after midday and
-- 2,250 print an hour that does not match the hour they were loaded, midday
-- itself printing the same either way.
--
-- HH24 in the mask fixes every print from here, and the stored timestamp is
-- right, so the affected sheets can be reprinted exactly as they should have
-- been. Every load time is recorded correctly, to the second, in the right
-- time zone.
CREATE TABLE fulfilment.manifest_prints (
    print_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    manifest_ref varchar(16) NOT NULL,
    loaded_at    timestamptz NOT NULL,
    printed_time varchar(8) NOT NULL
);

INSERT INTO fulfilment.manifest_prints (manifest_ref, loaded_at, printed_time)
SELECT 'MAN-' || lpad(g::text, 10, '0'),
       (DATE '2026-05-01' + (g % 120))::timestamptz
           + ((8 + (g % 8)) * INTERVAL '1 hour')
           + ((g % 60) * INTERVAL '1 minute'),
       to_char((DATE '2026-05-01' + (g % 120))::timestamptz
           + ((8 + (g % 8)) * INTERVAL '1 hour')
           + ((g % 60) * INTERVAL '1 minute'), 'HH:MI')
FROM generate_series(1, 6000) AS g;

-- DEFECT the-grant-covered-the-tables-that-existed-on-the-day-it-was-run
--
-- The reporting role was granted select on all tables in the schema, which
-- grants it on the tables that existed at that moment and on nothing created
-- afterwards, so the two tables added since are unreadable to it.
--
-- ON ALL TABLES IN SCHEMA is not a standing rule. It expands to one grant per
-- table at the time it runs, and the standing version is ALTER DEFAULT
-- PRIVILEGES, which is a different statement that has to be run before the
-- tables are created. The grant was run once during the reporting rollout and
-- written down as the way access is given, so every schema change since has
-- shipped without it. Nothing has broken yet, and that is the trap: this
-- database also hands PUBLIC a select on every table it creates, so the
-- reports read the new tables through a grant nobody meant them to use. The
-- day that public grant is withdrawn, which is on every remediation list ever
-- written against this estate, the reporting role loses two tables it was
-- never actually given and the overnight reports fail with permission denied.
--
-- Measured: 4,800 rows across 2 tables whose access lists carry no grant to
-- the reporting role, in a schema where 19 older tables carry one.
--
-- ALTER DEFAULT PRIVILEGES for the role that creates the tables makes it
-- standing, and a repeat of the grant catches the two that are already here.
-- The role is correct, its schema usage is right, and every table it was
-- granted still reads.
CREATE ROLE manifest_reader NOLOGIN;
GRANT USAGE ON SCHEMA analytics TO manifest_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA analytics TO manifest_reader;

CREATE TABLE analytics.late_scan_counts (
    count_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code  varchar(12) NOT NULL,
    counted_on  date NOT NULL,
    late_scans  integer NOT NULL
);

CREATE TABLE analytics.late_scan_reasons (
    reason_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code  varchar(12) NOT NULL,
    reason_code varchar(10) NOT NULL,
    raised_on   date NOT NULL
);

INSERT INTO analytics.late_scan_counts (depot_code, counted_on, late_scans)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-06-01' + (g % 90),
       g % 45
FROM generate_series(1, 3000) AS g;

INSERT INTO analytics.late_scan_reasons (depot_code, reason_code, raised_on)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       CASE WHEN g % 4 = 0 THEN 'TRAFFIC' WHEN g % 4 = 1 THEN 'HANDHELD'
            WHEN g % 4 = 2 THEN 'STAFFING' ELSE 'WEATHER' END,
       DATE '2026-06-01' + (g % 90)
FROM generate_series(1, 1800) AS g;

-- DEFECT the-amount-column-was-declared-with-a-negative-scale
--
-- The levy amount is declared with a negative scale, so every value is rounded
-- to the nearest thousand pence on the way in and the pence are gone.
--
-- A negative scale is legal and it means the opposite of what a scale usually
-- means: numeric(9,-3) keeps nine digits and stores the value to the nearest
-- thousand. It was written during a modelling exercise about the size of the
-- levy, where the figures were quoted in thousands, and it was copied into the
-- table definition as though it described the units rather than the rounding.
-- The rounding happens on insert, silently, exactly as a declared scale is
-- supposed to. The source text is still on the row because the feed is kept
-- verbatim, which is the only reason the difference can be shown. The levy is
-- reconciled against the authority's statement, and it is out by up to five
-- pounds per line in both directions, which nets to something small enough to
-- be written off each month.
--
-- Measured: 3,000 levy charges of which 2,997 differ from the amount the feed
-- supplied, by up to 500 pence either way, the other 3 being the amounts that
-- happened to land on a round thousand.
--
-- Declaring the column numeric(12,0) keeps every pence and the reports can
-- divide by a thousand where they want thousands. Every charge is against the
-- right account, on the right date, and the text the authority sent is stored
-- untouched.
CREATE TABLE payments.levy_charges (
    charge_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref   varchar(12) NOT NULL,
    charged_on    date NOT NULL,
    amount_text   varchar(12) NOT NULL,
    amount_p      numeric(9,-3) NOT NULL
);

INSERT INTO payments.levy_charges (account_ref, charged_on, amount_text, amount_p)
SELECT 'ACC-' || lpad((1 + (g % 700))::text, 6, '0'),
       DATE '2026-04-01' + (g % 160),
       (100000 + (g * 7))::text,
       (100000 + (g * 7))::numeric
FROM generate_series(1, 3000) AS g;

-- DEFECT the-reload-restarted-the-identity-and-reissued-every-pass-number
--
-- The site pass table was emptied with TRUNCATE ... RESTART IDENTITY and
-- reloaded, so the pass numbers were handed out again from one and every scan
-- recorded before the reload now names somebody else's pass.
--
-- TRUNCATE does not reset a sequence unless it is asked to, and asking is one
-- clause. It was added so the reloaded table would read from one again, which
-- looked tidy in a table nobody joins to, except that the scan log joins to
-- it. The scans keep the pass code they read at the time, because the reader
-- writes what it scanned, and that is the only reason this is provable. The
-- reload also changed the order, because the source file is sorted by holder
-- now and was sorted by depot then, so the numbers did not land where they
-- were. Every scan still resolves to a pass, which is what makes it
-- dangerous: the gate report names a real person for every scan and names the
-- wrong one.
--
-- Measured: 3,600 pass scans, every one of which names a pass whose code is
-- not the code the reader recorded at the gate, across 1,200 passes.
--
-- Rekeying the scans from the code they recorded puts every scan back on the
-- right pass, and the reload wants to leave the sequence alone. Every pass is
-- valid, every holder is right, and every scan happened where and when it says.
CREATE TABLE ops.site_passes (
    pass_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pass_code varchar(12) NOT NULL,
    holder    varchar(40) NOT NULL
);

CREATE TABLE ops.pass_scans (
    scan_id           integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pass_id           integer NOT NULL,
    pass_code_at_scan varchar(12) NOT NULL,
    scanned_at        timestamptz NOT NULL
);

INSERT INTO ops.site_passes (pass_code, holder)
SELECT 'PASS-' || lpad(g::text, 6, '0'), 'Holder ' || g
FROM generate_series(1, 1200) AS g;

INSERT INTO ops.pass_scans (pass_id, pass_code_at_scan, scanned_at)
SELECT p.pass_id, p.pass_code,
       TIMESTAMPTZ '2026-08-03 06:00:00+01' + (p.pass_id * INTERVAL '1 minute')
           + (s * INTERVAL '4 hours')
FROM ops.site_passes p, generate_series(1, 3) AS s;

-- The reload, sorted by holder rather than by depot, from a sequence that was
-- sent back to one.
TRUNCATE ops.site_passes RESTART IDENTITY;

INSERT INTO ops.site_passes (pass_code, holder)
SELECT 'PASS-' || lpad((1201 - g)::text, 6, '0'), 'Holder ' || (1201 - g)
FROM generate_series(1, 1200) AS g;

-- DEFECT the-delete-rule-reports-a-delete-that-never-reaches-the-table
--
-- The case archive carries a rule that turns every delete into an update, so
-- the nightly purge reports three thousand rows deleted and the table still
-- holds them.
--
-- A DO INSTEAD rule replaces the statement it fires on. The delete never
-- happens, the update that replaces it does, and the command tag the client
-- receives is the tag of the rewritten statement, which reports the same row
-- count. The rule was written to make a delete safe while an export was being
-- proved, and the export was signed off eighteen months ago. A rule is
-- invisible from the table: nothing in the column list or the constraints
-- hints at it, and the only places it shows are the catalogue and a schema
-- dump nobody reads to the end. The purge is measured by what it reports, so
-- it has reported success every night since, while the archive has grown
-- without bound and the retention statement the business signed is not true.
--
-- Measured: 9,000 archived cases of which 3,000 were deleted by the purge,
-- are flagged accordingly, and are still in the table.
--
-- Dropping the rule and letting the delete through is one statement, after
-- which the flagged rows can go in one pass. Every case is archived correctly,
-- the flag records exactly which rows the purge asked for, and nothing has
-- been lost.
CREATE TABLE support.case_archive (
    archive_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref    varchar(14) NOT NULL,
    archived_on date NOT NULL,
    is_deleted  boolean NOT NULL DEFAULT false
);

INSERT INTO support.case_archive (case_ref, archived_on)
SELECT 'CASE-' || lpad(g::text, 9, '0'),
       DATE '2026-01-05' + (g % 300)
FROM generate_series(1, 9000) AS g;

CREATE RULE case_archive_soft_delete AS
    ON DELETE TO support.case_archive
    DO INSTEAD UPDATE support.case_archive
       SET is_deleted = true
       WHERE archive_id = OLD.archive_id;

-- The nightly purge, which reports every row it asked for.
DELETE FROM support.case_archive WHERE archived_on < DATE '2026-04-15';

-- DEFECT the-backfill-set-a-null-value-and-jsonb-set-returned-null-for-the-whole-document
--
-- The care label backfill wrote each product's care note into the attributes
-- document with jsonb_set, and jsonb_set returns null when any argument is
-- null, so the twelve hundred products with no care note lost every attribute
-- they had.
--
-- jsonb_set is strict. Given a null value it does not leave the document
-- alone, and it does not write a JSON null: it returns SQL NULL, and the
-- update writes that over the whole column. The backfill was written against
-- a sample where every product had a care note, because the sample came from
-- the category that prompted the work. The column is nullable, as it has
-- always been, so nothing raised. The product page treats a null document as a
-- product with no attributes and renders the rest of the page normally, which
-- is why this was not noticed for a season: the pages look sparse rather than
-- broken.
--
-- Measured: 6,000 care attribute rows of which 1,200 hold no document at all,
-- every one of them a product whose care note was missing.
--
-- Wrapping the value in coalesce, or filtering the update to rows that have a
-- note, stops it happening again, and the lost attributes are recoverable from
-- the catalogue feed. The 4,800 documents the backfill did write are correct
-- and carry every attribute they had before.
CREATE TABLE catalog.care_attributes (
    attr_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku        varchar(16) NOT NULL,
    care_note  varchar(40),
    attributes jsonb
);

INSERT INTO catalog.care_attributes (sku, care_note, attributes)
SELECT 'SKU-' || lpad(g::text, 8, '0'),
       CASE WHEN g % 5 = 0 THEN NULL ELSE 'Wash at ' || (30 + (g % 3) * 10) END,
       jsonb_build_object('colour', 'shade ' || (1 + (g % 12)),
                          'size', 'S' || (1 + (g % 6)))
FROM generate_series(1, 6000) AS g;

-- The backfill.
UPDATE catalog.care_attributes
   SET attributes = jsonb_set(attributes, '{care}', to_jsonb(care_note));

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.care_attributes ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.care_attributes:' || concat_ws('|', x.sku, x.care_note, x.attributes))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.care_attributes x
)
UPDATE catalog.care_attributes t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.care_attributes ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.care_attributes ADD CONSTRAINT care_attributes_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_care_attributes_product_id ON catalog.care_attributes (product_id);

ALTER TABLE fulfilment.carrier_manifest_lines ADD COLUMN print_id integer;

WITH p AS (
    SELECT print_id AS v, row_number() OVER (ORDER BY print_id) - 1 AS k
      FROM fulfilment.manifest_prints
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.manifest_prints)
                 * power((abs(hashtext('fulfilment.carrier_manifest_lines:' || concat_ws('|', x.order_ref, x.weight_kg))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.carrier_manifest_lines x
)
UPDATE fulfilment.carrier_manifest_lines t
   SET print_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.carrier_manifest_lines ALTER COLUMN print_id SET NOT NULL;
ALTER TABLE fulfilment.carrier_manifest_lines ADD CONSTRAINT carrier_manifest_lines_print_id_fkey FOREIGN KEY (print_id) REFERENCES fulfilment.manifest_prints (print_id);
CREATE INDEX ix_carrier_manifest_lines_print_id ON fulfilment.carrier_manifest_lines (print_id);

ALTER TABLE fulfilment.manifest_prints ADD COLUMN carrier_id integer;

WITH p AS (
    SELECT carrier_id AS v, row_number() OVER (ORDER BY carrier_id) - 1 AS k
      FROM fulfilment.carriers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.carriers)
                 * power((abs(hashtext('fulfilment.manifest_prints:' || concat_ws('|', x.manifest_ref, x.printed_time))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.manifest_prints x
)
UPDATE fulfilment.manifest_prints t
   SET carrier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.manifest_prints ALTER COLUMN carrier_id SET NOT NULL;
ALTER TABLE fulfilment.manifest_prints ADD CONSTRAINT manifest_prints_carrier_id_fkey FOREIGN KEY (carrier_id) REFERENCES fulfilment.carriers (carrier_id);
CREATE INDEX ix_manifest_prints_carrier_id ON fulfilment.manifest_prints (carrier_id);

ALTER TABLE ops.pass_voids ADD COLUMN pass_id integer;

WITH p AS (
    SELECT pass_id AS v, row_number() OVER (ORDER BY pass_id) - 1 AS k
      FROM ops.site_passes
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.site_passes)
                 * power((abs(hashtext('ops.pass_voids:' || concat_ws('|', x.pass_ref, x.reason, x.voided_by))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.pass_voids x
)
UPDATE ops.pass_voids t
   SET pass_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.pass_voids ALTER COLUMN pass_id SET NOT NULL;
ALTER TABLE ops.pass_voids ADD CONSTRAINT pass_voids_pass_id_fkey FOREIGN KEY (pass_id) REFERENCES ops.site_passes (pass_id);
CREATE INDEX ix_pass_voids_pass_id ON ops.pass_voids (pass_id);

ALTER TABLE ops.site_passes ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.site_passes:' || concat_ws('|', x.pass_code, x.holder))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.site_passes x
)
UPDATE ops.site_passes t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.site_passes ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.site_passes ADD CONSTRAINT site_passes_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_site_passes_store_id ON ops.site_passes (store_id);

ALTER TABLE payments.levy_charges ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.levy_charges:' || concat_ws('|', x.account_ref, x.amount_text, x.amount_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.levy_charges x
)
UPDATE payments.levy_charges t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.levy_charges ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.levy_charges ADD CONSTRAINT levy_charges_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_levy_charges_transaction_id ON payments.levy_charges (transaction_id);

ALTER TABLE support.case_archive ADD COLUMN case_id integer;

WITH p AS (
    SELECT case_id AS v, row_number() OVER (ORDER BY case_id) - 1 AS k
      FROM support.case_records
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.case_records)
                 * power((abs(hashtext('support.case_archive:' || concat_ws('|', x.case_ref, x.is_deleted))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.case_archive x
)
UPDATE support.case_archive t
   SET case_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.case_archive ALTER COLUMN case_id SET NOT NULL;
ALTER TABLE support.case_archive ADD CONSTRAINT case_archive_case_id_fkey FOREIGN KEY (case_id) REFERENCES support.case_records (case_id);
CREATE INDEX ix_case_archive_case_id ON support.case_archive (case_id);
-- <<< relationships
