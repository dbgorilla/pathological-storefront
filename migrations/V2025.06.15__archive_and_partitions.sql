-- Cross River Trading Co. -- archiving old orders
-- author: N. Farrell (data)
-- postgres: 16
--
-- orders has grown past what the reporting queries can scan. Two approaches
-- were taken, eighteen months apart, by different people.

CREATE SCHEMA archive;

-- Approach one, 2023: copy old years into year tables by hand.
--
-- DEFECT manual-partition-schema-drift
-- These were created from the shape of orders as it stood on the day each was
-- made. orders_2023 predates the Meridian columns; orders_2024 has them. A
-- UNION ALL across the two fails, and any tool that assumes year tables share
-- a shape is wrong about these.
CREATE TABLE archive.orders_2023 (
    order_id      integer PRIMARY KEY,
    customer_id   integer NOT NULL,
    status        varchar(255) NOT NULL,
    total_cents   integer NOT NULL,
    placed_at     timestamptz NOT NULL,
    store_id      integer
);

CREATE TABLE archive.orders_2024 (
    order_id       integer PRIMARY KEY,
    customer_id    integer NOT NULL,
    status         varchar(255) NOT NULL,
    total_cents    integer NOT NULL,
    placed_at      timestamptz NOT NULL,
    store_id       integer,
    -- Present here and absent from orders_2023.
    total_minor    bigint,
    currency_code  char(3),
    gift_message   varchar(255)
);

-- Approach two, 2025: do it properly with declarative partitioning.
CREATE TABLE archive.page_views_archive (
    page_view_id  bigint NOT NULL,
    customer_id   integer,
    product_id    integer,
    store_id      integer,
    viewed_at     timestamptz NOT NULL
) PARTITION BY RANGE (viewed_at);

CREATE TABLE archive.page_views_2025q3 PARTITION OF archive.page_views_archive
    FOR VALUES FROM ('2025-07-01') TO ('2025-10-01');
CREATE TABLE archive.page_views_2025q4 PARTITION OF archive.page_views_archive
    FOR VALUES FROM ('2025-10-01') TO ('2026-01-01');
CREATE TABLE archive.page_views_2026q1 PARTITION OF archive.page_views_archive
    FOR VALUES FROM ('2026-01-01') TO ('2026-04-01');
CREATE TABLE archive.page_views_2026q2 PARTITION OF archive.page_views_archive
    FOR VALUES FROM ('2026-04-01') TO ('2026-07-01');

-- DEFECT missing-current-partition
-- The partitions were created by hand, four quarters ahead, by someone who
-- intended to automate it later. The last one ends on 2026-07-01.
--
-- There is no DEFAULT partition, so an insert dated after that point fails
-- outright with "no partition of relation found for row". The archive job has
-- been failing since July and its errors go to a log nobody reads.

COMMENT ON TABLE archive.page_views_archive IS
    'Partitioned by quarter. Partitions were hand-created to 2026-07-01 and stop there.';

-- DEFECT index-on-one-partition-only
--
-- Created at two in the morning during an incident. The customer history screen
-- was timing out on the current quarter, an index on customer_id fixed it, and
-- the change was made where the problem was.
--
-- An index created on the partitioned parent is built on every partition and on
-- every partition added afterwards. This one was created on a single partition,
-- so it covers 2026 Q2 and nothing else. The screen is fast for the quarter
-- that was on fire and scans every row for the other three, which is the shape
-- of the original problem and the reason nobody reopened the ticket.
--
-- Nothing reports this. \d on the parent lists no index at all; \d on each
-- partition has to be read one at a time to see that three of the four differ.
-- Every partition created from now on will be missing it too.
CREATE INDEX ix_page_views_2026q2_customer
    ON archive.page_views_2026q2 (customer_id);

-- DEFECT primary-key-widened-to-satisfy-partitioning
--
-- The archive needed a primary key, and PRIMARY KEY (page_view_id) was
-- refused: PostgreSQL requires every unique constraint on a partitioned table
-- to contain the partition key, because it can only enforce uniqueness inside
-- one partition. Adding viewed_at made the error go away and the deploy went
-- out.
--
-- The key that resulted promises something nobody asked for. It makes the pair
-- unique and leaves page_view_id free to repeat, so the same archived page
-- view can exist once in each quarter. That is exactly what the archive loader
-- produces when it is re-run over a window it has already copied, which is how
-- it recovers from a failed night, and it is the one case the key was added to
-- stop.
--
-- Measured: the same page_view_id inserts cleanly into two quarters. The
-- constraint is listed as the primary key, the column everybody joins on is in
-- it, and the duplicate shows up as a doubled row count in a report rather
-- than as an error at load time.
ALTER TABLE archive.page_views_archive
    ADD CONSTRAINT page_views_archive_pkey PRIMARY KEY (page_view_id, viewed_at);

-- DEFECT inheritance-parent-enforces-nothing
--
-- A third approach, from the 2025 attempt to make the two hand-made year
-- tables queryable as one. Table inheritance predates declarative
-- partitioning, it is still in PostgreSQL, and it is what the tutorial that
-- was open at the time described.
--
-- An inheritance parent is not a partitioned table. A query naming it reads
-- the children too, which is the effect that was wanted, and nothing else
-- carries down: the primary key on the parent constrains only the parent's own
-- rows, so the same order_id can exist in orders_2023 and orders_2024 at once,
-- and there is no partition bound to say which year a row belongs in. Nothing
-- stops a 2024 order being written into orders_2023.
--
-- The parent has no rows of its own and never will. Every tool that reports
-- table sizes shows it as empty, every count from it returns the children, and
-- the difference between the two numbers is the whole trap.
CREATE TABLE archive.orders_base (
    order_id      integer PRIMARY KEY,
    customer_id   integer NOT NULL,
    status        varchar(255) NOT NULL,
    total_cents   integer NOT NULL,
    placed_at     timestamptz NOT NULL,
    store_id      integer
);

ALTER TABLE archive.orders_2023 INHERIT archive.orders_base;
ALTER TABLE archive.orders_2024 INHERIT archive.orders_base;

-- DEFECT union-branch-columns-in-the-wrong-order
--
-- One list of every order id the business has ever had, live and archived,
-- for the reconciliation that runs against the payment provider. UNION ALL of
-- three branches, written in one sitting.
--
-- The second and third branches list customer_id and store_id the other way
-- round. A UNION matches its branches by position and not by name, so the
-- archived rows arrive with the store in the customer column and the customer
-- in the store column. Both are integer, so nothing can object: there is no
-- type error to raise and no name for the result to disagree with, because the
-- column names come from the first branch alone.
--
-- Measured: every one of the archived rows carries the wrong customer. They
-- are integers in the right range, so they look like customers, and the
-- reconciliation matches most of them against a real customer who did not
-- place the order. The live branch is correct, which is most of the rows, so
-- the output passes any spot check that starts at the top.
CREATE VIEW analytics.v_order_index AS
SELECT order_id, customer_id, store_id, 'live'::text AS source
FROM storefront.orders
UNION ALL
SELECT order_id, store_id, customer_id, 'archive-2023'::text
FROM archive.orders_2023
UNION ALL
SELECT order_id, store_id, customer_id, 'archive-2024'::text
FROM archive.orders_2024;

-- DEFECT invalid-partitioned-index-never-attached
--
-- An index on viewed_at across the whole archive, added when the retention
-- report started timing out. On a partitioned table the parent index is a
-- template: it is created ON ONLY the parent and becomes usable when a
-- matching index exists on every partition and has been attached to it.
--
-- The attaching was to be done partition by partition out of hours, and the
-- first one was never done. An index in that state is marked invalid, and an
-- invalid index is ignored by the planner while still being listed by every
-- catalogue query, every schema browser and every dump.
--
-- Measured: one invalid index in the database. It answers nothing, and it is
-- the index the retention report was supposed to use, so the report still
-- times out and the ticket was closed as fixed in 2025. The fix is to build a
-- matching index on each partition and ATTACH it, at which point the parent
-- turns valid on its own.
CREATE INDEX ix_page_views_archive_viewed_at
    ON ONLY archive.page_views_archive (viewed_at);

-- DEFECT function-on-the-partition-key-defeats-pruning
--
-- Recent page views out of the archive. The partition key is viewed_at and
-- the filter is on viewed_at, so this looks like exactly the query
-- partitioning was introduced to make fast.
--
-- Partition pruning matches the filter against the partition bounds, and it
-- can only do that when the key appears on its own. Casting it to date
-- produces an expression the planner cannot compare to a timestamptz bound,
-- so no partition is excluded and every one is scanned. The cast is there
-- because the report compares against a date and the author removed the
-- mismatch on the wrong side of the operator.
--
-- Writing viewed_at >= TIMESTAMPTZ '2026-01-01 00:00+00' prunes to the
-- partitions that can hold matching rows and changes no output. Nothing warns
-- that the current form does not, and the plan is the only place it shows.
CREATE VIEW archive.v_page_views_recent AS
SELECT page_view_id, viewed_at, customer_id, product_id
FROM archive.page_views_archive
WHERE viewed_at::date >= DATE '2026-01-01';
