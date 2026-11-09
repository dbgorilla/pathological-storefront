-- Cross River Trading Co. -- pallet labels, settlement totals, supplier sites,
-- round stops, daily takings, account flags
-- author: T. Marchetti
-- postgres: 18
--
-- The pallet label print log, the card settlement file, the supplier site
-- register, the van round and its stops, the daily takings summary on the
-- finance dashboard, and the account flag the old system still writes.

-- DEFECT index-leads-with-a-column-that-has-one-value
--
-- The label print log carries a two column index, leading with the region.
--
-- Cross River trades in one region and always has. The column was added for a
-- European expansion that was cancelled, and every row says UK. An index that
-- leads with a column holding one value does no narrowing at all on its first
-- column, so every lookup by print time walks the whole index in region order
-- before it can use the second column, and the index is the size of the table
-- while behaving like a sequential scan with extra steps.
--
-- Measured: 3,000 label prints, one distinct region code, and the index
-- leading with that column.
--
-- Reversing the columns makes the index useful, or dropping it costs nothing.
-- An unused index still has to be maintained on every insert, which this table
-- takes several thousand of a day.
CREATE TABLE ops.pallet_labels (
    print_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region_code varchar(4) NOT NULL,
    pallet_ref  varchar(16) NOT NULL,
    depot_code  varchar(12) NOT NULL,
    printed_at  timestamptz NOT NULL
);

INSERT INTO ops.pallet_labels (region_code, pallet_ref, depot_code, printed_at)
SELECT 'UK',
       'PAL-' || lpad(g::text, 8, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-06-01 04:00:00+01' + (g * INTERVAL '9 minutes')
FROM generate_series(1, 3000) AS g;

CREATE INDEX pallet_labels_region_printed_idx
    ON ops.pallet_labels (region_code, printed_at);

-- DEFECT double-precision-money-column-does-not-add-up
--
-- Card settlement lines are held in a double precision column, which was the
-- default type in the tool that generated the table.
--
-- Double precision is binary floating point and cannot hold most decimal
-- amounts exactly. Each line is a little out, the error accumulates across a
-- settlement batch, and the batch total does not equal the total of the same
-- lines added up in decimal. The difference is fractions of a penny per batch,
-- which is enough to make the settlement file disagree with the bank and not
-- enough to point at anything.
--
-- Measured: 2,000 settlement lines across 40 batches, and on 20 of those
-- batches the floating point total differs from the decimal total of the same
-- rows, which is kept alongside for exactly this reason.
--
-- numeric is the type for money. The reconciliation is done by a person who
-- has learned to ignore differences under a penny, which also hides real ones.
CREATE TABLE payments.settlement_lines (
    line_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_ref    varchar(16) NOT NULL,
    merchant_ref varchar(12) NOT NULL,
    amount       double precision NOT NULL,
    amount_exact numeric(12,2) NOT NULL,
    settled_on   date NOT NULL
);

INSERT INTO payments.settlement_lines (batch_ref, merchant_ref, amount, amount_exact, settled_on)
SELECT 'BATCH-' || lpad((1 + (g % 40))::text, 4, '0'),
       'MER-' || lpad((1 + (g % 25))::text, 4, '0'),
       (12.07 + (g % 350) * 0.07)::numeric(12,2)::double precision,
       (12.07 + (g % 350) * 0.07)::numeric(12,2),
       DATE '2026-07-01' + (g % 30)
FROM generate_series(1, 2000) AS g;

-- DEFECT check-constraint-written-so-it-can-never-fail
--
-- The supplier site register requires a contact name, and there is a check
-- constraint on the column that says so.
--
-- The constraint tests that the trimmed length is zero or more. Every string
-- has a length of zero or more, including the empty one, so the constraint
-- accepts everything the column can hold and has never rejected a row. It was
-- meant to say greater than zero. It is in the schema, it is in the review
-- that signed the schema off, and it does nothing.
--
-- Measured: 900 supplier sites, 180 of them with a blank contact name, all of
-- them accepted by a constraint written to forbid exactly that.
--
-- A constraint that cannot fail is worse than no constraint, because the next
-- person to read the table sees the guarantee and writes code that relies on
-- it. The blank names surface when a delivery needs a signature.
CREATE TABLE supply.supplier_sites (
    site_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref varchar(12) NOT NULL,
    site_name    varchar(60) NOT NULL,
    contact_name varchar(60) NOT NULL,
    opened_on    date NOT NULL,
    CONSTRAINT supplier_sites_contact_present CHECK (length(trim(contact_name)) >= 0)
);

INSERT INTO supply.supplier_sites (supplier_ref, site_name, contact_name, opened_on)
SELECT 'SUP-' || lpad((1 + (g % 70))::text, 3, '0'),
       'Site ' || g,
       CASE WHEN g % 5 = 0 THEN '' ELSE 'Contact ' || g END,
       DATE '2023-01-01' + (g % 1100)
FROM generate_series(1, 900) AS g;

-- DEFECT on-delete-set-null-against-a-not-null-column
--
-- A round stop belongs to a van round, and the foreign key is declared ON
-- DELETE SET NULL so that retiring a round leaves its history behind.
--
-- The column is NOT NULL. Setting it to null is the one thing that cannot
-- happen, so deleting a van round does not leave history behind: it raises a
-- not null violation and the delete fails. The referential action and the
-- column definition each look correct on their own and contradict each other.
--
-- Measured: the foreign key on fulfilment.round_stops carries the set null
-- action against a column declared NOT NULL.
--
-- ON DELETE SET NULL wants a nullable column; keeping the history wants the
-- round retired by a flag rather than deleted. Rounds are retired perhaps
-- twice a year, so the failure is rare enough to be remembered as a one off
-- each time it happens.
CREATE TABLE fulfilment.van_rounds (
    round_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    round_code varchar(12) NOT NULL UNIQUE,
    depot_code varchar(12) NOT NULL,
    opened_on  date NOT NULL
);

CREATE TABLE fulfilment.round_stops (
    stop_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    round_id    integer NOT NULL REFERENCES fulfilment.van_rounds (round_id) ON DELETE SET NULL,
    address_ref varchar(16) NOT NULL,
    stop_no     integer NOT NULL,
    called_on   date NOT NULL
);

INSERT INTO fulfilment.van_rounds (round_code, depot_code, opened_on)
SELECT 'RND-' || lpad(g::text, 6, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2024-02-01' + (g % 800)
FROM generate_series(1, 120) AS g;

INSERT INTO fulfilment.round_stops (round_id, address_ref, stop_no, called_on)
SELECT r.round_id,
       'ADDR-' || lpad(((r.round_id * 31 + s) % 4000)::text, 6, '0'),
       s,
       DATE '2026-07-01' + (s % 20)
FROM fulfilment.van_rounds r,
     generate_series(1, 12) AS s;

-- DEFECT materialised-view-has-not-been-refreshed-since-it-was-created
--
-- The finance dashboard reads daily takings from a materialised view, which
-- was built to keep a heavy aggregate off the till table.
--
-- A materialised view holds the rows it held when it was last refreshed.
-- Nothing refreshes this one: there is no job, no trigger and no line in the
-- deployment that touches it. It answers instantly and it answers with the
-- data as it stood on the day the view was created, which is why the
-- dashboard's recent days look quiet.
--
-- Measured: 2,000 till takings rows, and the view accounting for 1,600 of
-- them. The 400 missing are every takings row written since the view was
-- created.
--
-- A refresh in the nightly schedule fixes it, and so does an ordinary view if
-- the aggregate is cheap enough. The dashboard is read every morning and the
-- numbers move, because the view still holds days the business is still
-- trading through, so nobody reads it as frozen.
CREATE TABLE storefront.till_takings (
    taking_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    taken_on   date NOT NULL,
    till_no    integer NOT NULL,
    amount     numeric(12,2) NOT NULL
);

INSERT INTO storefront.till_takings (depot_code, taken_on, till_no, amount)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-06-01' + (g % 40),
       1 + (g % 6),
       (80 + (g % 1400))::numeric(12,2)
FROM generate_series(1, 1600) AS g;

CREATE MATERIALIZED VIEW analytics.mv_daily_takings AS
SELECT taken_on,
       count(*) AS takings_rows,
       sum(amount) AS takings
FROM storefront.till_takings
GROUP BY taken_on;

-- Trading since the view was built.
INSERT INTO storefront.till_takings (depot_code, taken_on, till_no, amount)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-07-11' + (g % 20),
       1 + (g % 6),
       (80 + (g % 1400))::numeric(12,2)
FROM generate_series(1, 400) AS g;

-- DEFECT one-flag-column-holds-eight-spellings-of-two-answers
--
-- The account flag says whether an account is on stop. Three systems write it
-- and none of them agrees with the others on how to spell yes.
--
-- The column is text, so it takes Y, y, 1 and true from the three writers, and
-- N, n, 0 and false for the other answer. Every reader has to know all eight,
-- and a reader that checks for one spelling quietly treats the other three as
-- the opposite answer. An account on stop under a spelling the credit check
-- does not know about is an account that can still order.
--
-- Measured: 1,600 account flags holding 8 distinct values between them, four
-- meaning yes and four meaning no.
--
-- A boolean column takes one of two values and a check constraint on text
-- takes one of a named set. Each writer is correct by its own convention,
-- which is why this has survived three rewrites of the code around it.
CREATE TABLE legacy.account_flags (
    flag_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    flag_name   varchar(24) NOT NULL,
    flag_value  varchar(8) NOT NULL,
    written_by  varchar(24) NOT NULL,
    written_at  timestamptz NOT NULL
);

INSERT INTO legacy.account_flags (account_ref, flag_name, flag_value, written_by, written_at)
SELECT 'ACC-' || lpad((1 + (g % 900))::text, 5, '0'),
       'on_stop',
       (ARRAY['Y', 'N', 'y', 'n', '1', '0', 'true', 'false'])[1 + (g % 8)],
       (ARRAY['ledger', 'ledger', 'counter', 'counter', 'web', 'web', 'web', 'web'])[1 + (g % 8)],
       TIMESTAMPTZ '2026-05-01 08:00:00+01' + (g * INTERVAL '17 minutes')
FROM generate_series(1, 1600) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.pallet_labels ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.pallet_labels:' || concat_ws('|', x.region_code, x.pallet_ref, x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.pallet_labels x
)
UPDATE ops.pallet_labels t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.pallet_labels ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.pallet_labels ADD CONSTRAINT pallet_labels_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_pallet_labels_warehouse_id ON ops.pallet_labels (warehouse_id);

ALTER TABLE storefront.till_takings ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('storefront.till_takings:' || concat_ws('|', x.depot_code, x.till_no, x.amount))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.till_takings x
)
UPDATE storefront.till_takings t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.till_takings ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE storefront.till_takings ADD CONSTRAINT till_takings_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_till_takings_store_id ON storefront.till_takings (store_id);
-- <<< relationships
