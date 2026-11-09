-- Cross River Trading Co. -- pass voids, invoice due dates, campaign stats,
-- shop visits, trade invoices, merchant payouts
-- author: T. Marchetti
-- postgres: 18
--
-- Voiding a gate pass, the due date on a trade invoice, the campaign statistics
-- the marketing agency reads, the shop visit log the reporting role queries,
-- the trade invoices behind a supplier, and the merchant payout row.

-- DEFECT anybody-may-run-the-function-that-voids-a-gate-pass
--
-- Voiding a gate pass runs through a SECURITY DEFINER function, so that the
-- gatehouse terminal can void a pass without holding write access to the table.
--
-- The function checks nothing about its caller. Execute on a function is
-- granted to everybody by default and nobody revoked it, so every role in the
-- database can void any pass, and the function will do it with the owner's
-- privileges. It records who called it, which is the only reason this is
-- visible at all: the web application's role appears in the void log, and the
-- web application has no business voiding gate passes.
--
-- Measured: 1,200 pass voids, 300 of them recorded against the web
-- application's role.
--
-- A check on current_user inside the function, and execute granted to the
-- gatehouse role rather than left with PUBLIC, are both one line. The voids
-- look ordinary in the yard's own report, which does not show who made them.
CREATE TABLE ops.pass_voids (
    void_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pass_ref  varchar(16) NOT NULL,
    reason    varchar(40) NOT NULL,
    voided_by varchar(24) NOT NULL,
    voided_at timestamptz NOT NULL
);

CREATE FUNCTION ops.fn_void_gate_pass(p_pass_ref varchar, p_reason varchar)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, ops
AS $$
DECLARE
    v_id integer;
BEGIN
    INSERT INTO ops.pass_voids (pass_ref, reason, voided_by, voided_at)
    VALUES (p_pass_ref, p_reason, current_user, now())
    RETURNING void_id INTO v_id;
    RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION ops.fn_void_gate_pass(varchar, varchar) TO PUBLIC;

INSERT INTO ops.pass_voids (pass_ref, reason, voided_by, voided_at)
SELECT 'GP-' || lpad(g::text, 8, '0'),
       (ARRAY['vehicle turned away', 'wrong depot', 'duplicate', 'driver changed'])[1 + (g % 4)],
       CASE WHEN g % 4 = 0 THEN 'web_app' ELSE 'gatehouse' END,
       TIMESTAMPTZ '2026-05-02 07:00:00+01' + (g * INTERVAL '29 minutes')
FROM generate_series(1, 1200) AS g;

-- DEFECT due-dates-were-backfilled-at-thirty-days-for-everybody
--
-- Trade invoices gained a due date column. The historic rows were backfilled at
-- thirty days from issue, because thirty days is the standard term.
--
-- It is the standard term and it is not everybody's term. Accounts negotiated
-- down to fourteen days and up to sixty days both exist, and the backfill did
-- not look at the account. Every historic invoice now claims a due date the
-- customer never agreed to, in both directions: the fourteen day accounts look
-- late when they were not, and the sixty day accounts look current when they
-- were overdue.
--
-- Measured: 2,000 invoices against 400 accounts, and 1,330 invoices whose due
-- date does not match the account's own terms.
--
-- The terms were on the account the whole time and joining to them is the
-- backfill that should have run. The credit control list is built from this
-- column, so the chasing has been aimed at the wrong customers since the day it
-- was populated.
CREATE TABLE payments.account_terms (
    account_ref varchar(12) PRIMARY KEY,
    terms_days  integer NOT NULL,
    agreed_on   date NOT NULL
);

CREATE TABLE payments.invoice_due_dates (
    invoice_ref varchar(16) PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    issued_on   date NOT NULL,
    due_on      date NOT NULL,
    amount      numeric(12,2) NOT NULL
);

INSERT INTO payments.account_terms (account_ref, terms_days, agreed_on)
SELECT 'ACC-' || lpad(g::text, 5, '0'),
       (ARRAY[14, 30, 60])[1 + (g % 3)],
       DATE '2022-01-01' + (g % 1200)
FROM generate_series(1, 400) AS g;

INSERT INTO payments.invoice_due_dates (invoice_ref, account_ref, issued_on, due_on, amount)
SELECT 'TIN-' || lpad(g::text, 8, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       DATE '2026-01-01' + (g % 200),
       DATE '2026-01-01' + (g % 200) + 30,
       (90 + (g % 4000))::numeric(12,2)
FROM generate_series(1, 2000) AS g;

-- DEFECT reader-has-the-table-and-not-the-schema-it-lives-in
--
-- The agency's reporting role was granted select on the campaign statistics
-- table. It cannot read a row.
--
-- Reading a table needs usage on the schema that holds it as well as select on
-- the table itself, and the grant only did the second. Every privilege audit
-- shows the role holding select on exactly the table it is supposed to read,
-- and every query it runs returns permission denied for schema marketing. The
-- grant is present, correct and useless.
--
-- Measured: the agency role holds select on marketing.campaign_stats and no
-- usage on the marketing schema.
--
-- GRANT USAGE ON SCHEMA marketing is the missing line. The agency reports the
-- failure as the report being broken, and it has been retried, rewritten and
-- escalated as a reporting problem three times.
CREATE TABLE marketing.campaign_stats (
    campaign_code varchar(16) NOT NULL,
    stat_on       date NOT NULL,
    impressions   integer NOT NULL,
    clicks        integer NOT NULL,
    spend         numeric(10,2) NOT NULL,
    PRIMARY KEY (campaign_code, stat_on)
);

INSERT INTO marketing.campaign_stats (campaign_code, stat_on, impressions, clicks, spend)
SELECT 'CMP-' || lpad(c::text, 6, '0'),
       DATE '2026-06-01' + d,
       2000 + ((c * d * 17) % 60000),
       10 + ((c * d) % 900),
       (40 + ((c * d * 3) % 700))::numeric(10,2)
FROM generate_series(1, 40) AS c,
     generate_series(0, 29) AS d;

CREATE ROLE agency_reader NOLOGIN;
GRANT SELECT ON marketing.campaign_stats TO agency_reader;

-- DEFECT reporting-role-was-granted-all-privileges-on-every-table
--
-- The reporting role needs to read the shop visit log. It was granted all
-- privileges on every table in the storefront schema.
--
-- ALL is shorter to type than SELECT and it was a Friday. The role can insert,
-- update, delete and truncate every table in the schema that holds the shop,
-- the baskets and the orders. Nothing it runs uses any of that, so nothing has
-- gone wrong and nothing will until a report is written with a typo in it or
-- the role's credentials are used by something that is not a report.
--
-- Measured: the reporting role holds update on the shop visit and shop basket
-- tables, which it is supposed to be able to read and nothing else.
--
-- GRANT SELECT is the grant that was meant, and revoking the rest is one
-- statement. A privilege audit that lists roles rather than privileges shows
-- one reporting role with access to one schema, which is exactly what was asked
-- for at the time.
CREATE TABLE storefront.shop_visits (
    visit_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_ref varchar(32) NOT NULL,
    landed_on  varchar(120) NOT NULL,
    visited_at timestamptz NOT NULL
);

CREATE TABLE storefront.shop_baskets (
    basket_ref  varchar(16) PRIMARY KEY,
    session_ref varchar(32) NOT NULL,
    items       integer NOT NULL,
    created_at  timestamptz NOT NULL
);

INSERT INTO storefront.shop_visits (session_ref, landed_on, visited_at)
SELECT md5(g::text),
       '/' || (ARRAY['home', 'search', 'basket', 'product', 'offers'])[1 + (g % 5)],
       TIMESTAMPTZ '2026-07-01 08:00:00+01' + (g * INTERVAL '2 minutes')
FROM generate_series(1, 3000) AS g;

INSERT INTO storefront.shop_baskets (basket_ref, session_ref, items, created_at)
SELECT 'SBK-' || lpad(g::text, 8, '0'),
       md5(g::text),
       1 + (g % 9),
       TIMESTAMPTZ '2026-07-01 08:10:00+01' + (g * INTERVAL '5 minutes')
FROM generate_series(1, 1200) AS g;

CREATE ROLE report_writer NOLOGIN;
GRANT USAGE ON SCHEMA storefront TO report_writer;
GRANT ALL ON ALL TABLES IN SCHEMA storefront TO report_writer;

-- DEFECT cascade-on-a-supplier-delete-took-the-invoices-with-it
--
-- Trade invoices reference their supplier with ON DELETE CASCADE, so that
-- removing a supplier does not leave rows behind.
--
-- Removing a supplier is not supposed to remove its invoices. Invoices are
-- financial records and are kept for six years whatever happens to the
-- relationship. The cascade was written by somebody clearing up orphan rows in
-- a test database and it does exactly what it says: a tidy up of twenty dormant
-- suppliers deleted four hundred invoices without a word, and the only record
-- that they existed is the load table, which counts what was loaded.
--
-- Measured: 2,000 invoice lines loaded, 1,600 invoices in the table, and 20
-- suppliers removed.
--
-- ON DELETE RESTRICT refuses the delete and makes the question visible, which
-- is what a financial record wants. The gap was found by a total that no longer
-- matched last year's accounts, eleven months later.
CREATE TABLE supply.trade_suppliers (
    supplier_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref varchar(12) NOT NULL UNIQUE,
    trading_name varchar(60) NOT NULL,
    opened_on    date NOT NULL
);

CREATE TABLE supply.trade_invoices (
    invoice_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id integer NOT NULL REFERENCES supply.trade_suppliers (supplier_id) ON DELETE CASCADE,
    invoice_ref varchar(16) NOT NULL,
    issued_on   date NOT NULL,
    amount      numeric(12,2) NOT NULL
);

CREATE TABLE supply.trade_invoice_loads (
    load_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    loaded_on    date NOT NULL,
    lines_loaded integer NOT NULL
);

INSERT INTO supply.trade_suppliers (supplier_ref, trading_name, opened_on)
SELECT 'TSU-' || lpad(g::text, 6, '0'),
       'Trade supplier ' || g,
       DATE '2018-01-01' + (g % 2500)
FROM generate_series(1, 100) AS g;

INSERT INTO supply.trade_invoices (supplier_id, invoice_ref, issued_on, amount)
SELECT s.supplier_id,
       'TRI-' || lpad((s.supplier_id * 100 + n)::text, 8, '0'),
       DATE '2025-01-01' + ((s.supplier_id * n) % 500),
       (200 + ((s.supplier_id * n * 7) % 9000))::numeric(12,2)
FROM supply.trade_suppliers s,
     generate_series(1, 20) AS n;

INSERT INTO supply.trade_invoice_loads (loaded_on, lines_loaded)
SELECT DATE '2025-01-01' + (g * 30), 100
FROM generate_series(1, 20) AS g;

-- The tidy up of dormant suppliers.
DELETE FROM supply.trade_suppliers WHERE supplier_id % 5 = 0;

-- DEFECT row-policy-restricts-reads-and-checks-nothing-on-write
--
-- Merchant payouts are protected by a row policy so that a merchant sees only
-- its own payouts. The policy has a USING clause and no WITH CHECK clause.
--
-- USING filters what a statement can see. WITH CHECK decides what it may write,
-- and when it is absent for an INSERT the policy allows any row at all. A
-- merchant can therefore insert a payout attributed to another merchant, which
-- it will then be unable to see, which is the detail that makes this hard to
-- find by testing: everything a merchant writes and reads back behaves exactly
-- as it should.
--
-- Measured: one policy on payments.merchant_payouts with a USING clause and no
-- WITH CHECK, over 1,500 payouts for 25 merchants.
--
-- FOR ALL wants both clauses, and the WITH CHECK is usually the same expression
-- as the USING. The policy was reviewed by reading what a merchant can see,
-- which is the half that is correct.
CREATE TABLE payments.merchant_payouts (
    payout_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_ref varchar(12) NOT NULL,
    paid_on      date NOT NULL,
    amount       numeric(12,2) NOT NULL
);

INSERT INTO payments.merchant_payouts (merchant_ref, paid_on, amount)
SELECT 'MER-' || lpad((1 + (g % 25))::text, 4, '0'),
       DATE '2026-05-01' + (g % 120),
       (120 + (g % 7000))::numeric(12,2)
FROM generate_series(1, 1500) AS g;

ALTER TABLE payments.merchant_payouts ENABLE ROW LEVEL SECURITY;

CREATE POLICY merchant_payouts_own_rows ON payments.merchant_payouts
    FOR ALL
    USING (merchant_ref = current_setting('app.merchant_ref', true));

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE marketing.campaign_stats ADD COLUMN campaign_id integer;

WITH p AS (
    SELECT campaign_id AS v, row_number() OVER (ORDER BY campaign_id) - 1 AS k
      FROM marketing.campaigns
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM marketing.campaigns)
                 * power((abs(hashtext('marketing.campaign_stats:' || concat_ws('|', x.campaign_code, x.impressions, x.clicks, x.spend))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.campaign_stats x
)
UPDATE marketing.campaign_stats t
   SET campaign_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.campaign_stats ALTER COLUMN campaign_id SET NOT NULL;
ALTER TABLE marketing.campaign_stats ADD CONSTRAINT campaign_stats_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES marketing.campaigns (campaign_id);
CREATE INDEX ix_campaign_stats_campaign_id ON marketing.campaign_stats (campaign_id);

ALTER TABLE payments.account_terms ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('payments.account_terms:' || concat_ws('|', x.account_ref, x.terms_days))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.account_terms x
)
UPDATE payments.account_terms t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.account_terms ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE payments.account_terms ADD CONSTRAINT account_terms_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_account_terms_customer_id ON payments.account_terms (customer_id);

ALTER TABLE payments.invoice_due_dates ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('payments.invoice_due_dates:' || concat_ws('|', x.invoice_ref, x.account_ref, x.amount))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.invoice_due_dates x
)
UPDATE payments.invoice_due_dates t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.invoice_due_dates ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE payments.invoice_due_dates ADD CONSTRAINT invoice_due_dates_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_invoice_due_dates_customer_id ON payments.invoice_due_dates (customer_id);

ALTER TABLE storefront.shop_baskets ADD COLUMN order_id integer;

WITH p AS (
    SELECT order_id AS v, row_number() OVER (ORDER BY order_id) - 1 AS k
      FROM storefront.orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.orders)
                 * power((abs(hashtext('storefront.shop_baskets:' || concat_ws('|', x.basket_ref, x.session_ref, x.items))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.shop_baskets x
)
UPDATE storefront.shop_baskets t
   SET order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.shop_baskets ALTER COLUMN order_id SET NOT NULL;
ALTER TABLE storefront.shop_baskets ADD CONSTRAINT shop_baskets_order_id_fkey FOREIGN KEY (order_id) REFERENCES storefront.orders (order_id);
CREATE INDEX ix_shop_baskets_order_id ON storefront.shop_baskets (order_id);

ALTER TABLE storefront.shop_visits ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('storefront.shop_visits:' || concat_ws('|', x.session_ref, x.landed_on))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.shop_visits x
)
UPDATE storefront.shop_visits t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.shop_visits ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE storefront.shop_visits ADD CONSTRAINT shop_visits_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_shop_visits_store_id ON storefront.shop_visits (store_id);

ALTER TABLE supply.trade_invoice_loads ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.trade_invoice_loads:' || concat_ws('|', x.lines_loaded))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.trade_invoice_loads x
)
UPDATE supply.trade_invoice_loads t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.trade_invoice_loads ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.trade_invoice_loads ADD CONSTRAINT trade_invoice_loads_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_trade_invoice_loads_supplier_id ON supply.trade_invoice_loads (supplier_id);
-- <<< relationships
