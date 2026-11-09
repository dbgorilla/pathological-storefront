-- Cross River Trading Co. -- shift logs, label codes, ledger counters,
-- page hits, vendor refs, queue items
-- author: T. Marchetti
-- postgres: 18
--
-- What hours were worked at each depot, how a shelf label is coded, where the
-- ledger counters stand, how often each page is read, which vendor a document
-- belongs to, and what is still waiting in the delivery queue.

-- DEFECT the-day-is-cut-in-utc-and-the-business-day-starts-an-hour-earlier
--
-- The logged day is stored as the date part of the timestamp read in UTC,
-- the depots are in London, and London is an hour ahead in summer, so every
-- log made in the first hour after midnight is filed against the previous
-- day.
--
-- A timestamptz holds an instant, not a date, and turning one into a date
-- requires choosing a zone. The cast used here chooses UTC, which is the
-- zone the server runs in and not the zone anybody works in. For eight
-- months of the year the two agree and nothing is visibly wrong. Between the
-- last Sunday in March and the last Sunday in October they are an hour
-- apart, and the hour that falls off the end of the day falls onto the day
-- before. The shift report is what the depot supervisors are paid against,
-- so a log at half past midnight pays the wrong day, and the correction
-- arrives from payroll a month later as a query about a shift nobody worked.
--
-- Measured: 12,000 shift logs of which 500 carry a stored day that does not
-- match the date of the same instant read in Europe/London.
--
-- Storing the day as the London date, or dropping the column and deriving it
-- with an explicit zone, removes the choice from the load. Every log names a
-- real depot, the instants are all correct, and the minutes worked are
-- right.
CREATE TABLE ops.shift_logs (
    log_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code   text NOT NULL,
    logged_at    timestamptz NOT NULL,
    logged_day   date NOT NULL,
    minutes_on   integer NOT NULL
);

INSERT INTO ops.shift_logs (depot_code, logged_at, logged_day, minutes_on)
SELECT
    'DEP-' || lpad(((g % 40) + 1)::text, 3, '0'),
    ts,
    (ts AT TIME ZONE 'UTC')::date,
    ((g % 480) + 1)
FROM generate_series(1, 12000) g
CROSS JOIN LATERAL (
    SELECT TIMESTAMPTZ '2026-06-01 00:30:00+01' + ((g % 3000) || ' hours')::interval AS ts
) t;

-- DEFECT one-side-of-the-join-is-collated-c-and-the-other-is-not
--
-- The label code column is declared COLLATE C while the database is
-- en_US.utf8, so the codes sort by byte value, and the picker query that
-- asks for everything between a and z quietly excludes every code that
-- starts with a capital letter.
--
-- A collation is what makes a text comparison mean something, and C means
-- compare the bytes. Under the database collation the letters interleave, so
-- an uppercase A sits next to a lowercase a and both are inside the range.
-- Under C every uppercase letter is below every lowercase one, so all of
-- them fall out of the bottom. The column was given the C collation for
-- speed, which is real: byte comparison is markedly faster, and on a code
-- column that was going to be all uppercase it costs nothing. Then the codes
-- stopped being all uppercase. The query does not fail, the index is used,
-- and the result is a quarter short.
--
-- Measured: 9,000 label codes of which 2,250 fall outside the range under
-- the column's own collation and inside it under the database default.
--
-- Dropping the collation from the column, or writing the range query with an
-- explicit collation, makes the two agree. Every code is unique, every label
-- text is correct, and the 6,750 lowercase codes are returned properly.
CREATE TABLE catalog.label_codes (
    label_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    label_code   text COLLATE "C" NOT NULL,
    label_text   text NOT NULL
);

INSERT INTO catalog.label_codes (label_code, label_text)
SELECT
    CASE WHEN g % 4 = 0
         THEN 'AL' || lpad(g::text, 6, '0')
         ELSE 'al' || lpad(g::text, 6, '0') END,
    'label ' || g
FROM generate_series(1, 9000) g;

CREATE INDEX idx_label_codes_code ON catalog.label_codes (label_code);

-- DEFECT the-counter-is-an-integer-and-it-is-two-thirds-of-the-way-to-the-ceiling
--
-- The ledger counters are stored in a four byte integer, which stops at
-- 2,147,483,647, and more than a thousand of them are already above two
-- billion.
--
-- An integer overflow in PostgreSQL is not a wraparound to a negative
-- number, which is what most people expect and would at least be visible. It
-- is an error: the update fails, the transaction rolls back, and the ledger
-- posting it was part of rolls back with it. So the failure mode is not a
-- wrong number, it is a payment run that stops, at a moment nobody chose, on
-- whichever counter crosses first. The column is an integer because it was a
-- count of documents and four bytes was plenty for that. It is now a count
-- of ledger movements, which is three orders of magnitude larger, and the
-- type was never revisited because nothing about the change touched the
-- schema.
--
-- Measured: 8,000 ledger counters of which 1,333 hold a value above two
-- billion, in a column whose maximum is 2,147,483,647.
--
-- Widening the column to bigint is an ALTER that rewrites the table and is
-- far cheaper now than during the incident. Every counter name is unique and
-- every value is the correct count of what it counts.
CREATE TABLE payments.ledger_counters (
    counter_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    counter_name  text NOT NULL,
    counter_value integer NOT NULL
);

INSERT INTO payments.ledger_counters (counter_name, counter_value)
SELECT
    'LDG-' || lpad(g::text, 6, '0'),
    1400000000 + ((g % 8000) * 90000)
FROM generate_series(1, 8000) g;

-- DEFECT the-hot-counter-is-indexed-so-every-increment-rewrites-the-index
--
-- There is a btree index on the hit count, which is the column the recorder
-- increments on every single request, so every increment writes an index
-- entry as well as a row.
--
-- PostgreSQL can usually update a row without touching any index, by writing
-- the new version on the same page and chaining it to the old one. That
-- optimisation is off the moment an indexed column changes. So an index on a
-- counter converts a cheap in page update into a full row rewrite plus an
-- index insert plus an index entry to clean up later, and it does so at
-- exactly the rate of the traffic. The index exists because someone wanted
-- the most visited pages, which is a reporting query that runs once a day
-- and could sort sixteen thousand rows without an index in a few
-- milliseconds. The cost is paid on every write to serve a read that happens
-- once.
--
-- Measured: 16,000 page counters behind 1 btree index on the counter column,
-- which every request updates.
--
-- Dropping the index removes the write cost entirely and the daily report
-- will not notice. Every path is unique, every count is accurate, and the
-- last hit time is right.
CREATE TABLE analytics.page_hits (
    page_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    page_path    text NOT NULL,
    hit_count    integer NOT NULL,
    last_hit_at  timestamptz NOT NULL
);

INSERT INTO analytics.page_hits (page_path, hit_count, last_hit_at)
SELECT
    '/p/' || lpad(g::text, 7, '0'),
    ((g % 5000) + 1),
    TIMESTAMPTZ '2026-09-01 00:00:00+01' + ((g % 40000) || ' seconds')::interval
FROM generate_series(1, 16000) g;

-- The counter is the column the hit recorder increments on every request.
CREATE INDEX idx_page_hits_count ON analytics.page_hits (hit_count);

-- DEFECT the-reference-is-text-with-no-key-behind-it-and-some-of-it-points-nowhere
--
-- The vendor reference is a plain text column with no foreign key behind it,
-- and two thousand of the documents name a vendor code that is not in the
-- vendor list.
--
-- Without a foreign key the database has no opinion about what that column
-- contains. It is text, the values look like vendor codes, every tool that
-- reads the schema will guess that they are vendor codes, and nothing
-- checks. The codes came in from a supplier portal that numbers its own
-- vendors independently, and the overlap with the internal list is partial.
-- The relationship is real and it is enforced nowhere, so it is enforced by
-- whoever writes the next query, differently each time. A report that joins
-- vendor to document silently loses those two thousand documents, and a
-- report that counts documents finds them, and the two numbers are then
-- reconciled by hand every month.
--
-- Measured: 14,000 vendor references of which 2,000 name a code absent from
-- the 600 vendors on file, under 0 foreign keys.
--
-- Adding the foreign key after the two thousand are resolved makes the guess
-- into a fact. Every document reference is unique, every date is right, and
-- the 12,000 references that do match point at the correct vendor.
CREATE TABLE supply.vendor_master (
    vendor_code  text PRIMARY KEY,
    vendor_name  text NOT NULL
);

INSERT INTO supply.vendor_master (vendor_code, vendor_name)
SELECT 'VEN-' || lpad(g::text, 5, '0'), 'vendor ' || g
FROM generate_series(1, 600) g;

CREATE TABLE supply.vendor_refs (
    ref_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vendor_ref   text NOT NULL,
    document_ref text NOT NULL,
    raised_on    date NOT NULL
);

INSERT INTO supply.vendor_refs (vendor_ref, document_ref, raised_on)
SELECT
    'VEN-' || lpad(((g % 700) + 1)::text, 5, '0'),
    'DOC-' || lpad(g::text, 7, '0'),
    DATE '2026-03-01' + ((g % 200) || ' days')::interval
FROM generate_series(1, 14000) g;

-- DEFECT count-star-counts-the-rows-the-outer-join-invented
--
-- The attempt count was filled in by a query that groups a left join and
-- counts star, and count star over a left join counts the row the join
-- invented for an item with no attempts, so every untried item came back as
-- one.
--
-- A left join guarantees at least one output row per left side row. When
-- there is no match the extra columns are null, and count star does not care
-- about null, because it counts rows. Counting the joined column instead,
-- count of the attempt id, would have returned zero, because that is what
-- counting a column does: it ignores nulls. The two forms are one word apart
-- and they differ only on exactly the rows this table cares about. The
-- consequence is that the retry job, which looks for items with no attempts,
-- finds none of the two thousand that have never been tried, and they sit in
-- the queue permanently, counted as in progress, retried by nobody.
--
-- Measured: 10,000 queue items of which 2,000 record 1 attempt and have no
-- attempt rows at all.
--
-- Counting the attempt id rather than star fixes the backfill and the two
-- thousand can be recomputed. Every payload reference is unique, every
-- attempt row is real, and the 8,000 items that were tried carry the right
-- count.
CREATE TABLE ops.queue_items (
    item_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payload_ref   text NOT NULL,
    attempt_count integer NOT NULL DEFAULT 0
);

CREATE TABLE ops.queue_attempts (
    attempt_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_id      integer NOT NULL REFERENCES ops.queue_items (item_id),
    attempted_at timestamptz NOT NULL,
    outcome      text NOT NULL
);

INSERT INTO ops.queue_items (payload_ref)
SELECT 'PAY-' || lpad(g::text, 7, '0')
FROM generate_series(1, 10000) g;

INSERT INTO ops.queue_attempts (item_id, attempted_at, outcome)
SELECT
    i.item_id,
    TIMESTAMPTZ '2026-09-10 00:00:00+01' + ((i.item_id % 5000) || ' seconds')::interval,
    CASE WHEN i.item_id % 3 = 0 THEN 'failed' ELSE 'delivered' END
FROM ops.queue_items i
WHERE i.item_id % 5 <> 0;

-- The backfill that filled in the attempt count.
UPDATE ops.queue_items q
SET attempt_count = s.n
FROM (
    SELECT i.item_id, count(*) AS n
    FROM ops.queue_items i
    LEFT JOIN ops.queue_attempts a ON a.item_id = i.item_id
    GROUP BY i.item_id
) s
WHERE s.item_id = q.item_id;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE payments.ledger_counters ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.ledger_counters:' || concat_ws('|', x.counter_name, x.counter_value))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.ledger_counters x
)
UPDATE payments.ledger_counters t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.ledger_counters ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.ledger_counters ADD CONSTRAINT ledger_counters_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_ledger_counters_transaction_id ON payments.ledger_counters (transaction_id);

ALTER TABLE supply.supplier_sites ADD COLUMN vendor_code text;

WITH p AS (
    SELECT vendor_code AS v, row_number() OVER (ORDER BY vendor_code) - 1 AS k
      FROM supply.vendor_master
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.vendor_master)
                 * power((abs(hashtext('supply.supplier_sites:' || concat_ws('|', x.supplier_ref, x.site_name, x.contact_name))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.supplier_sites x
)
UPDATE supply.supplier_sites t
   SET vendor_code = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.supplier_sites ALTER COLUMN vendor_code SET NOT NULL;
ALTER TABLE supply.supplier_sites ADD CONSTRAINT supplier_sites_vendor_code_fkey FOREIGN KEY (vendor_code) REFERENCES supply.vendor_master (vendor_code);
CREATE INDEX ix_supplier_sites_vendor_code ON supply.supplier_sites (vendor_code);

ALTER TABLE supply.vendor_master ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.vendor_master:' || concat_ws('|', x.vendor_code, x.vendor_name))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.vendor_master x
)
UPDATE supply.vendor_master t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.vendor_master ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.vendor_master ADD CONSTRAINT vendor_master_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_vendor_master_supplier_id ON supply.vendor_master (supplier_id);
-- <<< relationships
