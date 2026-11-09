-- Cross River Trading Co. -- pallet moves, gate events, buying notes, portal
-- activity, case attachments, depot clock-ins
-- author: T. Marchetti
-- postgres: 18
--
-- Where a pallet went, who came through the gate, what a buyer wrote down,
-- what the customer portal recorded, what was attached to a case, and when
-- somebody started their shift.

-- DEFECT the-trigger-condition-never-matches-what-the-application-writes
--
-- The audit trigger on pallet moves carries a WHEN clause testing the status
-- against CANCELLED in capitals. The application writes it in lower case, so
-- the trigger has never fired.
--
-- The WHEN clause was added to keep the audit table small, which was a
-- reasonable thing to want, and the value in it was copied from the
-- specification rather than from the code. The specification was written in
-- capitals because the whole document is. Nothing failed: a trigger whose
-- condition is false is a trigger that did its job and decided there was
-- nothing to record. The cancellations are the only pallet moves anybody ever
-- asks about, because a cancelled move is a pallet that is somewhere it is not
-- recorded as being.
--
-- Measured: 7,200 pallet moves of which 1,800 are cancelled, against an audit
-- table holding none of them, behind one trigger with a WHEN condition.
--
-- Comparing on upper(NEW.status) fixes it, and the audit for the moves already
-- made cannot be reconstructed. The trigger is present, enabled, correctly
-- owned and syntactically fine.
CREATE TABLE ops.pallet_moves (
    move_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pallet_ref varchar(16) NOT NULL,
    from_depot varchar(12) NOT NULL,
    to_depot   varchar(12) NOT NULL,
    status     varchar(12) NOT NULL,
    moved_at   timestamptz NOT NULL
);

CREATE TABLE ops.pallet_move_audit (
    audit_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    move_id    integer NOT NULL,
    pallet_ref varchar(16) NOT NULL,
    seen_at    timestamptz NOT NULL
);

CREATE FUNCTION ops.fn_audit_pallet_move() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.pallet_move_audit (move_id, pallet_ref, seen_at)
    VALUES (NEW.move_id, NEW.pallet_ref, NEW.moved_at);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_pallet_move AFTER INSERT ON ops.pallet_moves
    FOR EACH ROW WHEN (NEW.status = 'CANCELLED')
    EXECUTE FUNCTION ops.fn_audit_pallet_move();

INSERT INTO ops.pallet_moves (pallet_ref, from_depot, to_depot, status, moved_at)
SELECT 'PAL-' || lpad(g::text, 10, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       'DEP-' || lpad((1 + ((g + 17) % 40))::text, 3, '0'),
       CASE WHEN g % 4 = 0 THEN 'cancelled' ELSE 'completed' END,
       TIMESTAMPTZ '2026-04-06 06:00:00+01' + (g * INTERVAL '21 minutes')
FROM generate_series(1, 7200) AS g;

-- DEFECT the-partitioned-table-could-not-take-the-key-it-needed
--
-- The gate event table is partitioned by month and has no primary key,
-- because the key the application needs does not include the partition
-- column.
--
-- A primary key on a partitioned table must contain every partitioning
-- column. The natural key here is the badge and the sequence number the gate
-- controller emits, which says nothing about the month. Rather than widen the
-- key, whoever partitioned the table dropped it, and nothing complained,
-- because partitioning was done to make the archive job cheaper and the
-- archive job does not care. The loader was written to upsert on that key. An
-- upsert needs a unique index, so the loader now deletes by badge and sequence
-- and inserts again, in two statements, with no lock between them.
--
-- Measured: 9,000 gate events across three monthly partitions with no primary
-- key on the partitioned table.
--
-- Widening the key to include the event month makes the constraint legal and
-- the upsert possible. Every partition is attached, every row routes
-- correctly, and the archive job runs in seconds.
CREATE TABLE ops.gate_events (
    badge_no   varchar(10) NOT NULL,
    event_seq  integer NOT NULL,
    depot_code varchar(12) NOT NULL,
    direction  varchar(4) NOT NULL,
    event_month date NOT NULL
) PARTITION BY RANGE (event_month);

CREATE TABLE ops.gate_events_2026_06 PARTITION OF ops.gate_events
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE ops.gate_events_2026_07 PARTITION OF ops.gate_events
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE ops.gate_events_2026_08 PARTITION OF ops.gate_events
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');

INSERT INTO ops.gate_events (badge_no, event_seq, depot_code, direction, event_month)
SELECT 'BDG-' || lpad((1 + (g % 900))::text, 5, '0'),
       g,
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       CASE WHEN g % 2 = 0 THEN 'in' ELSE 'out' END,
       (ARRAY[DATE '2026-06-01', DATE '2026-07-01', DATE '2026-08-01'])[1 + (g % 3)]
FROM generate_series(1, 9000) AS g;

-- DEFECT a-read-only-role-may-create-tables-in-the-schema-it-reads
--
-- The agency reporting role holds CREATE on the supply schema. It was meant to
-- hold nothing but USAGE and SELECT.
--
-- The grant was written as ALL PRIVILEGES ON SCHEMA supply, which on a schema
-- is USAGE and CREATE and nothing else, so it reads as a small grant and is
-- not one. CREATE on a schema is permission to add objects to it, and an
-- object added to a schema that sits early on somebody's search path is
-- consulted before the object it shadows. The agency connects from outside the
-- estate over a pooled connection shared with the buying application, and the
-- buying application's search path starts with supply.
--
-- Measured: 3,600 buying notes in a schema where the agency reporting role
-- holds CREATE.
--
-- REVOKE CREATE ON SCHEMA supply FROM agency_reader is one statement and the
-- role loses nothing it uses. The role has never created anything, every
-- object in the schema is owned by the migration user, and the privilege
-- report shows a grant that was requested and approved.
CREATE TABLE supply.buying_notes (
    note_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    buyer_ref  varchar(12) NOT NULL,
    note_text  varchar(200) NOT NULL,
    written_on date NOT NULL
);

INSERT INTO supply.buying_notes (buyer_ref, note_text, written_on)
SELECT 'BUY-' || lpad((1 + (g % 60))::text, 4, '0'),
       'Note ' || g || ': supplier contacted, awaiting revised pricing.',
       DATE '2025-09-15' + (g % 370)
FROM generate_series(1, 3600) AS g;

GRANT ALL PRIVILEGES ON SCHEMA supply TO agency_reader;

-- DEFECT paging-by-offset-rescans-every-page-before-the-one-asked-for
--
-- The portal activity export pages with OFFSET. Page three hundred reads the
-- first three hundred pages and throws away all but the last.
--
-- OFFSET does not skip rows: it produces them and discards them, so the cost
-- of a page grows with how far into the result it sits. The function was
-- written against a table with four hundred rows, where two pages is the whole
-- thing, and it has been correct and fast ever since. The table is now sixty
-- thousand rows and the export walks every page in order, so the walk costs
-- the square of the pages rather than the count of the rows. It is also not
-- stable: a row inserted during the walk shifts the boundary and a row is
-- either exported twice or not at all.
--
-- Measured: one full walk of 300 pages scanning 9,030,000 rows to return the
-- 60,000 that are in the table.
--
-- Keyset paging, carrying the last key forward instead of a page number, makes
-- every page cost the same and fixes the shifting boundary at the same time.
-- Every page returns exactly two hundred rows in the right order and the
-- export has never produced a wrong total.
CREATE TABLE ops.portal_activity (
    activity_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    action_name varchar(30) NOT NULL,
    happened_at timestamptz NOT NULL
);

INSERT INTO ops.portal_activity (account_ref, action_name, happened_at)
SELECT 'ACC-' || lpad((1 + (g % 3000))::text, 8, '0'),
       (ARRAY['login', 'view_order', 'download_invoice',
              'update_address', 'raise_case'])[1 + (g % 5)],
       TIMESTAMPTZ '2026-07-01 00:00:00+01' + (g * INTERVAL '45 seconds')
FROM generate_series(1, 60000) AS g;

CREATE FUNCTION ops.fn_event_page(p_page integer)
RETURNS SETOF ops.portal_activity
LANGUAGE sql STABLE AS $$
    SELECT * FROM ops.portal_activity
    ORDER BY activity_id
    OFFSET (p_page - 1) * 200
    LIMIT 200;
$$;

CREATE TABLE ops.event_page_log (
    page_no      integer PRIMARY KEY,
    rows_scanned integer NOT NULL,
    walked_at    timestamptz NOT NULL
);

INSERT INTO ops.event_page_log (page_no, rows_scanned, walked_at)
SELECT g, g * 200, TIMESTAMPTZ '2026-09-06 02:00:00+01' + (g * INTERVAL '4 seconds')
FROM generate_series(1, 300) AS g;

-- DEFECT the-second-policy-widened-the-first-instead-of-narrowing-it
--
-- Case attachments carry two row security policies. Both are permissive, so
-- they are combined with OR, and the second one grants back everything the
-- first was written to withhold.
--
-- The first policy limits an agent to the attachments on cases in their own
-- team. The second was added so that the complaints team could see
-- attachments flagged as complaints, whatever team the case belongs to.
-- Written as a permissive policy, that is not an exception: it is an
-- alternative. A row satisfies the table's security if it satisfies either
-- one, so every attachment flagged as a complaint is readable by every agent,
-- and every attachment is flagged as a complaint by the form's default.
--
-- Measured: 9,600 case attachments under two permissive policies on one table.
--
-- The second policy wants to be RESTRICTIVE, or the two want folding into one
-- expression. Both policies are enabled, both are correct in isolation, and
-- row security is on.
CREATE TABLE support.case_attachments (
    attachment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref      varchar(16) NOT NULL,
    team_code     varchar(8) NOT NULL,
    is_complaint  boolean NOT NULL,
    file_name     varchar(80) NOT NULL
);

INSERT INTO support.case_attachments (case_ref, team_code, is_complaint, file_name)
SELECT 'CAS-' || lpad((1 + (g % 3200))::text, 10, '0'),
       'TEAM-' || lpad((1 + (g % 12))::text, 3, '0'),
       true,
       'attachment-' || g || '.pdf'
FROM generate_series(1, 9600) AS g;

ALTER TABLE support.case_attachments ENABLE ROW LEVEL SECURITY;

CREATE POLICY case_attachments_own_team ON support.case_attachments
    FOR SELECT USING (team_code = current_setting('app.team_code', true));

-- The exception the complaints team asked for.
CREATE POLICY case_attachments_complaints ON support.case_attachments
    FOR SELECT USING (is_complaint);

-- DEFECT the-device-writes-wall-clock-into-a-column-read-as-utc
--
-- The clock-in terminal writes local wall clock time into a column with no
-- time zone, and everything downstream reads that column as UTC. Between
-- March and October it is an hour out.
--
-- The terminal is a fixed device in a depot and it reports what its own clock
-- says, which is British time. The column was declared without a time zone
-- because the value has no offset on it, which is true and is exactly the
-- problem: nothing on the row says what it is local to. The gateway also
-- records a proper instant on the same row, which is where the discrepancy can
-- be seen, and nothing compares the two. Payroll reads the wall clock column,
-- so a summer shift starting at six is paid from five.
--
-- Measured: 6,000 clock-ins of which 3,000 fall in British Summer Time and
-- disagree by an hour with the gateway instant on the same row.
--
-- Storing the instant and rendering the wall clock when it is needed is the
-- fix, and the gateway column already holds it. Every timestamp is a real
-- reading from a working clock and no row is internally malformed.
CREATE TABLE ops.depot_clock_ins (
    clock_in_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    badge_no    varchar(10) NOT NULL,
    depot_code  varchar(12) NOT NULL,
    clocked_at  timestamp NOT NULL,
    device_utc  timestamptz NOT NULL
);

-- Winter, where the depot clock and UTC agree.
INSERT INTO ops.depot_clock_ins (badge_no, depot_code, clocked_at, device_utc)
SELECT 'BDG-' || lpad((1 + (g % 900))::text, 5, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       (TIMESTAMPTZ '2026-01-10 08:00:00+00' + (g * INTERVAL '10 minutes'))
           AT TIME ZONE 'Europe/London',
       TIMESTAMPTZ '2026-01-10 08:00:00+00' + (g * INTERVAL '10 minutes')
FROM generate_series(1, 3000) AS g;

-- Summer, where they do not.
INSERT INTO ops.depot_clock_ins (badge_no, depot_code, clocked_at, device_utc)
SELECT 'BDG-' || lpad((1 + (g % 900))::text, 5, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       (TIMESTAMPTZ '2026-06-01 05:00:00+00' + (g * INTERVAL '10 minutes'))
           AT TIME ZONE 'Europe/London',
       TIMESTAMPTZ '2026-06-01 05:00:00+00' + (g * INTERVAL '10 minutes')
FROM generate_series(1, 3000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.depot_clock_ins ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.depot_clock_ins:' || concat_ws('|', x.badge_no, x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.depot_clock_ins x
)
UPDATE ops.depot_clock_ins t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.depot_clock_ins ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.depot_clock_ins ADD CONSTRAINT depot_clock_ins_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_depot_clock_ins_store_id ON ops.depot_clock_ins (store_id);

ALTER TABLE ops.pallet_moves ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.pallet_moves:' || concat_ws('|', x.pallet_ref, x.from_depot, x.to_depot, x.status))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.pallet_moves x
)
UPDATE ops.pallet_moves t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.pallet_moves ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.pallet_moves ADD CONSTRAINT pallet_moves_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_pallet_moves_warehouse_id ON ops.pallet_moves (warehouse_id);

ALTER TABLE ops.portal_activity ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('ops.portal_activity:' || concat_ws('|', x.account_ref, x.action_name))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.portal_activity x
)
UPDATE ops.portal_activity t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.portal_activity ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE ops.portal_activity ADD CONSTRAINT portal_activity_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_portal_activity_customer_id ON ops.portal_activity (customer_id);

ALTER TABLE supply.buying_notes ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.buying_notes:' || concat_ws('|', x.buyer_ref, x.note_text))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.buying_notes x
)
UPDATE supply.buying_notes t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.buying_notes ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.buying_notes ADD CONSTRAINT buying_notes_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_buying_notes_supplier_id ON supply.buying_notes (supplier_id);

ALTER TABLE support.case_attachments ADD COLUMN case_id integer;

WITH p AS (
    SELECT case_id AS v, row_number() OVER (ORDER BY case_id) - 1 AS k
      FROM support.case_records
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.case_records)
                 * power((abs(hashtext('support.case_attachments:' || concat_ws('|', x.case_ref, x.team_code, x.is_complaint, x.file_name))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.case_attachments x
)
UPDATE support.case_attachments t
   SET case_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.case_attachments ALTER COLUMN case_id SET NOT NULL;
ALTER TABLE support.case_attachments ADD CONSTRAINT case_attachments_case_id_fkey FOREIGN KEY (case_id) REFERENCES support.case_records (case_id);
CREATE INDEX ix_case_attachments_case_id ON support.case_attachments (case_id);
-- <<< relationships
