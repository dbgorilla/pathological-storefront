-- Cross River Trading Co. -- warehouse stock, customer tags, shipping bands
-- author: R. Okonjo
-- postgres: 18
--
-- The second half of the autumn backlog. Warehouse stock moves off the
-- spreadsheet the DC has been keeping since the 2016 launch, marketing gets the
-- customer tags they have asked for twice a year since 2019, and the shipping
-- surcharge finally comes out of the application and into the database.

-- DEFECT ctid-stored-as-a-stable-row-pointer
--
-- supply.contract_price_reviews has no primary key. That is a known problem and
-- it is catalogued separately; this is what somebody built on top of it.
--
-- The nightly export has to record where it got to, and with no key to record
-- there was nothing obvious to store except the row's physical location. ctid
-- looks like an identifier, prints like an identifier, and can be compared and
-- joined like one.
--
-- It is a block number and a slot, and it changes whenever the row is updated,
-- because an update writes a new version of the row somewhere else. Nothing
-- rewrites the saved pointers and nothing errors when they stop matching. A
-- stale pointer either finds no row or, worse, finds whichever row happens to
-- occupy that slot now.
--
-- Measured: 148 pointers were captured and 50 no longer resolve to the row they
-- were captured from, because a reviewer name was corrected on those rows in
-- the same change. VACUUM FULL, a CLUSTER or a restore would invalidate all
-- 148 at once, and none of those operations would log anything.
--
-- The export silently re-sends or silently skips, depending on which way the
-- pointer lands, and the supplier reconciliation has never been able to explain
-- its duplicates.
CREATE TABLE ops.export_cursors (
    cursor_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id integer NOT NULL,
    product_id  integer NOT NULL,
    row_pointer tid     NOT NULL,
    captured_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN ops.export_cursors.row_pointer IS
    'Physical location of the reviewed row. The review table has no key to use instead.';

INSERT INTO ops.export_cursors (supplier_id, product_id, row_pointer)
SELECT r.supplier_id, r.product_id, r.ctid
FROM supply.contract_price_reviews r;

-- The correction that moved a third of the rows. Ordinary, reviewed, and it
-- invalidated a third of the pointers above without touching them.
UPDATE supply.contract_price_reviews
   SET reviewer = btrim(reviewer)
 WHERE supplier_id % 3 = 0;

-- DEFECT upsert-replaces-instead-of-accumulating
--
-- Goods-in calls this once per line on the delivery note. A product arriving
-- for the first time is inserted; a product already stocked is topped up. The
-- ON CONFLICT clause is what makes the second case work and it is why nobody
-- has looked at this function since it shipped.
--
-- EXCLUDED is the row that was proposed, not the row that is there. Assigning
-- on_hand = EXCLUDED.on_hand overwrites the stock level with the size of the
-- delivery. The accumulating version needs warehouse_stock.on_hand +
-- EXCLUDED.on_hand, which is four extra characters and the entire difference.
--
-- Measured: two waves were received, 10 units then 5 units, for each of 200
-- products. Stock should total 3,000 and totals 1,000, which is the second wave
-- alone.
--
-- The error is invisible on a first delivery and invisible whenever consecutive
-- deliveries happen to be the same size. It shows up as shrinkage, which the DC
-- already has a process for, so it is absorbed rather than investigated.
CREATE TABLE supply.warehouse_stock (
    product_id   integer NOT NULL REFERENCES storefront.products(product_id),
    warehouse_id integer NOT NULL REFERENCES fulfilment.warehouses(warehouse_id),
    on_hand      integer NOT NULL CHECK (on_hand >= 0),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (product_id, warehouse_id)
);

CREATE FUNCTION supply.fn_receive_stock(p_product integer, p_warehouse integer, p_units integer)
RETURNS void
LANGUAGE sql
AS $$
    INSERT INTO supply.warehouse_stock (product_id, warehouse_id, on_hand)
    VALUES (p_product, p_warehouse, p_units)
    ON CONFLICT (product_id, warehouse_id)
    DO UPDATE SET on_hand = EXCLUDED.on_hand,
                  updated_at = now();
$$;

COMMENT ON FUNCTION supply.fn_receive_stock(integer, integer, integer) IS
    'Record a received quantity against warehouse stock. Called once per delivery line.';

-- Two deliveries of the same 200 products, a fortnight apart.
SELECT supply.fn_receive_stock(p.product_id, 1, 10)
FROM (SELECT product_id FROM storefront.products ORDER BY product_id LIMIT 200) p;

SELECT supply.fn_receive_stock(p.product_id, 1, 5)
FROM (SELECT product_id FROM storefront.products ORDER BY product_id LIMIT 200) p;

-- DEFECT array-agg-over-an-outer-join-produces-a-null-element
--
-- Marketing wanted every customer with their tags, tags being optional, which
-- is what the LEFT JOIN is for. The join is right. The aggregate is not.
--
-- array_agg over an outer join that matched nothing does not return an empty
-- array. It returns an array containing one NULL, because the outer join
-- produced one row with a NULL in it and array_agg faithfully aggregated that
-- row. The result has length 1 and reads as a customer with one tag.
--
-- Measured: 2,340 of the 3,120 customers have no tags at all, and every one of
-- them is reported with an array of length 1. Any consumer that counts tags by
-- array_length sees 3,120 tagged customers and zero untagged ones.
--
-- array_remove, or array_agg with a FILTER clause, returns the empty array that
-- was meant. The segmentation export has been reading these as a tag it does
-- not recognise and dropping them, which is the only reason the campaign lists
-- are not four times too big.
CREATE TABLE marketing.customer_tags (
    customer_id integer NOT NULL REFERENCES storefront.customers(customer_id),
    tag         varchar(40) NOT NULL,
    tagged_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (customer_id, tag)
);

INSERT INTO marketing.customer_tags (customer_id, tag)
SELECT c.customer_id,
       CASE c.customer_id % 12
           WHEN 0 THEN 'trade'
           WHEN 4 THEN 'high-value'
           ELSE 'newsletter'
       END
FROM storefront.customers c
WHERE c.customer_id % 4 = 0;

CREATE VIEW analytics.v_customer_tags AS
SELECT c.customer_id,
       c.email,
       array_agg(t.tag) AS tags
FROM storefront.customers c
LEFT JOIN marketing.customer_tags t ON t.customer_id = c.customer_id
GROUP BY c.customer_id, c.email;

-- DEFECT planner-setting-baked-into-a-function
--
-- The daily revenue call was slow once, on a day when the planner chose a
-- sequential scan over the orders table. Turning the sequential scan off in a
-- session made it fast, and the fix was to make that permanent by attaching the
-- setting to the function.
--
-- A SET clause on a function applies for the whole call and cannot be overridden
-- by the caller. It is not a hint, it is a prohibition, and it survives every
-- change in data volume, statistics and PostgreSQL version that would otherwise
-- have let the planner choose correctly. enable_seqscan = off does not forbid
-- sequential scans outright; it prices them absurdly, so the planner takes an
-- index plan that is worse whenever the index plan is worse.
--
-- Measured: the function carries proconfig enable_seqscan=off. It is the only
-- routine in the database that does, and it is invisible in the function body,
-- so reading the SQL tells you nothing.
--
-- It is fast on a single day, which is how it is always tested, and it is the
-- reason the month-end call takes minutes. Nobody connects the two, because the
-- month-end call is a different routine that calls this one in a loop.
CREATE FUNCTION analytics.fn_revenue_for_day(p_day date)
RETURNS bigint
LANGUAGE sql
STABLE
SET enable_seqscan = off
AS $$
    SELECT coalesce(sum(o.total_cents), 0)
      FROM storefront.orders o
     WHERE o.placed_at::date = p_day;
$$;

COMMENT ON FUNCTION analytics.fn_revenue_for_day(date) IS
    'Revenue for one day. SET added after a slow query in 2024.';

-- DEFECT overlapping-bands-match-a-value-twice
--
-- The shipping surcharge is a lookup by unit count, and the bands were typed in
-- from the carrier's rate card, which prints them as 1-2, 2-3, 3-4. The rate
-- card means those boundaries to belong to one band each. BETWEEN is inclusive
-- at both ends, so as written every boundary value belongs to two.
--
-- A lookup that matches twice is not an error, it is a join that returns two
-- rows, and the view that sums the surcharge sums both of them.
--
-- Measured: 27,761 order lines produce 50,895 rows through the view. Every line
-- of 2 units and every line of 3 units is counted twice, because 2 and 3 are
-- both boundaries. Only the 4,627 lines of 4 units are counted once.
--
-- The surcharge total is therefore almost exactly double, and it has been
-- reconciled against the carrier invoice by applying a correction factor that
-- somebody derived empirically in 2024 and wrote into the finance spreadsheet.
CREATE TABLE fulfilment.shipping_bands (
    band_id         integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    label           varchar(20) NOT NULL,
    min_units       integer NOT NULL,
    max_units       integer NOT NULL,
    surcharge_cents integer NOT NULL,
    CHECK (max_units >= min_units)
);

INSERT INTO fulfilment.shipping_bands (label, min_units, max_units, surcharge_cents)
VALUES ('1-2 units', 1, 2, 250),
       ('2-3 units', 2, 3, 400),
       ('3-4 units', 3, 4, 550);

CREATE VIEW fulfilment.v_order_item_surcharge AS
SELECT oi.order_item_id,
       oi.order_id,
       oi.quantity,
       b.label,
       b.surcharge_cents
FROM storefront.order_items oi
JOIN fulfilment.shipping_bands b
  ON oi.quantity BETWEEN b.min_units AND b.max_units;

-- DEFECT refresh-matview-inside-a-row-trigger
--
-- The merchandising dashboard was stale between nightly refreshes, and the
-- request was to have it update when stock changed. This does exactly that, one
-- row at a time.
--
-- REFRESH MATERIALIZED VIEW rebuilds the whole view. In a FOR EACH ROW trigger
-- it rebuilds the whole view once per row, so a delivery note of two hundred
-- lines aggregates every order line in the database two hundred times, inside
-- the transaction that is trying to record the delivery. It also takes an
-- ACCESS EXCLUSIVE lock on the view each time, so the dashboard is unavailable
-- for the duration and any concurrent goods-in blocks behind it.
--
-- Measured: it is the only trigger in the database whose function refreshes a
-- materialised view. It is attached to supply.warehouse_stock and it fires per
-- row on insert and on update.
--
-- Nothing has gone wrong yet because the trigger was added after this
-- migration's own load, and goods-in has not run since. The first delivery note
-- through it will be the test.
CREATE FUNCTION supply.fn_refresh_product_revenue()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW analytics.mv_product_revenue;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_warehouse_stock_refresh_revenue
    AFTER INSERT OR UPDATE ON supply.warehouse_stock
    FOR EACH ROW EXECUTE FUNCTION supply.fn_refresh_product_revenue();
