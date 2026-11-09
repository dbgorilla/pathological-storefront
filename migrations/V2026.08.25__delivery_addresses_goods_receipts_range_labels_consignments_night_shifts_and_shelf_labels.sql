-- Cross River Trading Co. -- delivery addresses, goods receipts, range labels,
-- consignments, night shifts, shelf labels
-- author: T. Marchetti
-- postgres: 18
--
-- Where a customer wants things sent, what arrived against a purchase order,
-- what a range is called, what went out on a lorry, who worked the night, and
-- what the label on the shelf says.

-- DEFECT one-default-address-per-customer-is-a-rule-nothing-declares
--
-- Every customer has exactly one delivery address marked as the default. The
-- database does not know that is a rule.
--
-- The rule is enforced in the checkout service, in a transaction that clears
-- the old default before setting the new one, and it has held for every
-- customer since the column was added. It holds because one service owns the
-- write path. The import that loads addresses from the trade portal is the
-- second write path, it sets is_default from the file, and the file has a
-- default flag on every row. Nothing has gone wrong yet because no trade
-- customer has more than one address in the portal.
--
-- Measured: 7,200 delivery addresses over 2,400 customers, every one of which
-- has exactly one default, with no unique index expressing it.
--
-- A unique index on customer_ref where is_default is the whole fix and it will
-- apply cleanly today. Left alone, the first trade customer with two portal
-- addresses gets two defaults and the checkout picks whichever the planner
-- returns first.
CREATE TABLE storefront.delivery_addresses (
    address_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_ref varchar(12) NOT NULL,
    line_one     varchar(60) NOT NULL,
    postcode     varchar(10) NOT NULL,
    is_default   boolean NOT NULL
);

INSERT INTO storefront.delivery_addresses (customer_ref, line_one, postcode, is_default)
SELECT 'CUS-' || lpad(c::text, 7, '0'),
       (c * 3 + s) || ' Millbank Road',
       'CR' || lpad(((c + s) % 90)::text, 2, '0') || ' ' || (1 + ((c + s) % 9)) || 'HW',
       s = 1
FROM generate_series(1, 2400) AS c
CROSS JOIN generate_series(1, 3) AS s;

-- DEFECT the-validating-trigger-runs-before-the-one-that-changes-the-total
--
-- One trigger checks that the receipt total is the quantity times the unit
-- price. A second trigger then changes the total. The check has already run.
--
-- Both are BEFORE INSERT triggers, so they fire in name order, and the
-- validating one is named first by accident rather than by design. It sees
-- the total the application sent, which is always correct, and passes. The
-- discount trigger then takes five per cent off for bulk receipts and writes
-- the new total, which no longer matches the columns beside it. The check was
-- added precisely to stop the total drifting from the line, and the thing that
-- makes it drift runs where the check cannot see it.
--
-- Measured: 3,000 goods receipts of which 1,500 are bulk and hold a total that
-- is not the quantity times the unit price, behind a validating trigger that
-- passed every one of them.
--
-- The check belongs in an AFTER trigger or a constraint, where it sees the row
-- that is actually stored. Renaming the triggers to reverse the order makes
-- the discount fail the check instead, which is the argument that has kept
-- this open. Every insert succeeds, so nothing appears in any log.
CREATE TABLE supply.goods_receipts (
    receipt_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref   varchar(16) NOT NULL,
    qty         integer NOT NULL,
    unit_p      integer NOT NULL,
    total_p     integer NOT NULL,
    received_on date NOT NULL
);

CREATE FUNCTION supply.fn_a_check_receipt_total() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.total_p <> NEW.qty * NEW.unit_p THEN
        RAISE EXCEPTION 'receipt total % does not match % x %',
            NEW.total_p, NEW.qty, NEW.unit_p;
    END IF;
    RETURN NEW;
END;
$$;

CREATE FUNCTION supply.fn_b_apply_receipt_discount() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.qty >= 11 THEN
        NEW.total_p := round(NEW.total_p * 0.95);
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_a_check_receipt_total BEFORE INSERT ON supply.goods_receipts
    FOR EACH ROW EXECUTE FUNCTION supply.fn_a_check_receipt_total();

CREATE TRIGGER trg_b_apply_receipt_discount BEFORE INSERT ON supply.goods_receipts
    FOR EACH ROW EXECUTE FUNCTION supply.fn_b_apply_receipt_discount();

INSERT INTO supply.goods_receipts (order_ref, qty, unit_p, total_p, received_on)
SELECT 'PO-' || lpad(g::text, 10, '0'),
       1 + (g % 20),
       100 + (g % 900),
       (1 + (g % 20)) * (100 + (g % 900)),
       DATE '2026-01-06' + (g % 260)
FROM generate_series(1, 3000) AS g;

-- DEFECT the-lookup-function-is-volatile-so-it-runs-once-per-row
--
-- The function that turns a range code into a label reads one table and
-- returns one string. It is declared volatile, so the planner has to call it
-- for every row it returns.
--
-- Volatile is the default when nothing is written, and nothing was written.
-- The function is a lookup: the same code gives the same label all day. Marked
-- stable, the planner may call it once per distinct value and may use it in an
-- index condition. Marked volatile, it cannot cache anything, cannot push it
-- down, and cannot reorder around it, so the report that renders twenty four
-- thousand rows makes twenty four thousand calls, each of which is its own
-- index lookup on a small table.
--
-- Measured: 24,000 range items behind a view that calls a volatile lookup
-- function once per row.
--
-- One word in the function definition. Nobody has looked, because the function
-- is correct, the report returns the right labels, and the cost lands as a
-- report that takes nine seconds rather than as an error.
CREATE TABLE catalog.range_labels (
    range_code  varchar(12) PRIMARY KEY,
    range_label varchar(60) NOT NULL
);

CREATE TABLE catalog.range_items (
    item_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    range_code varchar(12) NOT NULL,
    item_name  varchar(80) NOT NULL
);

INSERT INTO catalog.range_labels (range_code, range_label)
SELECT 'RNG-' || lpad(g::text, 5, '0'), 'Range ' || g || ' collection'
FROM generate_series(1, 300) AS g;

INSERT INTO catalog.range_items (range_code, item_name)
SELECT 'RNG-' || lpad((1 + (g % 300))::text, 5, '0'),
       'Item ' || g
FROM generate_series(1, 24000) AS g;

CREATE FUNCTION catalog.fn_range_label(p_range_code varchar)
RETURNS varchar
LANGUAGE sql
AS $$
    SELECT range_label FROM catalog.range_labels WHERE range_code = p_range_code;
$$;

CREATE VIEW analytics.v_range_labels AS
SELECT i.item_id,
       i.item_name,
       catalog.fn_range_label(i.range_code) AS range_label
FROM catalog.range_items AS i;

-- DEFECT the-reader-role-can-reset-the-sequence-it-was-given-for-reading
--
-- The stock reading role was granted every privilege on the consignment
-- number sequence. UPDATE on a sequence is the privilege that lets you call
-- setval.
--
-- The grant was written as ALL PRIVILEGES because the role needed currval to
-- read back the number the job it watches had just allocated, and ALL was
-- shorter than working out which of USAGE, SELECT and UPDATE that needs. It
-- needs SELECT. UPDATE lets the role move the sequence anywhere, including
-- backwards, at which point the next consignment number collides with one
-- already issued and the goods leave the yard under a number that is already
-- on a different lorry's paperwork.
--
-- Measured: 9,000 consignments numbered from a sequence that stock_reader
-- holds UPDATE on.
--
-- GRANT SELECT ON SEQUENCE is what was wanted. The role has never called
-- setval, so nothing in the audit or the data shows the privilege is there.
CREATE SEQUENCE ops.consignment_no_seq START WITH 500001;

CREATE TABLE ops.consignments (
    consignment_no integer PRIMARY KEY DEFAULT nextval('ops.consignment_no_seq'),
    depot_code     varchar(12) NOT NULL,
    carrier_ref    varchar(16) NOT NULL,
    despatched_on  date NOT NULL
);

INSERT INTO ops.consignments (depot_code, carrier_ref, despatched_on)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       'CAR-' || lpad((1 + (g % 120))::text, 6, '0'),
       DATE '2026-02-09' + (g % 220)
FROM generate_series(1, 9000) AS g;

GRANT ALL PRIVILEGES ON SEQUENCE ops.consignment_no_seq TO stock_reader;

-- DEFECT the-eight-hour-shift-is-seven-hours-on-the-night-the-clocks-change
--
-- A night shift is stored as a start instant and an end instant eight hours
-- later. On the two nights a year the clocks change, eight hours of elapsed
-- time is seven or nine hours on the wall.
--
-- The rota writes the start from the local 22:00 and computes the end by
-- adding an interval of eight hours, which is eight hours of absolute time and
-- is the right answer for pay. It is the wrong answer for the rota, which is
-- read as a clock time: the October shift shows as ending at 05:00 and the
-- March one at 07:00, and the depot manager reads those as a mistake and
-- corrects the rota by hand. Adding eight hours to a local time and adding
-- eight hours to an instant are different operations and this system needs
-- both, in different places.
--
-- Measured: 14,600 night shifts across 40 depots, of which 80 span a local
-- clock difference that is not eight hours.
--
-- The rota wants the local end time computed in the local zone, and pay wants
-- the instants, which means storing both. Every row is correct as an instant,
-- so every check that subtracts the timestamps passes.
CREATE TABLE ops.night_shifts (
    shift_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    started_at timestamptz NOT NULL,
    ended_at   timestamptz NOT NULL
);

INSERT INTO ops.night_shifts (depot_code, started_at, ended_at)
SELECT 'DEP-' || lpad(d::text, 3, '0'),
       ((DATE '2025-10-01' + n) + TIME '22:00') AT TIME ZONE 'Europe/London',
       (((DATE '2025-10-01' + n) + TIME '22:00') AT TIME ZONE 'Europe/London')
           + INTERVAL '8 hours'
FROM generate_series(1, 40) AS d
CROSS JOIN generate_series(0, 364) AS n;

-- DEFECT update-was-granted-without-the-select-the-where-clause-needs
--
-- The counter staff role may update the shelf label table and may not read it.
-- Every update it writes has a WHERE clause.
--
-- The grant was written to the letter of the request, which said the counter
-- staff need to correct a shelf label and must not be able to list prices. An
-- UPDATE with a WHERE clause reads the rows it is choosing between, so it
-- needs SELECT on the columns in that clause, and without it the statement
-- fails with a permission denied on the table the role was just granted. The
-- till software catches the error, shows "could not save", and the staff
-- rewrite the label by hand on a sticker.
--
-- Measured: 4,800 shelf labels where counter_staff holds UPDATE and does not
-- hold SELECT.
--
-- Column level SELECT on the key alone is enough and keeps the prices hidden.
-- The grant reads correctly in every listing: the role has update on the
-- table, which is exactly what the request asked for.
CREATE TABLE catalog.shelf_labels (
    label_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku        varchar(16) NOT NULL,
    shelf_code varchar(12) NOT NULL,
    price_p    integer NOT NULL,
    printed_on date NOT NULL
);

INSERT INTO catalog.shelf_labels (sku, shelf_code, price_p, printed_on)
SELECT 'SKU-' || lpad(g::text, 8, '0'),
       'SHL-' || lpad((1 + (g % 600))::text, 5, '0'),
       120 + (g % 9000),
       DATE '2026-05-11' + (g % 120)
FROM generate_series(1, 4800) AS g;

GRANT UPDATE ON catalog.shelf_labels TO counter_staff;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.range_items ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.range_items:' || concat_ws('|', x.range_code, x.item_name))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.range_items x
)
UPDATE catalog.range_items t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.range_items ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.range_items ADD CONSTRAINT range_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_range_items_product_id ON catalog.range_items (product_id);

ALTER TABLE catalog.range_labels ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.range_labels:' || concat_ws('|', x.range_code, x.range_label))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.range_labels x
)
UPDATE catalog.range_labels t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.range_labels ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.range_labels ADD CONSTRAINT range_labels_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_range_labels_product_id ON catalog.range_labels (product_id);

ALTER TABLE catalog.shelf_labels ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.shelf_labels:' || concat_ws('|', x.sku, x.shelf_code, x.price_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.shelf_labels x
)
UPDATE catalog.shelf_labels t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.shelf_labels ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.shelf_labels ADD CONSTRAINT shelf_labels_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_shelf_labels_product_id ON catalog.shelf_labels (product_id);

ALTER TABLE ops.consignments ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('ops.consignments:' || concat_ws('|', x.depot_code, x.carrier_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.consignments x
)
UPDATE ops.consignments t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.consignments ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE ops.consignments ADD CONSTRAINT consignments_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_consignments_shipment_id ON ops.consignments (shipment_id);

ALTER TABLE ops.night_shifts ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.night_shifts:' || concat_ws('|', x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.night_shifts x
)
UPDATE ops.night_shifts t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.night_shifts ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.night_shifts ADD CONSTRAINT night_shifts_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_night_shifts_store_id ON ops.night_shifts (store_id);

ALTER TABLE storefront.delivery_addresses ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('storefront.delivery_addresses:' || concat_ws('|', x.customer_ref, x.line_one, x.postcode, x.is_default))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.delivery_addresses x
)
UPDATE storefront.delivery_addresses t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.delivery_addresses ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE storefront.delivery_addresses ADD CONSTRAINT delivery_addresses_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_delivery_addresses_customer_id ON storefront.delivery_addresses (customer_id);

ALTER TABLE supply.goods_receipts ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.goods_receipts:' || concat_ws('|', x.order_ref, x.qty, x.unit_p, x.total_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.goods_receipts x
)
UPDATE supply.goods_receipts t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.goods_receipts ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.goods_receipts ADD CONSTRAINT goods_receipts_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_goods_receipts_purchase_order_id ON supply.goods_receipts (purchase_order_id);
-- <<< relationships
