-- Cross River Trading Co. -- index pass, contact extract, order channel
-- author: M. Okonkwo
-- postgres: 18
--
-- Three unrelated pieces of work that shipped together in the same window:
-- an index review that was asked to cut index size, a contact extract for
-- the reporting role, and the channel column the sales report had been
-- asking for since the phone desk opened.

-- DEFECT brin-index-on-an-unordered-column
--
-- The index review was asked to cut index size, and BRIN is the answer to
-- that question: it stores one summary per range of blocks instead of one
-- entry per row, so it is a few kilobytes where a btree on the same column
-- is megabytes. The saving is real and it is the only thing that was
-- measured before this shipped.
--
-- BRIN summarises each block range by the minimum and maximum value in it,
-- and it can skip a range only when the value being looked for falls outside
-- that pair. That works when the column's order on disk follows its order in
-- value. It does nothing at all when it does not.
--
-- storefront.order_items is written in order of order, and the product on a
-- line has no relation to when the order was placed. Measured: the physical
-- correlation of product_id is 0.004, where 1.0 is a perfectly ordered
-- column.
--
-- Measured, at the default range size of 128 blocks: this table is two
-- ranges, and both of them summarise as min 1, max 2000, which is the entire
-- catalogue. There is no product, and there can be no product, for which
-- this index excludes a single block. It answers every lookup with the whole
-- table.
--
-- It is not even reached, because the unique constraint on the table leaves
-- a btree on the same column that the planner prefers every time. So what
-- was added is 24 kB of index that is written on every insert, rebuilt on
-- every restore, carried in every backup, and cannot answer a question.
-- Nothing about the index name says BRIN, and the review's own report says
-- index size went down, which it did.
CREATE INDEX ix_order_items_product_brin ON storefront.order_items USING brin (product_id);

-- DEFECT hash-index-cannot-answer-a-range-query
--
-- The same review replaced the btree on sent_at with a hash index, for the
-- same reason: a hash index on a timestamp is smaller, and the ticket that
-- asked for the index said the report "looks messages up by date".
--
-- A hash index supports exactly one operator, equality. It cannot answer
-- >=, <, BETWEEN or ORDER BY, and it cannot enforce uniqueness. Every query
-- the support SLA report runs filters sent_at over a range of dates, which
-- is the one thing this index can never help with, and no query anywhere
-- asks for a message by its exact sent_at to the microsecond.
--
-- So the index is maintained on every insert into a table of 1,800 messages
-- that grows with every reply, it occupies space in every backup, and it has
-- never been used and cannot be. PostgreSQL does not warn: the index is
-- valid, the planner simply never picks it. The access method appears only
-- in \d output and in pg_am; the name looks like any other index on a
-- timestamp.
CREATE INDEX ix_ticket_messages_sent_at ON support.ticket_messages USING hash (sent_at);

-- DEFECT unique-on-order-id-forbids-a-second-payment
--
-- A retry loop in the payment service double-charged eleven customers over
-- one weekend in 2026. The fix went in at the database, where it could not
-- be got around: one transaction per order, enforced.
--
-- It stops the double charge. It also makes four ordinary things impossible.
-- A failed authorisation followed by a successful one is two rows for one
-- order, and it is the single most common sequence in card payments. A
-- capture that follows an authorisation is two rows. A part payment on a
-- split order is two rows. A fresh authorisation after a refund is two rows.
-- All four now raise a unique violation, which the payment service catches
-- and reports to the customer as "duplicate transaction", because from its
-- side that is the only thing this error has ever meant.
--
-- Nothing in the data contradicts the constraint today: there are 12,145
-- transactions against 12,145 distinct orders, because every one of those
-- sequences was still being written by hand into a spreadsheet when this
-- shipped. The constraint reads as a correct statement about the business,
-- and it will keep reading that way until the first failed card of the day.
ALTER TABLE payments.transactions
    ADD CONSTRAINT transactions_order_id_key UNIQUE (order_id);

-- DEFECT view-without-security-barrier-leaks-rows
--
-- The reporting role needs customer contact details for the ones who opted
-- in to marketing, and must not see the rest. A view with a WHERE clause,
-- granted to the role and with no grant on the table, is the standard way to
-- write that and it is what was written: 750 of the 3,120 customers are
-- visible through it.
--
-- A view is not a security boundary unless it says it is. Without
-- WITH (security_barrier = true) the planner is free to push a qualifier
-- from the outer query underneath the view's own WHERE, and it will when
-- that looks cheaper. A function or operator that is not marked LEAKPROOF
-- can therefore run against every row of storefront.customers, including the
-- 2,370 the view exists to hide.
--
-- Measured: a query of the form SELECT ... FROM this view WHERE f(email),
-- with f an ordinary plpgsql function, returned the 750 rows the view
-- permits and handed all 3,120 email addresses to f on the way. With
-- security_barrier set, the same query hands f 750.
--
-- The leak is not hypothetical and does not need an exotic function: an
-- error message that quotes its input, a RAISE NOTICE, or a function that
-- writes what it saw to a table are all enough, and the reporting role can
-- create functions in its own schema. The rows never appear in the result
-- set, so nothing an auditor reads from the query output shows anything
-- wrong.
--
-- security_barrier is one word in one place, it costs a plan that cannot
-- push those qualifiers down, and every catalogue view of this database
-- describes the object identically with or without it.
CREATE VIEW storefront.v_customer_contact AS
SELECT customer_id, email, full_name, marketing_optin
FROM storefront.customers
WHERE marketing_optin = 'yes';

-- DEFECT grant-on-a-view-without-schema-usage
--
-- The grant that makes the extract available to the reporting role, and the
-- only thing the change ticket asked for. It was applied, it succeeded, and
-- the ticket was closed.
--
-- Reaching an object needs two permissions in PostgreSQL: SELECT on the
-- object and USAGE on the schema that contains it. report_reader has never
-- had USAGE on storefront. The grant is recorded, information_schema lists
-- the privilege, and every query the role runs against the view fails with
-- "permission denied for schema storefront", which reads like the grant was
-- never applied and sends whoever is debugging it to look at the table
-- privileges, where everything is in order.
--
-- GRANT does not warn, because a privilege can legitimately be granted
-- before the schema is opened up. Nothing reconciles the two halves, so the
-- extract has been unreadable by the role it was built for since the day it
-- shipped.
GRANT SELECT ON storefront.v_customer_contact TO report_reader;

-- DEFECT explicit-null-overrides-the-column-default
--
-- The sales report wanted to split takings by channel, so the column was
-- added with a default, which is the change that needs nothing else to
-- change: every row that exists gets 'web', every insert that does not
-- mention the column gets 'web', and the column can be read as never empty.
--
-- A default fills a column that the INSERT does not name. It does nothing
-- for an INSERT that names the column and passes NULL, because a named NULL
-- is a value and not an absence. The phone desk's importer builds its column
-- list from the table, so it names every column, and it has no channel to
-- send.
--
-- 632 of 13,880 orders have no channel. They are the phone orders, taken in
-- sterling over the desk, and that is the one channel the report was added
-- to measure. They land in a null
-- bucket that the report prints as a blank row, and they disappear
-- altogether from the version of the report that joins a channel lookup
-- table, because that join is an inner one. Neither output says a row is
-- missing.
--
-- No report coalesces the column, and there is no reason any of them should:
-- the DDL says it has a default, and a column with a default does not come
-- back null.
ALTER TABLE storefront.orders ADD COLUMN channel varchar(255) DEFAULT 'web';

UPDATE storefront.orders SET channel = NULL
 WHERE currency_code = 'GBP' AND order_id % 7 = 0;

COMMENT ON COLUMN storefront.orders.channel IS
    'Sales channel. Defaults to web; the phone importer sends NULL explicitly.';
