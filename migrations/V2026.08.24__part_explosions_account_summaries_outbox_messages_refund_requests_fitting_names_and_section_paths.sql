-- Cross River Trading Co. -- part explosions, account summaries, outbox
-- messages, refund requests, fitting names, section paths
-- author: T. Marchetti
-- postgres: 18
--
-- What a part is made of, what a merchant is owed, what the system still has
-- to tell the outside world, a customer asking for money back, the name of a
-- fitting, and where a section sits in the catalogue.

-- DEFECT the-bill-of-materials-contains-itself-three-levels-down
--
-- Sixty assemblies contain a part that contains a part that contains the
-- original assembly. Anything that walks the bill of materials down never
-- reaches the bottom.
--
-- The explosion table is a plain parent and child pair with a quantity, and
-- nothing forbids a cycle because nothing can: a constraint that rejects one
-- has to walk the whole graph on every insert. The cycles were created by
-- engineering changes that swapped a sub-assembly for a kit containing the
-- thing it replaced. Each change was correct on its own. The costing run
-- recurses to a depth of eight and stops, so it returns a number rather than
-- hanging, and the number counts the cycle parts eight times over.
--
-- Measured: 2,000 parts and 6,000 explosion rows, of which 180 form 60 closed
-- three-part loops.
--
-- The fix is a cycle check when a change is posted, plus a decision about
-- which of the sixty edges to cut, which needs an engineer for each one. The
-- costing run completes and the totals look high rather than wrong.
CREATE TABLE supply.parts (
    part_id   integer PRIMARY KEY,
    part_code varchar(16) NOT NULL,
    part_name varchar(80) NOT NULL
);

CREATE TABLE supply.part_explosions (
    explosion_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_part_id integer NOT NULL REFERENCES supply.parts (part_id),
    child_part_id  integer NOT NULL REFERENCES supply.parts (part_id),
    qty            integer NOT NULL
);

INSERT INTO supply.parts (part_id, part_code, part_name)
SELECT g, 'PRT-' || lpad(g::text, 6, '0'), 'Part ' || g
FROM generate_series(1, 2000) AS g;

-- Assemblies 1 to 200 over components 201 to 2000. No edge points back up.
INSERT INTO supply.part_explosions (parent_part_id, child_part_id, qty)
SELECT 1 + (g % 200),
       201 + (g % 1800),
       1 + (g % 6)
FROM generate_series(1, 5820) AS g;

-- The sixty engineering changes, each correct on its own.
INSERT INTO supply.part_explosions (parent_part_id, child_part_id, qty)
SELECT v.parent, v.child, 1
FROM generate_series(1, 60) AS g
CROSS JOIN LATERAL (VALUES (1800 + g, 1860 + g),
                          (1860 + g, 1920 + g),
                          (1920 + g, 1800 + g)) AS v(parent, child);

-- DEFECT the-function-returns-the-column-the-role-is-not-allowed-to-read
--
-- The merchant account table grants column by column and holds the API secret
-- back. The function beside it returns the whole row.
--
-- Column level grants were added when the reporting role was given access to
-- merchant settlement, and they were added carefully: merchant reference,
-- display name and settled amount, and not the secret. The summary function
-- predates that work, is SECURITY DEFINER because it was written for a
-- background job, and returns the table's composite type, so it returns every
-- column the table has. Granting EXECUTE on it hands over the secret and the
-- column grants say nothing about it. The careful part of the permission model
-- is bypassed by the part nobody revisited.
--
-- Measured: 240 merchant accounts where remittance_reader holds SELECT on
-- three columns and not on api_secret, and holds EXECUTE on a definer function
-- returning all four.
--
-- The function wants an explicit column list in its return type, or its own
-- revoke. Every permission audit that reads table grants sees the secret
-- protected, because on the table it is.
CREATE TABLE payments.merchant_accounts (
    merchant_ref varchar(12) PRIMARY KEY,
    display_name varchar(60) NOT NULL,
    api_secret   varchar(48) NOT NULL,
    settled_p    bigint NOT NULL
);

INSERT INTO payments.merchant_accounts (merchant_ref, display_name, api_secret, settled_p)
SELECT 'MER-' || lpad(g::text, 6, '0'),
       'Merchant ' || g,
       'sk_' || md5('merchant' || g),
       100000 + (g * 7919)
FROM generate_series(1, 240) AS g;

GRANT SELECT (merchant_ref, display_name, settled_p)
    ON payments.merchant_accounts TO remittance_reader;

CREATE FUNCTION payments.fn_account_summary(p_merchant_ref varchar)
RETURNS payments.merchant_accounts
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, payments
AS $$
    SELECT * FROM payments.merchant_accounts WHERE merchant_ref = p_merchant_ref;
$$;

GRANT EXECUTE ON FUNCTION payments.fn_account_summary(varchar) TO remittance_reader;

-- DEFECT the-outbox-has-no-key-and-every-retried-publish-is-still-in-it
--
-- The outbox table has no primary key and no unique index on the message key,
-- and the publisher retries.
--
-- The publisher writes the message, publishes it, then marks it sent. When the
-- publish succeeds and the mark fails, the next run writes the message again,
-- because the write comes first and there is nothing to collide with. The
-- consumer is documented as idempotent, which is true of four of the six
-- consumers. The other two send an email and adjust a balance.
--
-- Measured: 14,400 outbox messages holding 12,000 distinct message keys, with
-- 2,400 keys present twice and no primary key on the table.
--
-- A unique index on the message key turns the second write into an error the
-- publisher can ignore. Adding it now needs the 2,400 duplicates resolved
-- first, and resolving one means deciding whether its consumer already acted.
CREATE TABLE ops.outbox_messages (
    message_key  varchar(40) NOT NULL,
    topic        varchar(40) NOT NULL,
    payload      varchar(200) NOT NULL,
    written_at   timestamptz NOT NULL,
    sent         boolean NOT NULL
);

INSERT INTO ops.outbox_messages (message_key, topic, payload, written_at, sent)
SELECT 'MSG-' || lpad(g::text, 10, '0'),
       (ARRAY['order.placed', 'order.shipped', 'refund.raised',
              'stock.moved', 'invoice.issued', 'account.changed'])[1 + (g % 6)],
       'Payload for message ' || g,
       TIMESTAMPTZ '2026-04-06 00:00:00+01' + (g * INTERVAL '90 seconds'),
       true
FROM generate_series(1, 12000) AS g;

-- The runs where the publish landed and the mark did not.
INSERT INTO ops.outbox_messages (message_key, topic, payload, written_at, sent)
SELECT 'MSG-' || lpad((g * 5)::text, 10, '0'),
       (ARRAY['order.placed', 'order.shipped', 'refund.raised',
              'stock.moved', 'invoice.issued', 'account.changed'])[1 + ((g * 5) % 6)],
       'Payload for message ' || (g * 5),
       TIMESTAMPTZ '2026-04-06 00:02:00+01' + (g * INTERVAL '450 seconds'),
       true
FROM generate_series(1, 2400) AS g;

-- DEFECT the-trigger-is-enabled-for-replica-only-so-it-never-fires
--
-- The refund audit trigger is set to fire only in replica mode. Nothing here
-- runs in replica mode.
--
-- A bulk correction was loaded with session_replication_role set to replica so
-- that the triggers would stay out of the way, and the trigger was afterwards
-- set with ENABLE REPLICA instead of ENABLE, which is one word away and reads
-- as if it turns the trigger back on. It turns it on for exactly the mode
-- nothing uses. The trigger is listed as enabled in every tool that shows a
-- boolean, and psql marks it in a way that is easy to read past.
--
-- Measured: 6,000 refund requests against 1,200 audit rows, leaving 4,800
-- refunds with no audit record, behind one trigger in replica mode.
--
-- ALTER TABLE ... ENABLE TRIGGER is the whole fix. The missing 4,800 audit
-- rows cannot be reconstructed, because the audit is the only place the
-- approving user was ever written.
CREATE TABLE payments.refund_requests (
    request_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref   varchar(16) NOT NULL,
    amount_p    integer NOT NULL,
    approved_by varchar(20) NOT NULL,
    raised_at   timestamptz NOT NULL
);

CREATE TABLE payments.refund_request_audit (
    audit_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id  integer NOT NULL,
    approved_by varchar(20) NOT NULL,
    seen_at     timestamptz NOT NULL
);

CREATE FUNCTION payments.fn_audit_refund_request() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO payments.refund_request_audit (request_id, approved_by, seen_at)
    VALUES (NEW.request_id, NEW.approved_by, NEW.raised_at);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_audit_refund_request AFTER INSERT ON payments.refund_requests
    FOR EACH ROW EXECUTE FUNCTION payments.fn_audit_refund_request();

INSERT INTO payments.refund_requests (order_ref, amount_p, approved_by, raised_at)
SELECT 'ORD-' || lpad(g::text, 10, '0'),
       200 + (g % 18000),
       'USR-' || lpad((1 + (g % 40))::text, 4, '0'),
       TIMESTAMPTZ '2026-02-02 08:00:00+00' + (g * INTERVAL '7 minutes')
FROM generate_series(1, 1200) AS g;

-- The bulk correction, and the word that was meant to put it back.
ALTER TABLE payments.refund_requests ENABLE REPLICA TRIGGER trg_audit_refund_request;

INSERT INTO payments.refund_requests (order_ref, amount_p, approved_by, raised_at)
SELECT 'ORD-' || lpad((100000 + g)::text, 10, '0'),
       200 + (g % 18000),
       'USR-' || lpad((1 + (g % 40))::text, 4, '0'),
       TIMESTAMPTZ '2026-03-01 08:00:00+00' + (g * INTERVAL '5 minutes')
FROM generate_series(1, 4800) AS g;

-- DEFECT the-index-was-built-under-a-collation-the-queries-do-not-use
--
-- The index on the fitting name was built with COLLATE "C". The column is in
-- the database collation and so is every query against it.
--
-- The COLLATE "C" was copied from a tuning note about making a LIKE prefix
-- search use an index, where it is the right advice, and applied to an index
-- that serves equality and ordering instead. An index whose collation differs
-- from the one a comparison uses cannot answer that comparison, so the planner
-- ignores it. Nothing failed: the queries returned the same rows, more slowly,
-- and the index has been maintained on every write since.
--
-- Measured: 9,000 fitting names where the one index over the name column
-- carries a collation the column does not.
--
-- Rebuilding the index without the COLLATE clause is a concurrent build and a
-- drop. The index exists, is valid, has a sensible name and appears in every
-- list of indexes on the table, so the table reads as indexed.
CREATE TABLE catalog.fitting_names (
    fitting_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fitting_name text NOT NULL,
    range_code   varchar(12) NOT NULL
);

INSERT INTO catalog.fitting_names (fitting_name, range_code)
SELECT 'Fitting ' || g || ' ' || (ARRAY['brass', 'chrome', 'nickel', 'steel'])[1 + (g % 4)],
       'RNG-' || lpad((1 + (g % 300))::text, 5, '0')
FROM generate_series(1, 9000) AS g;

CREATE INDEX fitting_names_name_idx ON catalog.fitting_names (fitting_name COLLATE "C");

-- DEFECT the-materialised-path-names-ancestors-that-no-longer-exist
--
-- Each section carries the path of node identifiers above it as a string. Some
-- of those identifiers belong to nodes that were deleted.
--
-- The path is written when a section is created and rewritten when it is
-- moved, and deleting a node higher up is neither of those things. The delete
-- removes the node and the rows that reference it by foreign key, and leaves
-- every path string that merely names it, because a string is not a reference
-- and the database has no way to know it was meant to be one. The breadcrumb
-- on the catalogue page renders the identifiers it cannot resolve as an empty
-- link.
--
-- Measured: 1,200 section paths against 1,200 nodes, where 300 paths name at
-- least one identifier that is not in the node table.
--
-- The path wants rebuilding from the parent links, and the delete wants to
-- rebuild the paths below it. Every path is well formed and parses cleanly,
-- so the format check that runs nightly passes.
CREATE TABLE catalog.section_nodes (
    node_id   integer PRIMARY KEY,
    node_name varchar(60) NOT NULL
);

CREATE TABLE catalog.section_paths (
    node_id integer PRIMARY KEY REFERENCES catalog.section_nodes (node_id),
    path    varchar(60) NOT NULL
);

INSERT INTO catalog.section_nodes (node_id, node_name)
SELECT g, 'Section ' || g
FROM generate_series(1, 1200) AS g;

INSERT INTO catalog.section_paths (node_id, path)
SELECT g,
       CASE WHEN g % 4 = 0
            THEN '/' || (5000 + (g % 300)) || '/' || (1 + (g % 1200)) || '/' || g || '/'
            ELSE '/' || (1 + (g % 40)) || '/' || (1 + (g % 1200)) || '/' || g || '/'
       END
FROM generate_series(1, 1200) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.fitting_names ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.fitting_names:' || concat_ws('|', x.fitting_name, x.range_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.fitting_names x
)
UPDATE catalog.fitting_names t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.fitting_names ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.fitting_names ADD CONSTRAINT fitting_names_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_fitting_names_product_id ON catalog.fitting_names (product_id);

ALTER TABLE payments.bank_feed_lines ADD COLUMN merchant_ref character varying(12);

WITH p AS (
    SELECT merchant_ref AS v, row_number() OVER (ORDER BY merchant_ref) - 1 AS k
      FROM payments.merchant_accounts
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.merchant_accounts)
                 * power((abs(hashtext('payments.bank_feed_lines:' || concat_ws('|', x.feed_ref, x.amount_cents))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.bank_feed_lines x
)
UPDATE payments.bank_feed_lines t
   SET merchant_ref = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.bank_feed_lines ALTER COLUMN merchant_ref SET NOT NULL;
ALTER TABLE payments.bank_feed_lines ADD CONSTRAINT bank_feed_lines_merchant_ref_fkey FOREIGN KEY (merchant_ref) REFERENCES payments.merchant_accounts (merchant_ref);
CREATE INDEX ix_bank_feed_lines_merchant_ref ON payments.bank_feed_lines (merchant_ref);

ALTER TABLE payments.merchant_accounts ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.merchant_accounts:' || concat_ws('|', x.merchant_ref, x.display_name, x.api_secret, x.settled_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.merchant_accounts x
)
UPDATE payments.merchant_accounts t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.merchant_accounts ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.merchant_accounts ADD CONSTRAINT merchant_accounts_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_merchant_accounts_transaction_id ON payments.merchant_accounts (transaction_id);

ALTER TABLE payments.refund_requests ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.refund_requests:' || concat_ws('|', x.order_ref, x.amount_p, x.approved_by))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.refund_requests x
)
UPDATE payments.refund_requests t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.refund_requests ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.refund_requests ADD CONSTRAINT refund_requests_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_refund_requests_transaction_id ON payments.refund_requests (transaction_id);

ALTER TABLE supply.hazard_sheets ADD COLUMN part_id integer;

WITH p AS (
    SELECT part_id AS v, row_number() OVER (ORDER BY part_id) - 1 AS k
      FROM supply.parts
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.parts)
                 * power((abs(hashtext('supply.hazard_sheets:' || concat_ws('|', x.sku, x.hazard_class, x.sheet_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.hazard_sheets x
)
UPDATE supply.hazard_sheets t
   SET part_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.hazard_sheets ALTER COLUMN part_id SET NOT NULL;
ALTER TABLE supply.hazard_sheets ADD CONSTRAINT hazard_sheets_part_id_fkey FOREIGN KEY (part_id) REFERENCES supply.parts (part_id);
CREATE INDEX ix_hazard_sheets_part_id ON supply.hazard_sheets (part_id);

ALTER TABLE supply.kit_definitions ADD COLUMN part_id integer;

WITH p AS (
    SELECT part_id AS v, row_number() OVER (ORDER BY part_id) - 1 AS k
      FROM supply.parts
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.parts)
                 * power((abs(hashtext('supply.kit_definitions:' || concat_ws('|', x.kit_name, x.component_skus, x.quantities))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.kit_definitions x
)
UPDATE supply.kit_definitions t
   SET part_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.kit_definitions ALTER COLUMN part_id SET NOT NULL;
ALTER TABLE supply.kit_definitions ADD CONSTRAINT kit_definitions_part_id_fkey FOREIGN KEY (part_id) REFERENCES supply.parts (part_id);
CREATE INDEX ix_kit_definitions_part_id ON supply.kit_definitions (part_id);

ALTER TABLE supply.reorder_points ADD COLUMN part_id integer;

WITH p AS (
    SELECT part_id AS v, row_number() OVER (ORDER BY part_id) - 1 AS k
      FROM supply.parts
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.parts)
                 * power((abs(hashtext('supply.reorder_points:' || concat_ws('|', x.sku, x.reorder_at))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.reorder_points x
)
UPDATE supply.reorder_points t
   SET part_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.reorder_points ALTER COLUMN part_id SET NOT NULL;
ALTER TABLE supply.reorder_points ADD CONSTRAINT reorder_points_part_id_fkey FOREIGN KEY (part_id) REFERENCES supply.parts (part_id);
CREATE INDEX ix_reorder_points_part_id ON supply.reorder_points (part_id);
-- <<< relationships
