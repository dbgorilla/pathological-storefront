-- Cross River Trading Co. -- trading history, 2022 to the start of 2026
-- author: (fixture data)
-- postgres: 17
--
-- The second half of the trading history. It is loaded here, before the
-- PostgreSQL 18 migrations, so that those migrations act on real rows.
--
-- currency_code is set by hand rather than left to the column default, because
-- the column did not exist until February 2023. Orders placed before then have
-- no currency, which is the state the 2026 backfill is written against.
--
-- 5880 orders spread evenly over 1470 days from 2022-01-01. Every day offset
-- carries exactly four orders, so the counts the backfill produces are exact.

INSERT INTO storefront.orders (customer_id, status, placed_at, store_id, currency_code)
SELECT
    CASE WHEN g % 10 = 0 THEN 1 + (g % 300) ELSE 1 + (g % 3000) END,
    (ARRAY['paid','paid','paid','paid','shipped','shipped','cancelled','pending'])[1 + (g % 8)],
    TIMESTAMPTZ '2022-01-01' + make_interval(days => g % 1470, mins => (g * 23) % 1440),
    CASE WHEN g % 7 = 0 THEN NULL ELSE 1 + (g % 3) END,
    -- Day offset 408 is 2023-02-13, the day the column was added.
    CASE WHEN (g % 1470) >= 408 THEN 'GBP' ELSE NULL END
FROM generate_series(1, 5880) AS g;

INSERT INTO storefront.order_items (order_id, product_id, quantity, unit_price_cents)
SELECT
    o.order_id,
    1 + ((o.order_id * s.n * 13) % 2000),
    1 + (s.n % 4),
    p.price_cents
FROM storefront.orders o
CROSS JOIN LATERAL generate_series(1, 1 + (o.order_id % 3)) AS s(n)
JOIN storefront.products p ON p.product_id = 1 + ((o.order_id * s.n * 13) % 2000)
WHERE o.placed_at >= TIMESTAMPTZ '2022-01-01'
-- Same reason as the order_items insert in V2021.12.01: order_item_id is
-- generated, later migrations pick rows by it, and without an order the plan
-- decides which row gets which id.
ORDER BY o.order_id, s.n;

UPDATE storefront.orders o
   SET total_cents = sub.total
  FROM (SELECT order_id, sum(quantity * unit_price_cents) AS total
          FROM storefront.order_items GROUP BY order_id) sub
 WHERE o.order_id = sub.order_id
   AND o.placed_at >= TIMESTAMPTZ '2022-01-01';

INSERT INTO fulfilment.shipments (order_id, carrier_id, warehouse_id, tracking_code, status, dispatched_at)
SELECT
    o.order_id,
    1 + (o.order_id % 3),
    1,
    'TRK' || lpad(o.order_id::text, 9, '0'),
    CASE WHEN o.status = 'shipped' THEN 'delivered' ELSE 'pending' END,
    o.placed_at + INTERVAL '2 days'
FROM storefront.orders o
WHERE o.placed_at >= TIMESTAMPTZ '2022-01-01'
  AND o.status IN ('paid', 'shipped');

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
WHERE o.placed_at >= TIMESTAMPTZ '2022-01-01'
  AND o.status <> 'pending';

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
FROM payments.transactions t
WHERE t.processed_at >= TIMESTAMPTZ '2022-01-01';

INSERT INTO storefront.page_views (customer_id, product_id, viewed_at, store_id)
SELECT
    1 + (g % 3000),
    1 + (g % 2000),
    TIMESTAMPTZ '2022-01-01' + make_interval(days => (g * 31) % 1470, mins => (g * 11) % 1440),
    CASE WHEN g % 5 = 0 THEN 3 ELSE NULL END
FROM generate_series(1, 10000) AS g;
