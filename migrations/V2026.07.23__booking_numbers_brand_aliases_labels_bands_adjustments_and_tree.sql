-- Cross River Trading Co. -- courier booking numbers, brand aliases, goods
-- labels, order bands, stock adjustments, merchandise tree
-- author: P. Adeyemi
-- postgres: 18
--
-- The booking number the courier quotes back, the brand alias list the search
-- box uses, the label the printer puts on a pallet, the order size band the
-- commercial report groups on, the stock adjustments the warehouse posts, and
-- the merchandise tree the category page walks.

-- DEFECT setval-with-is-called-false-reissues-the-last-number
--
-- Booking numbers come from a sequence. A resync procedure keeps the sequence
-- level with the data after a restore, by taking the highest booking number and
-- calling setval with a third argument of false.
--
-- The third argument to setval is is_called. Passing false means the value given
-- has not been handed out yet, so the next call to nextval returns it rather
-- than the one after it. The resync also takes its maximum from a filtered
-- query, the bookings made before June, so the sequence is not set level with
-- the data at all: it is set back to where the data stood two months ago.
--
-- Measured: 1,200 bookings hold 900 distinct booking numbers. 300 numbers are
-- on two bookings each, and the column has no unique constraint to stop it
-- because a booking number was never meant to be a key.
--
-- setval with is_called left at its default sets the last value used, which is
-- what the word resync means here, and the maximum has to be taken over the
-- whole table. Both bookings quote the same number to the courier, and the one
-- that gets cancelled is whichever the courier looks up first.
CREATE SEQUENCE fulfilment.courier_booking_numbers START 1;

CREATE TABLE fulfilment.courier_bookings (
    booking_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    booking_no integer NOT NULL DEFAULT nextval('fulfilment.courier_booking_numbers'),
    depot      varchar(20) NOT NULL,
    booked_on  date NOT NULL
);

INSERT INTO fulfilment.courier_bookings (depot, booked_on)
SELECT (ARRAY['preston','leeds','hull','crewe'])[1 + (g % 4)],
       DATE '2026-03-01' + (g / 6)
FROM generate_series(1, 900) AS g;

-- The resync, run after the June restore.
SELECT setval('fulfilment.courier_booking_numbers',
              (SELECT max(booking_no) FROM fulfilment.courier_bookings
                WHERE booked_on < DATE '2026-06-01'),
              false);

INSERT INTO fulfilment.courier_bookings (depot, booked_on)
SELECT (ARRAY['preston','leeds','hull','crewe'])[1 + (g % 4)],
       DATE '2026-06-15' + (g / 20)
FROM generate_series(1, 300) AS g;

-- DEFECT non-deterministic-collation-makes-unique-fold-case-so-the-load-drops-rows
--
-- Brand aliases feed the search box, so the column was given a case insensitive
-- collation to make matching easy, and a unique constraint to keep the list
-- tidy.
--
-- A non-deterministic collation does not only change comparison, it changes what
-- equal means for the unique constraint too. Two aliases that differ only in
-- case are the same value as far as the index is concerned, so the second one
-- cannot be stored. The load uses ON CONFLICT DO NOTHING, so it does not fail:
-- it inserts the rows it can and returns.
--
-- Measured: 600 staged aliases produce 400 rows. The 200 that were dropped are
-- the ones whose spelling differs from an existing alias only in case, and the
-- capitalisation the brand owner asked for is the one that was lost.
--
-- Case insensitive searching is what the collation is for; case insensitive
-- uniqueness is a separate decision and here it was made by accident. The list
-- looks complete, the search works, and the alias the supplier's own artwork
-- uses is not in it.
CREATE COLLATION catalog.brand_ci (
    provider = icu,
    locale = 'und-u-ks-level2',
    deterministic = false
);

CREATE TABLE catalog.brand_alias_staging (
    staging_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    brand_ref  varchar(16) NOT NULL,
    alias      varchar(40) NOT NULL
);

INSERT INTO catalog.brand_alias_staging (brand_ref, alias)
SELECT 'BR' || lpad((1 + g % 400)::text, 4, '0'),
       CASE WHEN g > 400
            THEN upper('brand ' || lpad((1 + g % 400)::text, 4, '0'))
            ELSE 'Brand ' || lpad((1 + g % 400)::text, 4, '0')
       END
FROM generate_series(1, 600) AS g;

CREATE TABLE catalog.brand_aliases (
    alias_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    brand_ref varchar(16) NOT NULL,
    alias     varchar(40) COLLATE catalog.brand_ci NOT NULL UNIQUE
);

INSERT INTO catalog.brand_aliases (brand_ref, alias)
SELECT s.brand_ref, s.alias
FROM catalog.brand_alias_staging s
ORDER BY s.staging_id
ON CONFLICT DO NOTHING;

-- DEFECT two-before-triggers-fire-in-name-order-and-the-second-overwrites-the-first
--
-- A pallet label carries a batch prefix and a depot prefix. Each is applied by
-- its own BEFORE INSERT trigger, so the two changes stayed in separate reviews.
--
-- Several BEFORE triggers on one table fire in alphabetical order by trigger
-- name, and each one sees whatever the previous one left in NEW. Both of these
-- assign the whole label rather than adding to it, so the one whose name sorts
-- later wins outright and the other one may as well not exist. Nothing in
-- either trigger's own code says so, and each is correct read on its own.
--
-- Measured: 1,000 labels printed. All 1,000 carry the depot prefix and none
-- carries the batch number, because trg_label_depot sorts after
-- trg_label_batch. The batch number is what a recall is traced on.
--
-- One trigger that applies both parts is the shape this wanted, and if there
-- have to be two then the second must append to what it was given rather than
-- overwrite it. The printed label is well formed and scans, which is the whole
-- of what was tested.
CREATE TABLE ops.goods_labels (
    label_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    item_ref      varchar(20) NOT NULL,
    batch_no      varchar(12) NOT NULL,
    depot         varchar(20) NOT NULL,
    printed_label varchar(80)
);

CREATE FUNCTION ops.fn_label_apply_batch() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.printed_label := NEW.batch_no || '/' || NEW.item_ref;
    RETURN NEW;
END;
$$;

CREATE FUNCTION ops.fn_label_apply_prefix() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.printed_label := upper(NEW.depot) || '/' || NEW.item_ref;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_label_batch
    BEFORE INSERT ON ops.goods_labels
    FOR EACH ROW EXECUTE FUNCTION ops.fn_label_apply_batch();

CREATE TRIGGER trg_label_depot
    BEFORE INSERT ON ops.goods_labels
    FOR EACH ROW EXECUTE FUNCTION ops.fn_label_apply_prefix();

INSERT INTO ops.goods_labels (item_ref, batch_no, depot)
SELECT 'IT' || lpad(g::text, 6, '0'),
       'B' || lpad((1 + g / 50)::text, 5, '0'),
       (ARRAY['preston','leeds','hull','crewe'])[1 + (g % 4)]
FROM generate_series(1, 1000) AS g;

-- DEFECT stored-generated-column-uses-a-function-that-is-not-really-immutable
--
-- Orders carry a size band, held as a stored generated column so it can never
-- disagree with the total. The band comes from a lookup table, through a
-- function that had to be marked IMMUTABLE for the generated column to be
-- accepted.
--
-- A function that reads a table is not immutable, and marking it so does not
-- make it so, it only stops PostgreSQL from checking. A stored generated column
-- is computed once, at write time, and never again. So when the bands were
-- re-cut in June every order written before then kept the band it was given
-- under the old boundaries, and nothing recomputed them because as far as the
-- database is concerned the inputs cannot have changed.
--
-- Measured: 1,200 orders. 305 of them carry a band the lookup table no longer
-- agrees with, and the commercial report groups on the stored column.
--
-- A view or a plain expression recomputes on every read, which is what a band
-- derived from a lookup needs. Marking the function IMMUTABLE was not an
-- optimisation, it was the only way to get the definition past the parser, and
-- that is the point at which the design was already wrong.
CREATE TABLE catalog.order_band_lookup (
    band     varchar(12) PRIMARY KEY,
    lo_cents integer NOT NULL,
    hi_cents integer NOT NULL
);

INSERT INTO catalog.order_band_lookup (band, lo_cents, hi_cents)
VALUES ('small',  0,      4999),
       ('medium', 5000,   19999),
       ('large',  20000,  999999);

CREATE FUNCTION catalog.fn_band_for(p_cents integer) RETURNS varchar
LANGUAGE sql IMMUTABLE AS $$
    SELECT b.band FROM catalog.order_band_lookup b
     WHERE p_cents BETWEEN b.lo_cents AND b.hi_cents
     LIMIT 1;
$$;

CREATE TABLE storefront.order_bands (
    order_ref   varchar(16) PRIMARY KEY,
    total_cents integer NOT NULL,
    band        varchar(12) GENERATED ALWAYS AS (catalog.fn_band_for(total_cents)) STORED
);

INSERT INTO storefront.order_bands (order_ref, total_cents)
SELECT 'SO' || lpad(g::text, 6, '0'),
       500 + (g * 311) % 59500
FROM generate_series(1, 1200) AS g;

-- The June re-cut, after the commercial review.
UPDATE catalog.order_band_lookup SET hi_cents = 9999  WHERE band = 'small';
UPDATE catalog.order_band_lookup SET lo_cents = 10000, hi_cents = 29999 WHERE band = 'medium';
UPDATE catalog.order_band_lookup SET lo_cents = 30000 WHERE band = 'large';

-- DEFECT negative-quantity-means-a-write-off-and-nothing-says-so
--
-- Stock adjustments are posted as a quantity and a reason. A write-off is
-- posted as a negative quantity, which is the convention the warehouse system
-- has used since it was written and which is recorded nowhere.
--
-- The on hand view was written later, by somebody who read the column name and
-- took the quantity for a magnitude with the direction held in the reason. It
-- sums abs(quantity), so every write-off adds stock instead of removing it, and
-- each one is counted twice wrong: once for the stock that is not there and
-- once for the stock it says arrived.
--
-- Measured: 2,400 adjustments covering 200 skus. The real net movement is
-- 274,740 units and the on hand view reports 378,060, which is 103,320 units of
-- stock that was written off and is counted as if it had arrived.
--
-- A comment on the column, or a separate direction column, or a check that the
-- reason and the sign agree, would each have made this impossible. The figure
-- the view produces is positive, plausible, and reconciles against nothing,
-- because the only other place the number appears is the same view.
CREATE TABLE supply.stock_adjustments (
    adj_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku      varchar(20) NOT NULL,
    quantity integer NOT NULL,
    reason   varchar(30) NOT NULL,
    posted_on date NOT NULL
);

INSERT INTO supply.stock_adjustments (sku, quantity, reason, posted_on)
SELECT 'CRT-' || lpad((1 + g % 200)::text, 5, '0'),
       CASE WHEN g % 5 = 0 THEN -(20 + (g * 7) % 180)
            ELSE 40 + (g * 13) % 260
       END,
       CASE WHEN g % 5 = 0 THEN 'damage write off' ELSE 'goods received' END,
       DATE '2026-01-05' + (g % 200)
FROM generate_series(1, 2400) AS g;

CREATE VIEW analytics.v_stock_on_hand AS
SELECT a.sku,
       sum(abs(a.quantity)) AS on_hand
FROM supply.stock_adjustments a
GROUP BY a.sku;

-- DEFECT category-parent-cycle-makes-the-depth-limited-rollup-double-count
--
-- The merchandise tree is a parent pointer per node, and the category page
-- rolls up every descendant of a node with a recursive walk. The walk carries a
-- depth limit, added when the page once hung.
--
-- A merge in March pointed a node at one of its own descendants, so two nodes
-- now point at each other. The depth limit means the walk terminates rather than
-- hanging, which is why the bug was closed: it does not terminate because it has
-- finished, it terminates because it has run out of allowance, and it revisits
-- the three nodes in the cycle once per lap until it does.
--
-- Measured: 300 nodes in the tree. The rollup emits 935 rows, and 44 of the
-- root and node pairs in it appear more than once, every one of them a node
-- reachable through the cycle. Those categories report their item counts
-- several times over.
--
-- A cycle is what the walk has to detect, by carrying the path and stopping
-- when a node appears in it twice, and an application rule or a periodic check
-- is what stops one being created. The depth limit turned a hang, which somebody
-- would have investigated, into a wrong number, which nobody did.
CREATE TABLE catalog.merchandise_tree (
    node_id   integer PRIMARY KEY,
    parent_id integer REFERENCES catalog.merchandise_tree(node_id),
    node_name varchar(60) NOT NULL,
    item_count integer NOT NULL
);

INSERT INTO catalog.merchandise_tree (node_id, parent_id, node_name, item_count)
SELECT g,
       CASE WHEN g <= 10 THEN NULL ELSE 1 + (g / 10) END,
       'Category ' || lpad(g::text, 4, '0'),
       10 + (g * 7) % 90
FROM generate_series(1, 300) AS g;

-- The March merge, which pointed a node at one of its own descendants.
UPDATE catalog.merchandise_tree SET parent_id = 35 WHERE node_id = 4;

CREATE VIEW analytics.v_merchandise_rollup AS
WITH RECURSIVE walk(root_id, node_id, item_count, depth) AS (
    SELECT t.node_id, t.node_id, t.item_count, 0
    FROM catalog.merchandise_tree t
    UNION ALL
    SELECT w.root_id, c.node_id, c.item_count, w.depth + 1
    FROM walk w
    JOIN catalog.merchandise_tree c ON c.parent_id = w.node_id
    WHERE w.depth < 8
)
SELECT root_id, node_id, item_count, depth FROM walk;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.brand_aliases ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.brand_aliases:' || concat_ws('|', x.brand_ref, x.alias))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.brand_aliases x
)
UPDATE catalog.brand_aliases t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.brand_aliases ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.brand_aliases ADD CONSTRAINT brand_aliases_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_brand_aliases_product_id ON catalog.brand_aliases (product_id);

ALTER TABLE fulfilment.courier_bookings ADD COLUMN carrier_id integer;

WITH p AS (
    SELECT carrier_id AS v, row_number() OVER (ORDER BY carrier_id) - 1 AS k
      FROM fulfilment.carriers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.carriers)
                 * power((abs(hashtext('fulfilment.courier_bookings:' || concat_ws('|', x.depot))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.courier_bookings x
)
UPDATE fulfilment.courier_bookings t
   SET carrier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.courier_bookings ALTER COLUMN carrier_id SET NOT NULL;
ALTER TABLE fulfilment.courier_bookings ADD CONSTRAINT courier_bookings_carrier_id_fkey FOREIGN KEY (carrier_id) REFERENCES fulfilment.carriers (carrier_id);
CREATE INDEX ix_courier_bookings_carrier_id ON fulfilment.courier_bookings (carrier_id);

ALTER TABLE ops.goods_labels ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.goods_labels:' || concat_ws('|', x.item_ref, x.batch_no, x.depot, x.printed_label))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.goods_labels x
)
UPDATE ops.goods_labels t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.goods_labels ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.goods_labels ADD CONSTRAINT goods_labels_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_goods_labels_warehouse_id ON ops.goods_labels (warehouse_id);

ALTER TABLE supply.stock_adjustments ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.stock_adjustments:' || concat_ws('|', x.sku, x.quantity, x.reason))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.stock_adjustments x
)
UPDATE supply.stock_adjustments t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.stock_adjustments ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.stock_adjustments ADD CONSTRAINT stock_adjustments_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_stock_adjustments_purchase_order_id ON supply.stock_adjustments (purchase_order_id);
-- <<< relationships
