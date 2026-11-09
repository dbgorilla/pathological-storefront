-- Cross River Trading Co. -- brand names, stock count grants, case comments,
-- basket totals, rate cards, courier surcharges
-- author: J. Whitcombe
-- postgres: 18
--
-- The brand list behind the site's filter, the stock count the auditors read,
-- the case comment thread, the basket total on the checkout page, the rate card
-- the yard charges against, and the courier surcharge on a heavy parcel.

-- DEFECT brand-names-are-sorted-under-the-c-collation-and-nobody-asked-for-it
--
-- Brand names are stored in a column declared COLLATE "C", which was copied
-- from an older table where the C collation had been chosen to make an index
-- work with a LIKE pattern.
--
-- The database collates as en_US and this one column does not. C ordering is
-- byte ordering, so every name beginning with a capital letter sorts before
-- every name beginning with a lower case one, and the brand filter on the site
-- lists the alphabet twice. The list is alphabetical by an ordering nobody
-- reading it uses, and there is nothing on screen to explain why a brand that
-- styles itself in lower case is at the bottom.
--
-- Measured: 600 brands, every one of which sits in a different position under the
-- database's own collation than they do under the column's.
--
-- Dropping the column's collation makes it sort like everything else, and the
-- LIKE index the C collation was for wants a text_pattern_ops index instead.
-- The brands at the bottom of the list are the ones that spell themselves in
-- lower case, which is a style choice new brands make more often than old ones.
CREATE TABLE catalog.brand_names (
    brand_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    brand_name varchar(60) COLLATE "C" NOT NULL UNIQUE,
    listed_on  date NOT NULL
);

INSERT INTO catalog.brand_names (brand_name, listed_on)
SELECT CASE WHEN g % 2 = 0
            THEN 'Brand ' || lpad(g::text, 4, '0')
            ELSE 'brand ' || lpad(g::text, 4, '0')
       END,
       DATE '2022-01-01' + (g % 1500)
FROM generate_series(1, 600) AS g;

-- DEFECT reader-role-was-granted-the-tables-that-existed-that-day
--
-- The stock audit role was given select on the stock count tables when it was
-- created. A third table was added to the same schema afterwards.
--
-- The grant named the tables one at a time, which is the only way to grant
-- them, and nothing repeats that grant for tables created later. There are no
-- default privileges set for the schema either. The role reads two of the
-- three tables and gets a permission denied on the third, and the report it
-- runs is written to left join that table, so the failure is the whole report
-- rather than a missing column.
--
-- Measured: three stock count tables in the ops schema and the audit role
-- holding select on two of them.
--
-- ALTER DEFAULT PRIVILEGES makes the grant apply to tables that do not exist
-- yet, which is what was meant. The auditors work from an export produced by
-- somebody else's login, so the broken report is not on anybody's list.
CREATE TABLE ops.stock_counts (
    count_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    counted_on date NOT NULL,
    counted_by varchar(24) NOT NULL
);

CREATE TABLE ops.stock_count_lines (
    line_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    count_id integer NOT NULL REFERENCES ops.stock_counts (count_id),
    sku      varchar(20) NOT NULL,
    units    integer NOT NULL
);

INSERT INTO ops.stock_counts (depot_code, counted_on, counted_by)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-04-01' + (g % 120),
       'counter ' || (1 + (g % 12))::text
FROM generate_series(1, 400) AS g;

INSERT INTO ops.stock_count_lines (count_id, sku, units)
SELECT c.count_id,
       'SKU-' || lpad(((c.count_id * 11 + s) % 900000)::text, 8, '0'),
       1 + ((c.count_id * s) % 300)
FROM ops.stock_counts c,
     generate_series(1, 5) AS s;

CREATE ROLE stock_reader NOLOGIN;
GRANT USAGE ON SCHEMA ops TO stock_reader;
GRANT SELECT ON ops.stock_counts TO stock_reader;
GRANT SELECT ON ops.stock_count_lines TO stock_reader;

-- Added after the grant, and after the role was signed off.
CREATE TABLE ops.stock_count_adjustments (
    adjustment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    count_id      integer NOT NULL REFERENCES ops.stock_counts (count_id),
    sku           varchar(20) NOT NULL,
    units_delta   integer NOT NULL,
    reason        varchar(40) NOT NULL
);

INSERT INTO ops.stock_count_adjustments (count_id, sku, units_delta, reason)
SELECT c.count_id,
       'SKU-' || lpad(((c.count_id * 11 + 2) % 900000)::text, 8, '0'),
       CASE WHEN c.count_id % 2 = 0 THEN 1 + (c.count_id % 20) ELSE -(1 + (c.count_id % 15)) END,
       (ARRAY['damaged', 'miscount', 'found', 'written off'])[1 + (c.count_id % 4)]
FROM ops.stock_counts c
WHERE c.count_id % 4 = 0;

-- DEFECT restored-rows-kept-their-keys-and-the-sequence-did-not
--
-- Case comments were restored from a backup after a bad deployment. The restore
-- kept the original comment ids, because the case threads reference them.
--
-- Restoring rows with explicit keys does not move the sequence behind the
-- column. The sequence is where it was when the backup was taken, thousands
-- below the highest key now in the table, and every insert from here until it
-- catches up asks for a key that already exists. Each one fails on the primary
-- key, the application retries, and the retry asks for the next one, which also
-- exists.
--
-- Measured: 4,000 case comments with a highest id of 4,000 and the sequence
-- sitting at 1,200, so 2,800 keys are already taken above it.
--
-- setval on the sequence to the table's maximum is one statement and is the
-- last step of any restore that keeps its keys. The failures look like a
-- flapping application rather than a restore that was not finished.
CREATE TABLE support.case_comments (
    comment_id  serial PRIMARY KEY,
    case_ref    varchar(16) NOT NULL,
    author      varchar(24) NOT NULL,
    body        varchar(200) NOT NULL,
    written_at  timestamptz NOT NULL
);

INSERT INTO support.case_comments (comment_id, case_ref, author, body, written_at)
SELECT g,
       'CASE-' || lpad((1 + (g % 900))::text, 6, '0'),
       'agent ' || (1 + (g % 30))::text,
       'Comment ' || g || ' on the case.',
       TIMESTAMPTZ '2026-02-01 09:00:00+00' + (g * INTERVAL '7 minutes')
FROM generate_series(1, 4000) AS g;

-- Where the sequence stood when the backup was taken.
SELECT setval('support.case_comments_comment_id_seq', 1200, true);

-- DEFECT basket-total-is-written-on-add-and-not-on-remove
--
-- The checkout page reads a basket total from its own table, kept up to date by
-- the code that adds a line to the basket.
--
-- Removing a line takes a different code path, written later, and that path
-- deletes the line without touching the total. The basket total is therefore
-- correct until the shopper changes their mind, and after that it is the total
-- of everything they ever put in the basket. The checkout page shows the
-- inflated figure and the payment is taken for the real one, so the shopper is
-- charged correctly and told they were charged more.
--
-- Measured: 500 baskets holding 2,308 lines, with 192 baskets whose stored
-- total no longer equals the sum of their lines.
--
-- One function that owns the total, called from both paths, is the fix, and
-- working the total out from the lines when the page renders removes the
-- question. The complaints come in as pricing complaints and are answered by
-- pointing at the correct card statement.
CREATE TABLE storefront.basket_lines (
    line_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    basket_ref varchar(16) NOT NULL,
    sku        varchar(20) NOT NULL,
    line_total numeric(10,2) NOT NULL
);

CREATE TABLE storefront.basket_totals (
    basket_ref varchar(16) PRIMARY KEY,
    total      numeric(10,2) NOT NULL,
    updated_at timestamptz NOT NULL
);

INSERT INTO storefront.basket_lines (basket_ref, sku, line_total)
SELECT 'BSK-' || lpad(b::text, 8, '0'),
       'SKU-' || lpad(((b * 7 + s) % 900000)::text, 8, '0'),
       (5 + ((b + s) % 90))::numeric(10,2)
FROM generate_series(1, 500) AS b,
     generate_series(1, 5) AS s;

INSERT INTO storefront.basket_totals (basket_ref, total, updated_at)
SELECT basket_ref, sum(line_total), TIMESTAMPTZ '2026-07-20 12:00:00+01'
FROM storefront.basket_lines
GROUP BY basket_ref;

-- Shoppers changing their minds, down the path that forgot the total.
DELETE FROM storefront.basket_lines WHERE line_id % 13 = 0;

-- DEFECT statement-level-audit-trigger-logs-one-row-for-a-whole-bulk-update
--
-- Rate card amendments are audited by a trigger, and the trigger is FOR EACH
-- STATEMENT.
--
-- A statement level trigger fires once per statement however many rows the
-- statement touched. It cannot see NEW or OLD, so the audit row records that
-- something changed and nothing about what. An amendment made one card at a
-- time is audited one row at a time, which is how it was tested. An amendment
-- made by the yearly uplift, which is four statements over hundreds of cards,
-- is audited four times.
--
-- Measured: 800 rate cards amended and 4 rows in the audit table.
--
-- FOR EACH ROW with OLD and NEW recorded gives the audit its subject back, and
-- a transition table gives the same thing at statement level if the volume
-- matters. The audit is inspected when a supplier disputes a rate, and the
-- bulk uplift is exactly when that happens.
CREATE TABLE ops.rate_cards (
    card_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref varchar(12) NOT NULL,
    service_code varchar(12) NOT NULL,
    rate         numeric(10,2) NOT NULL,
    amended_at   timestamptz
);

CREATE TABLE ops.rate_card_audit (
    audit_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    changed_at timestamptz NOT NULL,
    changed_by name NOT NULL
);

CREATE FUNCTION ops.fn_audit_rate_cards() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.rate_card_audit (changed_at, changed_by)
    VALUES (clock_timestamp(), current_user);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_rate_cards
    AFTER UPDATE ON ops.rate_cards
    FOR EACH STATEMENT EXECUTE FUNCTION ops.fn_audit_rate_cards();

INSERT INTO ops.rate_cards (supplier_ref, service_code, rate)
SELECT 'SUP-' || lpad((1 + (g % 70))::text, 3, '0'),
       'SVC-' || lpad((1 + (g % 16))::text, 3, '0'),
       (4 + (g % 120))::numeric(10,2)
FROM generate_series(1, 800) AS g;

-- The yearly uplift, in four statements.
UPDATE ops.rate_cards SET rate = round(rate * 1.03, 2), amended_at = TIMESTAMPTZ '2026-04-01 08:00:00+01' WHERE card_id % 4 = 0;
UPDATE ops.rate_cards SET rate = round(rate * 1.03, 2), amended_at = TIMESTAMPTZ '2026-04-01 08:00:00+01' WHERE card_id % 4 = 1;
UPDATE ops.rate_cards SET rate = round(rate * 1.03, 2), amended_at = TIMESTAMPTZ '2026-04-01 08:00:00+01' WHERE card_id % 4 = 2;
UPDATE ops.rate_cards SET rate = round(rate * 1.03, 2), amended_at = TIMESTAMPTZ '2026-04-01 08:00:00+01' WHERE card_id % 4 = 3;

-- DEFECT integer-division-in-the-commission-calculation-drops-the-pence
--
-- The courier surcharge is worked out per kilogram from a weight held in
-- grammes: weight times rate, divided by a thousand.
--
-- Every value in that expression is an integer, so the division is integer
-- division and the remainder is thrown away. The surcharge is always rounded
-- down, never to the nearest penny, and the amount lost is between nothing and
-- a penny on every parcel. It is charged to the courier, who is content, and it
-- is the kind of rounding that is only ever noticed by whoever is on the losing
-- side of it consistently.
--
-- Measured: 2,000 courier surcharges, 1,966 of them lower than the same
-- calculation done in decimal, which is kept alongside.
--
-- Dividing by 1000.0, or casting one operand to numeric, makes the division
-- decimal, and round rather than truncation decides the penny. The difference
-- per parcel is under a penny, and the volume is two thousand parcels a week.
CREATE TABLE payments.courier_surcharges (
    surcharge_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parcel_ref       varchar(16) NOT NULL,
    weight_g         integer NOT NULL,
    rate_pence_per_kg integer NOT NULL,
    surcharge_pence  integer NOT NULL,
    surcharge_exact  numeric(10,2) NOT NULL
);

INSERT INTO payments.courier_surcharges (parcel_ref, weight_g, rate_pence_per_kg, surcharge_pence, surcharge_exact)
SELECT 'PCL-' || lpad((500000 + g)::text, 8, '0'),
       w.weight_g,
       r.rate,
       w.weight_g * r.rate / 1000,
       round((w.weight_g * r.rate)::numeric / 1000, 2)
FROM generate_series(1, 2000) AS g,
     LATERAL (SELECT 250 + (g * 37) % 24000 AS weight_g) w,
     LATERAL (SELECT 15 + (g * 13) % 90 AS rate) r;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.brand_names ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.brand_names:' || concat_ws('|', x.brand_name))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.brand_names x
)
UPDATE catalog.brand_names t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.brand_names ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.brand_names ADD CONSTRAINT brand_names_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_brand_names_product_id ON catalog.brand_names (product_id);

ALTER TABLE payments.courier_surcharges ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.courier_surcharges:' || concat_ws('|', x.parcel_ref, x.weight_g, x.rate_pence_per_kg, x.surcharge_pence, x.surcharge_exact))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.courier_surcharges x
)
UPDATE payments.courier_surcharges t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.courier_surcharges ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.courier_surcharges ADD CONSTRAINT courier_surcharges_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_courier_surcharges_transaction_id ON payments.courier_surcharges (transaction_id);

ALTER TABLE storefront.basket_totals ADD COLUMN order_id integer;

WITH p AS (
    SELECT order_id AS v, row_number() OVER (ORDER BY order_id) - 1 AS k
      FROM storefront.orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.orders)
                 * power((abs(hashtext('storefront.basket_totals:' || concat_ws('|', x.basket_ref, x.total))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.basket_totals x
)
UPDATE storefront.basket_totals t
   SET order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.basket_totals ALTER COLUMN order_id SET NOT NULL;
ALTER TABLE storefront.basket_totals ADD CONSTRAINT basket_totals_order_id_fkey FOREIGN KEY (order_id) REFERENCES storefront.orders (order_id);
CREATE INDEX ix_basket_totals_order_id ON storefront.basket_totals (order_id);

ALTER TABLE support.case_comments ADD COLUMN case_id integer;

WITH p AS (
    SELECT case_id AS v, row_number() OVER (ORDER BY case_id) - 1 AS k
      FROM support.case_records
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.case_records)
                 * power((abs(hashtext('support.case_comments:' || concat_ws('|', x.case_ref, x.author, x.body))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.case_comments x
)
UPDATE support.case_comments t
   SET case_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.case_comments ALTER COLUMN case_id SET NOT NULL;
ALTER TABLE support.case_comments ADD CONSTRAINT case_comments_case_id_fkey FOREIGN KEY (case_id) REFERENCES support.case_records (case_id);
CREATE INDEX ix_case_comments_case_id ON support.case_comments (case_id);
-- <<< relationships
