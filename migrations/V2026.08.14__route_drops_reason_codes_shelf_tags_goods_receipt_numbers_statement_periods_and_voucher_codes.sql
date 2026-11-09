-- Cross River Trading Co. -- route drops, reason codes, shelf tags, goods
-- receipt numbers, statement periods, voucher codes
-- author: T. Marchetti
-- postgres: 18
--
-- The drops on a delivery route, the reason a thing was done, the tag on the
-- shelf edge, the number on a goods receipt, the period a statement covers, and
-- the voucher codes the marketing team hand out.

-- DEFECT the-parent-row-is-deleted-and-the-children-are-set-to-null
--
-- A drop belongs to a route plan. The foreign key is declared ON DELETE SET
-- NULL, so deleting a route plan leaves its drops behind with no route.
--
-- SET NULL was chosen so that deleting a cancelled route would not take the
-- delivery records with it, which is a reasonable thing to want and the wrong
-- way to get it. The drops survive, with nothing to say which route they were
-- on, and the column is nullable because it has to be for the action to be
-- legal. Every report that joins drops to routes loses them silently, and the
-- count of drops made never agrees with the sum of drops per route.
--
-- Measured: 4,500 route drops, of which 900 have no route plan, left behind by
-- 60 deleted routes.
--
-- ON DELETE RESTRICT plus a cancelled flag on the route keeps the history and
-- keeps the link. The orphaned drops are real deliveries that really happened,
-- so nothing about them looks wrong until somebody adds up two numbers that
-- were never going to match.
CREATE TABLE fulfilment.route_plans (
    plan_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    route_ref  varchar(16) NOT NULL UNIQUE,
    depot_code varchar(12) NOT NULL,
    plan_date  date NOT NULL
);

CREATE TABLE fulfilment.route_drops (
    drop_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    plan_id     integer REFERENCES fulfilment.route_plans (plan_id) ON DELETE SET NULL,
    stop_no     integer NOT NULL,
    account_ref varchar(12) NOT NULL,
    dropped_at  timestamptz NOT NULL
);

INSERT INTO fulfilment.route_plans (route_ref, depot_code, plan_date)
SELECT 'RTE-' || lpad(g::text, 8, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-02-02' + (g % 180)
FROM generate_series(1, 300) AS g;

INSERT INTO fulfilment.route_drops (plan_id, stop_no, account_ref, dropped_at)
SELECT p.plan_id,
       s,
       'ACC-' || lpad((1 + ((p.plan_id * 7 + s) % 400))::text, 5, '0'),
       (p.plan_date + TIME '07:00:00') AT TIME ZONE 'Europe/London' + (s * INTERVAL '25 minutes')
FROM fulfilment.route_plans AS p
CROSS JOIN generate_series(1, 15) AS s;

-- Sixty cancelled routes, deleted by the planner to clear the screen.
DELETE FROM fulfilment.route_plans WHERE plan_id % 5 = 0;

-- DEFECT two-schemas-hold-the-same-reference-list-and-they-have-drifted
--
-- The reason a thing was done is picked from a list of reason codes. There are
-- two lists, one in operations and one in support, and they were the same list
-- when they were copied.
--
-- They were copied because the two teams were on different release cycles and
-- neither wanted to wait for the other. Codes have been added to each since,
-- and not to the other. Worse, four codes exist in both lists with different
-- descriptions, so a reason recorded in one system reads as something else in
-- the other, and the weekly report that unions the two shows both descriptions
-- for the same code without saying which is which.
--
-- Measured: 60 reason codes in operations, 60 in support, 48 held in common,
-- and 4 of those 48 with different descriptions on each side.
--
-- One table in a shared schema, with a foreign key from both sides, is the fix
-- and the release cycle argument stopped applying three years ago. Both lists
-- are internally consistent and both are maintained, which is why neither team
-- believes theirs is the copy.
CREATE TABLE ops.reason_codes (
    reason_code varchar(8) PRIMARY KEY,
    description varchar(80) NOT NULL,
    added_on    date NOT NULL
);

CREATE TABLE support.reason_codes (
    reason_code varchar(8) PRIMARY KEY,
    description varchar(80) NOT NULL,
    added_on    date NOT NULL
);

INSERT INTO ops.reason_codes (reason_code, description, added_on)
SELECT 'RC-' || lpad(g::text, 4, '0'),
       'Reason ' || g,
       DATE '2021-06-01' + (g % 900)
FROM generate_series(1, 60) AS g;

INSERT INTO support.reason_codes (reason_code, description, added_on)
SELECT 'RC-' || lpad(g::text, 4, '0'),
       'Reason ' || g,
       DATE '2021-06-01' + (g % 900)
FROM generate_series(13, 72) AS g;

-- Four codes reworded on the support side and never on the operations side.
UPDATE support.reason_codes
SET description = 'Reason ' || substring(reason_code, 4)::integer || ' (revised)'
WHERE substring(reason_code, 4)::integer IN (17, 23, 37, 53);

-- DEFECT the-nightly-job-updates-every-row-to-the-value-it-already-had
--
-- The shelf tag job runs every night and sets the printed price on every tag
-- from the current price list.
--
-- It sets it on every tag, not on the tags whose price moved. Postgres writes a
-- new row version for an update whether or not the value changed, so the job
-- rewrites the whole table nightly, every row of it, and leaves a dead version
-- behind for each. The table is a hundred times the size of its data and the
-- autovacuum that would reclaim it is fighting a job that undoes the work every
-- night.
--
-- Measured: 12,000 shelf tags and 12,000 rows updated by the last run, of which
-- 11,940 were set to the price they already held.
--
-- A WHERE clause comparing the new price with the old one turns a twelve
-- thousand row write into a sixty row write. The job finishes inside its
-- window, so nothing has ever escalated, and the table's bloat is charged to
-- storage rather than to the job that causes it.
CREATE TABLE catalog.shelf_tags (
    tag_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku           varchar(20) NOT NULL,
    printed_price numeric(10,2) NOT NULL,
    list_price    numeric(10,2) NOT NULL,
    printed_on    date NOT NULL
);

INSERT INTO catalog.shelf_tags (sku, printed_price, list_price, printed_on)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       (2 + (g % 180))::numeric(10,2),
       (2 + (g % 180))::numeric(10,2),
       DATE '2026-06-01'
FROM generate_series(1, 12000) AS g;

-- Sixty prices actually moved.
UPDATE catalog.shelf_tags SET list_price = list_price + 0.50 WHERE tag_id % 200 = 0;

-- The nightly job, which sets the printed price on every tag.
UPDATE catalog.shelf_tags SET printed_price = list_price, printed_on = DATE '2026-06-02';

-- DEFECT the-sequence-was-reset-by-hand-and-handed-out-a-live-number
--
-- The goods receipt numbers come from a sequence. The sequence was reset by
-- hand during a restore and set to a number that had already been issued.
--
-- The receipt number column has no unique index, because the sequence was
-- supposed to guarantee uniqueness and a second index on a heavily written
-- table was argued against at the time. So the reissued numbers went in without
-- complaint. Two goods receipts now share a number, on different dates, against
-- different suppliers, and the warehouse enquiry screen shows whichever one the
-- query reaches first.
--
-- Measured: 6,000 goods receipts holding 5,800 distinct receipt numbers, with
-- 200 numbers issued twice.
--
-- A unique index on the receipt number would have refused the second issue and
-- turned a silent duplicate into a failed restore, which is the outcome anybody
-- would have chosen. The duplicates are eighteen months apart, so no screen
-- shows them side by side and nobody has seen the two rows together.
CREATE SEQUENCE supply.goods_receipt_seq;

CREATE TABLE supply.goods_receipt_numbers (
    receipt_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    receipt_no   integer NOT NULL,
    supplier_ref varchar(12) NOT NULL,
    received_on  date NOT NULL
);

INSERT INTO supply.goods_receipt_numbers (receipt_no, supplier_ref, received_on)
SELECT nextval('supply.goods_receipt_seq'),
       'SUP-' || lpad((1 + (g % 80))::text, 5, '0'),
       DATE '2024-09-01' + (g % 400)
FROM generate_series(1, 5800) AS g;

-- The restore, which put the sequence back to a number already issued.
SELECT setval('supply.goods_receipt_seq', 5600, true);

INSERT INTO supply.goods_receipt_numbers (receipt_no, supplier_ref, received_on)
SELECT nextval('supply.goods_receipt_seq'),
       'SUP-' || lpad((1 + (g % 80))::text, 5, '0'),
       DATE '2026-03-01' + (g % 150)
FROM generate_series(1, 200) AS g;

-- DEFECT a-half-open-range-is-checked-with-between-so-the-last-day-counts-twice
--
-- Statement periods are stored as a start date and an end date, and the
-- statement query selects transactions BETWEEN the two.
--
-- BETWEEN includes both ends. The next period starts on the day the last one
-- ended, because that is how the periods were generated, so every transaction
-- on a period boundary appears on two statements. The customer sees the same
-- transaction twice across two statements, once at the bottom of one and once
-- at the top of the next, and the statement totals add up to more than the year.
--
-- Measured: 240 statement periods, 239 of which start on the day the previous
-- one ends.
--
-- Either the end date becomes exclusive and the query uses >= and <, or the
-- periods stop overlapping. The double counted transactions are correct on both
-- statements taken alone, which is why every query about them has been answered
-- with "that is the one from last month".
CREATE TABLE payments.statement_periods (
    period_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    starts_on   date NOT NULL,
    ends_on     date NOT NULL,
    total       numeric(12,2) NOT NULL
);

INSERT INTO payments.statement_periods (account_ref, starts_on, ends_on, total)
SELECT 'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       DATE '2020-01-01' + ((g - 1) * 30),
       DATE '2020-01-01' + (g * 30),
       (200 + (g % 7000))::numeric(12,2)
FROM generate_series(1, 240) AS g;

-- DEFECT the-unique-index-is-over-a-nullable-column-so-the-nulls-all-pass
--
-- Voucher codes are unique. The unique index is on a nullable column, and in
-- SQL a null is not equal to another null, so any number of rows may hold a
-- null code and the index will not object.
--
-- The code is null while the voucher is being drafted and is filled in when the
-- campaign is approved. Drafts accumulate. There are now more vouchers with no
-- code than there are with one, all of them passing a unique index that reads
-- as though it guarantees something, and the code that generates a new voucher
-- code checks the table for a clash with a query that also compares against
-- null and therefore never matches.
--
-- Measured: 4,000 voucher rows under a unique index on the code, of which 2,400
-- hold a null code.
--
-- Either the column is NOT NULL and drafts live somewhere else, or the index is
-- partial and says WHERE code IS NOT NULL, which at least states what it
-- enforces. The index exists, is unique and is on the right column, so every
-- review of this table has passed it.
CREATE TABLE marketing.voucher_codes (
    voucher_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code        varchar(20),
    campaign    varchar(60) NOT NULL,
    face_value  numeric(10,2) NOT NULL,
    drafted_on  date NOT NULL
);

CREATE UNIQUE INDEX voucher_codes_code_uq ON marketing.voucher_codes (code);

INSERT INTO marketing.voucher_codes (code, campaign, face_value, drafted_on)
SELECT 'VCH-' || lpad(g::text, 10, '0'),
       'Campaign ' || (1 + (g % 30)),
       (5 + (g % 40))::numeric(10,2),
       DATE '2025-03-01' + (g % 500)
FROM generate_series(1, 1600) AS g;

-- The drafts, which accumulate.
INSERT INTO marketing.voucher_codes (code, campaign, face_value, drafted_on)
SELECT NULL,
       'Campaign ' || (1 + (g % 30)),
       (5 + (g % 40))::numeric(10,2),
       DATE '2025-03-01' + (g % 500)
FROM generate_series(1, 2400) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.shelf_tags ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.shelf_tags:' || concat_ws('|', x.sku, x.printed_price, x.list_price))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.shelf_tags x
)
UPDATE catalog.shelf_tags t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.shelf_tags ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.shelf_tags ADD CONSTRAINT shelf_tags_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_shelf_tags_product_id ON catalog.shelf_tags (product_id);

ALTER TABLE payments.statement_periods ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('payments.statement_periods:' || concat_ws('|', x.account_ref, x.total))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.statement_periods x
)
UPDATE payments.statement_periods t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.statement_periods ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE payments.statement_periods ADD CONSTRAINT statement_periods_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_statement_periods_customer_id ON payments.statement_periods (customer_id);

ALTER TABLE supply.goods_receipt_numbers ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.goods_receipt_numbers:' || concat_ws('|', x.receipt_no, x.supplier_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.goods_receipt_numbers x
)
UPDATE supply.goods_receipt_numbers t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.goods_receipt_numbers ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.goods_receipt_numbers ADD CONSTRAINT goods_receipt_numbers_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_goods_receipt_numbers_purchase_order_id ON supply.goods_receipt_numbers (purchase_order_id);
-- <<< relationships
