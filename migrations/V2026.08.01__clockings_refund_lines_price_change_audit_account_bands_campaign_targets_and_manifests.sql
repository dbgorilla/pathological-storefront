-- Cross River Trading Co. -- shift clockings, refund lines, price change
-- audit, account bands, campaign targets, inbound manifests
-- author: T. Marchetti
-- postgres: 18
--
-- The clock in terminal's table, the refund batch and its lines, the price
-- change audit, the account banding on the marketing dashboard, the campaign
-- target list, and the inbound manifest feed.

-- DEFECT unlogged-table-holds-the-clockings-payroll-is-run-from
--
-- Shift clockings were moved to an unlogged table during a week when the clock
-- in terminals were timing out, and it worked: an unlogged table does not go
-- through the write ahead log and writes are considerably cheaper.
--
-- An unlogged table is also emptied on crash recovery and is not replicated,
-- so it is not present on the standby and not in a base backup taken from it.
-- Payroll is run from this table. A crash at any point in a month costs the
-- clockings since the last export, and the standby has never had them at all.
--
-- Measured: 4,000 clockings, in a table whose persistence is unlogged.
--
-- A logged table with the load spread over the terminals is the fix. The
-- change was made under pressure, it solved the problem in front of everyone,
-- and nothing has gone wrong since, which is the whole difficulty.
CREATE UNLOGGED TABLE ops.shift_clockings (
    clocking_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    staff_ref   varchar(12) NOT NULL,
    depot_code  varchar(12) NOT NULL,
    clocked_at  timestamptz NOT NULL,
    direction   varchar(4) NOT NULL
);

INSERT INTO ops.shift_clockings (staff_ref, depot_code, clocked_at, direction)
SELECT 'STF-' || lpad((1 + (g % 260))::text, 5, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-07-01 05:45:00+01' + (g * INTERVAL '7 minutes'),
       CASE WHEN g % 2 = 0 THEN 'in' ELSE 'out' END
FROM generate_series(1, 4000) AS g;

-- DEFECT foreign-key-with-no-index-underneath-it
--
-- Refund lines reference their refund batch, and the foreign key is declared,
-- which is more than several older tables here manage.
--
-- Postgres indexes the parent side of a foreign key because the primary key is
-- indexed already. It does not index the child side, and nothing here does
-- either. Every delete or key update on a refund batch has to scan the whole
-- of refund lines to prove no child is left behind, and so does any join from
-- a batch down to its lines.
--
-- Measured: one foreign key on payments.refund_lines with no index whose
-- leading column is the referencing column, over 6,000 lines.
--
-- One index on the referencing column removes both problems. Batches are
-- deleted rarely enough that the scan is never the thing that gets blamed; it
-- shows up as the batch screen being slow, which is read as the screen.
CREATE TABLE payments.refund_batches (
    batch_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_ref  varchar(16) NOT NULL UNIQUE,
    raised_on  date NOT NULL,
    raised_by  varchar(24) NOT NULL
);

CREATE TABLE payments.refund_lines (
    line_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id   integer NOT NULL REFERENCES payments.refund_batches (batch_id),
    order_ref  varchar(16) NOT NULL,
    amount     numeric(12,2) NOT NULL,
    reason     varchar(24) NOT NULL
);

INSERT INTO payments.refund_batches (batch_ref, raised_on, raised_by)
SELECT 'RFB-' || lpad(g::text, 6, '0'),
       DATE '2026-05-01' + (g % 90),
       'refunds ' || (1 + (g % 5))::text
FROM generate_series(1, 300) AS g;

INSERT INTO payments.refund_lines (batch_id, order_ref, amount, reason)
SELECT b.batch_id,
       'ORD-' || lpad(((b.batch_id * 97 + s) % 900000)::text, 8, '0'),
       (5 + ((b.batch_id + s) % 300))::numeric(12,2),
       (ARRAY['damaged', 'not as described', 'late', 'cancelled'])[1 + (s % 4)]
FROM payments.refund_batches b,
     generate_series(1, 20) AS s;

-- DEFECT audit-trigger-was-disabled-for-a-load-and-never-enabled-again
--
-- Price changes are audited by a trigger. The trigger was disabled for a bulk
-- repricing, because the audit was doubling the time the load took, and it was
-- not enabled again afterwards.
--
-- A disabled trigger is still there. It is in the schema, it is in the dump,
-- and anybody reading the table sees an audited table. Nothing since the
-- repricing has been audited, and there is no gap in the audit table to notice
-- because the rows were never written in the first place.
--
-- Measured: 1,800 price changes, 1,200 with an audit row and 600 without, and
-- the trigger still disabled.
--
-- Enabling it costs nothing and the 600 cannot be recovered. This is the one
-- defect here that a routine schema diff would catch, if a schema diff were
-- run against a database rather than against the migration files.
CREATE TABLE catalog.price_changes (
    change_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku        varchar(20) NOT NULL,
    old_price  numeric(10,2) NOT NULL,
    new_price  numeric(10,2) NOT NULL,
    changed_at timestamptz NOT NULL
);

CREATE TABLE catalog.price_change_audit (
    audit_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    change_id  integer NOT NULL,
    sku        varchar(20) NOT NULL,
    new_price  numeric(10,2) NOT NULL,
    audited_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION catalog.fn_audit_price_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO catalog.price_change_audit (change_id, sku, new_price)
    VALUES (NEW.change_id, NEW.sku, NEW.new_price);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_price_change
    AFTER INSERT ON catalog.price_changes
    FOR EACH ROW EXECUTE FUNCTION catalog.fn_audit_price_change();

INSERT INTO catalog.price_changes (sku, old_price, new_price, changed_at)
SELECT 'SKU-' || lpad(g::text, 8, '0'),
       (4 + (g % 300))::numeric(10,2),
       (4 + (g % 300))::numeric(10,2) + 0.50,
       TIMESTAMPTZ '2026-06-01 06:00:00+01' + (g * INTERVAL '21 minutes')
FROM generate_series(1, 1200) AS g;

-- The bulk repricing.
ALTER TABLE catalog.price_changes DISABLE TRIGGER trg_audit_price_change;

INSERT INTO catalog.price_changes (sku, old_price, new_price, changed_at)
SELECT 'SKU-' || lpad((5000 + g)::text, 8, '0'),
       (4 + (g % 300))::numeric(10,2),
       (4 + (g % 300))::numeric(10,2) + 1.25,
       TIMESTAMPTZ '2026-07-15 22:00:00+01' + (g * INTERVAL '2 seconds')
FROM generate_series(1, 600) AS g;

-- DEFECT case-expression-with-no-else-bands-three-hundred-accounts-as-null
--
-- Accounts are banded by annual spend on the marketing dashboard: bronze,
-- silver, gold.
--
-- The CASE expression has a branch for each band and no ELSE. An expression
-- that matches no branch returns null, so the accounts above the top band come
-- back with no band at all. They are the largest accounts on the ledger and
-- they are the ones the banding exists to find.
--
-- Measured: 1,500 accounts, 300 of them above the top band and banded as null.
--
-- A final ELSE, or a top branch with no upper bound, covers the range. The
-- dashboard groups by band and shows the null group as an empty label at the
-- bottom of the chart, which reads as a rendering fault rather than as the
-- three hundred best customers.
CREATE TABLE storefront.account_spend (
    account_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref  varchar(12) NOT NULL,
    annual_spend numeric(12,2) NOT NULL,
    measured_on  date NOT NULL
);

INSERT INTO storefront.account_spend (account_ref, annual_spend, measured_on)
SELECT 'ACC-' || lpad(g::text, 5, '0'),
       CASE WHEN g % 5 = 0 THEN (20000 + (g % 900) * 50)::numeric(12,2)
            ELSE (200 + (g % 180) * 100)::numeric(12,2)
       END,
       DATE '2026-06-30'
FROM generate_series(1, 1500) AS g;

CREATE VIEW analytics.v_account_bands AS
SELECT account_ref,
       annual_spend,
       CASE WHEN annual_spend < 1000 THEN 'bronze'
            WHEN annual_spend < 5000 THEN 'silver'
            WHEN annual_spend < 20000 THEN 'gold'
       END AS band
FROM storefront.account_spend;

-- DEFECT codes-kept-in-an-array-column-cannot-be-joined-or-checked
--
-- A campaign targets a list of product groups, and the list is an array column
-- on the campaign row.
--
-- An array cannot carry a foreign key. Nothing stops a campaign naming a group
-- that has been retired, or a group that never existed, and nothing tells the
-- person retiring a group which campaigns point at it. The check has to be
-- written by hand in every query that cares, and most of them do not.
--
-- Measured: 400 campaigns, and 160 of them naming at least one group code that
-- is not in the product group table.
--
-- A campaign to group junction table makes the reference declarable and the
-- retirement check a join. The array is easier to write from the campaign
-- screen, which is where this design came from.
CREATE TABLE catalog.product_groups (
    group_code varchar(8) PRIMARY KEY,
    group_name varchar(60) NOT NULL,
    retired    boolean NOT NULL DEFAULT false
);

CREATE TABLE marketing.campaign_targets (
    campaign_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign_ref varchar(16) NOT NULL,
    group_codes  varchar(8)[] NOT NULL,
    starts_on    date NOT NULL
);

INSERT INTO catalog.product_groups (group_code, group_name, retired)
SELECT 'GRP' || lpad(g::text, 4, '0'),
       'Group ' || g,
       (g % 9 = 0)
FROM generate_series(1, 200) AS g;

INSERT INTO marketing.campaign_targets (campaign_ref, group_codes, starts_on)
SELECT 'CMP-' || lpad(g::text, 6, '0'),
       CASE WHEN g % 5 IN (0, 1)
            THEN ARRAY['GRP' || lpad((1 + (g % 200))::text, 4, '0'),
                       'GRP' || lpad((900 + (g % 50))::text, 4, '0')]
            ELSE ARRAY['GRP' || lpad((1 + (g % 200))::text, 4, '0'),
                       'GRP' || lpad((1 + ((g + 37) % 200))::text, 4, '0')]
       END,
       DATE '2026-04-01' + (g % 150)
FROM generate_series(1, 400) AS g;

-- DEFECT every-row-of-a-bulk-load-carries-the-same-transaction-timestamp
--
-- The inbound manifest feed stamps each row with now() as it is loaded, and
-- the received time is what the warehouse sorts by when it works out which
-- manifest arrived first.
--
-- now() is the time the transaction started, not the time the row was written.
-- A load is one transaction, so every row in it carries one identical
-- timestamp and the sort has nothing to work with. The order the warehouse
-- sees is whatever the query happens to return, and it changes between runs of
-- the same query.
--
-- Measured: 2,400 manifests loaded in one transaction, carrying 1 distinct
-- received time between them.
--
-- clock_timestamp() advances within a transaction and gives each row its own
-- instant. The rows do arrive in the right order on the day, because the feed
-- is written in order, and that is why this has never been the explanation for
-- a mis-sorted manifest.
CREATE TABLE supply.inbound_manifests (
    manifest_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    manifest_ref varchar(16) NOT NULL,
    supplier_ref varchar(12) NOT NULL,
    line_count   integer NOT NULL,
    received_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO supply.inbound_manifests (manifest_ref, supplier_ref, line_count)
SELECT 'MAN-' || lpad(g::text, 8, '0'),
       'SUP-' || lpad((1 + (g % 70))::text, 3, '0'),
       1 + (g % 40)
FROM generate_series(1, 2400) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.price_changes ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.price_changes:' || concat_ws('|', x.sku, x.old_price, x.new_price))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.price_changes x
)
UPDATE catalog.price_changes t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.price_changes ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.price_changes ADD CONSTRAINT price_changes_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_price_changes_product_id ON catalog.price_changes (product_id);

ALTER TABLE ops.shift_clockings ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.shift_clockings:' || concat_ws('|', x.staff_ref, x.depot_code, x.direction))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.shift_clockings x
)
UPDATE ops.shift_clockings t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.shift_clockings ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.shift_clockings ADD CONSTRAINT shift_clockings_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_shift_clockings_store_id ON ops.shift_clockings (store_id);

ALTER TABLE storefront.account_spend ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('storefront.account_spend:' || concat_ws('|', x.account_ref, x.annual_spend))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.account_spend x
)
UPDATE storefront.account_spend t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.account_spend ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE storefront.account_spend ADD CONSTRAINT account_spend_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_account_spend_customer_id ON storefront.account_spend (customer_id);

ALTER TABLE supply.inbound_manifests ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.inbound_manifests:' || concat_ws('|', x.manifest_ref, x.supplier_ref, x.line_count))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.inbound_manifests x
)
UPDATE supply.inbound_manifests t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.inbound_manifests ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.inbound_manifests ADD CONSTRAINT inbound_manifests_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_inbound_manifests_purchase_order_id ON supply.inbound_manifests (purchase_order_id);
-- <<< relationships
