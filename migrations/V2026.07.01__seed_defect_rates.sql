-- Cross River Trading Co. -- the state of things in July 2026
-- author: (fixture data)
-- postgres: 18
--
-- Everything in this file is a consequence of something the history already
-- described: orphans left by a delete that had no foreign key to stop it,
-- a reconciliation job that writes one column of a pair, rollups computed
-- from a filter that misses rows, and a config table full of template rows.
--
-- It runs last so that every count below is exact and can be asserted against
-- GROUND-TRUTH.md.

-- ---------------------------------------------------------------------------
-- Orphaned shipments
-- ---------------------------------------------------------------------------
--
-- DEFECT shipments-order-orphans
--
-- fulfilment.shipments.order_id has no foreign key (2016). A 2019 data
-- retention job deleted cancelled orders and left their shipments behind.
-- order_id values above the current maximum stand in for those deleted rows.

INSERT INTO fulfilment.shipments (order_id, carrier_id, warehouse_id, tracking_code, status, dispatched_at)
SELECT
    900000 + g,
    1 + (g % 3),
    1,
    'TRK' || lpad((900000 + g)::text, 9, '0'),
    'delivered',
    TIMESTAMPTZ '2019-04-01' + make_interval(days => (g % 400)::integer)
FROM generate_series(1, (SELECT (count(*) * 2) / 98 FROM fulfilment.shipments)) AS g;

-- ---------------------------------------------------------------------------
-- Meridian drift: 0.8% of orders
-- ---------------------------------------------------------------------------
--
-- The 2024 reconciliation job updates total_minor on its own. The dual-write
-- trigger fires only on total_cents and status, so it does not run, and the
-- two columns part company. Nothing reconciles them back.
--
-- 36 orders, which is 0.8% of the orders the job can touch at all.

-- The currency_code filter is not decoration. An invalid NOT NULL constraint
-- is still enforced against every new row version, so any UPDATE of a row
-- whose currency is null fails outright. Those orders are frozen: they can be
-- read and they can be deleted, and no column on them can be changed until
-- someone backfills the currency. The reconciliation job hits this and skips
-- them, which is why the drift below is confined to post-2023 orders.
UPDATE storefront.orders
   SET total_minor = total_minor + 1
 WHERE order_id % 125 = 0
   AND total_minor IS NOT NULL
   AND currency_code IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Case-duplicate customer emails
-- ---------------------------------------------------------------------------
--
-- The 2012 unique index is on the raw column, so 'A@x' and 'a@x' are two
-- customers. 120 people have two accounts here and neither the application
-- nor the constraint can tell.

INSERT INTO storefront.customers (email, full_name, created_at, marketing_optin)
SELECT
    'Customer' || g || '@Example.invalid',
    c.full_name,
    c.created_at + INTERVAL '400 days',
    'Y'
FROM generate_series(1, 120) AS g
JOIN storefront.customers c ON c.customer_id = g;

-- ---------------------------------------------------------------------------
-- A merge cycle in the support queue
-- ---------------------------------------------------------------------------
--
-- DEFECT ticket-merge-cycle
-- merged_into_ticket_id is a self-referencing foreign key with nothing to stop
-- a loop. An agent merged 101 into 102 and a second agent, working the other
-- end of the same conversation, merged 102 back into 101.
--
-- Following the chain to find the surviving ticket never terminates. Three
-- such pairs exist.

UPDATE support.tickets SET merged_into_ticket_id = 102 WHERE ticket_id = 101;
UPDATE support.tickets SET merged_into_ticket_id = 101 WHERE ticket_id = 102;
UPDATE support.tickets SET merged_into_ticket_id = 204 WHERE ticket_id = 203;
UPDATE support.tickets SET merged_into_ticket_id = 203 WHERE ticket_id = 204;
UPDATE support.tickets SET merged_into_ticket_id = 306 WHERE ticket_id = 305;
UPDATE support.tickets SET merged_into_ticket_id = 305 WHERE ticket_id = 306;

-- ---------------------------------------------------------------------------
-- ops.app_config: 40 rows, 31 of them blank
-- ---------------------------------------------------------------------------

INSERT INTO ops.app_config (config_key, config_value, value_kind, description, updated_by)
SELECT
    'app.setting_' || lpad(g::text, 2, '0'),
    CASE
        WHEN g <= 9  THEN (ARRAY['30','200','GBP','Europe/London','true',
                                 '5','warn','1000','false'])[g]
        WHEN g <= 13 THEN ''
        ELSE NULL
    END,
    CASE WHEN g % 3 = 0 THEN 'integer' WHEN g % 3 = 1 THEN 'string' ELSE 'boolean' END,
    'Template row created 2025-01-27',
    CASE WHEN g <= 9 THEN 'a.fenwick' ELSE NULL END
FROM generate_series(1, 40) AS g;

-- Nine rows carry a value. Rows 10 to 13 are the empty string and rows 14 to
-- 40 are null, which the application treats identically: use the compiled-in
-- default. That is 31 of 40 settings that configure nothing.

INSERT INTO ops.feature_flags (flag_key, enabled, rollout_pct, note)
SELECT
    'flag.' || (ARRAY['meridian_reads','new_checkout','sms_optin','segment_model',
                      'legacy_bridge_ui','partition_archive'])[g],
    (g % 2 = 0),
    CASE WHEN g % 2 = 0 THEN 100 ELSE 0 END,
    'Added during rollout ' || g
FROM generate_series(1, 6) AS g;

INSERT INTO ops.job_runs (job_name, started_at, finished_at, status, attempt, detail)
SELECT
    (ARRAY['nightly_rollup','archive_page_views','reconcile_totals','import_suppliers'])[1 + (g % 4)],
    TIMESTAMPTZ '2026-01-01' + make_interval(days => g / 4, hours => 2),
    TIMESTAMPTZ '2026-01-01' + make_interval(days => g / 4, hours => 2, mins => 18),
    -- archive_page_views has failed on every run since the last partition ran
    -- out on 2026-07-01. Nothing reads these rows.
    CASE
        WHEN (1 + (g % 4)) = 2 AND (TIMESTAMPTZ '2026-01-01' + make_interval(days => g / 4))
             >= TIMESTAMPTZ '2026-07-01' THEN 'failed'
        ELSE 'succeeded'
    END,
    -- The scheduler names the column, so the default that would be rejected is
    -- never reached from this path.
    1,
    NULL
FROM generate_series(1, 1000) AS g;

UPDATE ops.job_runs
   SET detail = 'ERROR: no partition of relation "page_views_archive" found for row'
 WHERE status = 'failed';

-- Runs the scheduler started and never closed off. It writes the row before it
-- forks the worker and updates it when the worker reports back, so a worker
-- that dies leaves the row at 'running' with a null finished_at, permanently.
-- Twenty-four of them have accumulated since 2025.
INSERT INTO ops.job_runs (job_name, started_at, finished_at, status, attempt, detail)
SELECT
    (ARRAY['nightly_rollup','archive_page_views','reconcile_totals','import_suppliers'])[1 + (g % 4)],
    TIMESTAMPTZ '2025-02-01' + make_interval(days => g * 13, hours => 2),
    NULL,
    'running',
    1,
    NULL
FROM generate_series(1, 24) AS g;

-- ---------------------------------------------------------------------------
-- analytics.daily_sales_rollup, which does not agree with its source
-- ---------------------------------------------------------------------------
--
-- Computed from storefront.orders, then adjusted to represent what the nightly
-- job actually produced: it filters on placed_at >= the previous run, so it
-- misses every order the support desk backdated. The rollup is short.

INSERT INTO analytics.daily_sales_rollup (rollup_day, store_id, order_count, revenue_cents, computed_at)
SELECT
    o.placed_at::date,
    coalesce(o.store_id, 1),
    count(*),
    sum(o.total_cents),
    TIMESTAMPTZ '2026-07-01 02:00'
FROM storefront.orders o
WHERE o.status IN ('paid', 'shipped')
GROUP BY 1, 2;

-- The job's date filter misses one day in forty. Those days are present in
-- orders and absent from the rollup entirely.
DELETE FROM analytics.daily_sales_rollup
 WHERE (extract(doy FROM rollup_day)::integer % 40) = 0;

-- And on the days it did run, refunds were never subtracted. refund_cents is
-- zero on every row while payments.refunds has rows against those days.

-- ---------------------------------------------------------------------------
-- Archive tables: two shapes, one of them short
-- ---------------------------------------------------------------------------

INSERT INTO archive.orders_2023 (order_id, customer_id, status, total_cents, placed_at, store_id)
SELECT order_id, customer_id, status, total_cents, placed_at, store_id
FROM storefront.orders
WHERE placed_at >= TIMESTAMPTZ '2023-01-01' AND placed_at < TIMESTAMPTZ '2024-01-01';

INSERT INTO archive.orders_2024 (order_id, customer_id, status, total_cents, placed_at, store_id,
                                 total_minor, currency_code, gift_message)
SELECT order_id, customer_id, status, total_cents, placed_at, store_id,
       total_minor, currency_code, gift_message
FROM storefront.orders
WHERE placed_at >= TIMESTAMPTZ '2024-01-01' AND placed_at < TIMESTAMPTZ '2025-01-01';

-- The partitioned archive holds only what fits. Page views after 2026-07-01
-- have nowhere to go and the job that would move them fails.
INSERT INTO archive.page_views_archive (page_view_id, customer_id, product_id, store_id, viewed_at)
SELECT page_view_id, customer_id, product_id, store_id, viewed_at
FROM storefront.page_views
WHERE viewed_at >= TIMESTAMPTZ '2025-07-01' AND viewed_at < TIMESTAMPTZ '2026-07-01';

-- ---------------------------------------------------------------------------
-- Temporal contract prices, and the promotions actually applied to orders
-- ---------------------------------------------------------------------------
--
-- contract_prices is the table that got temporal integrity right in 2026.
-- Non-overlapping windows per supplier and product, enforced by the primary
-- key rather than by convention.

INSERT INTO supply.contract_prices (supplier_id, product_id, price_cents, valid_during)
SELECT
    sp.supplier_id,
    sp.product_id,
    sp.cost_cents + (w.n * 50),
    daterange((DATE '2024-01-01' + make_interval(days => w.n * 365))::date,
              (DATE '2024-01-01' + make_interval(days => (w.n + 1) * 365))::date)
FROM supply.supplier_products sp
CROSS JOIN generate_series(0, 1) AS w(n)
WHERE sp.product_id % 9 = 0;

INSERT INTO supply.contract_price_reviews (supplier_id, product_id, reviewed_during, reviewer)
SELECT
    cp.supplier_id,
    cp.product_id,
    daterange(lower(cp.valid_during) + 30, lower(cp.valid_during) + 90),
    'p.lindqvist'
FROM supply.contract_prices cp
WHERE cp.product_id % 27 = 0;

-- applied_promotions is the child side of the MATCH SIMPLE composite foreign
-- key. Rows naming a promotion and no product satisfy it and reference
-- nothing, which is the whole problem with the default match mode.

INSERT INTO marketing.applied_promotions (order_item_id, promotion_id, product_id, discount_cents)
SELECT
    oi.order_item_id,
    pp.promotion_id,
    -- One row in twelve carries the promotion and leaves the product null.
    -- MATCH SIMPLE accepts it. MATCH FULL would not.
    CASE WHEN oi.order_item_id % 12 = 0 THEN NULL ELSE pp.product_id END,
    (oi.unit_price_cents * 10) / 100
FROM storefront.order_items oi
JOIN marketing.promotion_products pp ON pp.product_id = oi.product_id
WHERE oi.order_item_id % 31 = 0;

-- DEFECT duplicate-applied-promotions
--
-- The promotion engine writes this table one order line at a time and has no
-- record of what it has already written. Nothing in the table stops it: there
-- is no unique constraint on (order_item_id, promotion_id), because the column
-- pair that would carry one is the composite foreign key that was added
-- NOT VALID and never validated.
--
-- A March 2026 batch timed out halfway and was run again from the top. Every
-- line it had already reached got its discount applied a second time. The rows
-- are byte for byte identical apart from the generated key, so no report that
-- reads this table can tell which of a pair is the real one, and summing
-- discount_cents over an order double counts every line in the overlap.
INSERT INTO marketing.applied_promotions (order_item_id, promotion_id, product_id, discount_cents)
SELECT order_item_id, promotion_id, product_id, discount_cents
FROM marketing.applied_promotions
WHERE order_item_id % 2 = 0;

-- ---------------------------------------------------------------------------
-- Ledger imbalance
-- ---------------------------------------------------------------------------
--
-- Refunds were never posted to the ledger. Debits and credits differ by the
-- full refunded amount, and nothing in the schema says they should match.

-- ---------------------------------------------------------------------------
-- Coupon redemptions reloaded with the foreign keys switched off
-- ---------------------------------------------------------------------------
--
-- DEFECT fk-triggers-disabled
--
-- The 2024 coupon platform move reloaded this table from the vendor's export.
-- The load script turns the triggers off first, which is the standard way to
-- make a large reload finish, and turns them back on at the end. The run that
-- mattered failed part way through and the re-enable never ran.
--
-- ALTER TABLE ... DISABLE TRIGGER ALL does not only disable the triggers
-- somebody wrote. It disables the internal triggers that enforce every foreign
-- key on the table, all three of them here, and PostgreSQL keeps listing the
-- constraints exactly as before. psql shows them. information_schema shows
-- them. pg_dump writes them out. Nothing anywhere says they stopped running,
-- and re-enabling them does not check the rows that arrived while they were
-- off.
-- Switching those triggers off needs a real superuser, and a managed service
-- does not hand one out, so this has to degrade rather than stop the build.
-- session_replication_role gets the same rows past the same constraints and is
-- what AWS points customers at; if even that is refused the rows are skipped,
-- which costs nothing measured, because no defect counts them. What no
-- fallback reproduces is the triggers left marked disabled afterwards, and
-- that is exactly what pg_trigger records and what this defect is counted by.
-- Listed in scripts/env-limits/rds.tsv for that reason.
DO $$
DECLARE
    bypass text := NULL;
BEGIN
    BEGIN
        EXECUTE 'ALTER TABLE marketing.coupon_redemptions DISABLE TRIGGER ALL';
        bypass := 'triggers';
    EXCEPTION WHEN insufficient_privilege THEN
        BEGIN
            EXECUTE 'SET session_replication_role = replica';
            bypass := 'replication_role';
        EXCEPTION WHEN insufficient_privilege THEN
            RAISE NOTICE
                'no privilege to bypass foreign keys; skipping the orphaned coupon redemptions';
        END;
    END;

    -- Rows the vendor export carried that no longer match anything here:
    -- coupons retired before the move, and orders that were purged. Every one
    -- of these would have been rejected by a constraint that is still listed
    -- on the table.
    IF bypass IS NOT NULL THEN
        INSERT INTO marketing.coupon_redemptions (coupon_id, order_id, customer_id, redeemed_at)
        SELECT
            900000 + g,
            900000 + g,
            900000 + g,
            TIMESTAMPTZ '2024-09-14 02:00' + make_interval(mins => g * 7)
        FROM generate_series(1, 120) AS g;
    END IF;

    -- The disabled triggers stay disabled: that is the defect. The replication
    -- role is a session setting and is put back.
    IF bypass = 'replication_role' THEN
        EXECUTE 'SET session_replication_role = origin';
    END IF;
END $$;

-- ---------------------------------------------------------------------------
-- The ticket sequence, reset from the wrong number
-- ---------------------------------------------------------------------------
--
-- DEFECT sequence-reset-to-row-count
--
-- A 2026 archive trial copied tickets out, emptied the table and put them back.
-- The script ended by setting the sequence, so that the next new ticket would
-- not collide with the restored ones. It set it from a count of the rows it
-- had loaded rather than from the highest id, and its count excluded the closed
-- tickets it had not bothered to restore in the first pass.
--
-- Both numbers look like "how many tickets there are" and only one of them is
-- the right answer. The sequence now sits 150 below the highest ticket_id, so
-- the next 150 inserts each fail on the primary key, one at a time, as the
-- sequence walks back up over ids that are already taken.
SELECT setval(
    'support.tickets_ticket_id_seq',
    (SELECT count(*) FROM support.tickets WHERE status <> 'closed')
);

-- ---------------------------------------------------------------------------
-- Statistics
-- ---------------------------------------------------------------------------
--
-- Everything except the two tables whose statistics are meant to be wrong.
-- page_views and event_log are left unanalysed on purpose.

ANALYZE storefront.orders;
ANALYZE storefront.order_items;
ANALYZE storefront.products;
ANALYZE storefront.customers;
ANALYZE storefront.inventory;
ANALYZE fulfilment.shipments;
ANALYZE payments.transactions;
ANALYZE payments.ledger_entries;
ANALYZE legacy.customers;
ANALYZE legacy.orders;
ANALYZE legacy.addresses;
ANALYZE supply.supplier_products;
ANALYZE marketing.coupon_redemptions;
ANALYZE support.tickets;

-- ---------------------------------------------------------------------------
-- The audit trigger on tickets, switched off
-- ---------------------------------------------------------------------------
--
-- DEFECT disabled-trigger-audit-gap
--
-- The 2026 ticket backfill rewrote every open ticket to add the new queue
-- field. With the audit trigger live that is one ops.event_log row per ticket,
-- carrying the whole old and new row as JSON, and the backfill would not finish
-- inside its window. Disabling the trigger for the run was the right call.
-- Re-enabling it afterwards was step nine of a nine-step runbook.
--
-- support.tickets now has an audit trigger that is present, owned, and
-- inert. \d lists it. pg_dump writes it out. information_schema.triggers
-- reports it, because that view has no column for whether a trigger fires. The
-- single character in pg_trigger.tgenabled is the only place the difference is
-- recorded, and no schema comparison tool anybody here runs looks at it.
--
-- Support believes every change to a ticket is logged. Nothing has been logged
-- since the backfill, and the gap has no marker at either end.
ALTER TABLE support.tickets DISABLE TRIGGER trg_tickets_audit;

-- ---------------------------------------------------------------------------
-- The empty string the checkout posts when the gift box is left alone
-- ---------------------------------------------------------------------------
--
-- DEFECT empty-string-instead-of-null
--
-- The 2023 checkout rewrite posts every field on the form, whether or not it
-- was filled in. An untouched gift message arrives as an empty string, and the
-- column takes it, because an empty string is a perfectly good varchar.
--
-- A null says no gift message was asked for. An empty string says one was
-- asked for and it is blank. Every count of gift orders is written as
-- gift_message IS NOT NULL, because that is what the column meant from 2012
-- until the rewrite, and it now counts every order placed since.
--
-- Every order carrying an empty gift message was placed after the rewrite,
-- which is the same set the currency backfill reached. The packing screen
-- prints a gift card for each of them with nothing on it, which the warehouse
-- has been reporting as a printer fault for three years, and the marketing
-- report that tracks gifting shows a step change in 2023 that was read as the
-- rewrite's own success.
UPDATE storefront.orders
   SET gift_message = ''
 WHERE currency_code IS NOT NULL
   AND order_id % 5 = 0;

-- ---------------------------------------------------------------------------
-- The order total trigger that only watches inserts
-- ---------------------------------------------------------------------------
--
-- DEFECT sync-trigger-covers-insert-only
--
-- orders.total_cents is kept in step with the lines by a trigger, added when
-- the basket service started writing lines directly and the totals stopped
-- agreeing. It was written against the one case that was failing, which was a
-- new line arriving.
--
-- A line can also be changed or removed, and neither fires this trigger.
-- Editing a quantity or deleting a line leaves the order's total at whatever
-- it was when the last line was inserted, and there is no second job that
-- recomputes it. Support edit lines every day, which is the whole reason the
-- support desk has that screen.
--
-- Measured: inserting a line updates the order total; changing the quantity on
-- an existing line leaves it untouched. The table still looks maintained,
-- because the column moves whenever anyone is watching a new order, and the
-- orders that drift are the ones that were corrected after the fact. Adding OR
-- UPDATE OR DELETE to the CREATE TRIGGER is the fix.
CREATE FUNCTION storefront.fn_sync_order_total() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE storefront.orders o
       SET total_cents = (SELECT coalesce(sum(i.quantity * i.unit_price_cents), 0)
                            FROM storefront.order_items i
                           WHERE i.order_id = NEW.order_id)
     WHERE o.order_id = NEW.order_id;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_order_items_sync_total AFTER INSERT ON storefront.order_items
    FOR EACH ROW EXECUTE FUNCTION storefront.fn_sync_order_total();

-- DEFECT comma-separated-list-in-a-text-column
--
-- Campaign targeting moved from one segment per campaign to several. A second
-- table was the obvious answer and would have taken a fortnight of application
-- work, so the ids went into the existing row as a comma separated string and
-- the campaign tool split them client side.
--
-- Nothing in the database knows this column holds a list. It cannot be joined
-- to the segments it names, it cannot be constrained to ids that exist, and
-- membership has to be asked with LIKE, because that is the only operator that
-- looks inside a string. LIKE '%1%' matches segment 1, segment 10 through 19,
-- and segment 21.
--
-- Measured: asking for the campaigns targeting segment 1 with LIKE returns all
-- 60 campaigns and the true answer is 20, so 40 are pulled in by a digit
-- appearing inside another id. The counts are plausible, the campaigns are
-- real, and the spend lands against the wrong segments in every report built
-- on this column.
ALTER TABLE marketing.campaigns
    ADD COLUMN target_segments varchar(255);

UPDATE marketing.campaigns
   SET target_segments = (1 + (campaign_id % 3))::text
                         || ',' || (10 + (campaign_id % 5))::text
                         || ',' || (20 + (campaign_id % 2))::text;

-- DEFECT sentinel-date-instead-of-null
--
-- The buyers' screen requires an expected date before a purchase order can be
-- raised, and for a third of orders the supplier has not given one. The
-- convention that grew up is to type the earliest date the screen accepts.
--
-- 1900-01-01 is a real date to the database and to every query written over
-- it. It is not null, so nothing that checks for a missing date finds one, and
-- it sorts before every genuine date, so it wins every min() and every
-- earliest-first ordering in the purchasing reports.
--
-- Measured: 150 of the 600 purchase orders carry it. The overdue report counts
-- them as 126 years late, which is loud enough that people have learned to
-- ignore the top of that list, and quiet enough that the orders sitting in it
-- for real are ignored with them. Nothing in the schema records the
-- convention; expected_on is a nullable date that is never null.
UPDATE supply.purchase_orders
   SET expected_on = DATE '1900-01-01'
 WHERE purchase_order_id % 4 = 0;

-- DEFECT quoted-char-type-truncates-to-one-byte
--
-- A short outcome code beside the job status, so the operations dashboard can
-- colour a row without parsing the detail text. The codes are OK, ERR and RUN,
-- and the column was declared "char" because that reads as the character type
-- with nothing wasted.
--
-- "char" in double quotes is not char. It is a one byte internal type that
-- PostgreSQL uses in its own catalogues, and it truncates anything longer
-- without an error: char(3) was meant and would have held the codes. Writing
-- 'ERR' stores 'E' and reports success.
--
-- Measured: all 1,024 rows hold a single character. The three codes still
-- differ from each other, because their initials happen to, so the dashboard
-- colours correctly and nothing looks wrong. The next code anybody adds that
-- starts with O, E or R is silently the same value as one already there.
ALTER TABLE ops.job_runs
    ADD COLUMN outcome_code "char";

UPDATE ops.job_runs
   SET outcome_code = CASE status
                        WHEN 'succeeded' THEN 'OK'
                        WHEN 'failed'    THEN 'ERR'
                        ELSE 'RUN'
                      END;
