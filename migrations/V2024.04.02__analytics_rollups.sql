-- Cross River Trading Co. -- the data team arrives
-- author: N. Farrell (data)
-- postgres: 15
--
-- Rollup tables for the dashboards, and a segmentation table for a model the
-- team is building.
--
-- ROADMAP.md: "2024 to 2025: analytics and the model"

-- DEFECT rollup-disagrees-with-source
-- Populated nightly from storefront.orders by a job that filters on
-- placed_at >= the last run. Orders backdated by the support desk, and orders
-- whose totals are corrected after the fact, are never picked up. The rollup
-- and the table it summarises disagree, and the rollup is what the board sees.
CREATE TABLE analytics.daily_sales_rollup (
    rollup_day     date NOT NULL,
    store_id       integer NOT NULL,
    order_count    integer NOT NULL DEFAULT 0,
    revenue_cents  bigint NOT NULL DEFAULT 0,
    refund_cents   bigint NOT NULL DEFAULT 0,
    computed_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (rollup_day, store_id)
);

-- DEFECT empty-table-customer-segments
-- Created for a segmentation model that reached a notebook and never reached
-- production. Zero rows since 2024. Three dashboards join to it, all with a
-- LEFT JOIN, so they return 'unsegmented' for every customer and nobody has
-- noticed the model is not running.
CREATE TABLE analytics.customer_segments (
    customer_id    integer NOT NULL PRIMARY KEY,
    segment        varchar(255) NOT NULL,
    score          numeric(6,4),
    model_version  varchar(255),
    scored_at      timestamptz
);

-- DEFECT stale-statistics-page-views
-- ANALYZE on this table was competing with the analytics load window, so the
-- scale factor was raised until it stopped running. At 10.0 the table has to
-- grow by a thousand percent before autoanalyze considers it, which on a table
-- this size means never.
--
-- The planner's idea of n_distinct on product_id is years out of date.
ALTER TABLE storefront.page_views SET (
    autovacuum_analyze_scale_factor = 10.0,
    autovacuum_analyze_threshold = 2000000000
);

COMMENT ON TABLE storefront.page_views IS
    'Autoanalyze effectively disabled since 2024. Planner statistics are stale.';

-- DEFECT autovacuum-disabled-event-log
-- Turned off entirely during a 2024 incident, when autovacuum on this table
-- was holding I/O during the evening peak. Switching it back on was left as a
-- follow-up ticket. Dead tuples have accumulated ever since and the table has
-- never been vacuumed by anything.
ALTER TABLE ops.event_log SET (autovacuum_enabled = false);

-- DEFECT fillfactor-100-on-hot-update-table
-- inventory is updated on every sale. At fillfactor 100 there is no free space
-- in the page for a heap-only tuple update, so each update writes a new page
-- entry and touches every index on the table. Lowering it to 80 would let most
-- of these updates stay in place.
ALTER TABLE storefront.inventory SET (fillfactor = 100);

-- DEFECT statistics-target-one
--
-- The rollup work spent a week on slow plans. One of the things tried was
-- lowering the statistics target on order_items.product_id, on the reasoning
-- that a smaller sample would make ANALYZE finish faster on the largest table
-- in the database. It was meant to come back to 100 after the week.
--
-- At a target of 1, ANALYZE keeps one most-common value and one histogram
-- bucket for a column with thousands of distinct products. Every selectivity
-- estimate on that column is then a guess from almost nothing, and the planner
-- picks joins and scans from those guesses. ANALYZE runs, pg_stats has a row,
-- and nothing reports that the row is worthless.
ALTER TABLE storefront.order_items ALTER COLUMN product_id SET STATISTICS 1;

-- DEFECT unlogged-table-holding-durable-data
--
-- The promotion engine's writes were the slowest thing in the sale week, and
-- most of that cost is WAL. Making the table unlogged removed the WAL and the
-- writes got faster, which is exactly what was asked for.
--
-- An unlogged table is not crash safe. PostgreSQL truncates it during recovery,
-- every row, with no way to get them back. It is also not replicated, so it is
-- empty on every standby and missing from every physical backup taken from one.
--
-- This table is the only record of which discount was applied to which order
-- line. Finance reconciles against it. Nothing else in the database holds a
-- second copy, and none of that is visible from the table definition, which
-- still lists its columns, its keys and its indexes exactly as before.
ALTER TABLE marketing.applied_promotions SET UNLOGGED;

-- DEFECT grant-select-to-public
--
-- The analysts asked for read access to the payment tables for a revenue
-- report. Granting to PUBLIC was one statement and granting to a role meant
-- creating the role, granting it, and finding out who to put in it.
--
-- PUBLIC in PostgreSQL is not "everyone who has been given an account". It is
-- every role that exists now and every role created later, including the ones
-- created for a service, a migration tool, or a contractor, none of whom will
-- ever appear in a review of who can read payments. Revoking it later breaks
-- whatever has quietly come to depend on it.
GRANT SELECT ON payments.transactions, payments.refunds TO PUBLIC;

-- DEFECT left-join-defeated-by-where
--
-- Orders per customer, for the retention dashboard. Every customer is supposed
-- to appear, including the ones who have never ordered, because a count of zero
-- is the number the dashboard exists to show.
--
-- The LEFT JOIN is right. The WHERE clause below it is what breaks it: a
-- customer with no orders gets a row of nulls from the join, and a null status
-- fails `o.status <> 'cancelled'`, so the row is filtered out again. The
-- predicate belongs in the ON clause, where it would filter the joined side
-- without discarding the customer.
--
-- 690 of the 3,120 customers have no order that is not cancelled, and none of
-- them appear here. The dashboard shows no customers with zero orders and reads
-- as though everyone who signs up buys something.
CREATE VIEW analytics.v_customer_order_counts AS
SELECT c.customer_id, c.email, count(o.order_id) AS order_count
FROM storefront.customers c
LEFT JOIN storefront.orders o ON o.customer_id = c.customer_id
WHERE o.status <> 'cancelled'
GROUP BY c.customer_id, c.email;

-- DEFECT union-deduplicates-legitimate-rows
--
-- Every time a customer did something, one row each. Written with UNION because
-- UNION is the word for putting two result sets together, and because the two
-- arms come from different tables so there was no reason to expect overlap.
--
-- UNION removes duplicate rows across the whole result, and it does not stop at
-- the boundary between the two arms. A customer who placed two orders on the
-- same day produces the same pair twice from the order arm alone, and a coupon
-- is redeemed at the moment an order is placed, so the redemption arm repeats
-- pairs the order arm has already produced. Every one of those is dropped.
--
-- 13,880 orders and 847 redemptions go in and 14,000 rows come out. 727
-- touchpoints are gone, and they are the ones belonging to the most active
-- customers, because those are the ones who do two things in a day. UNION ALL
-- is the whole fix, and the version with the bug is the one that reads as more
-- careful.
CREATE VIEW analytics.v_customer_touchpoints AS
SELECT customer_id, placed_at::date AS happened_on
FROM storefront.orders
UNION
SELECT customer_id, redeemed_at::date
FROM marketing.coupon_redemptions;

-- DEFECT not-in-with-nullable-subquery
--
-- Which Cross River customers the Silverback bridge never matched, so the
-- integration team can work through them. The query reads exactly like the
-- question.
--
-- legacy.customer_map.customer_id is null for the 36 Silverback customers that
-- matched nothing. NOT IN against a list containing a null is never true: for
-- any candidate the answer is "unknown", because SQL cannot rule out that the
-- null is the value being tested. The view therefore returns no rows, always,
-- and would still return no rows if every customer were unmatched.
--
-- The honest answer is 1,956 customers. What the integration team see is an
-- empty list, which they read as the bridge being complete. NOT EXISTS is the
-- same query without the trap.
CREATE VIEW analytics.v_unmatched_customers AS
SELECT c.customer_id, c.email
FROM storefront.customers c
WHERE c.customer_id NOT IN (SELECT m.customer_id FROM legacy.customer_map m);

-- DEFECT day-interval-not-24-hours
--
-- Next-day dispatch, as the contract words it. The deadline is written as
-- placed_at plus 24 hours, which is the same thing all but two days a year.
--
-- It is not the same thing on those two days. Cross River is a UK business and
-- a London day is 23 hours in March and 25 in October. An interval of 24 hours
-- is an exact duration and adds the same number of seconds whatever the
-- calendar is doing; an interval of 1 day added in the local zone lands on the
-- same clock time the next day, which is what the contract means.
--
-- 77 orders sit across a transition and carry a deadline an hour away from the
-- one the customer was promised. In March the warehouse gets an hour less than
-- it should and misses; in October it gets an hour more and the report says it
-- was late when it was not. Twice a year, for one day, and then it goes away.
CREATE VIEW analytics.v_dispatch_sla AS
SELECT order_id, customer_id, placed_at,
       placed_at + interval '24 hours' AS dispatch_due_at
FROM storefront.orders
WHERE status NOT IN ('cancelled', 'refunded');

-- DEFECT group-by-timestamp-not-date
--
-- Revenue by day. The GROUP BY names placed_at, which is the column the day
-- comes from, and the query runs and returns rows that look like a rollup.
--
-- placed_at is a timestamptz to the microsecond. Grouping by it groups by the
-- instant, so almost every order is its own group and the view returns roughly
-- one row per order rather than one per day. The aggregate is computed, it is
-- correct for the group it was given, and the group is wrong.
--
-- The output has the right column names and the right types. A chart drawn from
-- it looks like a busy day-level chart, because 13,880 points at microsecond
-- resolution render as a dense line. date_trunc('day', placed_at) is the fix
-- and the difference in the statement is nine characters.
CREATE VIEW analytics.v_daily_revenue AS
SELECT placed_at AS day,
       count(*) AS order_count,
       sum(total_cents) AS revenue_cents
FROM storefront.orders
WHERE status NOT IN ('cancelled', 'refunded')
GROUP BY placed_at;

-- DEFECT case-without-else-buckets-to-null
--
-- The lifecycle column on the operations dashboard, mapping an order's status
-- onto the three words the business uses: waiting, in progress, complete. The
-- CASE lists every status the dashboard's author had in front of them.
--
-- 'cancelled' is not one of them, and a CASE with no ELSE returns null for
-- anything that matches no branch. PostgreSQL does not require an ELSE and does
-- not warn that one is missing, because a CASE that falls through to null is
-- ordinary SQL.
--
-- 1,735 cancelled orders come back with a null lifecycle. The dashboard groups
-- by that column, so they arrive as a fourth bucket with no name, and the
-- reading in the room has been that those are orders the pipeline has not
-- classified yet rather than orders that were cancelled. They are counted in
-- the total and excluded from every band, so the bands do not sum to the total
-- and the difference has been put down to rounding.
CREATE VIEW analytics.v_order_lifecycle AS
SELECT order_id,
       customer_id,
       status,
       CASE
           WHEN status = 'pending' THEN 'waiting'
           WHEN status = 'paid'    THEN 'in progress'
           WHEN status = 'shipped' THEN 'complete'
       END AS lifecycle_band,
       placed_at
FROM storefront.orders;

-- DEFECT between-excludes-the-final-day
--
-- The year-end extract finance reconciles against the bank. It was written
-- once, for 2024, and the dates are the two ends of the calendar year exactly
-- as finance wrote them on the ticket.
--
-- A bare date in a comparison against a timestamptz is midnight on that date.
-- BETWEEN is inclusive of both ends, so the upper end is 2024-12-31 00:00:00
-- and the year runs to the first instant of its last day rather than through
-- it. Every order placed after midnight on 31 December is outside the extract.
--
-- Four orders. The extract balances against nothing and the four are found by
-- hand every January, which is now part of the year-end checklist and has been
-- for two years. The fix is < '2025-01-01', and the reason nobody has made it
-- is that the view looks like it already says what it means.
CREATE VIEW analytics.v_finance_year_2024 AS
SELECT order_id, customer_id, status, total_cents, placed_at
FROM storefront.orders
WHERE placed_at BETWEEN DATE '2024-01-01' AND DATE '2024-12-31';

-- DEFECT count-star-over-left-join-counts-the-null-row
--
-- Tickets per customer, for the support load report. The LEFT JOIN is
-- deliberate and correct: a customer who has never raised a ticket has to
-- appear, because the report is read to find out who is not using the desk.
--
-- count(*) counts rows, and the row a LEFT JOIN manufactures for a customer
-- with no match is still a row. Every one of them is reported as having raised
-- one ticket. count(t.ticket_id) counts non-null values and would return zero,
-- which is the difference between the two forms and is invisible at a glance.
--
-- 2,520 of the 3,120 customers have never raised a ticket and all 2,520 are
-- reported with a count of one. The report totals 3,120 tickets against the
-- 600 rows in support.tickets, and it has never been checked against the table
-- it comes from because it is read as a report about customers rather than a
-- report about tickets.
CREATE VIEW analytics.v_customer_ticket_counts AS
SELECT c.customer_id,
       c.email,
       count(*) AS ticket_count
FROM storefront.customers c
LEFT JOIN support.tickets t ON t.customer_id = c.customer_id
GROUP BY c.customer_id, c.email;

-- DEFECT sum-over-fanned-out-join
--
-- Lifetime spend per customer, for the loyalty tiers. The join to order_items
-- is there because an earlier version of this view also reported the number of
-- items bought, and that column was dropped when the tier rules changed. The
-- join was left behind.
--
-- A join to a child table multiplies the parent row: an order with four lines
-- appears four times, and sum(o.total_cents) adds that order's total four
-- times. The aggregate is correct for the rows it was given and the rows are
-- wrong. Nothing about the statement looks unusual, because the sum names a
-- column from the table it is grouped by.
--
-- 2,730 of the 3,120 customers are reported as having spent more than they
-- have, by a factor that varies with how many lines their orders carry, so the
-- inflation is not a constant anyone could spot as one. The tiers have been
-- assigned from this view since 2024 and the customers who buy many cheap
-- items are the ones promoted hardest.
CREATE VIEW analytics.v_customer_spend AS
SELECT c.customer_id,
       c.email,
       sum(o.total_cents) AS lifetime_spend_cents
FROM storefront.customers c
JOIN storefront.orders o ON o.customer_id = c.customer_id
JOIN storefront.order_items i ON i.order_id = o.order_id
GROUP BY c.customer_id, c.email;

-- DEFECT cast-to-date-uses-session-timezone
--
-- Orders by day, for the operations standup. placed_at is a timestamptz, which
-- is the right type, and ::date is the shortest way to get a day out of it.
--
-- A timestamptz has no day of its own. Casting one to date renders the instant
-- in the session's TimeZone setting and takes the date part, so this view
-- returns a different answer to two sessions with different settings. The
-- server runs UTC, psql on the analyst's laptop inherits Europe/London, and the
-- reporting connection pool sets nothing at all.
--
-- 342 of the 13,880 orders land on a different day under Europe/London than
-- under UTC: everything placed between midnight and 01:00 local during British
-- Summer Time. The daily counts disagree by a handful of orders depending on
-- who ran the query, which reads as a race with the nightly load rather than
-- as a timezone, and the reconciliation that would show it is the one nobody
-- runs twice from two machines.
CREATE VIEW analytics.v_orders_by_day AS
SELECT placed_at::date AS order_day,
       count(*) AS order_count,
       sum(total_cents) AS revenue_cents
FROM storefront.orders
GROUP BY placed_at::date;

-- DEFECT soft-delete-flag-ignored-by-reports
--
-- Silverback order volumes, for the acquisition review. The table is read
-- whole, because it is an archive of a closed system and an archive does not
-- change.
--
-- Silverback never deleted a row. Their application set is_deleted and their
-- own reports filtered on it, which is a convention Cross River does not use
-- anywhere else and which nothing in the column name makes mandatory. The
-- import kept the flag and the convention did not come with it.
--
-- 100 of the 4,000 orders are deleted and all 100 are counted here. They are
-- cancellations and test orders, so they are the small ones, and the volume is
-- 2.5% high in a report that is read to judge whether the acquisition paid for
-- itself. The same query written by anyone who had worked at Silverback would
-- have the filter, and the same query written by anyone at Cross River will
-- not.
CREATE VIEW analytics.v_legacy_order_volumes AS
SELECT date_trunc('month', placed_at) AS month,
       count(*) AS order_count,
       sum(order_total) AS order_total
FROM legacy.orders
GROUP BY date_trunc('month', placed_at);

-- DEFECT count-of-nullable-column-undercounts
--
-- Card takings by month, for the finance pack. count(*) was in the first
-- draft. It came back from review with a note saying count(*) is vague about
-- what is being counted, and it was changed to name a column.
--
-- count(column) counts the rows where that column is not null. It is the same
-- answer as count(*) only on a column that is never null, and
-- payment_method_id is null on every transaction taken from a customer who did
-- not store the card: guest checkout, one-off orders, and everything taken
-- through the phone line.
--
-- 6,940 of the 12,145 transactions have no stored payment method, so this
-- report is 57% low and has been since the review. It is the same shape as the
-- correct query, it returns a plausible number, and it moves in the same
-- direction as the business every month, which is why the gap against the bank
-- statement was put down to settlement timing.
CREATE VIEW analytics.v_transactions_by_month AS
SELECT date_trunc('month', processed_at) AS month,
       count(payment_method_id) AS transaction_count,
       sum(amount) AS amount_taken
FROM payments.transactions
GROUP BY date_trunc('month', processed_at);

-- DEFECT limit-without-order-by
--
-- The ten best-selling products, for the front page of the merchandising
-- dashboard. The aggregate and the grouping are right and the limit is the ten
-- the dashboard has room for.
--
-- There is no ORDER BY. LIMIT without one takes whatever ten rows the plan
-- produces first, which is not a documented order and is not an order at all:
-- it is a side effect of the scan, the grouping strategy and how many workers
-- the planner chose. SQL has no default ordering and PostgreSQL does not warn,
-- because the statement asks for ten rows and gets ten rows.
--
-- The dashboard has shown ten products under a "Top sellers" heading since
-- 2024 and they are not the top ten. They are stable enough to look
-- deliberate, because the plan is stable while the table is, and they change
-- when it is vacuumed or when the row count crosses a parallel threshold,
-- which reads as the bestsellers moving.
CREATE VIEW analytics.v_top_products AS
SELECT i.product_id,
       sum(i.quantity) AS units_sold
FROM storefront.order_items i
GROUP BY i.product_id
LIMIT 10;

-- DEFECT to-char-mask-uses-months-for-minutes
--
-- Order timestamps as a string, for the file the payment provider takes. They
-- want the minute, not the second, and they want it in that exact layout.
--
-- In a to_char mask MM is months. Minutes are MI. The two letters sit four
-- lines apart in the manual's format table and the mask reads correctly in
-- English, so the mistake survives review by the person who wrote it and by
-- the person who checked it against the provider's specification.
--
-- The date half is right, because MM is months and that is where months
-- belong. The time half prints the hour and then the month again, so an order
-- placed at 00:17 on the eighth of May is written 2013-05-08 00:05.
--
-- 13,656 of the 13,880 orders are stamped with a time that is not the time
-- they were placed. The 224 that agree are the ones placed in a minute that
-- happens to match their month. Every value is a real two-digit number in the
-- right position, so the file parses, the provider accepts it, and the
-- disagreement only appears when somebody matches a disputed transaction
-- against the order by timestamp.
CREATE VIEW analytics.v_order_timestamps AS
SELECT order_id,
       placed_at,
       to_char(placed_at, 'YYYY-MM-DD HH24:MM') AS placed_at_label
FROM storefront.orders;

-- DEFECT covering-index-includes-every-column
--
-- Index-only scans were the answer to the reporting load in 2024, and an
-- INCLUDE list is how a btree carries the columns a query needs without
-- putting them in the key. The list was written by taking every column the
-- reports touched, which turned out to be every column there is.
--
-- The index now holds a second copy of the table. Every insert writes both,
-- every update to any column writes both, and HOT updates are no longer
-- possible on this table at all, because a HOT update requires that no indexed
-- column changed and every column is indexed.
--
-- Measured: the index covers all 12 columns of a 12-column table. It is
-- exactly as useful as the planner says it is -- index-only scans on orders
-- did get faster -- which is why it has never been questioned. The cost is
-- paid on the write side, by checkout, and shows up as the orders table
-- bloating and taking twice as long to vacuum.
CREATE INDEX ix_orders_covering ON storefront.orders (placed_at)
    INCLUDE (order_id, customer_id, status, total_cents, gift_message,
             staff_note, store_id, origin_return_id, total_minor,
             status_v2, currency_code);

-- DEFECT distinct-masks-a-fan-out-join
--
-- Customer order values, for the finance extract. The join to order_items was
-- there to exclude orders with no lines, and it returned one row per line, so
-- the duplicates were removed with DISTINCT and the counts looked right again.
--
-- DISTINCT removes duplicate rows, not duplicate joins. It collapses the
-- fan-out and it collapses anything else identical in the selected columns, so
-- two genuine orders by the same customer for the same amount become one row.
-- Adding order_id would keep them and would also bring the fan-out back, which
-- is why it is not there.
--
-- Measured: the extract holds 11,839 rows against 13,880 orders. The 2,041
-- missing are real orders, and they are concentrated on the customers who
-- order the same thing repeatedly, so the extract understates exactly the
-- customers finance cares most about. Nothing about the output looks
-- duplicated or short, which is what DISTINCT was added to achieve.
CREATE VIEW analytics.v_customer_order_values AS
SELECT DISTINCT o.customer_id, o.total_cents
FROM storefront.orders o
JOIN storefront.order_items i ON i.order_id = o.order_id;

-- DEFECT not-equals-excludes-the-nulls
--
-- Everything not priced in dollars, for the currency exposure report. <> is
-- the operator for is not, and it is the operator everybody reaches for.
--
-- <> against a null is null, and a WHERE clause keeps only the rows where it
-- is true. Every order whose currency_code is null is therefore excluded, even
-- though a null currency is certainly not USD. The filter reads as if it
-- removes one currency and it removes one currency plus everything unknown.
--
-- 9,460 of the 13,880 orders have no currency_code, because the column was
-- added in 2023 and only orders after the backfill carry one. The report
-- covers 4,420 orders and is presented as covering the book. Writing
-- currency_code IS DISTINCT FROM 'USD' includes them.
CREATE VIEW analytics.v_non_usd_orders AS
SELECT order_id, customer_id, total_cents, currency_code
FROM storefront.orders
WHERE currency_code <> 'USD';

-- DEFECT to-char-mask-too-narrow-returns-hashes
--
-- The receipt extract, formatting money for the PDF renderer. to_char with an
-- explicit mask is how every other formatted column in this schema is
-- written, and the mask was sized in 2024 against the order book as it then
-- was, where nothing had ever gone past 999.99.
--
-- to_char does not widen a mask and does not error when the number will not
-- fit. It returns a string of hashes the width of the mask. The renderer
-- prints what it is given.
--
-- Measured: 3,020 of the 13,880 receipts print #######. They are the largest
-- orders in the book, which is the set most likely to be queried about and
-- least likely to be waved through. Customers have been sent receipts with no
-- total on them since the extract was built.
CREATE VIEW analytics.v_order_receipt_lines AS
SELECT order_id,
       customer_id,
       total_cents,
       to_char(total_cents / 100.0, '999.99') AS total_formatted
FROM storefront.orders;

-- DEFECT rank-with-ties-returns-more-than-one-row
--
-- The largest order each customer has ever placed, for the account manager
-- screen. The window function is the right tool and the partition is right.
--
-- rank() and row_number() are not interchangeable. row_number() is arbitrary
-- but always one per partition; rank() gives tied rows the same rank, so
-- filtering to rank 1 returns every order tied on the top value rather than
-- one. The screen reads the view expecting one row per customer and renders
-- whichever arrives last.
--
-- Measured: 3,339 rows for 2,730 customers. 609 of those rows are the second
-- and third copy of a customer whose two largest orders came to the same
-- money, which is common here because the catalogue has fixed prices and
-- people re-order the same basket. Changing rank() to row_number() returns
-- 2,730 rows and needs no other edit.
CREATE VIEW analytics.v_largest_order_per_customer AS
SELECT customer_id, order_id, total_cents
FROM (
    SELECT customer_id,
           order_id,
           total_cents,
           rank() OVER (PARTITION BY customer_id ORDER BY total_cents DESC) AS rnk
    FROM storefront.orders
) r
WHERE rnk = 1;

-- DEFECT extract-dow-never-matches-sunday
--
-- Weekend trading, for the staffing model. Saturday and Sunday were written
-- as 6 and 7, which is how the week is numbered on a calendar, in ISO 8601,
-- and by extract(isodow).
--
-- extract(dow) numbers the week 0 to 6 with Sunday at 0. 7 is not a value it
-- can return, so that half of the filter matches nothing, and Sunday is
-- missing rather than duplicated. The view returns Saturdays only and no
-- error says so.
--
-- Measured: the view returns 1,985 orders. The real weekend is 3,967, so
-- every Sunday in fourteen years of trading is missing, which is 1,982
-- orders. The staffing model reads the weekend as half the size it is, and
-- the number is internally consistent year on year, so nothing about the
-- trend looks wrong. extract(isodow) numbers the week 1 to 7 and makes the
-- filter as written correct.
CREATE VIEW analytics.v_weekend_orders AS
SELECT order_id, customer_id, total_cents, placed_at
FROM storefront.orders
WHERE extract(dow FROM placed_at) IN (6, 7);

-- DEFECT integer-division-truncates-the-rate
--
-- The cancellation rate, for the board pack. Both counts are integers,
-- because count() returns bigint, and the multiplication by 100 is at the
-- end where it reads naturally.
--
-- Dividing one integer by another in SQL is integer division: the remainder
-- is discarded before anything else happens. The division runs first, gives
-- zero for every rate under one hundred percent, and the multiplication then
-- scales zero. There is no warning and no rounding; the result is exactly
-- zero and looks like a real measurement.
--
-- Measured: 1,735 of the 13,880 orders are cancelled, which is 12.5 per cent,
-- and the view reports 0. It has reported 0 every month since 2024, and a
-- cancellation rate that never moves reads as a well run business rather than
-- as a broken column. Multiplying by 100 before dividing, or making one side
-- numeric, gives 12.5.
CREATE VIEW analytics.v_cancellation_rate AS
SELECT count(*) AS orders,
       count(*) FILTER (WHERE status = 'cancelled') AS cancelled,
       (count(*) FILTER (WHERE status = 'cancelled') / count(*)) * 100 AS cancelled_pct
FROM storefront.orders;

-- DEFECT fixed-offset-timezone-ignores-daylight-saving
--
-- Orders bucketed into UK trading days. placed_at is timestamptz, so it has
-- to be converted to a local time before a date can be taken, and 'GMT' was
-- chosen because the business is in the UK and GMT is what the UK clock is
-- called.
--
-- GMT is a fixed offset of zero. Europe/London is a zone that spends about
-- half the year an hour ahead of it. Between late March and late October the
-- conversion is an hour early, so every order placed in the first hour of a
-- British day is booked to the day before.
--
-- Measured: 342 orders are filed under the wrong trading day. They are the
-- ones placed between midnight and one in the morning British time during
-- British Summer Time, so the error is invisible in a monthly total and
-- shifts revenue across a month end twice a year. AT TIME ZONE
-- 'Europe/London' is correct in both halves of the year.
CREATE VIEW analytics.v_orders_by_gmt_day AS
SELECT order_id,
       customer_id,
       total_cents,
       (placed_at AT TIME ZONE 'GMT')::date AS trading_day
FROM storefront.orders;

-- DEFECT anti-join-on-a-column-that-is-never-populated
--
-- Orders with nothing dispatched, for the fulfilment chase list. The shape is
-- the standard anti-join: outer join to shipments and keep the rows where the
-- shipment side is null.
--
-- The test is on delivered_at rather than on the joined key. delivered_at is
-- null on every shipment in this database, so it is null both when there is
-- no shipment and when there is one that has not been marked delivered, and
-- the filter cannot tell the two apart. Testing s.shipment_id IS NULL is the
-- anti-join; testing a nullable payload column is not.
--
-- Measured: the chase list holds all 13,880 orders. 3,470 of them genuinely
-- have no shipment, and the other 10,410 have one and are on the list anyway.
-- Fulfilment have treated the list as unusable since it was built, which is
-- also why nobody has reported it as wrong.
CREATE VIEW analytics.v_orders_awaiting_dispatch AS
SELECT o.order_id, o.customer_id, o.placed_at
FROM storefront.orders o
LEFT JOIN fulfilment.shipments s ON s.order_id = o.order_id
WHERE s.delivered_at IS NULL;

-- DEFECT subquery-column-resolves-to-the-outer-table
--
-- Cross River customers who also appear in the Silverback import, for the
-- de-duplication work. The subquery was written from memory of the legacy
-- table's shape.
--
-- legacy.customers has no column called email; it is email_address. A name a
-- subquery cannot resolve is looked for in the enclosing query, and it is
-- found there, so the subquery becomes "select this customer's own email for
-- every legacy row" and the test compares each customer's email to itself.
-- It is true for every customer with an email, and it never touches the
-- legacy table at all.
--
-- PostgreSQL cannot object: outer references are how correlated subqueries
-- work, and this one is syntactically indistinguishable from a deliberate
-- correlation. Qualifying the inner column as l.email is the fix, and it
-- turns the silent success into the error that should have been raised.
--
-- Measured: the view returns all 3,120 customers. The real answer, matching
-- email against email_address, is 789. The de-duplication work was scoped
-- against this view and has been reporting the whole customer base as
-- duplicated since 2024.
CREATE VIEW analytics.v_customers_also_in_silverback AS
SELECT c.customer_id, c.email
FROM storefront.customers c
WHERE c.email IN (SELECT email FROM legacy.customers);

-- DEFECT case-compares-to-null-with-equals
--
-- A readable currency label for the finance extract, with a branch for the
-- orders that predate the currency column.
--
-- Nothing is equal to null, including null. The first branch is null rather
-- than true for exactly the rows it was written for, so those rows fall
-- through to the ELSE and are labelled as a foreign currency instead of as
-- unknown. The branch is unreachable: no row can ever take it.
--
-- Measured: not one of the 13,880 orders is labelled unknown. The 9,460 with
-- no currency are labelled other, alongside the genuine foreign-currency
-- orders and indistinguishable from them, and 4,420 are labelled sterling.
-- WHEN currency_code IS NULL takes the branch as written.
CREATE VIEW analytics.v_order_currency_label AS
SELECT order_id,
       currency_code,
       CASE
           WHEN currency_code = NULL THEN 'unknown'
           WHEN currency_code = 'GBP' THEN 'sterling'
           ELSE 'other'
       END AS currency_label
FROM storefront.orders;

-- DEFECT union-mixes-major-and-minor-units
--
-- Every order ever taken, across the current book and the Silverback import,
-- for the lifetime revenue figure. The two branches line up on column count
-- and on type, because money casts to numeric without complaint.
--
-- storefront.orders.total_cents is minor units. legacy.orders.order_total is
-- the money type and is major units. The union puts them in one column named
-- amount, and every legacy order is therefore counted at a hundredth of its
-- value. Nothing in the result says which branch a row came from.
--
-- Measured: the view totals 881,554,866. The current book contributes
-- 880,737,046 in cents and the 4,000 legacy orders contribute 817,820, which
-- is 8,178,200 in the same units as everything else. Lifetime revenue is
-- understated by about eight million pence and the shortfall sits entirely in
-- the years before the acquisition, where nobody expects much.
CREATE VIEW analytics.v_all_order_amounts AS
SELECT order_id::text AS order_ref, total_cents::numeric AS amount
FROM storefront.orders
UNION ALL
SELECT order_number, order_total::numeric
FROM legacy.orders;

-- DEFECT left-join-filter-on-the-preserved-side
--
-- Shipments raised against cancelled orders, for the write-off report. The
-- condition on the order's status is in the ON clause because that is where
-- the other join conditions are, and putting it there is what keeps the outer
-- join outer.
--
-- It keeps the join outer for the wrong rows. A condition in the ON clause of
-- a LEFT JOIN decides which rows of the right table are matched; it cannot
-- remove rows of the left table, because a left join preserves those whether
-- they match or not. An order that is not cancelled is therefore still in the
-- result, carrying nulls where the shipment should be.
--
-- Moving the status test to the WHERE clause filters orders. Leaving it in ON
-- filters shipments, and the two read almost identically.
--
-- Measured: the write-off report returns all 13,880 orders, 12,145 of which
-- were never cancelled. No cancelled order in this database has a shipment at
-- all, so the report it was written to produce is empty and the one it
-- produces is the order book.
CREATE VIEW analytics.v_cancelled_order_shipments AS
SELECT o.order_id, o.status, s.shipment_id, s.status AS shipment_status
FROM storefront.orders o
LEFT JOIN fulfilment.shipments s
       ON s.order_id = o.order_id
      AND o.status = 'cancelled';

-- DEFECT concatenated-key-collides
--
-- A single-column key for each order line, for the export the warehouse
-- system reads. It has no composite key support, so the two ids are joined
-- into one string.
--
-- Concatenating two variable-length numbers without a separator is not
-- injective. Order 1 product 23 and order 12 product 3 both produce '123'.
-- The export loses one of them, silently, and which one survives depends on
-- the order rows arrive in.
--
-- Measured: 27,761 order lines reduce to 27,753 distinct pairs of ids, and to
-- 27,751 distinct keys. Six of the lost lines are the duplicate pairs the
-- table already permits; the other two are lines the concatenation cannot
-- tell apart. Inserting any separator that cannot appear in a number makes
-- the key injective again.
CREATE VIEW analytics.v_order_line_keys AS
SELECT order_id,
       product_id,
       order_id::text || product_id::text AS line_key,
       quantity
FROM storefront.order_items;

-- DEFECT de-morgan-error-in-a-filter
--
-- Tickets that are neither resolved nor closed, for the open work queue. The
-- negation was written once, around both tests, and the connective inside it
-- was left as the and of the sentence it was translated from.
--
-- NOT (a AND b) is true whenever either test fails, and a ticket has one
-- status, so it can never be both resolved and closed. The condition is
-- therefore true for every row, including the ones it was written to remove.
-- NOT (a OR b), or the IN form, says what was meant.
--
-- Measured: the open work queue holds all 600 tickets. 300 of them are
-- resolved or closed. The queue has been twice its true size since it was
-- built, and the screen's own paging is what has kept that from being
-- obvious.
CREATE VIEW analytics.v_open_tickets AS
SELECT ticket_id, customer_id, status, priority, opened_at
FROM support.tickets
WHERE NOT (status = 'resolved' AND status = 'closed');

-- DEFECT window-frame-defaults-to-range-and-lumps-ties
--
-- A running revenue total, one row per order, for the cumulative chart. The
-- window is ordered, which is what makes the sum cumulative.
--
-- A window with ORDER BY and no frame clause defaults to RANGE BETWEEN
-- UNBOUNDED PRECEDING AND CURRENT ROW, and RANGE treats every row that ties
-- on the ordering expression as the same position. The ordering here is the
-- date, so every order placed on one day sees the whole of that day already
-- added, including the orders after it.
--
-- ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW is one clause and gives a
-- total that advances one order at a time. Nothing warns, because the default
-- is the SQL standard's and it is right whenever the ordering is unique.
--
-- Measured: 13,880 orders produce 5,030 distinct running totals, one per
-- trading day. Every order placed on a day is charted at the day's closing
-- figure, so the cumulative line is a staircase and any reading taken from it
-- mid-day overstates revenue by up to a full day.
CREATE VIEW analytics.v_order_running_revenue AS
SELECT order_id,
       placed_at,
       total_cents,
       sum(total_cents) OVER (ORDER BY placed_at::date) AS running_total
FROM storefront.orders;

-- DEFECT full-outer-join-where-left-was-meant
--
-- Orders against their shipments, for the fulfilment reconciliation. FULL was
-- chosen over LEFT so that nothing could be missed, which is a reasonable
-- thing to want and not what FULL does.
--
-- A full join adds the unmatched rows from both sides. The unmatched rows on
-- the shipment side are shipments whose order_id points at no order, and they
-- arrive with a null order_id, a null status, and a shipment attached. Any
-- count of rows in this view is a count of orders plus those, and any sum
-- grouped by order_id gets a group for null.
--
-- Measured: the view returns 14,092 rows, 212 of which have no order_id.
-- Those are the orphan shipments, and the reconciliation that exists to find
-- discrepancies now contains them as rows rather than reporting them as a
-- number.
CREATE VIEW analytics.v_order_shipment_reconciliation AS
SELECT o.order_id, o.status, s.shipment_id, s.status AS shipment_status
FROM storefront.orders o
FULL OUTER JOIN fulfilment.shipments s ON s.order_id = o.order_id;

-- DEFECT between-with-the-bounds-reversed
--
-- First quarter trading, for the quarterly pack. The dates are right and they
-- are the right way round in the sentence the query was written from, which
-- reads from the end of the quarter back.
--
-- BETWEEN is low AND high, and it is not commutative: it expands to
-- x >= '2026-03-31' AND x <= '2026-01-01', which nothing can satisfy.
-- PostgreSQL does not object, because both bounds are valid dates and an
-- empty range is a legal range.
--
-- Measured: the view returns no rows at all. 36 orders were placed in the
-- quarter. An empty quarterly pack was read as a quiet quarter, which the
-- first quarter of 2026 was in any case.
CREATE VIEW analytics.v_first_quarter_2026_orders AS
SELECT order_id, customer_id, total_cents, placed_at
FROM storefront.orders
WHERE placed_at::date BETWEEN DATE '2026-03-31' AND DATE '2026-01-01';

-- DEFECT concatenation-with-a-null-blanks-the-whole-label
--
-- The picking slip line, built by concatenating the order reference, the
-- currency and the amount. The warehouse prints one of these per order.
--
-- Concatenation with || returns null when any operand is null. Not the empty
-- string, and not the rest of the line with a gap in it: the whole expression
-- is null, order reference included. currency_code has been nullable since
-- 2023 and is unset on every order the old checkout wrote.
--
-- Measured: 9,460 of the 13,880 labels are null. The slip prints blank and
-- the picker has nothing to match against the shelf, and the one field that
-- would identify the order is the field that disappeared with the others.
-- concat() ignores nulls and would have printed the rest of the line;
-- coalesce on the currency would have printed a gap. Neither is here.
CREATE VIEW analytics.v_order_picking_label AS
SELECT order_id,
       'ORD-' || order_id || ' ' || currency_code || ' ' || total_cents AS picking_label
FROM storefront.orders;

