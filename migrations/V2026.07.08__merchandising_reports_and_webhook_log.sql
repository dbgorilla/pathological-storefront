-- Cross River Trading Co. -- merchandising reports, supplier invoices, webhooks
-- author: P. Adeyemi
-- postgres: 18
--
-- Reporting work for the merchandising team, the supplier invoice register that
-- finance has been keeping in a spreadsheet, and the webhook delivery log that
-- came out of the 2026 integrations project.

-- DEFECT window-partition-missing-so-the-rank-is-global
--
-- Merchandising wanted the top products in each store, so they could see what
-- sells in the retail park that does not sell in town. The view groups by store
-- and product, and ranks by revenue, and every part of that is right except the
-- window.
--
-- rank() OVER (ORDER BY ...) with no PARTITION BY ranks over the whole result.
-- The store column is still there, still correct, still grouped, and the rank
-- beside it has nothing to do with it. A store's best-selling product may carry
-- rank 4,000.
--
-- Measured: filtering the view to revenue_rank <= 10 returns 10 rows, all from
-- whichever store sells most. The intended filter returns 40, because ranking
-- within each of the three stores carries ties past ten. Adding PARTITION BY
-- o.store_id is the whole fix.
--
-- The report looks right on the busiest store, because for that store a global
-- rank and a per-store rank nearly agree at the top. It is wrong everywhere
-- else, and the two smaller stores have concluded their customers buy nothing.
CREATE VIEW analytics.v_store_product_rank AS
SELECT o.store_id,
       oi.product_id,
       sum(oi.line_total_cents) AS revenue_cents,
       rank() OVER (ORDER BY sum(oi.line_total_cents) DESC) AS revenue_rank
FROM storefront.order_items oi
JOIN storefront.orders o ON o.order_id = oi.order_id
GROUP BY o.store_id, oi.product_id;

-- DEFECT group-by-a-non-unique-label-merges-entities
--
-- Spend per customer, grouped by the customer. The author grouped by the column
-- a human reads, which is the name, rather than the column that identifies the
-- row, which is the id.
--
-- Two customers with the same name become one row. Their orders are added
-- together and the result is attributed to a person who does not exist. Nothing
-- in the output says this happened; the view returns fewer rows than there are
-- customers and there is no obvious reason it should not.
--
-- Measured: the view returns 64 rows. 2,730 customers have ordered. The seed
-- data draws names from a small pool, so this is extreme here, but the shape is
-- the point: a name is not a key, and the report cannot tell you it merged.
--
-- This feeds the top-customers list, which is why the same handful of names has
-- been at the top of it since the report was written. They are not customers,
-- they are name collisions, and each one is dozens of people.
CREATE VIEW analytics.v_spend_by_customer_name AS
SELECT c.full_name,
       count(DISTINCT o.order_id) AS orders,
       sum(o.total_cents)         AS spend_cents
FROM storefront.customers c
JOIN storefront.orders o ON o.customer_id = c.customer_id
GROUP BY c.full_name;

-- DEFECT date-stored-as-text-sorts-lexically
--
-- The invoice register was a spreadsheet, and it was loaded as a spreadsheet:
-- every column text, every date in the format the supplier prints it in, day
-- first and no leading zeros. Changing the type was on the list and the list
-- was long.
--
-- A date in a text column sorts as text. '9/8/2026' is greater than
-- '22/12/2026' because '9' is greater than '2', and no comparison involving
-- these values means what it appears to mean. Nothing errors, because text
-- comparison is perfectly well defined; it is simply answering a different
-- question from the one asked.
--
-- Measured: max(invoice_date) returns '9/8/2026'. The latest invoice in the
-- register is dated 22 December 2026. Ordering by this column produces an order
-- that is neither chronological nor obviously wrong at a glance.
--
-- The month-end cut-off query uses a range over this column, which is why the
-- December accruals have been short every year and are corrected by hand in
-- January.
CREATE TABLE supply.supplier_invoices (
    invoice_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id  integer NOT NULL REFERENCES supply.suppliers(supplier_id),
    invoice_ref  varchar(30) NOT NULL,
    invoice_date varchar(10) NOT NULL,
    amount_cents integer NOT NULL CHECK (amount_cents > 0)
);

COMMENT ON COLUMN supply.supplier_invoices.invoice_date IS
    'Invoice date as printed by the supplier, day first. Retype as date: CRT-2231.';

INSERT INTO supply.supplier_invoices (supplier_id, invoice_ref, invoice_date, amount_cents)
SELECT 1 + (g % 7),
       'INV-' || lpad(g::text, 5, '0'),
       to_char(DATE '2025-01-04' + (g * 3), 'FMDD/FMMM/YYYY'),
       10000 + (g * 137)
FROM generate_series(0, 239) AS g;

-- DEFECT coalesce-turns-a-missing-join-into-zero
--
-- Spend per customer, this time keyed correctly and outer joined so that every
-- customer appears. The coalesce was added because the report looked untidy
-- with blanks in it.
--
-- A null on the null-producing side of an outer join means the customer has no
-- orders. Zero means the customer has orders that came to nothing. Replacing
-- the first with the second destroys the only distinction the report needed to
-- make, and it cannot be recovered downstream, because by then the two look
-- identical.
--
-- Measured: 390 customers report a spend of zero, and all 390 have never
-- ordered. There is not one genuine zero among them, so every value the
-- coalesce produced is a lie about a customer who is not a customer yet.
--
-- The win-back campaign targets customers whose spend has fallen to zero. It
-- has been mailing 390 people who have never bought anything, with a message
-- that thanks them for their past custom.
CREATE VIEW analytics.v_customer_spend_zero_filled AS
SELECT c.customer_id,
       c.full_name,
       coalesce(sum(o.total_cents), 0) AS spend_cents
FROM storefront.customers c
LEFT JOIN storefront.orders o ON o.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name;

-- DEFECT cte-materialized-blocks-predicate-pushdown
--
-- Written when the database was PostgreSQL 11, where every CTE was an
-- optimisation fence and MATERIALIZED did not exist as a keyword. The 2026
-- upgrade to 18 would have changed the plan, because from 12 onwards a CTE
-- referenced once is inlined and a filter on the view reaches the tables. The
-- upgrade notes said so, and the author added the keyword to keep the plan the
-- same.
--
-- The plan they kept is the slow one. AS MATERIALIZED forces the CTE to be
-- executed in full and stored, so a caller selecting one store's lines still
-- builds every order line in the database first and filters afterwards. The
-- keyword is doing exactly what it says, which is why nobody suspects it.
--
-- Measured: it is the only view in the database whose definition forces
-- materialisation. The CTE it fences is a 27,761 row join that every caller
-- pays for in full whatever they asked for.
--
-- The view is correct. It returns the right rows and always has, so it has
-- never been looked at in any investigation of why the merchandising screens
-- are slow.
CREATE VIEW analytics.v_recent_order_lines AS
WITH lines AS MATERIALIZED (
    SELECT oi.order_item_id,
           oi.order_id,
           oi.product_id,
           oi.quantity,
           oi.line_total_cents,
           o.store_id,
           o.placed_at
    FROM storefront.order_items oi
    JOIN storefront.orders o ON o.order_id = oi.order_id
)
SELECT * FROM lines;

-- DEFECT uuid-version-mixed-in-one-key-column
--
-- The webhook log was built in early 2026 on PostgreSQL 14, so its keys are
-- gen_random_uuid(), which is version 4 and random. After the upgrade to 18 the
-- default was changed to uuidv7(), which is version 7 and carries its creation
-- time in its leading bits. Both are uuids, both are unique, and the column
-- accepted the change without comment.
--
-- A version 7 key sorts by creation time and a version 4 key sorts arbitrarily.
-- In one column that means ordering by the key is chronological for the rows
-- written after the upgrade and meaningless for the rows written before, and
-- the join between the two halves of the table is silent.
--
-- Measured: 400 of the 1,000 keys are version 4 and 600 are version 7. Nothing
-- in the schema records which rows are which, and the only way to tell is to
-- read the version nibble out of the value.
--
-- The retention job deletes the oldest deliveries by ordering on the key, which
-- works for the version 7 rows and deletes version 4 rows at random. It has
-- been running since July.
CREATE TABLE ops.webhook_deliveries (
    delivery_id  uuid PRIMARY KEY DEFAULT uuidv7(),
    endpoint     varchar(120) NOT NULL,
    status_code  integer NOT NULL,
    delivered_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN ops.webhook_deliveries.delivery_id IS
    'Delivery key. Default changed from gen_random_uuid() to uuidv7() at the 18 upgrade.';

-- The rows written before the upgrade.
INSERT INTO ops.webhook_deliveries (delivery_id, endpoint, status_code)
SELECT gen_random_uuid(),
       'https://hooks.crossriver.example/order/' || (g % 5),
       CASE WHEN g % 23 = 0 THEN 500 ELSE 200 END
FROM generate_series(1, 400) AS g;

-- The rows written after it.
INSERT INTO ops.webhook_deliveries (endpoint, status_code)
SELECT 'https://hooks.crossriver.example/order/' || (g % 5),
       CASE WHEN g % 23 = 0 THEN 500 ELSE 200 END
FROM generate_series(1, 600) AS g;
