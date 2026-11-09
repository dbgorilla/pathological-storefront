-- Cross River Trading Co. -- trading history to the end of 2021
-- author: (fixture data)
-- postgres: 13
--
-- Nine years of trading, loaded here so that every migration after this point
-- operates on real rows. That matters: the 2023 NOT VALID constraints and the
-- 2026 partial backfill are only defects because there is data behind them.
--
-- Every value is derived arithmetically from generate_series, so the same
-- migration produces the same database on every run. There is no randomness.
--
-- Volumes are deliberately modest. Scaling this up is a separate job.

-- ---------------------------------------------------------------------------
-- Catalogue
-- ---------------------------------------------------------------------------

INSERT INTO storefront.categories (name, slug)
SELECT c.name, lower(replace(replace(c.name, ' & ', '-'), ' ', '-'))
FROM (VALUES
    ('Hardware'), ('Garden'), ('Kitchen'), ('Decorating'),
    ('Electrical'), ('Plumbing'), ('Timber'), ('Tools'),
    ('Cleaning'), ('Pet Supplies'), ('Stationery'), ('Automotive')
) AS c(name);

INSERT INTO catalog.brands (name, website)
SELECT 'Brand ' || chr(64 + g), 'https://brand' || g || '.example'
FROM generate_series(1, 14) AS g;

-- 2000 products. store_id is left null on the older two thirds, which is the
-- 2014 "null means the original shop" convention.
INSERT INTO storefront.products (sku, name, description, category_id, price_cents, created_at, store_id, brand_id)
SELECT
    'CR-' || lpad(g::text, 6, '0'),
    (ARRAY['Heavy Duty','Compact','Trade','Basic','Pro','Garden','Utility','Classic'])[1 + (g % 8)]
        || ' ' ||
    (ARRAY['Hammer','Spade','Kettle','Roller','Socket','Washer','Plank','Chisel',
           'Mop','Lead','Notebook','Wrench'])[1 + (g % 12)]
        || ' ' || g,
    'Catalogue item ' || g,
    1 + (g % 12),
    199 + (g * 37) % 24000,
    TIMESTAMPTZ '2012-03-01' + make_interval(days => (g * 1721) % 3560),
    CASE WHEN g % 3 = 0 THEN 1 + (g % 3) ELSE NULL END,
    1 + (g % 14)
FROM generate_series(1, 2000) AS g;

INSERT INTO storefront.inventory (product_id, quantity_available, store_id)
SELECT product_id, 5 + (product_id * 7) % 400,
       CASE WHEN product_id % 4 = 0 THEN 1 ELSE NULL END
FROM storefront.products;

-- Variants on a fifth of the catalogue.
INSERT INTO catalog.product_variants (product_id, variant_sku, size, colour, price_cents)
SELECT
    p.product_id,
    'CR-' || lpad(p.product_id::text, 6, '0') || '-' || s.n,
    (ARRAY['S','M','L','XL'])[1 + (s.n % 4)],
    (ARRAY['red','blue','green','black'])[1 + ((p.product_id + s.n) % 4)],
    p.price_cents + (s.n * 150)
FROM storefront.products p
CROSS JOIN generate_series(1, 2) AS s(n)
WHERE p.product_id % 5 = 0;

-- Entity-attribute-value rows, three per product on a slice of the catalogue.
INSERT INTO catalog.product_attributes (product_id, attribute_name, attribute_value, value_kind)
SELECT
    p.product_id,
    (ARRAY['weight_kg','material','voltage'])[s.n],
    (ARRAY[(0.5 + (p.product_id % 40))::text, 'steel', '240V'])[s.n],
    (ARRAY['number','text','text'])[s.n]
FROM storefront.products p
CROSS JOIN generate_series(1, 3) AS s(n)
WHERE p.product_id % 7 = 0;

-- Spec documents on a slice, so the jsonb containment query has something to
-- miss the index on.
UPDATE storefront.products
   SET spec = jsonb_build_object(
        'voltage', CASE WHEN product_id % 3 = 0 THEN '240V' ELSE '110V' END,
        'weight_kg', (0.5 + (product_id % 40)),
        'origin', (ARRAY['UK','DE','CN','PL'])[1 + (product_id % 4)])
 WHERE product_id % 4 = 0;

-- The suppliers who send weight_kg twice: a packed weight and then a unit
-- weight, both under the same key. The raw sheet is kept and the parsed
-- document is derived from it, which is what the import does.
UPDATE storefront.products
   SET spec_source = '{"voltage": "' || CASE WHEN product_id % 3 = 0 THEN '240V' ELSE '110V' END
        || '", "weight_kg": ' || (0.5 + (product_id % 40))
        || ', "origin": "' || (ARRAY['UK','DE','CN','PL'])[1 + (product_id % 4)]
        || '", "weight_kg": ' || (0.1 + ((product_id % 40) / 10.0)) || '}'
 WHERE product_id % 20 = 0;

UPDATE storefront.products
   SET spec = spec_source::jsonb
 WHERE spec_source IS NOT NULL;

-- The 2018 discontinuation import only classified the products the buyers had
-- in their spreadsheet. One in seven was not in it and was left unknown.
UPDATE storefront.products
   SET is_discontinued = CASE
        WHEN product_id % 7 = 0 THEN NULL
        WHEN product_id % 11 = 0 THEN true
        ELSE false
   END;

-- ---------------------------------------------------------------------------
-- Customers
-- ---------------------------------------------------------------------------

INSERT INTO storefront.customers (email, full_name, created_at, marketing_optin)
SELECT
    'customer' || g || '@example.invalid',
    (ARRAY['Alex','Sam','Jordan','Taylor','Morgan','Casey','Riley','Jamie'])[1 + (g % 8)]
        || ' ' ||
    (ARRAY['Smith','Jones','Lee','Patel','Garcia','Nguyen','Khan','Obrien'])[1 + ((g / 8) % 8)],
    TIMESTAMPTZ '2012-03-01' + make_interval(days => (g * 1103) % 3560),
    -- Four spellings for two states, exactly as the 2013 migration describes.
    CASE g % 4
        WHEN 0 THEN 'Y'
        WHEN 1 THEN 'N'
        WHEN 2 THEN 'yes'
        ELSE NULL
    END
FROM generate_series(1, 3000) AS g;

-- ---------------------------------------------------------------------------
-- Orders, 2012 to 2021
-- ---------------------------------------------------------------------------
--
-- Deliberately uneven: a tenth of the customers carry most of the orders, so
-- the planner's average-rows-per-customer estimate is wrong for exactly the
-- customers anyone looks up.

INSERT INTO storefront.orders (customer_id, status, placed_at, store_id)
SELECT
    CASE WHEN g % 10 = 0 THEN 1 + (g % 300) ELSE 1 + (g % 3000) END,
    (ARRAY['paid','paid','paid','paid','shipped','shipped','cancelled','pending'])[1 + (g % 8)],
    TIMESTAMPTZ '2012-03-01' + make_interval(days => (g * 433) % 3560, mins => (g * 17) % 1440),
    CASE WHEN g % 7 = 0 THEN NULL ELSE 1 + (g % 3) END
FROM generate_series(1, 8000) AS g;

INSERT INTO storefront.order_items (order_id, product_id, quantity, unit_price_cents)
SELECT
    o.order_id,
    1 + ((o.order_id * s.n * 13) % 2000),
    1 + (s.n % 4),
    p.price_cents
FROM storefront.orders o
CROSS JOIN LATERAL generate_series(1, 1 + (o.order_id % 3)) AS s(n)
JOIN storefront.products p ON p.product_id = 1 + ((o.order_id * s.n * 13) % 2000)
-- order_item_id is generated, so without this the plan decides which row gets
-- which id. Later migrations pick rows by `order_item_id % 31` and similar, and
-- those defects then measure a different number on a machine that chooses a
-- parallel scan. Seen for real: a build that reported 23 duplicate promotions
-- against a catalogued 25.
ORDER BY o.order_id, s.n;

UPDATE storefront.orders o
   SET total_cents = sub.total
  FROM (SELECT order_id, sum(quantity * unit_price_cents) AS total
          FROM storefront.order_items GROUP BY order_id) sub
 WHERE o.order_id = sub.order_id;

-- Page views. High churn, and the table whose statistics later go stale.
INSERT INTO storefront.page_views (customer_id, product_id, viewed_at, store_id)
SELECT
    1 + (g % 3000),
    1 + (g % 2000),
    TIMESTAMPTZ '2012-03-01' + make_interval(days => (g * 211) % 3560, mins => (g * 7) % 1440),
    CASE WHEN g % 5 = 0 THEN 3 ELSE NULL END
FROM generate_series(1, 15000) AS g;

-- Price history, half-open windows.
INSERT INTO storefront.price_history (product_id, price_cents, in_force, changed_by)
SELECT
    p.product_id,
    p.price_cents - 100,
    tstzrange(
        TIMESTAMPTZ '2019-01-01' + make_interval(days => (p.product_id % 400)),
        TIMESTAMPTZ '2019-01-01' + make_interval(days => (p.product_id % 400) + 90)
    ),
    'pricing-job'
FROM storefront.products p
WHERE p.product_id % 6 = 0;

-- ---------------------------------------------------------------------------
-- Fulfilment
-- ---------------------------------------------------------------------------

INSERT INTO fulfilment.shipments (order_id, carrier_id, warehouse_id, tracking_code, status, dispatched_at)
SELECT
    o.order_id,
    1 + (o.order_id % 3),
    1,
    'TRK' || lpad(o.order_id::text, 9, '0'),
    CASE WHEN o.status = 'shipped' THEN 'delivered' ELSE 'pending' END,
    o.placed_at + INTERVAL '2 days'
FROM storefront.orders o
WHERE o.status IN ('paid', 'shipped');

INSERT INTO fulfilment.stock_locations (warehouse_id, aisle, bay, product_id, quantity, position)
SELECT
    1,
    chr(65 + (p.product_id % 12)),
    lpad(((p.product_id % 40) + 1)::text, 2, '0'),
    p.product_id,
    10 + (p.product_id % 90),
    point(((p.product_id % 110))::float8, ((p.product_id % 70))::float8)
FROM storefront.products p
WHERE p.product_id % 3 = 0;

INSERT INTO fulfilment.returns (order_id, reason, received_at)
SELECT
    o.order_id,
    (ARRAY['damaged','wrong_item','unwanted','late','other'])[1 + (o.order_id % 5)],
    o.placed_at + INTERVAL '9 days'
FROM storefront.orders o
WHERE o.order_id % 23 = 0;

-- A supervisor approves a quantity before the line goes back on the shelf.
-- One return in four is still waiting for that approval, and every one of them
-- was restocked anyway.
INSERT INTO fulfilment.return_lines (return_id, order_item_id, quantity, approved_quantity, restocked)
SELECT r.return_id, oi.order_item_id, 1,
       CASE WHEN r.return_id % 4 = 0 THEN NULL ELSE 1 END,
       (r.return_id % 2 = 0)
FROM fulfilment.returns r
JOIN LATERAL (
    SELECT order_item_id FROM storefront.order_items
     WHERE order_id = r.order_id ORDER BY order_item_id LIMIT 1
) oi ON true;

-- ---------------------------------------------------------------------------
-- Supply
-- ---------------------------------------------------------------------------

INSERT INTO supply.suppliers (code, name, contact_email, lead_time_days, account_code)
SELECT 'SUP' || lpad(g::text, 3, '0'),
       'Supplier ' || g,
       'orders@supplier' || g || '.example',
       3 + (g % 28),
       -- Supplier 40 carries the reissued form of supplier 1's account code:
       -- the same six characters with a space after them. The finance system
       -- treats those as two accounts. char(12) treats them as one.
       CASE WHEN g = 40 THEN 'ACC001 ' ELSE 'ACC' || lpad(g::text, 3, '0') END
FROM generate_series(1, 40) AS g;

-- (supplier_id, supplier_sku) is unique across every row here. Nothing says so.
INSERT INTO supply.supplier_products (supplier_id, product_id, supplier_sku, cost_cents, minimum_order_qty)
SELECT
    1 + (p.product_id % 40),
    p.product_id,
    'S' || (1 + (p.product_id % 40)) || '-' || p.product_id,
    (p.price_cents * 6) / 10,
    1 + (p.product_id % 12)
FROM storefront.products p;

INSERT INTO supply.purchase_orders (supplier_id, warehouse_id, reference, status, raised_at, expected_on)
SELECT
    1 + (g % 40), 1,
    'PO-' || lpad(g::text, 6, '0'),
    (ARRAY['received','received','sent','part_received','draft'])[1 + (g % 5)],
    TIMESTAMPTZ '2018-01-16' + make_interval(days => (g * 31) % 1400),
    (TIMESTAMPTZ '2018-01-16' + make_interval(days => ((g * 31) % 1400) + 14))::date
FROM generate_series(1, 600) AS g;

INSERT INTO supply.purchase_order_lines (purchase_order_id, product_id, quantity_ordered, quantity_received, unit_cost_cents, unit_cost)
SELECT
    po.purchase_order_id,
    1 + ((po.purchase_order_id * s.n * 7) % 2000),
    10 * (1 + (s.n % 5)),
    CASE WHEN po.status = 'received' THEN 10 * (1 + (s.n % 5)) ELSE 0 END,
    500 + (po.purchase_order_id % 4000),
    -- Suppliers who quote per thousand send six decimal places, and the column
    -- has no scale to round them to. One purchase order in three is on those
    -- terms.
    CASE
        WHEN po.purchase_order_id % 3 = 0
            THEN ((500 + (po.purchase_order_id % 4000))::numeric / 97)
        ELSE round((500 + (po.purchase_order_id % 4000))::numeric / 100, 2)
    END
FROM supply.purchase_orders po
CROSS JOIN generate_series(1, 3) AS s(n);

-- supply.receipts stays empty. That is the defect.

-- ---------------------------------------------------------------------------
-- Payments
-- ---------------------------------------------------------------------------

INSERT INTO payments.payment_methods (customer_id, kind, last_four, expires_on, is_default)
SELECT
    c.customer_id,
    (ARRAY['card','card','paypal','account'])[1 + (c.customer_id % 4)],
    lpad(((c.customer_id * 13) % 10000)::text, 4, '0'),
    (DATE '2027-01-01' + make_interval(days => (c.customer_id % 900)))::date,
    true
FROM storefront.customers c
WHERE c.customer_id % 2 = 0;

-- amount is double precision. These values are chosen so that summing the
-- float column and summing the integer-cent column give different answers.
INSERT INTO payments.transactions (order_id, payment_method_id, amount, status, processed_at, provider_ref)
SELECT
    o.order_id,
    pm.payment_method_id,
    (o.total_cents::double precision / 100.0),
    CASE WHEN o.status = 'cancelled' THEN 'failed' ELSE 'captured' END,
    o.placed_at,
    'ref-' || o.order_id
FROM storefront.orders o
LEFT JOIN payments.payment_methods pm ON pm.customer_id = o.customer_id
WHERE o.status <> 'pending';

INSERT INTO payments.refunds (transaction_id, amount_cents, reason, refunded_at)
SELECT
    t.transaction_id,
    greatest(100, (t.amount * 100)::integer / 2),
    'return accepted',
    t.processed_at + INTERVAL '12 days'
FROM payments.transactions t
WHERE t.transaction_id % 31 = 0;

-- A batch of refunds re-imported in 2019 after a provider outage. The import
-- applied the pounds-to-pence conversion twice, once in the export and once in
-- the loader, so these amounts are four orders of magnitude too large. Finance
-- wrote them off against a suspense account rather than deleting them, and they
-- are still here. These are the rows the 2026 refund bound is written over.
INSERT INTO payments.refunds (transaction_id, amount_cents, reason, refunded_at)
SELECT
    t.transaction_id,
    (120000000 + (t.transaction_id % 7) * 40000000)::integer,
    'refund re-import 2019, double conversion',
    t.processed_at + INTERVAL '3 days'
FROM payments.transactions t
WHERE t.transaction_id % 400 = 0;

-- Ledger entries. Most are single sided. Every fiftieth transaction is posted
-- by the adjustment path, which writes both columns on one row instead of
-- writing two rows. Those are the rows the 2026 NOT ENFORCED constraint claims
-- to prevent and does not.
INSERT INTO payments.ledger_entries (transaction_id, account, debit_cents, credit_cents, posted_at)
SELECT
    t.transaction_id,
    (ARRAY['sales','cash','vat','fees'])[1 + (t.transaction_id % 4)],
    CASE
        WHEN t.transaction_id % 50 = 0  THEN greatest(1, (t.amount * 100)::bigint)
        WHEN t.transaction_id % 4  < 2  THEN (t.amount * 100)::bigint
        ELSE 0
    END,
    CASE
        WHEN t.transaction_id % 50 = 0  THEN greatest(1, (t.amount * 100)::bigint)
        WHEN t.transaction_id % 4  >= 2 THEN (t.amount * 100)::bigint
        ELSE 0
    END,
    t.processed_at
FROM payments.transactions t;

-- ---------------------------------------------------------------------------
-- Marketing
-- ---------------------------------------------------------------------------

INSERT INTO marketing.campaigns (name, channel, starts_on, ends_on, budget_cents, targeting, featured_product_ids)
SELECT
    'Campaign ' || g,
    (ARRAY['email','sms','post','display'])[1 + (g % 4)],
    (DATE '2018-08-01' + make_interval(days => (g * 37) % 1200))::date,
    (DATE '2018-08-01' + make_interval(days => ((g * 37) % 1200) + 30))::date,
    100000 + (g * 5000),
    -- One campaign in five was written by the older version of the tool, which
    -- sent the segment list unquoted. Those rows are not JSON and no constraint
    -- was there to say so.
    CASE
        WHEN g % 5 = 0 THEN '{segment: lapsed, min_orders: ' || g || '}'
        ELSE '{"segment": "lapsed", "min_orders": ' || g || '}'
    END,
    -- Three featured products. The 2019 catalogue tidy-up deleted a block of
    -- products in the 9000s, and one campaign in six still names one of them.
    CASE
        WHEN g % 6 = 0 THEN ARRAY[1 + (g * 7) % 2000, 1 + (g * 13) % 2000, 9000 + g]
        ELSE ARRAY[1 + (g * 7) % 2000, 1 + (g * 13) % 2000, 1 + (g * 19) % 2000]
    END
FROM generate_series(1, 60) AS g;

INSERT INTO marketing.coupons (campaign_id, code, percent_off, max_redemptions, expires_at)
SELECT
    1 + (g % 60),
    -- Codes the marketing team typed in themselves, one batch in ten, in
    -- lower case. The trigger that was supposed to fix that is below the table.
    CASE WHEN g % 10 = 0 THEN 'cr' || lpad(g::text, 5, '0')
         ELSE 'CR' || lpad(g::text, 5, '0') END,
    5 * (1 + (g % 6)),
    100 * (1 + (g % 10)),
    TIMESTAMPTZ '2019-01-01' + make_interval(days => (g * 29) % 1400)
FROM generate_series(1, 300) AS g;

INSERT INTO marketing.coupon_redemptions (coupon_id, order_id, customer_id, redeemed_at)
SELECT
    1 + (o.order_id % 300),
    o.order_id,
    o.customer_id,
    o.placed_at
FROM storefront.orders o
WHERE o.order_id % 11 = 0;

INSERT INTO marketing.sms_campaigns (campaign_id, shortcode, body, sent_at)
SELECT
    c.campaign_id, '60' || lpad(c.campaign_id::text, 3, '0'),
    'Cross River offer ' || c.campaign_id,
    TIMESTAMPTZ '2019-06-01' + make_interval(days => c.campaign_id)
FROM marketing.campaigns c
WHERE c.channel = 'sms';

INSERT INTO marketing.promotions (name, active_during, price_band, qty_band, percent_off)
SELECT
    'Promotion ' || g,
    daterange((DATE '2020-01-01' + make_interval(days => g * 10))::date,
              (DATE '2020-01-01' + make_interval(days => g * 10 + 45))::date),
    numrange(100, 50000),
    int4range(1, 20),
    5 * (1 + (g % 5))
FROM generate_series(1, 40) AS g;

INSERT INTO marketing.promotion_products (promotion_id, product_id)
SELECT p.promotion_id, pr.product_id
FROM marketing.promotions p
JOIN storefront.products pr ON pr.product_id % 40 = p.promotion_id % 40
WHERE pr.product_id % 17 = 0;

-- ---------------------------------------------------------------------------
-- Support
-- ---------------------------------------------------------------------------
--
-- subject_type includes 'subscription', pointing at a schema that was dropped
-- in March 2021. The CHECK constraint still permits it.

INSERT INTO support.tickets (customer_id, assigned_agent_id, subject_type, subject_id, status, priority, opened_at)
SELECT
    1 + (g % 3000),
    1 + (g % 2),
    -- Exactly 27 of 600 tickets, 4.5%, name a subject type whose schema was
    -- dropped in March 2021. The CHECK constraint still permits the value.
    CASE WHEN (g % 200) < 9
         THEN 'subscription'
         ELSE (ARRAY['order','order','shipment','product','return'])[1 + (g % 5)]
    END,
    1 + (g % 800),
    (ARRAY['resolved','closed','open','pending'])[1 + (g % 4)],
    1 + (g % 5),
    TIMESTAMPTZ '2020-03-10' + make_interval(days => (g * 3) % 630)
FROM generate_series(1, 600) AS g;

INSERT INTO support.ticket_messages (ticket_id, agent_id, body, is_internal, sent_at)
SELECT
    t.ticket_id,
    CASE WHEN s.n = 1 THEN NULL ELSE 1 + (t.ticket_id % 2) END,
    'Message ' || s.n || ' on ticket ' || t.ticket_id,
    (s.n = 3),
    t.opened_at + make_interval(hours => s.n * 5)
FROM support.tickets t
CROSS JOIN generate_series(1, 3) AS s(n);

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
-- ops.app_config does not exist until 2025 and is seeded there.

-- ---------------------------------------------------------------------------
-- Store hours, saved searches, shipment contents, scanners, product media
-- ---------------------------------------------------------------------------

INSERT INTO storefront.store_hours (store_id, day_of_week, opens_at, closes_at, last_reviewed)
SELECT
    s.store_id,
    d.dow,
    CASE WHEN d.dow = 0 THEN TIME '10:00' ELSE TIME '08:00' END,
    CASE WHEN d.dow = 0 THEN TIME '16:00' ELSE TIME '18:00' END,
    -- timetz, with a fixed offset that stops being correct in March.
    (TIME '09:30' AT TIME ZONE 'UTC')::timetz
FROM storefront.stores s
CROSS JOIN generate_series(0, 6) AS d(dow);

INSERT INTO storefront.saved_searches (customer_id, label, query, created_at)
SELECT
    c.customer_id,
    'Saved search ' || c.customer_id,
    to_tsquery('english', (ARRAY['hammer','spade','kettle','roller'])[1 + (c.customer_id % 4)]),
    c.created_at + INTERVAL '30 days'
FROM storefront.customers c
WHERE c.customer_id % 50 = 0;

INSERT INTO fulfilment.shipment_items (shipment_id, order_item_id, quantity)
SELECT s.shipment_id, oi.order_item_id, oi.quantity
FROM fulfilment.shipments s
JOIN storefront.order_items oi ON oi.order_id = s.order_id;

INSERT INTO fulfilment.scanners (warehouse_id, asset_tag, hw_address, last_seen_at)
SELECT
    1,
    'SCN-' || lpad(g::text, 4, '0'),
    ('02:00:00:00:' || lpad(to_hex(g / 256), 2, '0') || ':' || lpad(to_hex(g % 256), 2, '0'))::macaddr,
    TIMESTAMPTZ '2021-11-30 18:00' - make_interval(hours => g)
FROM generate_series(1, 24) AS g;

INSERT INTO catalog.media_assets (product_id, url, alt_text, sort_order)
SELECT
    p.product_id,
    'https://images.example/crossriver/' || p.sku || '-' || n.i || '.jpg',
    p.name,
    n.i
FROM storefront.products p
CROSS JOIN generate_series(1, 2) AS n(i)
WHERE p.product_id % 2 = 0;

-- Tickets linked to one another. Distinct from a merge: these are related,
-- not duplicates.
INSERT INTO support.ticket_links (from_ticket_id, to_ticket_id, relation)
SELECT t.ticket_id, t.ticket_id + 1,
       (ARRAY['related','duplicate','blocks'])[1 + (t.ticket_id % 3)]
FROM support.tickets t
WHERE t.ticket_id % 17 = 0
  AND EXISTS (SELECT 1 FROM support.tickets x WHERE x.ticket_id = t.ticket_id + 1);
