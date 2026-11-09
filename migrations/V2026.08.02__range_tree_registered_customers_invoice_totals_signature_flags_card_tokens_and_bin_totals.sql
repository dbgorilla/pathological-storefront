-- Cross River Trading Co. -- range tree, registered customers, invoice totals,
-- signature flags, card tokens, bin totals
-- author: J. Whitcombe
-- postgres: 18
--
-- The buying range hierarchy, the registered customer list, the invoice the
-- customer is sent, the proof of delivery flag, the stored card token, and the
-- bin total the stock screen reads.

-- DEFECT category-tree-contains-a-cycle-so-the-walk-never-terminates
--
-- Ranges sit in a hierarchy, each one naming its parent. Three of them name
-- each other.
--
-- A parent column with no cycle check is a graph, not a tree. The three ranges
-- point round in a ring, and every walk of the hierarchy that follows parents
-- upwards runs until something stops it: a recursion limit, a timeout, or the
-- memory on the box. The reporting job that rebuilds the range paths has a
-- depth cap on it, added the week the cycle was created, which is why the job
-- finishes and the three ranges simply have no path.
--
-- Measured: 303 ranges, and 3 of them able to reach themselves by following
-- parents.
--
-- A check on insert, or an exclusion of self-reference plus a periodic walk,
-- keeps it a tree. The depth cap turned an outage into a silent gap, which is
-- the trade every depth cap makes.
CREATE TABLE catalog.range_tree (
    range_code  varchar(10) PRIMARY KEY,
    range_name  varchar(60) NOT NULL,
    parent_code varchar(10),
    opened_on   date NOT NULL
);

INSERT INTO catalog.range_tree (range_code, range_name, parent_code, opened_on)
SELECT 'RNG' || lpad(g::text, 5, '0'),
       'Range ' || g,
       CASE WHEN g <= 10 THEN NULL
            ELSE 'RNG' || lpad(((g / 10))::text, 5, '0')
       END,
       DATE '2019-03-01' + (g % 2000)
FROM generate_series(1, 300) AS g;

-- The three that point round in a ring.
INSERT INTO catalog.range_tree (range_code, range_name, parent_code, opened_on)
VALUES ('RNG90001', 'Seasonal', 'RNG90002', DATE '2025-01-14'),
       ('RNG90002', 'Seasonal gifting', 'RNG90003', DATE '2025-01-14'),
       ('RNG90003', 'Seasonal gifting hampers', 'RNG90001', DATE '2025-01-14');

-- DEFECT unique-email-counts-deleted-customers-so-they-cannot-come-back
--
-- A customer who closes an account is soft deleted: the row stays, with a
-- deleted timestamp on it.
--
-- The unique index on the address is over the whole table, so a closed
-- account holds its address forever. A customer who closes an account and
-- comes back cannot register with the address they had, and the message they
-- are shown is that the address is already in use, which is true and reads as
-- an accusation.
--
-- Measured: 3,000 registered customers, 400 of them closed, and 400 addresses
-- held by a closed account and by nothing else.
--
-- A partial unique index over the live rows releases the address on closure,
-- and keeping the history is what the deleted timestamp is for. The support
-- desk handles these by asking the customer for a different address, which
-- works and quietly creates a second customer for the same person.
CREATE TABLE storefront.registered_customers (
    customer_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       varchar(120) NOT NULL UNIQUE,
    full_name   varchar(80) NOT NULL,
    registered_on date NOT NULL,
    deleted_at  timestamptz
);

INSERT INTO storefront.registered_customers (email, full_name, registered_on, deleted_at)
SELECT 'customer' || g || '@example.invalid',
       'Customer ' || g,
       DATE '2021-01-01' + (g % 1800),
       CASE WHEN g % 15 IN (0, 1) THEN TIMESTAMPTZ '2026-01-05 10:00:00+00' + (g * INTERVAL '3 hours')
            ELSE NULL
       END
FROM generate_series(1, 3000) AS g;

-- DEFECT invoice-header-total-disagrees-with-the-sum-of-its-lines
--
-- The invoice header carries a total, and the invoice lines carry the amounts
-- that total is made of.
--
-- The header total is written when the invoice is raised. Lines are amended
-- afterwards, by the credit desk correcting a price or removing a line that
-- was never delivered, and nothing rewrites the header. The same fact is held
-- in two places, one of them stops being true, and which one the customer sees
-- depends on which document they are sent: the invoice prints the header, the
-- statement adds up the lines.
--
-- Measured: 900 invoices, 211 of them with a header total that does not equal
-- the sum of their lines.
--
-- The total belongs in one place, worked out from the lines when it is needed,
-- or maintained by the same statement that amends them. The difference is
-- usually small, which is why it is settled by whoever argues longest.
CREATE TABLE storefront.invoice_headers (
    invoice_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_ref varchar(16) NOT NULL UNIQUE,
    account_ref varchar(12) NOT NULL,
    raised_on   date NOT NULL,
    total       numeric(12,2) NOT NULL
);

CREATE TABLE storefront.invoice_lines (
    line_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_ref varchar(16) NOT NULL,
    sku         varchar(20) NOT NULL,
    line_total  numeric(12,2) NOT NULL
);

INSERT INTO storefront.invoice_headers (invoice_ref, account_ref, raised_on, total)
SELECT 'INV-' || lpad(g::text, 8, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       DATE '2026-06-01' + (g % 60),
       (4 * (10 + (g % 90)))::numeric(12,2)
FROM generate_series(1, 900) AS g;

INSERT INTO storefront.invoice_lines (invoice_ref, sku, line_total)
SELECT h.invoice_ref,
       'SKU-' || lpad(((h.invoice_id * 13 + s) % 900000)::text, 8, '0'),
       (10 + (h.invoice_id % 90))::numeric(12,2)
FROM storefront.invoice_headers h,
     generate_series(1, 4) AS s;

-- The credit desk removing a line that was never delivered.
DELETE FROM storefront.invoice_lines l
WHERE l.line_id % 17 = 0
  AND l.invoice_ref IN (SELECT invoice_ref FROM storefront.invoice_headers);

-- DEFECT boolean-kept-as-a-smallint-has-a-third-value
--
-- The delivery signature flag is a smallint, because the terminal that writes
-- it speaks in numbers.
--
-- It sends 1 for signed and 0 for refused, and it sends 2 when the driver
-- could not get an answer either way. Two of those are an answer and one is
-- the absence of one, but every reader here was written against a column that
-- was described as a boolean, and each of them treats anything that is not
-- zero as signed. The consignments that were never checked are counted as
-- delivered and signed for.
--
-- Measured: 3,000 consignment checks holding 3 distinct values, 300 of them
-- the third one.
--
-- A boolean column plus a nullable timestamp says both things without
-- inventing a third state. The proof of delivery report is 300 rows too
-- optimistic and has been since the terminals were replaced.
CREATE TABLE fulfilment.consignment_checks (
    check_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    consignment_ref varchar(16) NOT NULL,
    is_signed       smallint NOT NULL,
    checked_at      timestamptz NOT NULL,
    courier_ref     varchar(12) NOT NULL
);

INSERT INTO fulfilment.consignment_checks (consignment_ref, is_signed, checked_at, courier_ref)
SELECT 'CNS-' || lpad((100000 + g)::text, 8, '0'),
       CASE WHEN g % 10 = 0 THEN 2
            WHEN g % 3 = 0 THEN 0
            ELSE 1
       END,
       TIMESTAMPTZ '2026-07-01 09:00:00+01' + (g * INTERVAL '11 minutes'),
       'CUR-' || lpad((1 + (g % 60))::text, 3, '0')
FROM generate_series(1, 3000) AS g;

-- DEFECT row-security-enabled-but-not-forced-on-the-owner
--
-- Card tokens are protected by row level security, with a policy restricting
-- each merchant to its own rows.
--
-- Row level security does not apply to the table's owner unless it is forced,
-- and the application connects as the owner. The policy is real, it is
-- correct, and it is not consulted for the one connection that matters. The
-- protection shows up in every review as present and applies to nobody.
--
-- Measured: row security enabled on payments.card_tokens and not forced,
-- across 1,500 tokens for 25 merchants.
--
-- ALTER TABLE ... FORCE ROW LEVEL SECURITY makes the owner obey the policy,
-- and an application role that does not own its tables is the better answer.
-- Testing the policy as a non-owner shows it working perfectly, which is how
-- it was signed off.
CREATE TABLE payments.card_tokens (
    token_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    merchant_ref varchar(12) NOT NULL,
    token        varchar(40) NOT NULL,
    last_four    char(4) NOT NULL,
    stored_at    timestamptz NOT NULL
);

INSERT INTO payments.card_tokens (merchant_ref, token, last_four, stored_at)
SELECT 'MER-' || lpad((1 + (g % 25))::text, 4, '0'),
       'tok_' || md5(g::text),
       lpad(((g * 7) % 10000)::text, 4, '0'),
       TIMESTAMPTZ '2026-03-01 09:00:00+00' + (g * INTERVAL '23 minutes')
FROM generate_series(1, 1500) AS g;

ALTER TABLE payments.card_tokens ENABLE ROW LEVEL SECURITY;

CREATE POLICY card_tokens_own_merchant ON payments.card_tokens
    FOR ALL
    USING (merchant_ref = current_setting('app.merchant_ref', true));

-- DEFECT summary-trigger-fires-on-insert-only
--
-- The stock screen reads a bin total, kept up to date by a trigger on bin
-- movements.
--
-- The trigger is AFTER INSERT. A movement corrected after the fact is an
-- update, and a movement entered against the wrong bin is deleted, and neither
-- of those reaches the total. The total is right for a bin nobody has had to
-- correct, which is most bins, and drifts further from the truth on exactly
-- the bins that have had the most attention.
--
-- Measured: 6,000 movements across 500 bins, 458 movements corrected or
-- removed since, and 352 bins whose total no longer equals the sum of their
-- movements.
--
-- The trigger wants INSERT OR UPDATE OR DELETE and the OLD row taken off the
-- total. The stock screen is checked against a count once a quarter, and the
-- differences are written off as shrinkage.
CREATE TABLE ops.bin_totals (
    bin_code    varchar(12) PRIMARY KEY,
    total_units integer NOT NULL DEFAULT 0
);

CREATE TABLE ops.bin_movements (
    movement_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bin_code    varchar(12) NOT NULL,
    units       integer NOT NULL,
    moved_at    timestamptz NOT NULL
);

CREATE FUNCTION ops.fn_add_bin_movement() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.bin_totals (bin_code, total_units)
    VALUES (NEW.bin_code, NEW.units)
    ON CONFLICT (bin_code) DO UPDATE
        SET total_units = ops.bin_totals.total_units + EXCLUDED.total_units;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_add_bin_movement
    AFTER INSERT ON ops.bin_movements
    FOR EACH ROW EXECUTE FUNCTION ops.fn_add_bin_movement();

INSERT INTO ops.bin_movements (bin_code, units, moved_at)
SELECT 'BIN-' || lpad((1 + (g % 500))::text, 6, '0'),
       1 + (g % 30),
       TIMESTAMPTZ '2026-06-01 06:00:00+01' + (g * INTERVAL '4 minutes')
FROM generate_series(1, 6000) AS g;

-- Corrections the total never saw.
UPDATE ops.bin_movements SET units = units + 5 WHERE movement_id % 23 = 0;
DELETE FROM ops.bin_movements WHERE movement_id % 29 = 11;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.range_tree ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.range_tree:' || concat_ws('|', x.range_code, x.range_name, x.parent_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.range_tree x
)
UPDATE catalog.range_tree t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.range_tree ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.range_tree ADD CONSTRAINT range_tree_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_range_tree_product_id ON catalog.range_tree (product_id);

ALTER TABLE ops.bin_movements ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.bin_movements:' || concat_ws('|', x.bin_code, x.units))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.bin_movements x
)
UPDATE ops.bin_movements t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.bin_movements ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.bin_movements ADD CONSTRAINT bin_movements_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_bin_movements_warehouse_id ON ops.bin_movements (warehouse_id);

ALTER TABLE ops.bin_totals ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.bin_totals:' || concat_ws('|', x.bin_code, x.total_units))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.bin_totals x
)
UPDATE ops.bin_totals t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.bin_totals ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.bin_totals ADD CONSTRAINT bin_totals_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_bin_totals_warehouse_id ON ops.bin_totals (warehouse_id);

ALTER TABLE payments.card_tokens ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.card_tokens:' || concat_ws('|', x.merchant_ref, x.token, x.last_four))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.card_tokens x
)
UPDATE payments.card_tokens t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.card_tokens ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.card_tokens ADD CONSTRAINT card_tokens_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_card_tokens_transaction_id ON payments.card_tokens (transaction_id);

ALTER TABLE storefront.invoice_headers ADD COLUMN order_id integer;

WITH p AS (
    SELECT order_id AS v, row_number() OVER (ORDER BY order_id) - 1 AS k
      FROM storefront.orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.orders)
                 * power((abs(hashtext('storefront.invoice_headers:' || concat_ws('|', x.invoice_ref, x.account_ref, x.total))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.invoice_headers x
)
UPDATE storefront.invoice_headers t
   SET order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.invoice_headers ALTER COLUMN order_id SET NOT NULL;
ALTER TABLE storefront.invoice_headers ADD CONSTRAINT invoice_headers_order_id_fkey FOREIGN KEY (order_id) REFERENCES storefront.orders (order_id);
CREATE INDEX ix_invoice_headers_order_id ON storefront.invoice_headers (order_id);

ALTER TABLE storefront.invoice_lines ADD COLUMN invoice_id integer;

WITH p AS (
    SELECT invoice_id AS v, row_number() OVER (ORDER BY invoice_id) - 1 AS k
      FROM storefront.invoice_headers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.invoice_headers)
                 * power((abs(hashtext('storefront.invoice_lines:' || concat_ws('|', x.invoice_ref, x.sku, x.line_total))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.invoice_lines x
)
UPDATE storefront.invoice_lines t
   SET invoice_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.invoice_lines ALTER COLUMN invoice_id SET NOT NULL;
ALTER TABLE storefront.invoice_lines ADD CONSTRAINT invoice_lines_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES storefront.invoice_headers (invoice_id);
CREATE INDEX ix_invoice_lines_invoice_id ON storefront.invoice_lines (invoice_id);
-- <<< relationships
