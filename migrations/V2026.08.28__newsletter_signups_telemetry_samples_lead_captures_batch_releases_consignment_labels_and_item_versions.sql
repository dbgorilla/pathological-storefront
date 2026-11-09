-- Cross River Trading Co. -- newsletter signups, telemetry samples, lead
-- captures, batch releases, consignment labels, item versions
-- author: T. Marchetti
-- postgres: 18
--
-- Who asked for the newsletter, what the depot hardware is reporting, who
-- filled in the enquiry form, which batches were released to sell, the label
-- on a consignment, and every version an item has been through.

-- DEFECT the-email-is-unique-once-you-lower-it-and-nothing-says-so
--
-- No two signups share an email address once case is ignored. Nothing in the
-- schema says that, and the column is not unique in any form.
--
-- The signup form lowercases what it is given before it looks for an existing
-- row, so the rule holds for every row the form has written, which is all of
-- them. The rule is in one JavaScript function and one Python handler and
-- nowhere else. The unsubscribe link matches on the address exactly as typed,
-- so an address that arrives capitalised through the import route would
-- unsubscribe nothing and would also be a second signup, and both halves of
-- that would look like the system working.
--
-- Measured: 9,000 newsletter signups holding 9,000 distinct lowercased email
-- addresses, with no unique index on the column or on any expression of it.
--
-- A unique index on lower(email_address) applies cleanly today and moves the
-- rule into the database. Every row is distinct as stored, so any check for
-- duplicates that compares the column to itself finds none.
CREATE TABLE marketing.newsletter_signups (
    signup_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email_address varchar(120) NOT NULL,
    source        varchar(20) NOT NULL,
    signed_up_on  date NOT NULL
);

INSERT INTO marketing.newsletter_signups (email_address, source, signed_up_on)
SELECT 'reader' || g || '@example.invalid',
       (ARRAY['footer', 'checkout', 'event', 'import'])[1 + (g % 4)],
       DATE '2022-11-14' + (g % 1300)
FROM generate_series(1, 9000) AS g;

-- DEFECT the-replicated-table-has-no-key-so-no-update-can-be-applied
--
-- The telemetry table has no primary key and its replica identity is the
-- default, which means the primary key. There is not one, so an update or a
-- delete on this table cannot be replicated at all.
--
-- The table was built for inserts only, which is true of the hardware feed and
-- was true of the table until the correction screen arrived. Logical
-- replication carries inserts happily and raises an error on the first update,
-- which stops the whole subscription, not just this table. The downstream
-- warehouse then stops receiving every table in the publication, and the first
-- sign of it is a report that is a day stale, then two days, then a week.
--
-- Measured: 36,000 telemetry samples in a table with no primary key and a
-- replica identity of d, which resolves to a primary key that does not exist.
--
-- A primary key on the identity column is the fix and it is one statement.
-- REPLICA IDENTITY FULL is the other, and it makes every update carry the
-- whole old row. Inserts replicate perfectly today, which is all anybody has
-- tested.
CREATE TABLE ops.telemetry_samples (
    sample_ref  varchar(24) NOT NULL,
    depot_code  varchar(12) NOT NULL,
    metric_name varchar(40) NOT NULL,
    metric_value integer NOT NULL,
    sampled_at  timestamptz NOT NULL
);

INSERT INTO ops.telemetry_samples (sample_ref, depot_code, metric_name, metric_value, sampled_at)
SELECT 'TLM-' || lpad(g::text, 12, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       (ARRAY['belt_amps', 'door_cycles', 'chiller_degc',
              'forklift_hours', 'gate_opens', 'wifi_clients'])[1 + (g % 6)],
       10 + (g % 400),
       TIMESTAMPTZ '2026-08-01 00:00:00+01' + (g * INTERVAL '70 seconds')
FROM generate_series(1, 36000) AS g;

-- DEFECT the-export-trigger-fires-before-the-one-that-scores-the-lead
--
-- Two after-insert triggers. The first copies the lead to the export table.
-- The second works out its score. Every exported lead is unscored.
--
-- The export trigger was written first and named for what it does. The scoring
-- trigger was added a year later, named for what it does, and the two names
-- put them in the wrong order, because triggers at the same timing fire
-- alphabetically and nobody chose that. The scoring trigger writes the score
-- back onto the lead, so the lead table is right. The export table took its
-- copy a moment earlier and holds a null where the score should be. The agency
-- that reads the export treats a null score as cold and works the list from
-- the bottom.
--
-- Measured: 6,000 lead captures of which 2,400 carry a score, against 2,400
-- exported copies of those same leads that carry none.
--
-- Renaming the triggers fixes it, or the export moves to a deferred constraint
-- trigger that runs at the end of the statement. Both tables are populated,
-- both look healthy, and the disagreement is only visible by joining them.
CREATE TABLE marketing.lead_captures (
    lead_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lead_ref   varchar(16) NOT NULL,
    region     varchar(12) NOT NULL,
    score      integer,
    captured_at timestamptz NOT NULL
);

CREATE TABLE marketing.lead_exports (
    export_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lead_id    integer NOT NULL,
    lead_ref   varchar(16) NOT NULL,
    score      integer,
    exported_at timestamptz NOT NULL
);

CREATE FUNCTION marketing.fn_a_export_lead() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO marketing.lead_exports (lead_id, lead_ref, score, exported_at)
    VALUES (NEW.lead_id, NEW.lead_ref, NEW.score, NEW.captured_at);
    RETURN NULL;
END;
$$;

CREATE FUNCTION marketing.fn_b_score_lead() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.region = 'north' THEN
        UPDATE marketing.lead_captures
        SET score = 40 + (NEW.lead_id % 60)
        WHERE lead_id = NEW.lead_id;
    END IF;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_a_export_lead AFTER INSERT ON marketing.lead_captures
    FOR EACH ROW EXECUTE FUNCTION marketing.fn_a_export_lead();

CREATE TRIGGER trg_b_score_lead AFTER INSERT ON marketing.lead_captures
    FOR EACH ROW EXECUTE FUNCTION marketing.fn_b_score_lead();

INSERT INTO marketing.lead_captures (lead_ref, region, captured_at)
SELECT 'LED-' || lpad(g::text, 10, '0'),
       CASE WHEN g % 5 < 2 THEN 'north' ELSE 'south' END,
       TIMESTAMPTZ '2026-06-02 08:00:00+01' + (g * INTERVAL '11 minutes')
FROM generate_series(1, 6000) AS g;

-- DEFECT the-trigger-body-was-stubbed-out-during-an-incident
--
-- The batch release audit trigger is enabled and fires on every insert. Its
-- body returns without writing anything.
--
-- During an incident the audit insert was deadlocking against the release
-- itself, and the fastest way out was to replace the function body with a
-- return and get the releases flowing again. That was the right call at two in
-- the morning. The follow-up ticket to put the body back was closed as a
-- duplicate of the incident, which was closed when the releases resumed. The
-- trigger still exists, is still enabled, and still runs, which is what every
-- check looks at.
--
-- Measured: 6,000 batch releases against 1,200 audit rows, all of them written
-- before the incident, behind a trigger that is enabled and does nothing.
--
-- Putting the body back is a repeatable migration and the deadlock it caused
-- needs the lock order fixed first. Nothing about the trigger's definition,
-- timing or enabled state looks wrong.
CREATE TABLE supply.batch_releases (
    release_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_ref  varchar(16) NOT NULL,
    released_by varchar(20) NOT NULL,
    released_at timestamptz NOT NULL
);

CREATE TABLE supply.batch_release_audit (
    audit_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    release_id integer NOT NULL,
    batch_ref  varchar(16) NOT NULL,
    seen_at    timestamptz NOT NULL
);

CREATE FUNCTION supply.fn_audit_batch_release() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO supply.batch_release_audit (release_id, batch_ref, seen_at)
    VALUES (NEW.release_id, NEW.batch_ref, NEW.released_at);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_batch_release AFTER INSERT ON supply.batch_releases
    FOR EACH ROW EXECUTE FUNCTION supply.fn_audit_batch_release();

INSERT INTO supply.batch_releases (batch_ref, released_by, released_at)
SELECT 'BAT-' || lpad(g::text, 10, '0'),
       'USR-' || lpad((1 + (g % 30))::text, 4, '0'),
       TIMESTAMPTZ '2026-01-12 06:00:00+00' + (g * INTERVAL '19 minutes')
FROM generate_series(1, 1200) AS g;

-- The two in the morning fix.
CREATE OR REPLACE FUNCTION supply.fn_audit_batch_release() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RETURN NULL;
END;
$$;

INSERT INTO supply.batch_releases (batch_ref, released_by, released_at)
SELECT 'BAT-' || lpad((100000 + g)::text, 10, '0'),
       'USR-' || lpad((1 + (g % 30))::text, 4, '0'),
       TIMESTAMPTZ '2026-03-02 06:00:00+00' + (g * INTERVAL '4 minutes')
FROM generate_series(1, 4800) AS g;

-- DEFECT the-sequence-belongs-to-no-column-so-every-tool-skips-it
--
-- The label number comes from a sequence that is not owned by the column it
-- feeds. Anything that walks a table's sequences does not find it.
--
-- The sequence was created by hand, before the table, and the default on the
-- column names it by string. That is a working arrangement and the numbers
-- come out right. It also means pg_get_serial_sequence returns null for the
-- column, so the environment refresh, which resets every sequence it can find
-- by walking the tables, walks straight past this one. Refreshed environments
-- therefore carry a sequence from whenever it was last touched, against a
-- table that has just been reloaded, and the first label printed collides.
--
-- Measured: 12,000 consignment labels numbered from a sequence that
-- pg_get_serial_sequence cannot associate with the column.
--
-- ALTER SEQUENCE ... OWNED BY is one statement and changes nothing about the
-- numbering. The sequence works, the default works, and every label printed
-- so far is unique.
CREATE SEQUENCE fulfilment.label_seq START WITH 700001;

CREATE TABLE fulfilment.consignment_labels (
    label_no    integer PRIMARY KEY DEFAULT nextval('fulfilment.label_seq'),
    consignment_ref varchar(16) NOT NULL,
    printed_at  timestamptz NOT NULL
);

INSERT INTO fulfilment.consignment_labels (consignment_ref, printed_at)
SELECT 'CNS-' || lpad(g::text, 10, '0'),
       TIMESTAMPTZ '2026-05-04 05:00:00+01' + (g * INTERVAL '3 minutes')
FROM generate_series(1, 12000) AS g;

-- DEFECT every-field-edit-writes-a-whole-new-copy-of-the-item
--
-- Editing one field on an item writes a complete new row carrying every field.
-- Four hundred items have produced forty eight thousand rows.
--
-- The table was designed to be append only so that any past state could be
-- reconstructed, which it can. What it was not designed for is the merchandise
-- team's workflow, which is to open an item, change one attribute, save, and
-- repeat. Each save copies the description, the long copy, the dimensions and
-- the care instructions unchanged into a new row. The table is now the largest
-- in the schema by bytes and the current view of it is a window function over
-- every version ever written, which is the query every product page runs.
--
-- Measured: 48,000 item versions over 400 items, of which 47,600 carry a long
-- copy character for character identical to the version before it.
--
-- Storing the changed field alone, or a current table beside the history,
-- turns the product page query into a primary key lookup. Every version is a
-- true record of the item at that moment, so the table is correct and it is
-- only its shape that is wrong.
CREATE TABLE catalog.item_versions (
    version_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_ref    varchar(16) NOT NULL,
    version_no  integer NOT NULL,
    description varchar(120) NOT NULL,
    long_copy   varchar(400) NOT NULL,
    dimensions  varchar(40) NOT NULL,
    care_notes  varchar(200) NOT NULL,
    saved_at    timestamptz NOT NULL
);

INSERT INTO catalog.item_versions
    (item_ref, version_no, description, long_copy, dimensions, care_notes, saved_at)
SELECT 'ITM-' || lpad(i::text, 8, '0'),
       v,
       'Item ' || i || ' description, revision ' || v,
       'Long copy for item ' || i || ' covering materials, origin and use.',
       (10 + (i % 40)) || 'x' || (10 + (i % 30)) || 'x' || (5 + (i % 12)),
       'Care notes for item ' || i || ': wipe clean, do not soak, store dry.',
       TIMESTAMPTZ '2024-02-05 09:00:00+00' + (i * INTERVAL '3 hours')
           + (v * INTERVAL '25 minutes')
FROM generate_series(1, 400) AS i
CROSS JOIN generate_series(1, 120) AS v;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.item_versions ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.item_versions:' || concat_ws('|', x.item_ref, x.version_no, x.description, x.long_copy, x.dimensions, x.care_notes))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.item_versions x
)
UPDATE catalog.item_versions t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.item_versions ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.item_versions ADD CONSTRAINT item_versions_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_item_versions_product_id ON catalog.item_versions (product_id);

ALTER TABLE fulfilment.consignment_checks ADD COLUMN label_no integer;

WITH p AS (
    SELECT label_no AS v, row_number() OVER (ORDER BY label_no) - 1 AS k
      FROM fulfilment.consignment_labels
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.consignment_labels)
                 * power((abs(hashtext('fulfilment.consignment_checks:' || concat_ws('|', x.consignment_ref, x.is_signed, x.courier_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.consignment_checks x
)
UPDATE fulfilment.consignment_checks t
   SET label_no = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.consignment_checks ALTER COLUMN label_no SET NOT NULL;
ALTER TABLE fulfilment.consignment_checks ADD CONSTRAINT consignment_checks_label_no_fkey FOREIGN KEY (label_no) REFERENCES fulfilment.consignment_labels (label_no);
CREATE INDEX ix_consignment_checks_label_no ON fulfilment.consignment_checks (label_no);

ALTER TABLE fulfilment.consignment_labels ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('fulfilment.consignment_labels:' || concat_ws('|', x.consignment_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.consignment_labels x
)
UPDATE fulfilment.consignment_labels t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.consignment_labels ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE fulfilment.consignment_labels ADD CONSTRAINT consignment_labels_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_consignment_labels_shipment_id ON fulfilment.consignment_labels (shipment_id);

ALTER TABLE fulfilment.consignment_milestones ADD COLUMN label_no integer;

WITH p AS (
    SELECT label_no AS v, row_number() OVER (ORDER BY label_no) - 1 AS k
      FROM fulfilment.consignment_labels
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.consignment_labels)
                 * power((abs(hashtext('fulfilment.consignment_milestones:' || concat_ws('|', x.consignment_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.consignment_milestones x
)
UPDATE fulfilment.consignment_milestones t
   SET label_no = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.consignment_milestones ALTER COLUMN label_no SET NOT NULL;
ALTER TABLE fulfilment.consignment_milestones ADD CONSTRAINT consignment_milestones_label_no_fkey FOREIGN KEY (label_no) REFERENCES fulfilment.consignment_labels (label_no);
CREATE INDEX ix_consignment_milestones_label_no ON fulfilment.consignment_milestones (label_no);

ALTER TABLE fulfilment.consignment_states ADD COLUMN label_no integer;

WITH p AS (
    SELECT label_no AS v, row_number() OVER (ORDER BY label_no) - 1 AS k
      FROM fulfilment.consignment_labels
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.consignment_labels)
                 * power((abs(hashtext('fulfilment.consignment_states:' || concat_ws('|', x.consignment_ref, x.status))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.consignment_states x
)
UPDATE fulfilment.consignment_states t
   SET label_no = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.consignment_states ALTER COLUMN label_no SET NOT NULL;
ALTER TABLE fulfilment.consignment_states ADD CONSTRAINT consignment_states_label_no_fkey FOREIGN KEY (label_no) REFERENCES fulfilment.consignment_labels (label_no);
CREATE INDEX ix_consignment_states_label_no ON fulfilment.consignment_states (label_no);

ALTER TABLE marketing.lead_captures ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('marketing.lead_captures:' || concat_ws('|', x.lead_ref, x.region, x.score))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.lead_captures x
)
UPDATE marketing.lead_captures t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.lead_captures ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE marketing.lead_captures ADD CONSTRAINT lead_captures_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_lead_captures_customer_id ON marketing.lead_captures (customer_id);

ALTER TABLE marketing.newsletter_signups ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('marketing.newsletter_signups:' || concat_ws('|', x.email_address, x.source))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.newsletter_signups x
)
UPDATE marketing.newsletter_signups t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.newsletter_signups ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE marketing.newsletter_signups ADD CONSTRAINT newsletter_signups_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_newsletter_signups_customer_id ON marketing.newsletter_signups (customer_id);
-- <<< relationships
