-- Cross River Trading Co. -- invoice imports, related products, handling
-- rates, export ledger, shift plans, parcel events
-- author: T. Marchetti
-- postgres: 18
--
-- What the supplier invoices said, what the website offers alongside a
-- product, what handling costs, what the finance export sent out, who is on
-- shift, and every scan a parcel collected on its way through.

-- DEFECT the-text-import-read-half-the-dates-the-american-way-round
--
-- The invoice import parses the date with a month first mask, and the file
-- writes it day first, so every date whose day is twelve or under was read
-- with the day and the month swapped.
--
-- The mask was set when the feed came from an American supplier and it was
-- never revisited when the feed was consolidated. A date such as 05/03 is
-- accepted by both masks and answers differently, which is the whole problem:
-- the import raises no error, because there is nothing wrong with the input.
-- Only the dates where the day exceeds twelve would have failed under the
-- wrong mask, and those are the ones that are right, because the parse fell
-- back. So the errors are invisible and the successes are wrong. The invoice
-- date drives the payment run, so those invoices are paid early or late by up
-- to eleven months, and the original string is still on the row, which is the
-- only reason this is provable at all.
--
-- Measured: 6,000 imported invoices of which 2,400 were read month first and
-- 2,200 hold a date that does not agree with the day first reading of the text
-- the file supplied, the remaining 200 being the days where the day and the
-- month are the same number.
--
-- Re-parsing the stored text with the right mask corrects every row, and the
-- import wants one mask that matches the feed. Every invoice is present, every
-- amount is right, and the source text was kept, which is what makes the fix
-- a single UPDATE rather than a re-import.
CREATE TABLE supply.invoice_imports (
    import_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_ref  varchar(18) NOT NULL,
    supplier_ref varchar(12) NOT NULL,
    date_text    varchar(10) NOT NULL,
    invoice_date date NOT NULL,
    amount_p     integer NOT NULL
);

INSERT INTO supply.invoice_imports (invoice_ref, supplier_ref, date_text, invoice_date, amount_p)
SELECT 'INV-' || lpad(g::text, 12, '0'),
       'SUP-' || lpad((1 + (g % 600))::text, 6, '0'),
       to_char(DATE '2026-01-01' + (g % 300), 'DD/MM/YYYY'),
       CASE WHEN extract(day FROM DATE '2026-01-01' + (g % 300)) <= 12
            THEN to_date(to_char(DATE '2026-01-01' + (g % 300), 'DD/MM/YYYY'), 'MM/DD/YYYY')
            ELSE DATE '2026-01-01' + (g % 300)
       END,
       5000 + (g % 400000)
FROM generate_series(1, 6000) AS g;

-- DEFECT the-link-table-holds-both-directions-of-the-same-pair
--
-- The related products table holds a pair of products in one row, and twelve
-- hundred pairs are in it twice, once each way round.
--
-- A relationship that has no direction wants storing once, with a rule that
-- says which of the two goes in the first column. There is no such rule here.
-- The merchandising screen writes the pair as the buyer entered it, and the
-- weekly import writes it as the supplier's file lists it, and the two orders
-- disagree for about a fifth of the catalogue. Nothing rejects the second row,
-- because the unique constraint is on the pair in the order it is stored. The
-- product page shows the same accessory twice, the count of related products
-- is wrong, and removing the relationship from one screen leaves the other
-- half of it behind.
--
-- Measured: 6,000 related product rows of which 2,400 have a mirror row
-- holding the same pair the other way round, being 1,200 pairs stored twice.
--
-- Storing the pair with the lower product code first, under a check constraint
-- that says so, makes the duplicate impossible. Every row names two real
-- products and the relationship each row describes is true.
CREATE TABLE catalog.related_products (
    sku_a     varchar(16) NOT NULL,
    sku_b     varchar(16) NOT NULL,
    added_on  date NOT NULL,
    PRIMARY KEY (sku_a, sku_b)
);

INSERT INTO catalog.related_products (sku_a, sku_b, added_on)
SELECT 'SKU-' || lpad(g::text, 8, '0'),
       'SKU-' || lpad((20000 + g)::text, 8, '0'),
       DATE '2026-02-10' + (g % 200)
FROM generate_series(1, 4800) AS g;

-- The same pairs as the supplier's file lists them.
INSERT INTO catalog.related_products (sku_a, sku_b, added_on)
SELECT 'SKU-' || lpad((20000 + g)::text, 8, '0'),
       'SKU-' || lpad(g::text, 8, '0'),
       DATE '2026-03-15' + (g % 100)
FROM generate_series(1, 1200) AS g;

-- DEFECT the-same-amount-with-two-scales-groups-as-two-suppliers
--
-- The handling rate is numeric with no declared scale, so the same rate is
-- stored as 2.5 by one screen and 2.50 by another. The two are equal as
-- numbers and different as text, and the rate card report groups them as text.
--
-- Numeric without a scale keeps whatever scale the value arrived with, which
-- is the right behaviour for a column that must not round anything. Equality
-- ignores the trailing zero, so every arithmetic check passes and every join
-- on the number matches. The rate card report builds its groups by casting the
-- rate to text, because the heading is printed from the same expression, and
-- the cast is faithful to what is stored. So the report shows twelve rate
-- bands where the business has six, each one split between the screen that
-- entered it and the file that loaded it.
--
-- Measured: 12,000 handling rates holding 6 distinct values as numbers and 12
-- as text.
--
-- Declaring the column numeric(8,2) normalises every row and the report can go
-- on grouping however it likes. Every rate is exact, every comparison between
-- rates is right, and no total is out by a penny.
CREATE TABLE catalog.handling_rates (
    rate_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    band_code  varchar(8) NOT NULL,
    rate_gbp   numeric NOT NULL,
    set_on     date NOT NULL
);

INSERT INTO catalog.handling_rates (depot_code, band_code, rate_gbp, set_on)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       'BND-' || lpad((1 + (g % 6))::text, 3, '0'),
       CASE WHEN (g / 6) % 2 = 0
            THEN ((1 + (g % 6)) + 0.5)::numeric
            ELSE to_char((1 + (g % 6)) + 0.5, 'FM999990.00')::numeric
       END,
       DATE '2026-01-20' + (g % 240)
FROM generate_series(1, 12000) AS g;

-- DEFECT the-export-rounds-every-key-above-two-to-the-fifty-third
--
-- The finance export reads settlement keys through a reader that holds every
-- number as a double, so twelve hundred keys above two to the fifty third came
-- back changed.
--
-- A double holds integers exactly up to two to the fifty third and then in
-- steps of two, so an odd key above that line cannot be represented and is
-- rounded to its even neighbour. The keys crossed that line eighteen months
-- ago, when the settlement sequence was moved onto a shared range. The export
-- is JSON and the reader is a general purpose one that parses every number the
-- same way, which is exactly what it is documented to do. The keys still look
-- right, because they are the same length and differ only in the last digit,
-- and the export reconciles on totals rather than on keys.
--
-- Measured: 6,000 settlement keys exported, of which 1,200 do not match the
-- key they were read from.
--
-- Exporting the key as a string is a one line change and every reader handles
-- it. The source table is correct, the totals agree, and every exported row
-- corresponds to a real settlement.
CREATE TABLE payments.settlement_keys (
    settlement_key bigint PRIMARY KEY,
    merchant_ref   varchar(12) NOT NULL,
    amount_p       integer NOT NULL,
    settled_on     date NOT NULL
);

CREATE TABLE analytics.export_ledger (
    export_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    settlement_key bigint NOT NULL,
    amount_p       integer NOT NULL,
    exported_at    timestamptz NOT NULL
);

INSERT INTO payments.settlement_keys (settlement_key, merchant_ref, amount_p, settled_on)
SELECT CASE WHEN g % 5 = 0
            THEN 9007199254740993 + ((g / 5) * 2)
            ELSE 4500000000 + g
       END,
       'MER-' || lpad((1 + (g % 900))::text, 6, '0'),
       100 + (g % 90000),
       DATE '2026-07-01' + (g % 80)
FROM generate_series(1, 6000) AS g;

-- The export, as the reader gave the keys back.
INSERT INTO analytics.export_ledger (settlement_key, amount_p, exported_at)
SELECT settlement_key::float8::bigint, amount_p,
       TIMESTAMPTZ '2026-09-19 02:00:00+01' + (amount_p * INTERVAL '1 second')
FROM payments.settlement_keys;

-- DEFECT the-column-was-created-quoted-so-only-one-spelling-of-it-works
--
-- The shift plan columns were created with quoted mixed case names, so every
-- statement that touches them must quote them in exactly that case, and any
-- that does not fails outright.
--
-- The table was generated from a spreadsheet whose headings became the column
-- names, capitals, spaces and all. PostgreSQL folds an unquoted identifier to
-- lower case, so the column called Shift Code can only ever be written as
-- "Shift Code": shift_code is a different name, and Shift_Code is the same as
-- shift_code and equally wrong. Every query against the table is therefore
-- copy and pasted from one that worked, and the one that got it wrong failed
-- immediately with a column not found error, which is at least honest. The
-- cost is that nothing generic can touch this table: no view built by a tool,
-- no ORM mapping, and no ad hoc query typed from memory.
--
-- Measured: 9,000 shift plans in a table with 3 columns whose names are not
-- their own lower case form.
--
-- Renaming the columns to lower case with underscores is three statements and
-- one pass through the queries that name them. Every column holds the right
-- data, the table is keyed and indexed properly, and every statement that does
-- quote the names correctly works exactly as intended.
CREATE TABLE ops.shift_plans (
    plan_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    "Shift Code" varchar(10) NOT NULL,
    "Depot Code" varchar(12) NOT NULL,
    "Planned On" date NOT NULL,
    headcount integer NOT NULL
);

INSERT INTO ops.shift_plans ("Shift Code", "Depot Code", "Planned On", headcount)
SELECT 'SH' || lpad((1 + (g % 3))::text, 2, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-06-01' + (g % 110),
       4 + (g % 30)
FROM generate_series(1, 9000) AS g;

-- DEFECT each-partition-was-given-its-own-sequence-so-the-keys-repeat
--
-- The parcel event partitions were each created with a default of their own
-- sequence, so the event key restarts at one in every month and the same key
-- names three different events.
--
-- The parent was created without a key, because a partitioned table can only
-- be keyed on something that includes the partition column and nobody wanted a
-- two column key. The partitions were then created one at a time by a script
-- that set up a sequence and a default alongside each one, which looks tidy
-- and reads as though each month is self contained. Nothing across the
-- partitions is unique, so nothing objects. Every join to a parcel event by
-- key alone returns one row per month, which triples the row count on the
-- tracking report, and the support tool that looks an event up by key shows
-- whichever month it found first.
--
-- Measured: 9,000 parcel events across three monthly partitions, of which
-- 3,000 keys appear in more than one partition, on a parent carrying no index
-- at all.
--
-- One sequence for the table, or a key that includes the month, makes an event
-- addressable again. Every event is in the right partition for its date, every
-- key is unique inside its own partition, and no partition has ever raised a
-- duplicate.
CREATE TABLE fulfilment.parcel_events (
    event_id    bigint NOT NULL,
    event_month date NOT NULL,
    parcel_ref  varchar(18) NOT NULL,
    event_code  varchar(12) NOT NULL
) PARTITION BY RANGE (event_month);

CREATE SEQUENCE fulfilment.parcel_events_jul_seq;
CREATE SEQUENCE fulfilment.parcel_events_aug_seq;
CREATE SEQUENCE fulfilment.parcel_events_sep_seq;

CREATE TABLE fulfilment.parcel_events_2026_07 PARTITION OF fulfilment.parcel_events
    FOR VALUES FROM ('2026-07-01') TO ('2026-08-01');
CREATE TABLE fulfilment.parcel_events_2026_08 PARTITION OF fulfilment.parcel_events
    FOR VALUES FROM ('2026-08-01') TO ('2026-09-01');
CREATE TABLE fulfilment.parcel_events_2026_09 PARTITION OF fulfilment.parcel_events
    FOR VALUES FROM ('2026-09-01') TO ('2026-10-01');

ALTER TABLE fulfilment.parcel_events_2026_07
    ALTER COLUMN event_id SET DEFAULT nextval('fulfilment.parcel_events_jul_seq');
ALTER TABLE fulfilment.parcel_events_2026_08
    ALTER COLUMN event_id SET DEFAULT nextval('fulfilment.parcel_events_aug_seq');
ALTER TABLE fulfilment.parcel_events_2026_09
    ALTER COLUMN event_id SET DEFAULT nextval('fulfilment.parcel_events_sep_seq');

INSERT INTO fulfilment.parcel_events_2026_07 (event_month, parcel_ref, event_code)
SELECT DATE '2026-07-01' + (g % 31),
       'PCL-' || lpad((1 + (g % 4000))::text, 13, '0'),
       CASE WHEN g % 3 = 0 THEN 'COLLECTED' WHEN g % 3 = 1 THEN 'AT_HUB' ELSE 'OUT_FOR_DEL' END
FROM generate_series(1, 3000) AS g;

INSERT INTO fulfilment.parcel_events_2026_08 (event_month, parcel_ref, event_code)
SELECT DATE '2026-08-01' + (g % 31),
       'PCL-' || lpad((1 + (g % 4000))::text, 13, '0'),
       CASE WHEN g % 3 = 0 THEN 'COLLECTED' WHEN g % 3 = 1 THEN 'AT_HUB' ELSE 'OUT_FOR_DEL' END
FROM generate_series(1, 3000) AS g;

INSERT INTO fulfilment.parcel_events_2026_09 (event_month, parcel_ref, event_code)
SELECT DATE '2026-09-01' + (g % 30),
       'PCL-' || lpad((1 + (g % 4000))::text, 13, '0'),
       CASE WHEN g % 3 = 0 THEN 'COLLECTED' WHEN g % 3 = 1 THEN 'AT_HUB' ELSE 'OUT_FOR_DEL' END
FROM generate_series(1, 3000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.related_products ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.related_products:' || concat_ws('|', x.sku_a, x.sku_b))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.related_products x
)
UPDATE catalog.related_products t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.related_products ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.related_products ADD CONSTRAINT related_products_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_related_products_product_id ON catalog.related_products (product_id);

ALTER TABLE ops.shift_plans ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.shift_plans:' || concat_ws('|', x."Shift Code", x."Depot Code", x.headcount))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.shift_plans x
)
UPDATE ops.shift_plans t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.shift_plans ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.shift_plans ADD CONSTRAINT shift_plans_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_shift_plans_store_id ON ops.shift_plans (store_id);

ALTER TABLE payments.settlement_keys ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.settlement_keys:' || concat_ws('|', x.settlement_key, x.merchant_ref, x.amount_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.settlement_keys x
)
UPDATE payments.settlement_keys t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.settlement_keys ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.settlement_keys ADD CONSTRAINT settlement_keys_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_settlement_keys_transaction_id ON payments.settlement_keys (transaction_id);

ALTER TABLE supply.invoice_imports ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.invoice_imports:' || concat_ws('|', x.invoice_ref, x.supplier_ref, x.date_text, x.amount_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.invoice_imports x
)
UPDATE supply.invoice_imports t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.invoice_imports ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.invoice_imports ADD CONSTRAINT invoice_imports_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_invoice_imports_supplier_id ON supply.invoice_imports (supplier_id);
-- <<< relationships
