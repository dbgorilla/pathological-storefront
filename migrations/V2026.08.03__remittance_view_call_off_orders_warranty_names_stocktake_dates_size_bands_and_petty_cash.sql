-- Cross River Trading Co. -- remittance view, call off orders, warranty names,
-- stocktake dates, size bands, petty cash
-- author: J. Whitcombe
-- postgres: 18
--
-- The remittance summary the supplier portal reads, the call off order, the
-- warranty claim form, the stocktake import from the handheld, the size band
-- on a garment, and the petty cash book.

-- DEFECT view-grant-hands-out-the-table-it-was-meant-to-hide
--
-- The supplier portal reads a summary view instead of the remittance table,
-- because the remittance table carries bank details.
--
-- The view selects every column of the table, including the bank details. A
-- view runs with the privileges of the owner, so granting select on the view
-- gives the reader everything the view can see, and the reader does not need
-- and does not have any privilege on the table itself. The grant on the table
-- was deliberately withheld, which is what makes this look safe in a review:
-- the audit shows no direct access to remittance advice.
--
-- Measured: the portal role holds select on analytics.v_remittance_summary and
-- no privilege at all on payments.remittance_advice, and the view exposes the
-- account number column.
--
-- A view that lists the columns it means to expose is the fix, and a column
-- level grant is the belt to go with it. The view is called a summary and
-- summarises nothing.
CREATE TABLE payments.remittance_advice (
    advice_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref   varchar(12) NOT NULL,
    paid_on        date NOT NULL,
    amount         numeric(12,2) NOT NULL,
    account_number varchar(8) NOT NULL,
    sort_code      varchar(8) NOT NULL
);

INSERT INTO payments.remittance_advice (supplier_ref, paid_on, amount, account_number, sort_code)
SELECT 'SUP-' || lpad((1 + (g % 70))::text, 3, '0'),
       DATE '2026-05-01' + (g % 100),
       (400 + (g % 9000))::numeric(12,2),
       lpad(((g * 37) % 100000000)::text, 8, '0'),
       lpad(((g * 11) % 1000000)::text, 6, '0')
FROM generate_series(1, 1400) AS g;

CREATE VIEW analytics.v_remittance_summary AS
SELECT * FROM payments.remittance_advice;

CREATE ROLE remittance_reader NOLOGIN;
GRANT USAGE ON SCHEMA analytics TO remittance_reader;
GRANT SELECT ON analytics.v_remittance_summary TO remittance_reader;

-- DEFECT check-constraint-added-not-valid-and-never-validated
--
-- Call off orders were given a check constraint requiring a positive quantity.
-- It was added NOT VALID, because validating it would have locked the table
-- during a working day and the rows already in it were known to be untidy.
--
-- NOT VALID means the constraint applies to new rows only. The plan was to fix
-- the old rows and run VALIDATE CONSTRAINT in the next maintenance window.
-- There was no next maintenance window. The bad rows are still there, the
-- constraint reads as enforced in every tool that lists constraints, and any
-- query written on the strength of it is wrong for exactly those rows.
--
-- Measured: 1,500 call off orders, 120 of them with a quantity of zero or
-- less, under a constraint that forbids it.
--
-- Fixing the rows and validating the constraint is an afternoon. The rows with
-- a zero quantity are read as cancelled by some reports and as errors by
-- others, and both readings are guesses.
CREATE TABLE supply.call_off_orders (
    call_off_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contract_ref varchar(16) NOT NULL,
    sku          varchar(20) NOT NULL,
    quantity     integer NOT NULL,
    called_on    date NOT NULL
);

INSERT INTO supply.call_off_orders (contract_ref, sku, quantity, called_on)
SELECT 'CTR-' || lpad((1 + (g % 120))::text, 6, '0'),
       'SKU-' || lpad(((g * 17) % 900000)::text, 8, '0'),
       CASE WHEN g % 25 = 0 THEN 0
            WHEN g % 25 = 1 THEN -(1 + (g % 5))
            ELSE 1 + (g % 400)
       END,
       DATE '2025-11-01' + (g % 300)
FROM generate_series(1, 1500) AS g;

ALTER TABLE supply.call_off_orders
    ADD CONSTRAINT call_off_orders_quantity_positive CHECK (quantity > 0) NOT VALID;

-- DEFECT copied-customer-name-on-the-claim-is-the-one-from-that-day
--
-- A warranty claim copies the account holder's name onto the claim, so the
-- claim form prints without a join.
--
-- The copy is never updated. An account holder who marries, divorces or
-- corrects a misspelling has a new name on the account and the old one on
-- every claim raised before the change. The claim is a record of what was
-- true on the day, which is a defensible thing for a document to be and is
-- not what this column is used for: the claims screen searches it, so the
-- customer telephoning about their claim cannot be found under their name.
--
-- Measured: 1,200 warranty claims and 2,000 account holders, 800 of whom have
-- been renamed since, leaving 800 claims naming somebody who no longer exists
-- under that name.
--
-- A join gives the current name and the claim document can keep its own copy
-- of what it printed. The search is the thing that breaks, and it breaks for
-- the customers most likely to be telephoning.
CREATE TABLE storefront.account_holders (
    holder_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL UNIQUE,
    holder_name varchar(80) NOT NULL,
    opened_on   date NOT NULL
);

CREATE TABLE support.warranty_claims (
    claim_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    holder_name varchar(80) NOT NULL,
    sku         varchar(20) NOT NULL,
    raised_on   date NOT NULL
);

INSERT INTO storefront.account_holders (account_ref, holder_name, opened_on)
SELECT 'ACC-' || lpad(g::text, 5, '0'),
       'Holder ' || g,
       DATE '2020-01-01' + (g % 2200)
FROM generate_series(1, 2000) AS g;

INSERT INTO support.warranty_claims (account_ref, holder_name, sku, raised_on)
SELECT h.account_ref,
       h.holder_name,
       'SKU-' || lpad(((h.holder_id * 29) % 900000)::text, 8, '0'),
       DATE '2026-01-01' + (h.holder_id % 200)
FROM storefront.account_holders h
WHERE h.holder_id % 5 IN (0, 1, 2);

-- Renamed since: married, divorced, or spelled correctly at last.
UPDATE storefront.account_holders
SET holder_name = 'Holder ' || holder_id || ' (corrected)'
WHERE holder_id % 5 IN (0, 1);

-- DEFECT dates-kept-as-day-first-text-are-ambiguous-for-the-first-twelve
--
-- The handheld stocktake export writes dates as text, day first, because that
-- is how they print on the sheet.
--
-- Text is not a date. Nothing checks the format, nothing orders correctly, and
-- for any day of the month up to twelve the same string is a valid date under
-- two different readings. A reader that assumes month first turns the third of
-- April into the fourth of March without complaint, and the rows it gets wrong
-- are the ones at the start of every month.
--
-- Measured: 1,200 stocktake imports, 441 of them holding a date that is also a
-- valid date read the other way round.
--
-- A date column takes the parsing once, at the import, where the format is
-- known. The stock team reconciles these by eye against the paper sheets,
-- which is why the ambiguity has never had to be resolved in the data.
CREATE TABLE legacy.stocktake_imports (
    import_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code  varchar(12) NOT NULL,
    taken_on    varchar(10) NOT NULL,
    counted_by  varchar(24) NOT NULL,
    line_count  integer NOT NULL
);

INSERT INTO legacy.stocktake_imports (depot_code, taken_on, counted_by, line_count)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       to_char(DATE '2026-01-01' + (g % 360), 'DD/MM/YYYY'),
       'counter ' || (1 + (g % 12))::text,
       20 + (g % 300)
FROM generate_series(1, 1200) AS g;

-- DEFECT enum-label-added-later-sorts-after-the-one-it-belongs-before
--
-- Garment sizes are an enum. Small and large were the original two, and medium
-- was added when the range grew.
--
-- An enum sorts in the order its labels were created, and a label added later
-- sorts last whatever it means. Medium therefore sorts after large in every
-- ORDER BY, every MIN and MAX, and every range comparison. The size picker on
-- the site lists small, large, medium, which customers read as a mistake in
-- the picker, and the size mix report puts the middle of the range at the
-- bottom of the table.
--
-- Measured: 900 garment sizes, 300 of them medium, every one of which compares
-- as greater than large.
--
-- Rebuilding the type in the right order means rewriting every column that
-- uses it, which is why it has not been done. A lookup table with an explicit
-- sort column never has this problem.
CREATE TYPE catalog.size_band AS ENUM ('small', 'large', 'medium');

CREATE TABLE catalog.garment_sizes (
    garment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku        varchar(20) NOT NULL,
    size       catalog.size_band NOT NULL,
    listed_on  date NOT NULL
);

INSERT INTO catalog.garment_sizes (sku, size, listed_on)
SELECT 'SKU-' || lpad(((g * 23) % 900000)::text, 8, '0'),
       (ARRAY['small', 'large', 'medium'])[1 + (g % 3)]::catalog.size_band,
       DATE '2024-08-01' + (g % 700)
FROM generate_series(1, 900) AS g;

-- DEFECT one-amount-column-holds-both-pounds-and-pence
--
-- The petty cash book takes lines from two places. The till writes pence, as
-- tills do. The ledger clerk types pounds.
--
-- The column is a plain integer with no unit anywhere near it: not in the
-- name, not in a comment, not in a constraint. Both writers are internally
-- consistent and the book adds them together. A total over a month is the sum
-- of two different units and means nothing, and it is out by a factor of a
-- hundred in whichever direction the month's mix happens to lean.
--
-- Measured: 1,500 petty cash lines, 600 of them written by the till in pence
-- and 900 typed by the ledger in pounds.
--
-- A numeric column in one unit, named for that unit, is the whole fix. The
-- monthly figure is small enough that a wrong total looks like a quiet month
-- rather than an error, and petty cash is the last thing anybody audits.
CREATE TABLE payments.petty_cash_lines (
    line_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code  varchar(12) NOT NULL,
    written_by  varchar(12) NOT NULL,
    amount      integer NOT NULL,
    spent_on    date NOT NULL,
    description varchar(60) NOT NULL
);

INSERT INTO payments.petty_cash_lines (depot_code, written_by, amount, spent_on, description)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       CASE WHEN g % 5 IN (0, 1) THEN 'till' ELSE 'ledger' END,
       CASE WHEN g % 5 IN (0, 1) THEN 550 + (g % 9000)
            ELSE 3 + (g % 90)
       END,
       DATE '2026-04-01' + (g % 150),
       (ARRAY['taxi', 'stamps', 'milk', 'window cleaner', 'keys cut'])[1 + (g % 5)]
FROM generate_series(1, 1500) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.garment_sizes ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.garment_sizes:' || concat_ws('|', x.sku, x.size))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.garment_sizes x
)
UPDATE catalog.garment_sizes t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.garment_sizes ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.garment_sizes ADD CONSTRAINT garment_sizes_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_garment_sizes_product_id ON catalog.garment_sizes (product_id);

ALTER TABLE payments.petty_cash_lines ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.petty_cash_lines:' || concat_ws('|', x.depot_code, x.written_by, x.amount, x.description))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.petty_cash_lines x
)
UPDATE payments.petty_cash_lines t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.petty_cash_lines ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.petty_cash_lines ADD CONSTRAINT petty_cash_lines_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_petty_cash_lines_transaction_id ON payments.petty_cash_lines (transaction_id);

ALTER TABLE payments.remittance_advice ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.remittance_advice:' || concat_ws('|', x.supplier_ref, x.amount, x.account_number, x.sort_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.remittance_advice x
)
UPDATE payments.remittance_advice t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.remittance_advice ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.remittance_advice ADD CONSTRAINT remittance_advice_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_remittance_advice_transaction_id ON payments.remittance_advice (transaction_id);

ALTER TABLE payments.remittance_lines ADD COLUMN advice_id integer;

WITH p AS (
    SELECT advice_id AS v, row_number() OVER (ORDER BY advice_id) - 1 AS k
      FROM payments.remittance_advice
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.remittance_advice)
                 * power((abs(hashtext('payments.remittance_lines:' || concat_ws('|', x.line_text, x.reference_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.remittance_lines x
)
UPDATE payments.remittance_lines t
   SET advice_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.remittance_lines ALTER COLUMN advice_id SET NOT NULL;
ALTER TABLE payments.remittance_lines ADD CONSTRAINT remittance_lines_advice_id_fkey FOREIGN KEY (advice_id) REFERENCES payments.remittance_advice (advice_id);
CREATE INDEX ix_remittance_lines_advice_id ON payments.remittance_lines (advice_id);

ALTER TABLE storefront.account_holders ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('storefront.account_holders:' || concat_ws('|', x.account_ref, x.holder_name))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.account_holders x
)
UPDATE storefront.account_holders t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.account_holders ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE storefront.account_holders ADD CONSTRAINT account_holders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_account_holders_customer_id ON storefront.account_holders (customer_id);

ALTER TABLE support.warranty_claims ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.warranty_claims:' || concat_ws('|', x.account_ref, x.holder_name, x.sku))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.warranty_claims x
)
UPDATE support.warranty_claims t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.warranty_claims ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.warranty_claims ADD CONSTRAINT warranty_claims_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_warranty_claims_ticket_id ON support.warranty_claims (ticket_id);
-- <<< relationships
