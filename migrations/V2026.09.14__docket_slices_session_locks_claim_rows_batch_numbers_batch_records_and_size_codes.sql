-- Cross River Trading Co. -- docket slices, session locks, claim rows,
-- batch numbers, batch records, size codes
-- author: T. Marchetti
-- postgres: 18
--
-- How a docket is broken into sliced work, what holds a resource while a
-- session runs, what has been claimed back from a supplier, how a payment run
-- is numbered, when a goods batch expires, and what sizes a product comes in.

-- DEFECT the-default-partition-is-collecting-rows-that-should-have-had-their-own
--
-- The docket slices are partitioned by month, the partitions run out at the
-- end of June, and a default partition catches everything after that, so
-- five and a half thousand slices are in one undivided heap instead of the
-- months they belong to.
--
-- A default partition is a safety net: it exists so an insert outside every
-- declared range succeeds rather than failing. That is the whole point of it
-- and it is also the whole problem, because the failure is the only signal
-- that the partitions have run out. The job that creates next month's
-- partition stopped running in June, and nothing noticed, because inserts
-- kept working. Two costs follow. Every query that filters on a date after
-- June has to read the default partition in full, since the planner knows
-- only that it holds whatever did not fit elsewhere, so partition pruning
-- does nothing for the most recent and most queried data. And a new
-- partition cannot now be created for July without either moving those rows
-- or detaching the default first, which turns a routine maintenance job into
-- a planned outage.
--
-- Measured: 18,000 docket slices of which 5,451 are in the default
-- partition, behind 6 monthly partitions that end at the start of July.
--
-- Creating the missing partitions and an alert on default partition row
-- count is the fix; the default itself is worth keeping, empty. Every slice
-- carries a real docket reference, date and unit count, and the six monthly
-- partitions hold exactly the rows they should.
CREATE TABLE ops.docket_slices (
    slice_id     bigint GENERATED ALWAYS AS IDENTITY,
    docket_ref   text NOT NULL,
    sliced_on    date NOT NULL,
    units        integer NOT NULL
) PARTITION BY RANGE (sliced_on);

CREATE TABLE ops.docket_slices_2026_01 PARTITION OF ops.docket_slices
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE ops.docket_slices_2026_02 PARTITION OF ops.docket_slices
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE ops.docket_slices_2026_03 PARTITION OF ops.docket_slices
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');
CREATE TABLE ops.docket_slices_2026_04 PARTITION OF ops.docket_slices
    FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');
CREATE TABLE ops.docket_slices_2026_05 PARTITION OF ops.docket_slices
    FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
CREATE TABLE ops.docket_slices_2026_06 PARTITION OF ops.docket_slices
    FOR VALUES FROM ('2026-06-01') TO ('2026-07-01');
CREATE TABLE ops.docket_slices_default PARTITION OF ops.docket_slices DEFAULT;

INSERT INTO ops.docket_slices (docket_ref, sliced_on, units)
SELECT
    'DKT-' || lpad(g::text, 7, '0'),
    DATE '2026-01-01' + ((g % 260) || ' days')::interval,
    ((g % 250) + 1)
FROM generate_series(1, 18000) g;

-- DEFECT autovacuum-was-switched-off-on-the-table-that-churns-most
--
-- Autovacuum is switched off on the session lock table, which is the highest
-- churn table in the database: every row is written, updated once when the
-- lock is released, and deleted within the hour.
--
-- Turning autovacuum off on a table does not stop the table needing vacuum,
-- it stops anything doing it. Dead rows accumulate at the rate of the churn,
-- the table bloats, and every scan of it reads the dead rows as well as the
-- live ones, so a table that holds a few thousand live locks can occupy
-- hundreds of megabytes and take a hundred times as long to scan as it
-- should. It was switched off during an incident, because autovacuum was
-- holding a lock the release job wanted and turning it off made the symptom
-- stop that night. There is a second and worse consequence: autovacuum is
-- also what advances the frozen transaction id, and a table excluded from it
-- eventually forces the whole database into a protective shutdown to prevent
-- wraparound, which is an outage for everything, not just this table.
--
-- Measured: 15,000 session locks on a table whose storage options carry
-- autovacuum_enabled switched off.
--
-- Turning it back on, and tuning the thresholds rather than disabling it, is
-- the fix; the lock contention it was hiding is a separate and smaller
-- problem. Every lock names a real session and resource, and the held times
-- are correct.
CREATE TABLE ops.session_locks (
    lock_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_ref  text NOT NULL,
    resource_ref text NOT NULL,
    held_from    timestamptz NOT NULL,
    held_until   timestamptz
);

ALTER TABLE ops.session_locks SET (autovacuum_enabled = false);

INSERT INTO ops.session_locks (session_ref, resource_ref, held_from, held_until)
SELECT
    'SES-' || lpad(((g % 9000) + 1)::text, 7, '0'),
    'RES-' || lpad(((g % 1200) + 1)::text, 6, '0'),
    TIMESTAMPTZ '2026-09-01 00:00:00+01' + ((g % 20000) || ' seconds')::interval,
    CASE WHEN g % 12 = 0 THEN NULL
         ELSE TIMESTAMPTZ '2026-09-01 00:00:40+01' + ((g % 20000) || ' seconds')::interval END
FROM generate_series(1, 15000) g;

-- DEFECT the-statistics-target-was-set-to-one-so-the-planner-sees-almost-nothing
--
-- The claim status column has its statistics target set to one, so ANALYZE
-- keeps a single most common value for it, and the status distribution is
-- extremely skewed: almost everything is settled and the eighty claims that
-- are not are the only ones anybody looks for.
--
-- With a target of one, the planner learns that settled is common and learns
-- nothing about anything else. Every other status falls into a single
-- undifferentiated remainder and is estimated from it, so a query for the
-- disputed claims is estimated at thousands of rows when it returns forty,
-- and the planner takes a sequential scan over the index that exists
-- precisely for that query. The setting was applied during a tuning exercise
-- to make ANALYZE cheaper on a large table, where the column was believed to
-- be almost constant and therefore not worth sampling. It is almost
-- constant. The rare values are the entire reason the table is queried.
--
-- Measured: 20,000 claims of which 80 are not settled, on a column whose
-- statistics target is 1 and for which ANALYZE has recorded 1 most common
-- value.
--
-- Resetting the target to the default, or raising it, lets the planner see
-- the rare statuses and use the index. Every claim names a real supplier,
-- the values are right, and the index on the status is valid and correctly
-- maintained.
CREATE TABLE analytics.claim_rows (
    claim_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    claim_status text NOT NULL,
    supplier_ref text NOT NULL,
    claim_value_p integer NOT NULL
);

-- Nearly every claim is settled. The handful that are not are the only ones
-- anybody queries for.
INSERT INTO analytics.claim_rows (claim_status, supplier_ref, claim_value_p)
SELECT
    CASE WHEN g % 500 = 0 THEN 'disputed' WHEN g % 250 = 0 THEN 'open' ELSE 'settled' END,
    'SUP-' || lpad(((g % 500) + 1)::text, 4, '0'),
    ((g % 60000) + 500)
FROM generate_series(1, 20000) g;

ALTER TABLE analytics.claim_rows ALTER COLUMN claim_status SET STATISTICS 1;

CREATE INDEX idx_claim_rows_status ON analytics.claim_rows (claim_status);

ANALYZE analytics.claim_rows;

-- DEFECT the-sequence-caches-a-thousand-so-every-session-burns-a-block-of-numbers
--
-- The batch number sequence caches a thousand values, so every session that
-- takes a single number reserves a thousand and discards the rest when it
-- disconnects.
--
-- A sequence cache is per session and per backend. It exists to avoid
-- touching the sequence on every call under heavy concurrency, and a cache
-- of a thousand is appropriate for a sequence called a thousand times a
-- second by a long lived connection. This one is called a handful of times
-- by each nightly run, from a connection that exits afterwards, so nine
-- hundred and ninety odd numbers are burned every time. Nothing breaks: the
-- numbers are still unique and still ascending within a session, which is
-- all a sequence promises. But the batch number is quoted to the bank on the
-- settlement file, the finance team reads the gaps as missing batches, and
-- reconciling a gap that does not correspond to anything is a morning's work
-- each time it is queried. Worse, numbers handed out by two concurrent
-- sessions interleave in blocks, so batch numbers are not in the order the
-- batches ran, which is the one thing everybody assumes they are.
--
-- Measured: 9,000 payment batches numbered from 1 sequence whose cache is
-- set to 1000.
--
-- Setting the cache to one costs nothing at this call rate and makes the
-- numbers dense and ordered again. Every batch number is unique, every run
-- label and start time is correct, and no batch is missing.
CREATE SEQUENCE payments.batch_no_seq CACHE 1000;

CREATE TABLE payments.batch_numbers (
    batch_no     bigint PRIMARY KEY DEFAULT nextval('payments.batch_no_seq'),
    run_label    text NOT NULL,
    run_started  timestamptz NOT NULL
);

INSERT INTO payments.batch_numbers (run_label, run_started)
SELECT
    'RUN-' || lpad(g::text, 6, '0'),
    TIMESTAMPTZ '2026-06-01 01:00:00+01' + ((g % 9000) || ' minutes')::interval
FROM generate_series(1, 9000) g;

-- DEFECT the-not-null-was-added-not-valid-so-the-rows-already-there-keep-their-nulls
--
-- The expiry date was made mandatory with a NOT NULL constraint added NOT
-- VALID, which applies to every row written from that moment and to none of
-- the rows already there, so two thousand four hundred batches still carry
-- no expiry at all.
--
-- Adding NOT VALID is the standard way to make a rule mandatory without
-- taking the lock and the scan that checking the whole table requires, and
-- it is exactly right as the first of two steps. The second step is VALIDATE
-- CONSTRAINT, which does the scan without blocking writes, and it was never
-- run, because the first step made the errors stop and the ticket was
-- closed. The constraint reads as an ordinary NOT NULL everywhere except in
-- the one catalogue column that records whether it has been validated. So
-- the column is documented as mandatory, the application trusts it and no
-- longer checks, and a stock rotation report that orders by expiry silently
-- drops a fifth of the batches, which are then never pulled from the shelf.
--
-- Measured: 12,000 batch records of which 2,400 hold no expiry, under 1 not-
-- null constraint that is present and not validated.
--
-- Backfilling the expiry from the goods receipt and then running VALIDATE
-- CONSTRAINT completes the change that was started. Every batch reference is
-- unique, every supplier is real, and the 9,600 batches with an expiry carry
-- the right one.
CREATE TABLE supply.batch_records (
    record_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_ref    text NOT NULL,
    expires_on   date,
    supplier_ref text NOT NULL
);

INSERT INTO supply.batch_records (batch_ref, expires_on, supplier_ref)
SELECT
    'BAT-' || lpad(g::text, 7, '0'),
    CASE WHEN g % 5 = 0 THEN NULL
         ELSE DATE '2026-10-01' + ((g % 400) || ' days')::interval END,
    'SUP-' || lpad(((g % 500) + 1)::text, 4, '0')
FROM generate_series(1, 12000) g;

-- Added so that new batches must carry an expiry. The rows already here do not.
ALTER TABLE supply.batch_records
    ADD CONSTRAINT batch_records_expires_on_not_null NOT NULL expires_on NOT VALID;

-- DEFECT the-numbers-are-stored-as-text-so-they-sort-and-range-as-text
--
-- The size is stored as text and every size is a number, so the sizes sort
-- as words: 10 comes before 9, 2 comes after 19, and the size list on every
-- product page is in an order that is correct for text and nonsense for
-- clothing.
--
-- Text ordering compares character by character, so the first character
-- decides, and 1 sorts before 9 regardless of what follows. The column is
-- text because the sizing was going to include letters one day, which it
-- still does not, and because the import file has them quoted. There is an
-- index on it, which makes it worse rather than better: a range query for
-- sizes between eight and twelve is a text range, it uses the index happily,
-- and it returns the wrong set with no sign of trouble. The size list is
-- also what the size chart is printed from, so the printed chart runs 1, 10,
-- 11 and so on, and the buyers reorder it by hand every season.
--
-- Measured: 9,000 sizes of which 6,300 are ten or more and therefore sort
-- before size 9 in text order.
--
-- Storing the size as a numeric, or as an integer with a separate label
-- column for the day the letters arrive, fixes the ordering and the ranges
-- together. Every size is against the right product, every value is a valid
-- number, and the range labels are correct.
CREATE TABLE catalog.size_codes (
    size_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_ref  text NOT NULL,
    size_text    text NOT NULL,
    range_label  text NOT NULL
);

INSERT INTO catalog.size_codes (product_ref, size_text, range_label)
SELECT
    'PRD-' || lpad(g::text, 6, '0'),
    ((g % 30) + 1)::text,
    CASE WHEN g % 3 = 0 THEN 'womenswear' WHEN g % 3 = 1 THEN 'menswear' ELSE 'childrenswear' END
FROM generate_series(1, 9000) g;

CREATE INDEX idx_size_codes_size ON catalog.size_codes (size_text);

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE payments.batch_numbers ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.batch_numbers:' || concat_ws('|', x.run_label))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.batch_numbers x
)
UPDATE payments.batch_numbers t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.batch_numbers ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.batch_numbers ADD CONSTRAINT batch_numbers_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_batch_numbers_transaction_id ON payments.batch_numbers (transaction_id);

ALTER TABLE supply.batch_releases ADD COLUMN record_id integer;

WITH p AS (
    SELECT record_id AS v, row_number() OVER (ORDER BY record_id) - 1 AS k
      FROM supply.batch_records
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.batch_records)
                 * power((abs(hashtext('supply.batch_releases:' || concat_ws('|', x.batch_ref, x.released_by))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.batch_releases x
)
UPDATE supply.batch_releases t
   SET record_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.batch_releases ALTER COLUMN record_id SET NOT NULL;
ALTER TABLE supply.batch_releases ADD CONSTRAINT batch_releases_record_id_fkey FOREIGN KEY (record_id) REFERENCES supply.batch_records (record_id);
CREATE INDEX ix_batch_releases_record_id ON supply.batch_releases (record_id);
-- <<< relationships
