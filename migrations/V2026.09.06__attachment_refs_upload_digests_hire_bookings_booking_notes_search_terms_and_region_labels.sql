-- Cross River Trading Co. -- attachment refs, upload digests, hire bookings,
-- booking notes, saved searches, region labels
-- author: T. Marchetti
-- postgres: 18
--
-- What was attached to a ticket, what was uploaded and checksummed, which
-- asset is out on hire and when, what a hire desk wrote against a request,
-- what people search the catalogue for, and what each region is called.

-- DEFECT the-large-objects-outlived-the-rows-that-pointed-at-them
--
-- The attachment rows were deleted and the large objects they pointed at were
-- not, so three hundred objects sit in the database with nothing referring to
-- them and no way to reach them.
--
-- A large object is not owned by the row that names it. Deleting the row
-- removes the reference and nothing else, because the object lives in its own
-- catalogue and only an explicit unlink removes it. The uploader journals
-- every object it creates, which is how this is provable at all, and the
-- delete path was written against the reference table alone, because that is
-- the table the screen knows about. Nothing complains: the objects take no
-- part in any query, no constraint refers to them, and the only sign is the
-- size of the database, which grows at the rate uploads are made rather than
-- at the rate attachments are kept. Restores carry them too, so the waste
-- compounds every time the estate is copied.
--
-- Measured: 900 journalled large objects of which 300 are still present in
-- the database and named by no attachment row.
--
-- Unlinking in the same transaction as the delete, or a sweep over the journal
-- for objects nothing references, reclaims the space. Every attachment that is
-- still referenced opens correctly, the journal is complete, and no reference
-- points at an object that has gone.
CREATE TABLE support.attachment_journal (
    journal_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loid       oid NOT NULL,
    created_on date NOT NULL
);

CREATE TABLE support.attachment_refs (
    ref_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loid       oid NOT NULL,
    ticket_ref varchar(14) NOT NULL,
    filename   varchar(40) NOT NULL
);

INSERT INTO support.attachment_journal (loid, created_on)
SELECT lo_from_bytea(0, ('attachment ' || g)::bytea),
       DATE '2026-05-01' + (g % 120)
FROM generate_series(1, 900) AS g;

-- The attachments still on a ticket. The rest were deleted from this table
-- alone.
INSERT INTO support.attachment_refs (loid, ticket_ref, filename)
SELECT loid,
       'TCK-' || lpad(journal_id::text, 9, '0'),
       'doc-' || journal_id || '.pdf'
FROM support.attachment_journal
WHERE journal_id % 3 <> 0;

-- DEFECT the-digest-was-written-as-the-text-of-its-own-hex
--
-- One upload path hands the checksum to the database as a hex string and the
-- column is bytea, so six hundred rows hold the sixty four characters of the
-- hex rather than the thirty two bytes they spell.
--
-- Casting text to bytea does not decode anything. It reads the string as bytes
-- in the escape format, and a string of hex digits contains no escape, so
-- every character is kept as its own byte. The result is twice the length and
-- entirely wrong, and it is still a valid bytea, so nothing raises. The
-- comparison that matters is against the digest of the file as computed at
-- read time, which is thirty two bytes, and it never matches, so those uploads
-- are reported as corrupt and re-sent. That has been happening for months and
-- was put down to the supplier's network.
--
-- Measured: 3,000 upload digests of which 600 are 64 bytes long, being the hex
-- text of a digest rather than the digest.
--
-- Decoding with decode(...,'hex') on the way in fixes the path, and the stored
-- rows can be decoded in place because the text is still exactly what was
-- computed. Every digest was calculated correctly, against the right file, and
-- the rows written by the other path are the right length and match.
CREATE TABLE support.upload_digests (
    digest_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    upload_ref  varchar(16) NOT NULL,
    payload_sha bytea NOT NULL,
    recorded_on date NOT NULL
);

INSERT INTO support.upload_digests (upload_ref, payload_sha, recorded_on)
SELECT 'UPL-' || lpad(g::text, 10, '0'),
       CASE WHEN g % 5 = 0
            THEN encode(sha256(('payload ' || g)::bytea), 'hex')::bytea
            ELSE sha256(('payload ' || g)::bytea)
       END,
       DATE '2026-04-05' + (g % 150)
FROM generate_series(1, 3000) AS g;

-- DEFECT the-exclusion-constraint-never-sees-a-booking-with-no-period
--
-- The hire bookings carry an exclusion constraint that stops one asset being
-- booked twice over the same hours, and the four hundred bookings written by
-- the old path have no period at all, so the constraint never considers them.
--
-- An exclusion constraint compares values with an operator, and an operator
-- against NULL is unknown, so a row with a null range conflicts with nothing
-- and nothing conflicts with it. The period column was added when the
-- constraint was, and the desk screen was changed to fill it. The overnight
-- import was not, because it writes the start and the end as separate columns
-- and always has, and both of those are still present and still correct. So
-- the table enforces the rule for bookings made by a person and enforces
-- nothing for bookings made by the file, and the double bookings that result
-- are exactly the ones nobody is watching.
--
-- Measured: 1,200 hire bookings of which 400 have no period, and all 400
-- overlap another booking of the same asset on the start and end times they do
-- carry.
--
-- Backfilling the period from the two columns and declaring it NOT NULL brings
-- those rows under the constraint, and the import wants to write it. Every
-- booking names a real asset, every start is before its end, and the bookings
-- that do carry a period are provably free of overlap.
CREATE TABLE ops.hire_bookings (
    booking_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    asset_id   integer NOT NULL,
    starts_at  timestamptz NOT NULL,
    ends_at    timestamptz NOT NULL,
    period     tstzrange,
    EXCLUDE USING gist (asset_id WITH =, period WITH &&)
);

INSERT INTO ops.hire_bookings (asset_id, starts_at, ends_at, period)
SELECT 1 + (g % 200),
       TIMESTAMPTZ '2026-06-01 08:00:00+01' + ((g / 200) * INTERVAL '1 day'),
       TIMESTAMPTZ '2026-06-01 12:00:00+01' + ((g / 200) * INTERVAL '1 day'),
       tstzrange(TIMESTAMPTZ '2026-06-01 08:00:00+01' + ((g / 200) * INTERVAL '1 day'),
                 TIMESTAMPTZ '2026-06-01 12:00:00+01' + ((g / 200) * INTERVAL '1 day'), '[)')
FROM generate_series(1, 800) AS g;

-- The overnight import, which writes the two columns and not the range.
INSERT INTO ops.hire_bookings (asset_id, starts_at, ends_at, period)
SELECT 1 + (g % 200),
       TIMESTAMPTZ '2026-07-01 09:00:00+01' + ((g % 200) * INTERVAL '1 day'),
       TIMESTAMPTZ '2026-07-01 15:00:00+01' + ((g % 200) * INTERVAL '1 day'),
       NULL
FROM generate_series(1, 400) AS g;

-- DEFECT the-routine-reads-lastval-after-the-trigger-moved-the-sequence
--
-- The booking routine takes the key of the request it has just inserted from
-- lastval, and an audit trigger on that table inserts a row of its own first,
-- so lastval returns the audit key and every note is filed against a request
-- that does not exist.
--
-- lastval returns the value most recently produced by nextval in this session,
-- whichever sequence produced it. The routine was written when the request
-- table was the only thing with a sequence, and it was correct for two years.
-- The audit trigger was added afterwards by a different piece of work. The
-- identity value for the request is taken before any BEFORE trigger runs, so
-- the trigger's own sequence is the last one moved and it is the one lastval
-- answers with. Nothing fails: the note table has no foreign key, the numbers are
-- the right shape, and the notes screen shows an empty list for a request
-- rather than an error, which reads as a request nobody commented on.
--
-- Measured: 600 booking notes, none of which name a request that exists, filed
-- against 600 real requests.
--
-- INSERT ... RETURNING request_id into a variable is the fix and cannot be
-- broken by anything added later. Every request is recorded correctly, the
-- audit is complete and points at the right request, and the text of every
-- note is intact.
CREATE TABLE ops.booking_requests (
    request_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    asset_id     integer NOT NULL,
    requested_on date NOT NULL
);

CREATE TABLE ops.booking_audit (
    audit_id    integer GENERATED ALWAYS AS IDENTITY (START WITH 700) PRIMARY KEY,
    request_ref integer NOT NULL,
    logged_at   timestamptz NOT NULL
);

CREATE TABLE ops.booking_notes (
    note_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id integer NOT NULL,
    note       text NOT NULL
);

CREATE FUNCTION ops.fn_audit_booking_request() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.booking_audit (request_ref, logged_at)
    VALUES (NEW.request_id, TIMESTAMPTZ '2026-08-01 06:00:00+01');
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_booking_request
    BEFORE INSERT ON ops.booking_requests
    FOR EACH ROW EXECUTE FUNCTION ops.fn_audit_booking_request();

CREATE FUNCTION ops.fn_log_hire_booking(p_asset integer, p_note text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    v_request_id integer;
BEGIN
    INSERT INTO ops.booking_requests (asset_id, requested_on)
    VALUES (p_asset, DATE '2026-08-01');

    v_request_id := lastval();

    INSERT INTO ops.booking_notes (request_id, note)
    VALUES (v_request_id, p_note);
END;
$$;

SELECT ops.fn_log_hire_booking(1 + (g % 200), 'hire desk note ' || g)
FROM generate_series(1, 600) AS g;

-- DEFECT the-saved-searches-are-shorter-than-a-trigram
--
-- The saved searches are indexed for substring matching with trigrams, and
-- fifteen hundred of the terms are two characters long, which is shorter than
-- a trigram, so the index can do nothing for them.
--
-- A trigram index cuts each value into three character pieces and looks a
-- query up by the pieces it contains. A two character term contains no whole
-- piece of the indexed value, so the index cannot narrow the search at all and
-- the planner falls back to reading the table and matching every row. The
-- short terms are the depot codes and the size codes, which is exactly what
-- the counter staff type, and they are the searches run most often. The index
-- looks healthy, it is used constantly by the long terms, and the statistics
-- show it doing work, so the slow searches read as a busy afternoon rather
-- than as an index that cannot help.
--
-- Measured: 6,000 saved searches of which 1,500 are shorter than three
-- characters, against a single trigram index on the term.
--
-- Codes want matching by equality or by prefix against a plain index, and the
-- free text wants the trigram index it already has. Every term is stored
-- correctly, the index is valid and does answer the longer searches, and no
-- search returns a wrong row.
CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

CREATE TABLE catalog.search_terms (
    term_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    term      varchar(40) NOT NULL,
    saved_on  date NOT NULL,
    run_count integer NOT NULL
);

CREATE INDEX search_terms_term_trgm
    ON catalog.search_terms USING gin (term public.gin_trgm_ops);

INSERT INTO catalog.search_terms (term, saved_on, run_count)
SELECT CASE WHEN g % 4 = 0
            THEN chr(65 + (g % 26)) || chr(65 + ((g / 26) % 26))
            ELSE 'waterproof jacket ' || (1 + (g % 400))
       END,
       DATE '2026-03-01' + (g % 180),
       1 + (g % 900)
FROM generate_series(1, 6000) AS g;

-- DEFECT the-index-was-built-under-a-collation-version-the-system-no-longer-has
--
-- The region labels are sorted under a collation the database still records at
-- the version it was created with, and the operating system now provides a
-- different one, so the index on the label is ordered by rules that are no
-- longer in force.
--
-- A collation is a library, not a property of PostgreSQL, and its sort order
-- changes between releases of that library. PostgreSQL records the version it
-- built each collation against so it can tell you when the two have parted
-- company, and it tells you with a warning at every connection that touches
-- it, which is exactly the kind of warning that gets filtered out of the
-- application log. An index built under the old order is no longer in order
-- under the new one, so an index scan can pass straight over a row that
-- matches. Equality on a value that the two versions order differently can
-- therefore return nothing while the row sits in the table, and a range over
-- labels can miss its ends.
--
-- Measured: 6,000 region labels behind 1 index whose column carries a
-- collation whose recorded version does not match the one the system provides.
--
-- Rebuilding the index and running ALTER COLLATION ... REFRESH VERSION is the
-- whole fix, and it must be done in that order. Every label is present and
-- correct, the column is the right type and length, and every query that reads
-- the table without the index returns the right answer.
CREATE COLLATION analytics.region_legacy (provider = icu, locale = 'en-GB', version = '1.0');

CREATE TABLE analytics.region_labels (
    label_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region_code varchar(8) NOT NULL,
    label       varchar(60) COLLATE analytics.region_legacy NOT NULL,
    updated_on  date NOT NULL
);

CREATE INDEX region_labels_label ON analytics.region_labels (label);

INSERT INTO analytics.region_labels (region_code, label, updated_on)
SELECT 'RG-' || lpad((1 + (g % 120))::text, 4, '0'),
       'Region ' || (1 + (g % 120)) || ' district ' || (1 + (g % 50)),
       DATE '2026-02-01' + (g % 210)
FROM generate_series(1, 6000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.search_terms ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.search_terms:' || concat_ws('|', x.term, x.run_count))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.search_terms x
)
UPDATE catalog.search_terms t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.search_terms ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.search_terms ADD CONSTRAINT search_terms_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_search_terms_product_id ON catalog.search_terms (product_id);

ALTER TABLE support.attachment_refs ADD COLUMN attachment_id integer;

WITH p AS (
    SELECT attachment_id AS v, row_number() OVER (ORDER BY attachment_id) - 1 AS k
      FROM support.attachments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.attachments)
                 * power((abs(hashtext('support.attachment_refs:' || concat_ws('|', x.ticket_ref, x.filename))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.attachment_refs x
)
UPDATE support.attachment_refs t
   SET attachment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.attachment_refs ALTER COLUMN attachment_id SET NOT NULL;
ALTER TABLE support.attachment_refs ADD CONSTRAINT attachment_refs_attachment_id_fkey FOREIGN KEY (attachment_id) REFERENCES support.attachments (attachment_id);
CREATE INDEX ix_attachment_refs_attachment_id ON support.attachment_refs (attachment_id);

ALTER TABLE support.upload_digests ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.upload_digests:' || concat_ws('|', x.upload_ref, x.payload_sha))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.upload_digests x
)
UPDATE support.upload_digests t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.upload_digests ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.upload_digests ADD CONSTRAINT upload_digests_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_upload_digests_ticket_id ON support.upload_digests (ticket_id);
-- <<< relationships
