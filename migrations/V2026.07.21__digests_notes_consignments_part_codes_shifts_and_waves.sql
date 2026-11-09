-- Cross River Trading Co. -- document digests, supplier note exports,
-- consignment milestones, supplier part codes, shift handovers, pick waves
-- author: P. Adeyemi
-- postgres: 18
--
-- The short reference the document store prints on a cover sheet, the note file
-- the buying desk sends out, the on time figure the transport meeting reads, the
-- supplier code load from the trade file, the shift handover times the depot
-- board shows, and the wave close the pickers press at the end of a run.

-- DEFECT hash-truncated-to-four-characters-collides
--
-- Every scanned document gets a digest of its reference, shortened to four hex
-- characters so it fits the cover sheet and can be typed back in by hand.
--
-- Four hex characters is 65,536 values. With three thousand documents the odds
-- of no two sharing one are effectively nil, and the column carries no unique
-- constraint because it was never meant to be a key. The lookup that takes a
-- typed digest and returns the document joins on it anyway.
--
-- Measured: 3,000 documents produce 2,920 distinct digests. 159 documents share
-- a digest with at least one other, and the lookup returns more than one
-- document for 79 of the codes somebody can type in.
--
-- A key that has to be short and typed is generated from a counter and checked
-- for uniqueness, not cut out of a hash and hoped over. The digest looks like a
-- digest, it is stable for a given reference, and the collision only shows up
-- when two of the documents that share one are both in front of somebody.
CREATE TABLE ops.document_digests (
    doc_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    doc_ref     varchar(32) NOT NULL UNIQUE,
    digest_short char(4) NOT NULL
);

INSERT INTO ops.document_digests (doc_ref, digest_short)
SELECT 'DOC-2026-' || lpad(g::text, 6, '0'),
       substr(md5('doc-' || g::text), 1, 4)
FROM generate_series(1, 3000) AS g;

CREATE INDEX ix_document_digests_short ON ops.document_digests (digest_short);

CREATE VIEW analytics.v_document_lookup AS
SELECT d.digest_short, d.doc_id, d.doc_ref
FROM ops.document_digests d;

-- DEFECT delimiter-appears-in-the-values-so-the-joined-string-cannot-be-split
--
-- Supplier notes are exported one row per supplier, with the individual notes
-- joined into a single comma separated field, and read back by splitting on the
-- comma.
--
-- Buyers write notes in prose, and prose has commas in it. A note containing one
-- comes back as two fields, every field after it shifts along, and the count of
-- fields no longer matches the count of notes. Nothing errors: the export is
-- well formed text and the split returns strings.
--
-- Measured: 200 suppliers exported. 120 of them have a note containing a comma,
-- and reading the export back gives 960 note fields for the 600 notes that went
-- into it. 720 of those fields are half a sentence.
--
-- A delimiter has to be one that cannot occur in the data, or the values have to
-- be quoted and escaped, which is what a CSV writer does and a string_agg does
-- not. A jsonb array or a child table keeps the boundary in the structure rather
-- than in a character. The export and the import agree on the format and
-- disagree about the data.
CREATE TABLE supply.supplier_note_items (
    note_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id integer NOT NULL,
    note_text   varchar(200) NOT NULL
);

INSERT INTO supply.supplier_note_items (supplier_id, note_text)
SELECT 1 + (g % 200),
       CASE WHEN g % 5 IN (0, 1, 2)
            THEN 'Ships Tuesdays, collections by arrangement'
            ELSE 'Pallet rate agreed'
       END
FROM generate_series(1, 600) AS g;

CREATE TABLE supply.supplier_notes_export (
    supplier_id integer PRIMARY KEY,
    notes_csv   varchar(2000) NOT NULL
);

INSERT INTO supply.supplier_notes_export (supplier_id, notes_csv)
SELECT n.supplier_id, string_agg(n.note_text, ',' ORDER BY n.note_id)
FROM supply.supplier_note_items n
GROUP BY n.supplier_id;

CREATE VIEW analytics.v_supplier_note_lines AS
SELECT e.supplier_id,
       trim(f.note) AS note
FROM supply.supplier_notes_export e
CROSS JOIN LATERAL unnest(string_to_array(e.notes_csv, ',')) AS f(note);

-- DEFECT greatest-ignores-nulls-so-a-missing-date-does-not-count
--
-- A consignment is on time if it finished on or before its due date, and the
-- finish is the later of the dispatch and the delivery, taken with greatest().
--
-- greatest() ignores nulls and returns the largest of the arguments that are not
-- null. So a consignment that was dispatched and never delivered does not
-- produce a null finish date: it produces the dispatch date, and if that was
-- before the due date the consignment counts as delivered on time. The one
-- category of failure the report exists to find is the one it scores as a
-- success.
--
-- Measured: 420 of the 900 consignments count as on time. 180 of those were
-- never delivered at all.
--
-- The finish date of an unfinished consignment is unknown, and an expression
-- that has to propagate that writes it out: delivered_on, with a separate test
-- for whether it is there. greatest() is the SQL standard's least surprising
-- name for its most surprising null rule, and the figure it produces goes
-- straight onto the transport meeting's slide.
CREATE TABLE fulfilment.consignment_milestones (
    consignment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    consignment_ref varchar(20) NOT NULL UNIQUE,
    due_on         date NOT NULL,
    dispatched_on  date,
    delivered_on   date
);

INSERT INTO fulfilment.consignment_milestones
       (consignment_ref, due_on, dispatched_on, delivered_on)
SELECT 'CN' || lpad(g::text, 6, '0'),
       DATE '2026-04-01' + (g % 90),
       DATE '2026-04-01' + (g % 90) - (g % 4),
       CASE WHEN g % 5 = 0 THEN NULL
            ELSE DATE '2026-04-01' + (g % 90) + (g % 3)
       END
FROM generate_series(1, 900) AS g;

CREATE VIEW analytics.v_consignment_last_seen AS
SELECT c.consignment_id,
       c.consignment_ref,
       c.due_on,
       greatest(c.dispatched_on, c.delivered_on) AS completed_on,
       greatest(c.dispatched_on, c.delivered_on) <= c.due_on AS on_time
FROM fulfilment.consignment_milestones c;

-- DEFECT unique-plus-empty-string-default-allows-only-one-blank
--
-- Supplier part codes are unique, and the column is not nullable because a
-- missing code is written as the empty string. The trade file load inserts with
-- ON CONFLICT DO NOTHING so a rerun is safe.
--
-- A nullable unique column permits any number of unknowns, because no null
-- equals another. A NOT NULL column defaulted to the empty string permits
-- exactly one, because every blank equals every other blank. So the first part
-- with no supplier code loads and every other one collides with it, and DO
-- NOTHING makes that silent: the load reports the rows it inserted and says
-- nothing about the rows it did not.
--
-- Measured: 900 staging rows produce 601 part codes. 299 parts are missing, all
-- of them parts whose supplier code was blank in the trade file, and the load
-- reported no errors.
--
-- Unknown is null, and a unique constraint is built to tolerate it. The empty
-- string is a value, and here it is a value that behaves as a key with exactly
-- one slot. The rows that went missing are the rows that most needed looking at.
CREATE TABLE catalog.supplier_part_staging (
    staging_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    part_no       varchar(20) NOT NULL,
    supplier_code varchar(24) NOT NULL
);

INSERT INTO catalog.supplier_part_staging (part_no, supplier_code)
SELECT 'SP' || lpad(g::text, 6, '0'),
       CASE WHEN g % 3 = 0 THEN '' ELSE 'SUP-' || lpad(g::text, 6, '0') END
FROM generate_series(1, 900) AS g;

CREATE TABLE catalog.supplier_part_codes (
    part_code_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    part_no       varchar(20) NOT NULL,
    supplier_code varchar(24) NOT NULL DEFAULT '' UNIQUE
);

-- The trade file load.
INSERT INTO catalog.supplier_part_codes (part_no, supplier_code)
SELECT s.part_no, s.supplier_code
FROM catalog.supplier_part_staging s
ON CONFLICT (supplier_code) DO NOTHING;

-- DEFECT timestamp-literal-without-a-zone-is-read-in-the-server-zone
--
-- Shift handovers are recorded as the wall clock time on the depot board, in a
-- timestamp column with no zone. The board redisplays them by casting to
-- timestamptz and rendering in Europe/London.
--
-- A timestamp without a zone carries no zone, so the cast has to assume one, and
-- what it assumes is the server's. This server runs in UTC. The depot runs in
-- London, which is UTC in the winter and an hour ahead of it from the last
-- Sunday in March to the last Sunday in October. So every handover recorded in
-- British Summer Time is redisplayed an hour later than it happened, and every
-- winter one is right.
--
-- Measured: 840 of the 1,200 handovers redisplay at a different time from the
-- one that was recorded, every one of them by exactly an hour, and all of them
-- fall between the two clock changes: the earliest is 29 March and the latest
-- 24 October.
--
-- The column should be timestamptz, written from a client that knows its own
-- zone, and then no reader has to assume anything. A wall clock time stored
-- bare is a number that means whatever the machine reading it decides, and the
-- handover log is what a dispute over a missed collection is settled with.
CREATE TABLE ops.shift_handovers (
    handover_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot       varchar(20) NOT NULL,
    handover_at timestamp NOT NULL
);

COMMENT ON COLUMN ops.shift_handovers.handover_at IS
    'Wall clock time on the depot board, Europe/London.';

INSERT INTO ops.shift_handovers (depot, handover_at)
SELECT (ARRAY['preston','leeds','hull','crewe'])[1 + (g % 4)],
       TIMESTAMP '2026-01-01 06:00:00' + ((g % 300) || ' days')::interval
                                       + ((g % 12) || ' hours')::interval
FROM generate_series(1, 1200) AS g;

CREATE VIEW analytics.v_shift_handover_times AS
SELECT h.handover_id,
       h.depot,
       h.handover_at,
       (h.handover_at::timestamptz AT TIME ZONE 'Europe/London') AS board_time
FROM ops.shift_handovers h;

-- DEFECT unreferenced-cte-never-runs-so-the-side-effect-is-skipped
--
-- Closing a pick wave stamps the wave and writes an audit row. The audit write
-- is a function call, put in a CTE in front of the UPDATE so the two happen in
-- one statement.
--
-- PostgreSQL evaluates a plain CTE only if the rest of the statement reads from
-- it, and nothing here reads from this one. A data modifying CTE, one whose body
-- is itself an INSERT or UPDATE, runs regardless; a SELECT calling a function
-- that writes does not. The two forms look alike, the statement is valid either
-- way, and the wave closes.
--
-- Measured: 400 waves closed and the audit table holds 0 rows. Every wave shows
-- a close time and none of them shows who closed it or when the audit thinks
-- they did.
--
-- The audit write belongs on a trigger, or in its own statement before the
-- UPDATE, where whether it runs does not depend on whether anything reads its
-- output. Nothing about the close failed and nothing raised. The audit trail was
-- simply never written, and the first anybody will ask for it is after a
-- stocktake disagrees.
CREATE TABLE ops.pick_waves (
    wave_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wave_ref  varchar(20) NOT NULL UNIQUE,
    depot     varchar(20) NOT NULL,
    closed_at timestamptz
);

CREATE TABLE ops.pick_wave_audit (
    audit_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wave_id   integer NOT NULL,
    closed_by varchar(40) NOT NULL,
    noted_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO ops.pick_waves (wave_ref, depot)
SELECT 'PW' || lpad(g::text, 6, '0'),
       (ARRAY['preston','leeds','hull','crewe'])[1 + (g % 4)]
FROM generate_series(1, 400) AS g;

CREATE FUNCTION ops.fn_record_wave_audit(p_wave_id integer, p_user varchar)
RETURNS integer
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO ops.pick_wave_audit (wave_id, closed_by)
    VALUES (p_wave_id, p_user);
    RETURN p_wave_id;
END;
$$;

CREATE FUNCTION ops.fn_close_pick_wave(p_wave_id integer, p_user varchar)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    WITH logged AS (
        SELECT ops.fn_record_wave_audit(p_wave_id, p_user) AS audited
    )
    UPDATE ops.pick_waves
       SET closed_at = TIMESTAMPTZ '2026-07-21 18:00:00+01'
     WHERE wave_id = p_wave_id;
END;
$$;

-- The end of the day, every wave closed by the shift lead.
SELECT ops.fn_close_pick_wave(w.wave_id, 'shift.lead')
FROM ops.pick_waves w;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.shift_handovers ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.shift_handovers:' || concat_ws('|', x.depot))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.shift_handovers x
)
UPDATE ops.shift_handovers t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.shift_handovers ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.shift_handovers ADD CONSTRAINT shift_handovers_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_shift_handovers_store_id ON ops.shift_handovers (store_id);
-- <<< relationships
