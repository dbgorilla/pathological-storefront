-- Cross River Trading Co. -- transit times, audience tags, case statuses,
-- asset transfers, staff badges, tariff lines
-- author: T. Marchetti
-- postgres: 18
--
-- How long a leg took, which audience a contact is in, where a support case
-- has got to, which depot an asset moved to, the number on a member of staff's
-- badge, and the tariff a product is shipped under.

-- DEFECT the-transit-hours-were-stored-as-an-integer-so-every-leg-is-short
--
-- The transit time is stored as a whole number of hours, computed by dividing
-- minutes by sixty in integer arithmetic. Every part hour is thrown away.
--
-- The column was added for a report that grouped legs into hour bands, where
-- whole hours are the right unit, and the value was written by the same query
-- that filled the bands. The carrier service level agreement is also written
-- in whole hours, and it is measured against this column. A leg that took
-- forty eight hours and fifty minutes is stored as forty eight and counts as
-- inside a forty eight hour agreement, so the carrier is never charged for it.
-- Every leg is short by up to fifty nine minutes and never long by any.
--
-- Measured: 12,000 transit legs, of which 9,600 hold an hour count that does
-- not match the interval between the two timestamps.
--
-- The two timestamps are on the row and the interval between them is the real
-- answer, so the column can be dropped and computed. Every stored value is
-- within an hour of the truth, which is why comparing a handful of rows by
-- hand has never found it.
CREATE TABLE fulfilment.transit_times (
    leg_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    route_ref varchar(16) NOT NULL,
    left_at   timestamptz NOT NULL,
    arrived_at timestamptz NOT NULL,
    hours     integer NOT NULL
);

INSERT INTO fulfilment.transit_times (route_ref, left_at, arrived_at, hours)
SELECT 'RTE-' || lpad((1 + (g % 600))::text, 6, '0'),
       TIMESTAMPTZ '2026-01-05 04:00:00+00' + (g * INTERVAL '13 minutes'),
       TIMESTAMPTZ '2026-01-05 04:00:00+00' + (g * INTERVAL '13 minutes')
           + ((60 * (5 + (g % 40)) + 12 * (g % 5)) * INTERVAL '1 minute'),
       (60 * (5 + (g % 40)) + 12 * (g % 5)) / 60
FROM generate_series(1, 12000) AS g;

-- DEFECT the-batched-backfill-skipped-the-rows-that-moved-under-it
--
-- The audience tag backfill ran in batches ordered by a column the backfill
-- itself was updating. Some rows moved out of the window before it reached
-- them.
--
-- The script selected the next ten thousand rows ordered by the tag column,
-- updated them, and repeated until nothing came back. Each batch changed the
-- value it was ordering on, so rows shifted position between batches, and the
-- loop terminated when a batch returned nothing rather than when every row was
-- done. It exited on the first gap. The rows that were missed still carry the
-- sentinel the column was created with, and the segment builder treats the
-- sentinel as a real audience, so those contacts are in every campaign that
-- targets everybody and no campaign that targets anybody.
--
-- Measured: 18,000 audience tags of which 1,200 still hold the UNSET sentinel
-- the column was created with.
--
-- Re-running the backfill over the sentinel rows alone is a single statement.
-- The script reported success, because it did what it was written to do, and
-- the count it logged was the number of rows it updated rather than the number
-- it should have.
CREATE TABLE marketing.audience_tags (
    tag_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contact_ref varchar(14) NOT NULL,
    tag_value   varchar(24) NOT NULL,
    tagged_on   date NOT NULL
);

INSERT INTO marketing.audience_tags (contact_ref, tag_value, tagged_on)
SELECT 'CNT-' || lpad(g::text, 9, '0'),
       CASE WHEN g % 15 = 0
            THEN 'UNSET'
            ELSE (ARRAY['trade', 'retail', 'lapsed', 'prospect',
                        'staff', 'wholesale', 'export'])[1 + (g % 7)]
       END,
       DATE '2024-09-16' + (g % 700)
FROM generate_series(1, 18000) AS g;

-- DEFECT the-status-column-and-the-status-history-disagree-about-now
--
-- Every case carries its current status in one table and its status history in
-- another. One transition writes the history and not the column.
--
-- There are three ways a case changes status: an agent does it in the console,
-- the escalation job does it on a timer, and the customer does it by replying
-- to a closed case. The first two write both tables in one transaction. The
-- third was added for the reply handler, which appends to the history and was
-- never given the update to the current status table, because whoever wrote it
-- read the history table and assumed the current status was a view over it. It
-- is not. The console shows the status column and the audit export shows the
-- history, so the two disagree in front of two different audiences.
--
-- Measured: 9,000 cases with 27,000 history rows, of which 2,400 carry a
-- current status that is not the status of their latest history row.
--
-- The current status wants to be derived, or the reply handler wants the
-- second write. Both tables are internally consistent and each one is right
-- about the thing it records, so neither has ever failed a check of its own.
CREATE TABLE support.case_current_status (
    case_ref   varchar(16) PRIMARY KEY,
    status     varchar(16) NOT NULL,
    changed_at timestamptz NOT NULL
);

CREATE TABLE support.case_status_history (
    history_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref   varchar(16) NOT NULL,
    status     varchar(16) NOT NULL,
    changed_at timestamptz NOT NULL
);

INSERT INTO support.case_status_history (case_ref, status, changed_at)
SELECT 'CAS-' || lpad(c::text, 8, '0'),
       (ARRAY['new', 'open', 'waiting', 'resolved', 'closed'])[1 + ((c + s) % 5)],
       TIMESTAMPTZ '2026-03-02 09:00:00+00' + (c * INTERVAL '4 minutes')
           + (s * INTERVAL '40 minutes')
FROM generate_series(1, 9000) AS c
CROSS JOIN generate_series(1, 3) AS s;

-- The console and the escalation job write both tables. The reply handler,
-- which is the path taken by four cases in fifteen, writes only the history.
INSERT INTO support.case_current_status (case_ref, status, changed_at)
SELECT 'CAS-' || lpad(c::text, 8, '0'),
       CASE WHEN c % 15 < 4
            THEN (ARRAY['new', 'open', 'waiting', 'resolved', 'closed'])[1 + ((c + 2) % 5)]
            ELSE (ARRAY['new', 'open', 'waiting', 'resolved', 'closed'])[1 + ((c + 3) % 5)]
       END,
       TIMESTAMPTZ '2026-03-02 09:00:00+00' + (c * INTERVAL '4 minutes')
           + INTERVAL '120 minutes'
FROM generate_series(1, 9000) AS c;

-- DEFECT the-audit-trigger-covers-insert-and-update-and-not-delete
--
-- The asset transfer audit trigger fires on insert and on update. Deleting a
-- transfer leaves no trace at all.
--
-- The trigger was written when transfers were append only, so INSERT OR UPDATE
-- covered everything that could happen. Deletion arrived later, with a screen
-- that lets a depot clerk remove a transfer raised in error, and the screen
-- was tested against the table rather than against the audit. The audit is the
-- record the insurer asks for when an asset cannot be found, and for a deleted
-- transfer it shows the asset arriving somewhere and never shows it leaving,
-- because the row that said it left is gone and nothing recorded its going.
--
-- Measured: 9,000 audited transfers against 7,200 transfers still in the
-- table, a gap of 1,800 deletions, behind one trigger that does not cover
-- DELETE.
--
-- Adding OR DELETE to the trigger and a row type to the audit is small. The
-- audit table is complete for every operation it covers, so a check that reads
-- the audit alone finds nothing missing.
CREATE TABLE ops.asset_transfers (
    transfer_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    asset_ref   varchar(16) NOT NULL,
    from_depot  varchar(12) NOT NULL,
    to_depot    varchar(12) NOT NULL,
    moved_on    date NOT NULL
);

CREATE TABLE ops.asset_transfer_audit (
    audit_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transfer_id integer NOT NULL,
    asset_ref   varchar(16) NOT NULL,
    seen_at     timestamptz NOT NULL
);

CREATE FUNCTION ops.fn_audit_asset_transfer() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.asset_transfer_audit (transfer_id, asset_ref, seen_at)
    VALUES (NEW.transfer_id, NEW.asset_ref, NEW.moved_on);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_asset_transfer
    AFTER INSERT OR UPDATE ON ops.asset_transfers
    FOR EACH ROW EXECUTE FUNCTION ops.fn_audit_asset_transfer();

INSERT INTO ops.asset_transfers (asset_ref, from_depot, to_depot, moved_on)
SELECT 'AST-' || lpad(g::text, 8, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       'DEP-' || lpad((1 + ((g + 7) % 40))::text, 3, '0'),
       DATE '2025-12-01' + (g % 280)
FROM generate_series(1, 9000) AS g;

-- The transfers a clerk removed on the corrections screen.
DELETE FROM ops.asset_transfers WHERE transfer_id % 5 = 0;

-- DEFECT the-unique-column-is-nullable-so-the-blanks-are-all-allowed
--
-- The badge number is unique and nullable. Two thousand four hundred staff
-- have no badge number, and the unique index has nothing to say about any of
-- them.
--
-- The uniqueness was declared because a badge number identifies one person.
-- The column was left nullable because contractors and new starters do not
-- have one on their first day. Postgres treats nulls as distinct in a unique
-- index by default, so the constraint that was meant to say "one person per
-- badge" says nothing at all about the two fifths of the table where the badge
-- is missing. The door system looks a person up by badge number and finds one
-- row or none, which is why the gap has never shown as a duplicate.
--
-- Measured: 6,000 staff badge rows of which 2,400 hold a null badge number,
-- under one unique index that permits every one of them.
--
-- Either the column is NOT NULL with a placeholder scheme, or the identity
-- lives somewhere else and the badge is an attribute. The index is valid and
-- enforced, so every schema review has seen a unique constraint and moved on.
CREATE TABLE ops.staff_badges (
    staff_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    staff_ref  varchar(12) NOT NULL,
    badge_no   varchar(10) UNIQUE,
    depot_code varchar(12) NOT NULL,
    started_on date NOT NULL
);

INSERT INTO ops.staff_badges (staff_ref, badge_no, depot_code, started_on)
SELECT 'STF-' || lpad(g::text, 7, '0'),
       CASE WHEN g % 5 < 2 THEN NULL ELSE 'BDG-' || lpad(g::text, 6, '0') END,
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2016-03-07' + (g % 3600)
FROM generate_series(1, 6000) AS g;

-- DEFECT on-update-set-null-orphans-every-child-when-the-code-changes
--
-- The tariff line points at the tariff code with ON UPDATE SET NULL. Renaming
-- a tariff code detaches every line that used it, in silence.
--
-- The action was chosen because ON UPDATE CASCADE had rewritten nine hundred
-- rows overnight once before and somebody wanted the opposite of that. SET
-- NULL is not the opposite: it is the same write, with the reference thrown
-- away instead of carried across. Tariff codes are renamed by the customs
-- team about twice a year, when the commodity schedule changes. Each rename
-- leaves the lines that used the old code pointing at nothing, and the export
-- paperwork prints an empty tariff, which the freight forwarder fills in from
-- memory.
--
-- Measured: 8,000 tariff lines under a foreign key whose update action is SET
-- NULL, against 400 tariff codes.
--
-- The fix is a surrogate key on the tariff code so that a rename is not an
-- update to the referenced column at all. No rename has happened since the
-- constraint was written, so the action has never fired.
CREATE TABLE supply.tariff_codes (
    tariff_code varchar(12) PRIMARY KEY,
    description varchar(80) NOT NULL,
    duty_pct    integer NOT NULL
);

CREATE TABLE supply.tariff_lines (
    line_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    consignment_ref varchar(16) NOT NULL,
    tariff_code varchar(12) REFERENCES supply.tariff_codes (tariff_code)
                ON UPDATE SET NULL,
    value_p     integer NOT NULL
);

INSERT INTO supply.tariff_codes (tariff_code, description, duty_pct)
SELECT 'TRF-' || lpad(g::text, 6, '0'),
       'Commodity group ' || g,
       2 + (g % 18)
FROM generate_series(1, 400) AS g;

INSERT INTO supply.tariff_lines (consignment_ref, tariff_code, value_p)
SELECT 'CNS-' || lpad(g::text, 10, '0'),
       'TRF-' || lpad((1 + (g % 400))::text, 6, '0'),
       5000 + (g % 400000)
FROM generate_series(1, 8000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE fulfilment.transit_times ADD COLUMN carrier_id integer;

WITH p AS (
    SELECT carrier_id AS v, row_number() OVER (ORDER BY carrier_id) - 1 AS k
      FROM fulfilment.carriers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.carriers)
                 * power((abs(hashtext('fulfilment.transit_times:' || concat_ws('|', x.route_ref, x.hours))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.transit_times x
)
UPDATE fulfilment.transit_times t
   SET carrier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.transit_times ALTER COLUMN carrier_id SET NOT NULL;
ALTER TABLE fulfilment.transit_times ADD CONSTRAINT transit_times_carrier_id_fkey FOREIGN KEY (carrier_id) REFERENCES fulfilment.carriers (carrier_id);
CREATE INDEX ix_transit_times_carrier_id ON fulfilment.transit_times (carrier_id);

ALTER TABLE marketing.audience_tags ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('marketing.audience_tags:' || concat_ws('|', x.contact_ref, x.tag_value))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.audience_tags x
)
UPDATE marketing.audience_tags t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.audience_tags ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE marketing.audience_tags ADD CONSTRAINT audience_tags_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_audience_tags_customer_id ON marketing.audience_tags (customer_id);

ALTER TABLE ops.staff_badges ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.staff_badges:' || concat_ws('|', x.staff_ref, x.badge_no, x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.staff_badges x
)
UPDATE ops.staff_badges t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.staff_badges ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.staff_badges ADD CONSTRAINT staff_badges_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_staff_badges_store_id ON ops.staff_badges (store_id);

ALTER TABLE support.case_current_status ADD COLUMN case_id integer;

WITH p AS (
    SELECT case_id AS v, row_number() OVER (ORDER BY case_id) - 1 AS k
      FROM support.case_records
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.case_records)
                 * power((abs(hashtext('support.case_current_status:' || concat_ws('|', x.case_ref, x.status))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.case_current_status x
)
UPDATE support.case_current_status t
   SET case_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.case_current_status ALTER COLUMN case_id SET NOT NULL;
ALTER TABLE support.case_current_status ADD CONSTRAINT case_current_status_case_id_fkey FOREIGN KEY (case_id) REFERENCES support.case_records (case_id);
CREATE INDEX ix_case_current_status_case_id ON support.case_current_status (case_id);
-- <<< relationships
