-- Cross River Trading Co. -- sensor readings, product titles, docket lines,
-- hire periods, depot totals, field changes
-- author: T. Marchetti
-- postgres: 18
--
-- What the chiller probes send back, what a product is called on the website,
-- what arrived against an order, what is out on hire, what a depot has sold
-- today, and who changed a field.

-- DEFECT the-column-order-pads-every-row-with-bytes-that-hold-nothing
--
-- The sensor reading columns alternate between a one byte flag and an eight
-- byte value, so every row carries twenty one bytes of padding that hold
-- nothing at all.
--
-- PostgreSQL stores columns in the order they are declared and aligns each one
-- to its own boundary, so a boolean sitting in front of a bigint costs seven
-- wasted bytes every row. The declaration reads well, because each flag sits
-- next to the value it qualifies, and that is exactly why nobody reordered it.
-- The cost is not in the flags but in the table: the padding is written to
-- disk, copied into shared buffers, read back by every sequential scan and
-- carried into every backup. On the reading table it is about a fifth of the
-- row. Nothing reports it, because no statistic distinguishes a padding byte
-- from a data byte.
--
-- Measured: 24,000 sensor readings in a table whose declaration puts a one
-- byte column immediately in front of an eight byte column three times over.
--
-- Declaring the eight byte columns first and the flags at the end stores the
-- same data in fewer pages and is a rewrite of one table. Every column is the
-- right type, every value is correct, and the table reads exactly as intended.
CREATE TABLE ops.sensor_readings (
    reading_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ok_flag     boolean NOT NULL,
    taken_at    timestamptz NOT NULL,
    in_range    boolean NOT NULL,
    reading_mk  bigint NOT NULL,
    calibrated  boolean NOT NULL,
    drift_ppm   bigint NOT NULL,
    probe_ref   varchar(12) NOT NULL
);

INSERT INTO ops.sensor_readings (ok_flag, taken_at, in_range, reading_mk, calibrated, drift_ppm, probe_ref)
SELECT g % 97 <> 0,
       TIMESTAMPTZ '2026-09-01 00:00:00+01' + (g * INTERVAL '30 seconds'),
       g % 53 <> 0,
       273000 + (g % 9000),
       g % 7 <> 0,
       g % 400,
       'PRB-' || lpad((1 + (g % 120))::text, 5, '0')
FROM generate_series(1, 24000) AS g;

-- DEFECT the-escaping-pass-ran-over-titles-that-were-already-escaped
--
-- The import escapes ampersands for the web template, and for one supplier's
-- feed it ran over titles that had already been escaped, so eighteen hundred
-- products are called something with an &amp;amp; in the middle of it.
--
-- Escaping is not idempotent: the ampersand in &amp; is itself an ampersand,
-- so a second pass turns it into &amp;amp;. The feed in question already
-- escaped its titles, which nobody knew, because the only sample anybody had
-- looked at was a title with no ampersand in it. The template escapes nothing
-- itself, on the grounds that the data is already safe, so the double escape
-- goes straight to the page and the customer reads the entity. Search makes it
-- worse: a shopper looking for the product by name matches neither form.
--
-- Measured: 9,000 product titles of which 1,800 contain a double escaped
-- ampersand.
--
-- The affected rows want one pass of unescaping, and the import wants to stop
-- escaping what the feed already escaped. Every title is present, in the right
-- row, and renders as valid markup.
CREATE TABLE catalog.product_titles (
    sku         varchar(16) PRIMARY KEY,
    title       varchar(120) NOT NULL,
    supplier_ref varchar(12) NOT NULL,
    loaded_on   date NOT NULL
);

INSERT INTO catalog.product_titles (sku, title, supplier_ref, loaded_on)
SELECT 'SKU-' || lpad(g::text, 8, '0'),
       CASE WHEN g % 5 = 0
            THEN replace(replace('Bolts & Washers pack ' || g, '&', '&amp;'), '&', '&amp;')
            ELSE replace('Bolts & Washers pack ' || g, '&', '&amp;')
       END,
       'SUP-' || lpad((1 + (g % 600))::text, 6, '0'),
       DATE '2026-06-15' + (g % 90)
FROM generate_series(1, 9000) AS g;

-- DEFECT the-fixed-width-feed-left-a-trailing-space-on-every-key-it-wrote
--
-- The docket line carries the order reference as it came off a fixed width
-- feed, padded to sixteen characters with a space. The order header holds it
-- unpadded, and varchar comparison does not ignore trailing spaces, so those
-- lines match no order.
--
-- The feed pads every field to the column width, which is what fixed width
-- means, and the loader writes the field as it finds it. It worked for years
-- because the references were sixteen characters long and there was nothing to
-- pad. The current numbering runs to fifteen, so one space arrives on the end
-- of every reference the new format writes. There is no foreign key on the
-- column, which is the only reason the rows loaded. On screen the two look
-- identical, because a trailing space does not render, and the goods-in
-- report simply shows the line against no order at all.
--
-- Measured: 12,000 docket lines of which 2,400 match no order header as
-- stored and match one exactly once the trailing space is removed.
--
-- Trimming on load, and a foreign key afterwards, closes it for good. Every
-- line names a real order, the quantities are right, and the reference is
-- correct to the character except for the padding.
CREATE TABLE supply.order_headers (
    order_ref  varchar(16) PRIMARY KEY,
    supplier_ref varchar(12) NOT NULL,
    raised_on  date NOT NULL
);

CREATE TABLE supply.docket_lines (
    line_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref varchar(16) NOT NULL,
    sku       varchar(16) NOT NULL,
    qty       integer NOT NULL,
    booked_on date NOT NULL
);

INSERT INTO supply.order_headers (order_ref, supplier_ref, raised_on)
SELECT 'PO-' || lpad(g::text, 12, '0'),
       'SUP-' || lpad((1 + (g % 600))::text, 6, '0'),
       DATE '2026-05-05' + (g % 120)
FROM generate_series(1, 4000) AS g;

INSERT INTO supply.docket_lines (order_ref, sku, qty, booked_on)
SELECT CASE WHEN g % 5 = 0
            THEN 'PO-' || lpad((1 + (g % 4000))::text, 12, '0') || ' '
            ELSE 'PO-' || lpad((1 + (g % 4000))::text, 12, '0')
       END,
       'SKU-' || lpad((1 + (g % 2000))::text, 8, '0'),
       1 + (g % 60),
       DATE '2026-06-01' + (g % 100)
FROM generate_series(1, 12000) AS g;

-- DEFECT the-check-constraint-passes-every-row-whose-return-date-is-missing
--
-- The hire period check says the return date must be after the hire date, and
-- a row with no return date satisfies it, because the comparison is unknown
-- and a check constraint passes on unknown.
--
-- This is the rule of three-valued logic that every review forgets: a check
-- constraint rejects a row only when the expression is false, so null against
-- anything is a pass. The constraint was added to stop a keying error that had
-- put a return before a hire, and it does stop exactly that. It was then
-- written up as the guarantee that every hire has a sane return, which it is
-- not. The hire desk reads the open hires off a different screen, so nobody
-- has ever cross-checked the two, and equipment that was never booked back in
-- sits in the table looking like equipment still out on hire.
--
-- Measured: 9,000 hire periods under one check constraint, of which 3,600 have
-- no return date and are therefore checked by nothing.
--
-- Adding NOT NULL, or spelling the rule as returned_on IS NULL OR returned_on
-- > hired_on and meaning it, makes the intent explicit. The constraint is
-- valid, enforced and has genuinely caught the reversal it was written for.
CREATE TABLE fulfilment.hire_periods (
    hire_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    asset_ref   varchar(14) NOT NULL,
    hired_on    date NOT NULL,
    returned_on date,
    CONSTRAINT hire_periods_return_after_hire CHECK (returned_on > hired_on)
);

INSERT INTO fulfilment.hire_periods (asset_ref, hired_on, returned_on)
SELECT 'AST-' || lpad((1 + (g % 1500))::text, 9, '0'),
       DATE '2025-09-22' + (g % 350),
       CASE WHEN g % 5 < 2 THEN NULL
            ELSE DATE '2025-09-22' + (g % 350) + (1 + (g % 40))
       END
FROM generate_series(1, 9000) AS g;

-- DEFECT the-trigger-updates-the-summary-table-with-no-where-clause
--
-- The trigger that rolls a sale into the depot total updates the total table
-- without naming a depot, so every sale is added to every depot.
--
-- The trigger was written against a table that held one row, back when the
-- total was a group total, and the depot column was added underneath it. An
-- UPDATE with no WHERE is legal, it reports the number of rows it touched,
-- and forty is a plausible number when the trigger fires forty thousand times
-- in a night. The totals are wrong in a way that is hard to see, because they
-- are all wrong identically and they all still go up through the day. It is
-- the depot league table, which is read every morning and which currently
-- shows forty depots tied.
--
-- Measured: 40 depot totals holding one and the same figure, rolled from
-- 3,000 sales by a trigger whose UPDATE names no depot.
--
-- One WHERE clause fixes the trigger and a single pass over the sales rebuilds
-- the totals. Every sale is recorded correctly in the sales table, and the sum
-- of all depots is right, which is the figure the board sees.
CREATE TABLE ops.depot_totals (
    depot_code varchar(12) PRIMARY KEY,
    total_p    bigint NOT NULL DEFAULT 0
);

CREATE TABLE ops.depot_sales (
    sale_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    amount_p   integer NOT NULL,
    sold_at    timestamptz NOT NULL
);

INSERT INTO ops.depot_totals (depot_code)
SELECT 'DEP-' || lpad(g::text, 3, '0')
FROM generate_series(1, 40) AS g;

CREATE FUNCTION ops.fn_roll_depot_total()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE ops.depot_totals SET total_p = total_p + NEW.amount_p;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_roll_depot_total
    AFTER INSERT ON ops.depot_sales
    FOR EACH ROW EXECUTE FUNCTION ops.fn_roll_depot_total();

INSERT INTO ops.depot_sales (depot_code, amount_p, sold_at)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       100 + (g % 9000),
       TIMESTAMPTZ '2026-09-18 07:00:00+01' + (g * INTERVAL '10 seconds')
FROM generate_series(1, 3000) AS g;

-- DEFECT every-audit-row-says-the-connection-pool-made-the-change
--
-- The field change audit stamps each row with the database user, and every
-- connection comes from a pool that logs in as one role, so twelve thousand
-- rows all say the same thing.
--
-- Defaulting the column to current_user is the obvious way to record who did
-- something and it is right on a database where people connect as themselves.
-- Nobody has connected as themselves here since the application was put behind
-- a pool. The end user is known to the application and is never passed down,
-- so the audit records the pool. It is worse than an empty column, because the
-- column is populated, the audit looks complete, and it was signed off as
-- meeting the record keeping requirement. The first time it was needed was a
-- disputed price change, and the answer was the name of a service account.
--
-- Measured: 12,000 field change rows carrying exactly one distinct user
-- between them.
--
-- The application user wants passing down, by a session setting the default
-- reads or as a column the application fills. Every row is otherwise complete:
-- the table, the column, the old value, the new value and the time are all
-- correct and in order.
CREATE TABLE support.field_changes (
    change_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name varchar(40) NOT NULL,
    field_name varchar(40) NOT NULL,
    old_value  varchar(80),
    new_value  varchar(80),
    changed_by varchar(40) NOT NULL DEFAULT current_user,
    changed_at timestamptz NOT NULL
);

INSERT INTO support.field_changes (table_name, field_name, old_value, new_value, changed_at)
SELECT CASE WHEN g % 3 = 0 THEN 'orders' WHEN g % 3 = 1 THEN 'customers' ELSE 'products' END,
       CASE WHEN g % 4 = 0 THEN 'status' WHEN g % 4 = 1 THEN 'price_p' WHEN g % 4 = 2 THEN 'quantity' ELSE 'notes' END,
       'old ' || g,
       'new ' || g,
       TIMESTAMPTZ '2026-04-01 08:00:00+01' + (g * INTERVAL '11 minutes')
FROM generate_series(1, 12000) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.product_titles ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.product_titles:' || concat_ws('|', x.sku, x.title, x.supplier_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.product_titles x
)
UPDATE catalog.product_titles t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.product_titles ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.product_titles ADD CONSTRAINT product_titles_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_product_titles_product_id ON catalog.product_titles (product_id);

ALTER TABLE fulfilment.hire_periods ADD COLUMN round_id integer;

WITH p AS (
    SELECT round_id AS v, row_number() OVER (ORDER BY round_id) - 1 AS k
      FROM fulfilment.van_rounds
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.van_rounds)
                 * power((abs(hashtext('fulfilment.hire_periods:' || concat_ws('|', x.asset_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.hire_periods x
)
UPDATE fulfilment.hire_periods t
   SET round_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.hire_periods ALTER COLUMN round_id SET NOT NULL;
ALTER TABLE fulfilment.hire_periods ADD CONSTRAINT hire_periods_round_id_fkey FOREIGN KEY (round_id) REFERENCES fulfilment.van_rounds (round_id);
CREATE INDEX ix_hire_periods_round_id ON fulfilment.hire_periods (round_id);

ALTER TABLE supply.docket_lines ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.docket_lines:' || concat_ws('|', x.order_ref, x.sku, x.qty))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.docket_lines x
)
UPDATE supply.docket_lines t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.docket_lines ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.docket_lines ADD CONSTRAINT docket_lines_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_docket_lines_purchase_order_id ON supply.docket_lines (purchase_order_id);

ALTER TABLE supply.order_headers ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.order_headers:' || concat_ws('|', x.order_ref, x.supplier_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.order_headers x
)
UPDATE supply.order_headers t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.order_headers ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.order_headers ADD CONSTRAINT order_headers_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_order_headers_purchase_order_id ON supply.order_headers (purchase_order_id);

ALTER TABLE support.field_changes ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.field_changes:' || concat_ws('|', x.table_name, x.field_name, x.old_value, x.new_value, x.changed_by))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.field_changes x
)
UPDATE support.field_changes t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.field_changes ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.field_changes ADD CONSTRAINT field_changes_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_field_changes_ticket_id ON support.field_changes (ticket_id);
-- <<< relationships
