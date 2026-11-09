-- Cross River Trading Co. -- delivery promises, channel order counts, billing
-- anchors, listing deletes, repair job numbers, tote moves
-- author: R. Okonjo
-- postgres: 18
--
-- The promise report the service desk works from, the channel counts on the
-- daily trading sheet, the direct debit schedule, the listing withdrawal the
-- buying desk runs, the repair job number, and the tote move log.

-- DEFECT left-join-undone-by-a-where-clause-on-the-right-hand-table
--
-- The promise report is orders with their delivery promise, and it is a LEFT
-- JOIN because an order does not always have one.
--
-- The WHERE clause then filters on a column from the promised side: only
-- promises for this quarter. An order with no promise has nulls in those
-- columns, the comparison is unknown, and the row is dropped. The LEFT JOIN
-- has been turned back into an inner join by a line written twenty lines
-- below it.
--
-- Measured: 1,800 trade orders, 1,400 with a promise, and a report showing
-- 1,400. The 400 orders with no promise at all are the ones the service desk
-- is looking for, and they are the ones that cannot appear.
--
-- The condition belongs in the JOIN clause, where a non-matching promise
-- leaves the order in place with nulls beside it. The report has a plausible
-- row count, which is what has kept it.
CREATE TABLE storefront.trade_orders (
    order_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref   varchar(16) NOT NULL UNIQUE,
    account_ref varchar(12) NOT NULL,
    placed_on   date NOT NULL,
    order_value numeric(12,2) NOT NULL
);

CREATE TABLE fulfilment.delivery_promises (
    promise_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref   varchar(16) NOT NULL,
    promised_on date NOT NULL,
    promised_by varchar(24) NOT NULL
);

INSERT INTO storefront.trade_orders (order_ref, account_ref, placed_on, order_value)
SELECT 'TRD-' || lpad(g::text, 8, '0'),
       'ACC-' || lpad((1 + (g % 300))::text, 5, '0'),
       DATE '2026-07-01' + (g % 60),
       (40 + (g % 900))::numeric(12,2)
FROM generate_series(1, 1800) AS g;

INSERT INTO fulfilment.delivery_promises (order_ref, promised_on, promised_by)
SELECT 'TRD-' || lpad(g::text, 8, '0'),
       DATE '2026-07-04' + (g % 60),
       'desk ' || (1 + (g % 6))::text
FROM generate_series(1, 1400) AS g;

CREATE VIEW analytics.v_orders_with_promise AS
SELECT o.order_id,
       o.order_ref,
       o.account_ref,
       o.placed_on,
       o.order_value,
       p.promised_on
FROM storefront.trade_orders o
LEFT JOIN fulfilment.delivery_promises p ON p.order_ref = o.order_ref
WHERE p.promised_on >= DATE '2026-07-01';

-- DEFECT count-of-a-nullable-column-reports-fewer-orders-than-there-are
--
-- The daily trading sheet counts orders per day with count(channel_code).
--
-- count of a column counts the rows where that column is not null, and the
-- channel code is null on every order taken over the telephone, because the
-- telephone was never given a channel when the codes were introduced. Those
-- orders are not counted anywhere: they are not a channel with a small number
-- beside it, they are absent.
--
-- Measured: 1,800 channel orders, 240 of them with no channel code, and a
-- daily sheet totalling 1,560.
--
-- count(*) counts orders. The two figures are close enough that the difference
-- reads as a quiet day, and the telephone desk's own numbers have never been
-- reconciled against the trading sheet.
CREATE TABLE storefront.channel_orders (
    order_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref    varchar(16) NOT NULL,
    channel_code varchar(8),
    ordered_on   date NOT NULL,
    order_value  numeric(12,2) NOT NULL
);

INSERT INTO storefront.channel_orders (order_ref, channel_code, ordered_on, order_value)
SELECT 'CHN-' || lpad(g::text, 8, '0'),
       CASE WHEN g % 15 IN (0, 1) THEN NULL
            ELSE (ARRAY['web', 'app', 'edi', 'counter'])[1 + (g % 4)]
       END,
       DATE '2026-07-01' + (g % 30),
       (25 + (g % 500))::numeric(12,2)
FROM generate_series(1, 1800) AS g;

CREATE VIEW analytics.v_channel_order_counts AS
SELECT ordered_on,
       count(channel_code) AS orders,
       sum(order_value) AS order_value
FROM storefront.channel_orders
GROUP BY ordered_on;

-- DEFECT adding-one-month-to-a-month-end-clamps-the-billing-date
--
-- A direct debit schedule is built by taking the last date and adding a month
-- to it, twelve times.
--
-- Adding a month to the 31st of a month with no 31st gives the last day that
-- month has. That would be harmless if the next date were worked out from the
-- anchor, but it is worked out from the date before it, so once the schedule
-- clamps it never climbs back. An account anchored on the 31st of January
-- bills on the 28th of February and on the 28th of every month after that,
-- for the rest of the year.
--
-- Measured: 720 schedule rows across 60 accounts anchored on month ends, and
-- 210 of them fall on a different day from the anchor plus that many months.
--
-- Anchor plus n months gives each date independently and clamps only where it
-- has to. Customers on the 29th, 30th and 31st quietly move to the 28th and
-- nobody complains, because being billed earlier is not what generates a call.
CREATE TABLE payments.billing_schedules (
    schedule_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref  varchar(12) NOT NULL,
    anchor_on    date NOT NULL,
    period_no    integer NOT NULL,
    scheduled_on date NOT NULL
);

INSERT INTO payments.billing_schedules (account_ref, anchor_on, period_no, scheduled_on)
WITH RECURSIVE anchors AS (
    SELECT 'ACC-' || lpad((1 + g)::text, 5, '0') AS account_ref,
           (DATE '2026-01-01' + ((g % 4) * 3) * INTERVAL '1 month'
              + ((28 + (g % 4)) - 1) * INTERVAL '1 day')::date AS anchor_on
    FROM generate_series(0, 59) AS g
), rolled AS (
    SELECT a.account_ref, a.anchor_on, 0 AS period_no, a.anchor_on AS scheduled_on
    FROM anchors a
    UNION ALL
    SELECT r.account_ref, r.anchor_on, r.period_no + 1,
           (r.scheduled_on + INTERVAL '1 month')::date
    FROM rolled r
    WHERE r.period_no < 11
)
SELECT account_ref, anchor_on, period_no, scheduled_on FROM rolled;

-- DEFECT before-delete-trigger-returns-null-and-the-delete-does-nothing
--
-- Withdrawing a supplier listing is a DELETE, and a BEFORE DELETE trigger
-- records what was withdrawn before it goes.
--
-- The function writes its log row and returns NULL. A BEFORE trigger that
-- returns NULL cancels the operation for that row, so the log is written and
-- the listing stays. The DELETE reports zero rows affected, which is only
-- visible to a caller that looks, and the buying desk's withdrawal script does
-- not look.
--
-- Measured: 240 listings withdrawn, 240 rows in the withdrawal log, and 240
-- listings still live in the catalogue.
--
-- A BEFORE DELETE trigger must return OLD for the delete to proceed. The log
-- makes the withdrawal look done, so the discrepancy only shows up when a
-- supplier asks why a withdrawn line is still being ordered.
CREATE TABLE catalog.supplier_listings (
    listing_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref varchar(12) NOT NULL,
    sku          varchar(20) NOT NULL,
    status       varchar(16) NOT NULL,
    listed_on    date NOT NULL
);

CREATE TABLE catalog.listing_delete_log (
    log_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    listing_id   integer NOT NULL,
    supplier_ref varchar(12) NOT NULL,
    sku          varchar(20) NOT NULL,
    withdrawn_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION catalog.fn_block_listing_delete() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO catalog.listing_delete_log (listing_id, supplier_ref, sku)
    VALUES (OLD.listing_id, OLD.supplier_ref, OLD.sku);
    RETURN NULL;
END;
$$;

INSERT INTO catalog.supplier_listings (supplier_ref, sku, status, listed_on)
SELECT 'SUP-' || lpad((1 + (g % 70))::text, 3, '0'),
       'SKU-' || lpad(g::text, 8, '0'),
       CASE WHEN g % 5 = 0 THEN 'discontinued' ELSE 'live' END,
       DATE '2024-04-01' + (g % 600)
FROM generate_series(1, 1200) AS g;

CREATE TRIGGER trg_log_listing_delete
    BEFORE DELETE ON catalog.supplier_listings
    FOR EACH ROW EXECUTE FUNCTION catalog.fn_block_listing_delete();

-- The quarterly withdrawal run.
DELETE FROM catalog.supplier_listings WHERE status = 'discontinued';

-- DEFECT reference-numbers-in-a-text-column-sort-lexicographically
--
-- Repair job numbers are a count per unit, held in a text column because the
-- first system printed them with a letter in front and the letter was dropped
-- in the migration that brought them here.
--
-- Text sorts a character at a time, so job 9 sorts after job 10 and after job
-- 100. The latest job per unit is worked out with max(), so for any unit that
-- has reached ten jobs the report shows the wrong one, and it shows it
-- confidently.
--
-- Measured: 1,260 repair jobs across 120 units, and on 66 of those units the
-- highest job number by text is not the highest by number.
--
-- An integer column sorts the way the number is meant to. Every unit with
-- fewer than ten jobs reads correctly, which is most of them on any given day,
-- so the report is right far more often than it is wrong.
CREATE TABLE support.repair_jobs (
    job_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    unit_ref  varchar(16) NOT NULL,
    job_no    varchar(12) NOT NULL,
    logged_on date NOT NULL,
    engineer  varchar(24) NOT NULL
);

INSERT INTO support.repair_jobs (unit_ref, job_no, logged_on, engineer)
SELECT 'UNIT-' || lpad(u::text, 6, '0'),
       j::text,
       DATE '2025-05-01' + ((u * 7 + j) % 400),
       'engineer ' || (1 + ((u + j) % 14))::text
FROM generate_series(1, 120) AS u,
     generate_series(1, 1 + (u % 20)) AS j;

CREATE VIEW analytics.v_latest_repair AS
SELECT unit_ref,
       max(job_no) AS latest_job_no,
       count(*) AS jobs
FROM support.repair_jobs
GROUP BY unit_ref;

-- DEFECT sequence-left-behind-by-a-bulk-load-with-explicit-keys
--
-- Tote moves were loaded from the old warehouse system with their keys
-- included, so the numbering would line up with the paperwork.
--
-- Supplying the key explicitly does not advance the sequence behind it. The
-- sequence is still where the load found it, and the next insert that lets the
-- sequence pick a key will pick one that is already taken and fail on the
-- primary key. It will keep failing, once per insert, until it has counted its
-- way up past the loaded range.
--
-- Measured: 2,000 tote moves loaded, the highest key 2,000, and the sequence
-- sitting at 1.
--
-- setval on the sequence after a keyed load is the whole fix, and it is one
-- line that is easy to leave out of a migration nobody expects to run twice.
-- Nothing reads wrong until the first write arrives.
CREATE TABLE ops.tote_moves (
    move_id    serial PRIMARY KEY,
    tote_ref   varchar(16) NOT NULL,
    from_depot varchar(12) NOT NULL,
    to_depot   varchar(12) NOT NULL,
    moved_at   timestamptz NOT NULL
);

INSERT INTO ops.tote_moves (move_id, tote_ref, from_depot, to_depot, moved_at)
SELECT g,
       'TOTE-' || lpad((1 + (g % 700))::text, 6, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       'DEP-' || lpad((1 + ((g + 7) % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-06-01 05:30:00+01' + (g * INTERVAL '13 minutes')
FROM generate_series(1, 2000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.supplier_listings ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.supplier_listings:' || concat_ws('|', x.supplier_ref, x.sku, x.status))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.supplier_listings x
)
UPDATE catalog.supplier_listings t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.supplier_listings ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.supplier_listings ADD CONSTRAINT supplier_listings_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_supplier_listings_product_id ON catalog.supplier_listings (product_id);

ALTER TABLE fulfilment.delivery_promises ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('fulfilment.delivery_promises:' || concat_ws('|', x.order_ref, x.promised_by))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.delivery_promises x
)
UPDATE fulfilment.delivery_promises t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.delivery_promises ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE fulfilment.delivery_promises ADD CONSTRAINT delivery_promises_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_delivery_promises_shipment_id ON fulfilment.delivery_promises (shipment_id);

ALTER TABLE ops.tote_moves ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.tote_moves:' || concat_ws('|', x.tote_ref, x.from_depot, x.to_depot))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.tote_moves x
)
UPDATE ops.tote_moves t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.tote_moves ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.tote_moves ADD CONSTRAINT tote_moves_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_tote_moves_warehouse_id ON ops.tote_moves (warehouse_id);

ALTER TABLE payments.billing_schedules ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('payments.billing_schedules:' || concat_ws('|', x.account_ref, x.period_no))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.billing_schedules x
)
UPDATE payments.billing_schedules t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.billing_schedules ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE payments.billing_schedules ADD CONSTRAINT billing_schedules_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_billing_schedules_customer_id ON payments.billing_schedules (customer_id);

ALTER TABLE support.repair_jobs ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.repair_jobs:' || concat_ws('|', x.unit_ref, x.job_no, x.engineer))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.repair_jobs x
)
UPDATE support.repair_jobs t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.repair_jobs ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.repair_jobs ADD CONSTRAINT repair_jobs_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_repair_jobs_ticket_id ON support.repair_jobs (ticket_id);
-- <<< relationships
