-- Cross River Trading Co. -- console roles, balances, week numbers, brand codes
-- author: P. Adeyemi
-- postgres: 18
--
-- The warehouse console's role check, the overdrawn accounts report finance
-- open every morning, the weekly picking figures, the callback list the support
-- desk dials from, the goods-in load, and the brand code the catalogue team
-- correct by hand.

-- DEFECT containment-operator-reversed-grants-every-role
--
-- The console decides who sees the admin screens by asking whether the user's
-- roles contain admin. The operator is the array containment one, and it was
-- written round the wrong way.
--
-- ARRAY['admin'] @> roles asks whether every role the user holds is admin,
-- which is a different question and is true for two groups: users who hold
-- admin, and users who hold nothing at all. An account created and never given
-- a role has an empty array, and the empty array is contained in everything.
-- The check is not broken for the people it was tested with, because a real
-- admin passes either way round.
--
-- Measured: 80 accounts are shown as administrators. 10 of them hold the admin
-- role. The other 70 hold no role at all, which is how every account starts.
--
-- roles @> ARRAY['admin'] is the check that was meant, and 'admin' = ANY(roles)
-- says it more plainly. Nothing here errors, nothing is logged, and the people
-- it lets in are the ones nobody has got round to setting up yet.
CREATE TABLE ops.console_users (
    user_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    username varchar(40) NOT NULL UNIQUE,
    roles    text[] NOT NULL DEFAULT '{}'
);

INSERT INTO ops.console_users (username, roles)
SELECT 'console.' || lpad(g::text, 4, '0'),
       CASE WHEN g % 50 = 0 THEN ARRAY['admin']
            WHEN g % 7  = 0 THEN '{}'::text[]
            WHEN g % 2  = 0 THEN ARRAY['picker']
            ELSE ARRAY['viewer']
       END
FROM generate_series(1, 500) AS g;

CREATE VIEW ops.v_console_admins AS
SELECT u.user_id,
       u.username
FROM ops.console_users u
WHERE ARRAY['admin'] @> u.roles;

COMMENT ON VIEW ops.v_console_admins IS
    'Console accounts with the admin role. Read by the access review.';

-- DEFECT order-by-resolves-to-the-select-alias
--
-- The twenty most overdrawn accounts, worst first. The balance is selected
-- through abs() so the report prints the amount owed without a minus sign in
-- front of it, and the alias was kept as balance_cents so the column heading
-- did not change.
--
-- ORDER BY resolves a bare name as an output column before it looks for an
-- input column, so ORDER BY balance_cents sorts by abs(balance_cents), not by
-- the column of that name in the table. The sort is over distance from zero.
-- Ascending, that is the accounts closest to square, and the worst debts in the
-- ledger are the rows furthest from the top of the report.
--
-- Measured: none of the twenty accounts listed are overdrawn at all. The worst
-- account in the ledger owes 90,910 pennies and is not on the report. The
-- largest figure the report prints is 39 pennies.
--
-- Qualifying the column as b.balance_cents in the ORDER BY sorts by the table
-- column, and renaming the output column avoids the question. The report has
-- twenty rows, sorted, with amounts in them, which is what it is checked for.
CREATE TABLE payments.customer_balances (
    customer_id   integer PRIMARY KEY REFERENCES storefront.customers(customer_id),
    balance_cents integer NOT NULL
);

INSERT INTO payments.customer_balances (customer_id, balance_cents)
SELECT c.customer_id,
       CASE WHEN c.customer_id % 5 = 0
            THEN -1000 - ((c.customer_id * 37) % 90000)
            ELSE (c.customer_id * 13) % 5000
       END
FROM storefront.customers c;

CREATE VIEW analytics.v_overdrawn_accounts AS
SELECT b.customer_id,
       abs(b.balance_cents) AS balance_cents
FROM payments.customer_balances b
ORDER BY balance_cents
LIMIT 20;

-- DEFECT iso-week-bucketed-under-the-calendar-year
--
-- Picks per week, grouped by the year and the week number so the warehouse can
-- compare this week against the same week last year.
--
-- extract(week) is the ISO week number, and ISO weeks belong to ISO years,
-- which do not always agree with the calendar year at the turn of it. The first
-- days of January can fall in week 52 or 53 of the year before. Pairing an ISO
-- week with a calendar year produces a bucket that cannot exist, and splits one
-- real week across two rows of the report.
--
-- Measured: the report contains a row for week 53 of 2027, a year that has no
-- week 53. It holds 1,242 picks over the 3 days that belong to week 53 of 2026,
-- which appears on the report as a separate row of 2,426 picks over 4 days.
--
-- extract(isoyear) is the year that goes with an ISO week, and to_char with
-- IYYY-IW gives both from one call. The bug hides for fifty-one weeks of the
-- year and shows up in the week the year-on-year comparison is run for.
CREATE TABLE ops.picking_rates (
    recorded_on date PRIMARY KEY,
    picks       integer NOT NULL
);

INSERT INTO ops.picking_rates (recorded_on, picks)
SELECT d::date, 400 + (extract(day FROM d)::integer * 7)
FROM generate_series(DATE '2026-12-01', DATE '2027-01-31', INTERVAL '1 day') AS d;

CREATE VIEW analytics.v_weekly_picks AS
SELECT extract(year FROM r.recorded_on)::integer AS year_no,
       extract(week FROM r.recorded_on)::integer AS week_no,
       sum(r.picks)                              AS picks,
       count(*)                                  AS days
FROM ops.picking_rates r
GROUP BY 1, 2;

-- DEFECT phone-number-in-a-numeric-column-loses-the-leading-zero
--
-- The callback list. The numbers came off a spreadsheet, where they were
-- already numbers, and the column was created to match.
--
-- A phone number is not a quantity. It is never added to anything, its digits
-- are positional, and the first of them is a zero that a numeric type has no
-- way to keep. Every domestic number in the table is stored one digit short,
-- and the desk dials what the screen shows.
--
-- Measured: 832 of the 1,040 numbers are ten digits long and were eleven in the
-- file they came from. The 208 written in international form survive, because
-- those start with a 4.
--
-- varchar is the type for a phone number, and it also holds the spacing, the
-- extension and the plus. Nothing rejected the load, every row is present, and
-- the column validates as a number because that is exactly what it is now.
CREATE TABLE support.callback_requests (
    request_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  integer NOT NULL REFERENCES storefront.customers(customer_id),
    phone_number bigint NOT NULL,
    requested_on date NOT NULL
);

COMMENT ON COLUMN support.callback_requests.phone_number IS
    'Contact number as loaded from the callback spreadsheet.';

INSERT INTO support.callback_requests (customer_id, phone_number, requested_on)
SELECT c.customer_id,
       CASE WHEN c.customer_id % 5 = 0
            THEN ('44' || lpad((1772500000 + c.customer_id)::text, 10, '0'))::bigint
            ELSE ('0'  || lpad((1772500000 + c.customer_id)::text, 10, '0'))::bigint
       END,
       DATE '2026-05-04' + (c.customer_id % 120)
FROM storefront.customers c
WHERE c.customer_id % 3 = 0;

-- DEFECT unique-nulls-not-distinct-drops-staged-rows
--
-- Goods-in lines, keyed by the purchase order reference and the batch code.
-- Bulk goods have no batch, so the batch code is null for them. The unique
-- constraint was declared NULLS NOT DISTINCT, because two rows with no batch
-- looked like a duplicate of each other when the table was designed.
--
-- NULLS NOT DISTINCT means exactly that: every bulk line on a purchase order
-- collides with the first one. The load runs with ON CONFLICT DO NOTHING, which
-- was added so a rerun of the file would be safe, so the collisions are not
-- errors. They are rows that were in the file and are not in the table, and the
-- load reports success.
--
-- Measured: 600 of the 900 staged lines reached the table. 300 were dropped,
-- all of them bulk lines on a purchase order that had more than one.
--
-- The default is NULLS DISTINCT, which is what this table needed, with a batch
-- code of its own for bulk lines if two of them really must be told apart. The
-- staging table still holds the file, so the difference is visible to anybody
-- who counts both, and nothing counts both.
CREATE TABLE supply.goods_in_staging (
    stage_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_ref     varchar(16) NOT NULL,
    batch_code varchar(16),
    qty        integer NOT NULL
);

CREATE TABLE supply.goods_in_lines (
    line_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    po_ref     varchar(16) NOT NULL,
    batch_code varchar(16),
    qty        integer NOT NULL,
    UNIQUE NULLS NOT DISTINCT (po_ref, batch_code)
);

INSERT INTO supply.goods_in_staging (po_ref, batch_code, qty)
SELECT 'PO' || lpad(po::text, 6, '0'),
       CASE WHEN line <= 3
            THEN 'B' || lpad(po::text, 4, '0') || '-' || line::text
       END,
       10 * line + (po % 7)
FROM generate_series(1, 150) AS po,
     generate_series(1, 6) AS line;

INSERT INTO supply.goods_in_lines (po_ref, batch_code, qty)
SELECT s.po_ref, s.batch_code, s.qty
FROM supply.goods_in_staging s
ON CONFLICT DO NOTHING;

-- DEFECT on-update-cascade-on-a-natural-key-rewrites-every-child
--
-- Brands are keyed by the brand code, which is the code the catalogue team use
-- and correct. The products reference it, with ON UPDATE CASCADE so a
-- correction does not orphan anything.
--
-- The cascade works. That is the cost: correcting one character of one brand
-- code rewrites every product row carrying it, takes a row lock on each, writes
-- a new version of each, and leaves the old versions for vacuum. The natural
-- key is the one thing in the table that people expect to edit, and it is the
-- value stored in every child row.
--
-- Measured: one code correction moved 500 of the 20,000 product rows. The
-- catalogue team make that edit whenever a brand is renamed.
--
-- A surrogate brand_id in the child rows makes the correction a one row update,
-- with the code kept in one place. Nothing here is incorrect and nothing will
-- ever show up as an error: it shows up as a statement that takes minutes and
-- blocks the catalogue while it runs.
CREATE TABLE catalog.brand_codes (
    brand_code varchar(12) PRIMARY KEY,
    name       varchar(60) NOT NULL
);

CREATE TABLE catalog.brand_products (
    entry_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku        varchar(20) NOT NULL,
    brand_code varchar(12) NOT NULL
        REFERENCES catalog.brand_codes(brand_code) ON UPDATE CASCADE
);

INSERT INTO catalog.brand_codes (brand_code, name)
SELECT 'BR' || lpad(g::text, 4, '0'), 'Brand ' || lpad(g::text, 4, '0')
FROM generate_series(1, 40) AS g;

INSERT INTO catalog.brand_products (sku, brand_code)
SELECT 'CRT-' || lpad(g::text, 6, '0'),
       'BR' || lpad((1 + (g % 40))::text, 4, '0')
FROM generate_series(1, 20000) AS g;

CREATE INDEX ix_brand_products_brand_code ON catalog.brand_products (brand_code);

-- The correction the catalogue team made in June, when the brand was renamed.
UPDATE catalog.brand_codes
   SET brand_code = 'NORTHSTAR'
 WHERE brand_code = 'BR0007';

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.console_users ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('ops.console_users:' || concat_ws('|', x.username, x.roles))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.console_users x
)
UPDATE ops.console_users t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.console_users ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE ops.console_users ADD CONSTRAINT console_users_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_console_users_customer_id ON ops.console_users (customer_id);
-- <<< relationships
