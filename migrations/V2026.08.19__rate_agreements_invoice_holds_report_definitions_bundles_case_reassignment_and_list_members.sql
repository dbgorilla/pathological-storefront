-- Cross River Trading Co. -- rate agreements, invoice holds, report
-- definitions, product bundles, case reassignment, list members
-- author: T. Marchetti
-- postgres: 18
--
-- What a supplier charges from a given date, an invoice held back from
-- payment, the definition of a report, a bundle of products sold together, the
-- handing of a case to another agent, and who is on a marketing list.

-- DEFECT the-pair-is-unique-in-the-data-and-nothing-says-so
--
-- A supplier has one rate agreement per effective date. That is true of every
-- row in the table and nothing in the schema says it.
--
-- The table has a surrogate key on an identity column and no constraint on the
-- pair that actually identifies a row. The loader enforces it, in the sense
-- that the loader has never written a duplicate, and the loader is a Python
-- script that has been rewritten twice. Every query that picks the rate in
-- force for a date assumes one row comes back, and the ones that use a
-- subquery will fail loudly if two ever do, while the ones that use a join
-- will quietly double the line.
--
-- Measured: 4,800 rate agreements over 400 suppliers and 12 effective dates
-- each, with 4,800 distinct (supplier, effective from) pairs and no unique
-- constraint over those two columns.
--
-- A unique constraint on the pair would be accepted by the data as it stands
-- today. It has not been added because nobody is certain it holds historically,
-- which is a question the data answers in one query.
CREATE TABLE supply.rate_agreements (
    agreement_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref   varchar(12) NOT NULL,
    effective_from date NOT NULL,
    rate_p         integer NOT NULL
);

INSERT INTO supply.rate_agreements (supplier_ref, effective_from, rate_p)
SELECT 'SUP-' || lpad(s::text, 5, '0'),
       DATE '2024-01-01' + (n * 90),
       120 + ((s * 7 + n) % 900)
FROM generate_series(1, 400) AS s
CROSS JOIN generate_series(0, 11) AS n;

-- DEFECT the-second-trigger-overwrites-what-the-first-one-calculated
--
-- Two before-insert triggers on the invoice holds table. The first works out
-- how much is being held. The second clears the released amount. They fire in
-- name order and the second one invalidates the first one's answer.
--
-- The held total is the invoice amount less whatever has already been
-- released. The release-clearing trigger was added later, by a different
-- change, to stop a partial release being carried into a new hold. It is named
-- trg_b_clear_released, the total trigger is named trg_a_set_hold_total, and
-- Postgres fires triggers of the same timing in alphabetical order. So the
-- total is computed against a released amount that is about to be zeroed, and
-- the row it is stored on says the released amount is zero.
--
-- Measured: 3,000 invoice holds, of which 1,500 store a held total that does
-- not equal the amount less the released figure on the same row.
--
-- One trigger doing both things in the order the business wants, or the total
-- computed in the after-insert. Every individual number on the row is a number
-- the system once believed, which is why reconciling them has been attempted
-- twice and abandoned twice.
CREATE TABLE payments.invoice_holds (
    hold_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_ref varchar(20) NOT NULL,
    amount_p    integer NOT NULL,
    released_p  integer NOT NULL DEFAULT 0,
    hold_total_p integer,
    held_on     date NOT NULL
);

CREATE FUNCTION payments.fn_set_hold_total() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.hold_total_p := NEW.amount_p - NEW.released_p;
    RETURN NEW;
END;
$$;

CREATE FUNCTION payments.fn_clear_released() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.released_p := 0;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_a_set_hold_total BEFORE INSERT ON payments.invoice_holds
    FOR EACH ROW EXECUTE FUNCTION payments.fn_set_hold_total();

CREATE TRIGGER trg_b_clear_released BEFORE INSERT ON payments.invoice_holds
    FOR EACH ROW EXECUTE FUNCTION payments.fn_clear_released();

INSERT INTO payments.invoice_holds (invoice_ref, amount_p, released_p, held_on)
SELECT 'INV-' || lpad(g::text, 10, '0'),
       5000 + (g % 90000),
       CASE WHEN g % 2 = 0 THEN 500 + (g % 3000) ELSE 0 END,
       DATE '2026-02-02' + (g % 200)
FROM generate_series(1, 3000) AS g;

-- DEFECT the-config-table-names-tables-that-were-dropped-years-ago
--
-- The report definitions table holds the name of the table each report reads
-- from, as text. A quarter of those names are of tables that no longer exist.
--
-- The name is text because the definitions are edited by the reporting team
-- through a screen, and a text column can hold anything, including the name of
-- something that has been dropped. Nothing validates it on write and nothing
-- re-validates it when a table is dropped, because a text column carries no
-- dependency. The report fails at run time with a relation does not exist
-- error, which is caught by the scheduler and logged as a failed run, and a
-- failed run of a report nobody has opened in two years is not looked at.
--
-- Measured: 240 report definitions, of which 60 name a relation that does not
-- exist in the database.
--
-- A regclass column carries the dependency and refuses the drop, which is the
-- whole point of the type. The definitions look complete and well maintained
-- because the rows are all there and all populated.
CREATE TABLE ops.report_definitions (
    report_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    report_name  varchar(80) NOT NULL,
    source_table varchar(120) NOT NULL,
    defined_on   date NOT NULL
);

INSERT INTO ops.report_definitions (report_name, source_table, defined_on)
SELECT 'Report ' || g,
       (ARRAY['ops.depot_registry', 'catalog.pack_sizes', 'payments.invoice_holds'])[1 + (g % 3)],
       DATE '2020-03-02' + (g % 2000)
FROM generate_series(1, 180) AS g;

-- The tables these were written against have since been dropped.
INSERT INTO ops.report_definitions (report_name, source_table, defined_on)
SELECT 'Report ' || (500 + g),
       'ops.legacy_depot_throughput_' || (1 + (g % 6)),
       DATE '2019-06-03' + (g % 400)
FROM generate_series(1, 60) AS g;

-- DEFECT the-two-tables-require-each-other-so-neither-can-be-loaded-first
--
-- The bundle header points at its lead item and the bundle item points at its
-- header. Each foreign key requires the other table to be populated first.
--
-- The lead item is the one shown on the listing, so the header needs it, and
-- an item belongs to exactly one bundle, so the item needs the header. Loading
-- a bundle means inserting the header with a null lead item, inserting the
-- items, then going back and setting the lead. The loader does the first two
-- steps and the third is a separate job that fails silently on any bundle
-- whose items were rejected. The headers that come out of that have no lead
-- item, so the listing shows a bundle with no picture and no price.
--
-- Measured: 600 bundles with 2,400 items between them, of which 300 headers
-- have a null lead item despite having items in the bundle.
--
-- Deferring one of the two constraints, or dropping the lead item column in
-- favour of a flag on the item, breaks the cycle. Both foreign keys are correct
-- in isolation, which is why each has survived every review of its own table.
CREATE TABLE catalog.bundle_headers (
    bundle_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bundle_ref   varchar(16) NOT NULL UNIQUE,
    lead_item_id integer,
    created_on   date NOT NULL
);

CREATE TABLE catalog.bundle_items (
    item_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    bundle_id integer NOT NULL REFERENCES catalog.bundle_headers (bundle_id),
    sku       varchar(20) NOT NULL,
    quantity  integer NOT NULL
);

ALTER TABLE catalog.bundle_headers
    ADD CONSTRAINT bundle_headers_lead_item_fkey
    FOREIGN KEY (lead_item_id) REFERENCES catalog.bundle_items (item_id);

INSERT INTO catalog.bundle_headers (bundle_ref, created_on)
SELECT 'BND-' || lpad(g::text, 8, '0'),
       DATE '2025-07-01' + (g % 400)
FROM generate_series(1, 600) AS g;

INSERT INTO catalog.bundle_items (bundle_id, sku, quantity)
SELECT h.bundle_id,
       'SKU-' || lpad((1 + ((h.bundle_id * 11 + s) % 700))::text, 6, '0'),
       1 + ((h.bundle_id + s) % 4)
FROM catalog.bundle_headers AS h
CROSS JOIN generate_series(1, 4) AS s;

-- The third step of the load, which reaches half the bundles.
UPDATE catalog.bundle_headers AS h
SET lead_item_id = (SELECT min(i.item_id) FROM catalog.bundle_items AS i
                    WHERE i.bundle_id = h.bundle_id)
WHERE h.bundle_id % 2 = 0;

-- DEFECT the-definer-function-builds-its-where-clause-by-concatenation
--
-- The case reassignment function runs as its owner and builds its UPDATE by
-- gluing the caller's arguments into a string.
--
-- It is SECURITY DEFINER for the right reason: reassigning a case writes to a
-- table agents cannot write to directly. It builds the statement with EXECUTE
-- and string concatenation because an earlier version needed a dynamic table
-- name, which it no longer does. Nothing quotes the arguments. A case
-- reference containing a quote closes the literal and the rest of it runs as
-- SQL, with the owner's rights, which are the rights the function exists to
-- lend. One call with a crafted reference reassigns every case in the table.
--
-- Measured: 1,200 case assignments, of which 1,200 were reassigned to a single
-- agent by one call whose case reference closed the quote.
--
-- format with %L, or a plain parameterised UPDATE since the table name is
-- fixed, removes it entirely. The function has a search path set and is granted
-- to one role, so it passes every check that is run against definer functions.
CREATE TABLE support.case_assignments (
    assignment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref      varchar(16) NOT NULL,
    agent_ref     varchar(12) NOT NULL,
    assigned_at   timestamptz NOT NULL
);

INSERT INTO support.case_assignments (case_ref, agent_ref, assigned_at)
SELECT 'CAS-' || lpad(g::text, 8, '0'),
       'AGT-' || lpad((1 + (g % 60))::text, 5, '0'),
       TIMESTAMPTZ '2026-06-01 09:00:00+01' + (g * INTERVAL '17 minutes')
FROM generate_series(1, 1200) AS g;

CREATE FUNCTION support.fn_reassign_case(p_case_ref varchar, p_agent_ref varchar)
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, support
AS $$
DECLARE n integer;
BEGIN
    EXECUTE 'UPDATE support.case_assignments SET agent_ref = ''' || p_agent_ref
         || ''', assigned_at = now() WHERE case_ref = ''' || p_case_ref || '''';

    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

GRANT EXECUTE ON FUNCTION support.fn_reassign_case(varchar, varchar) TO app_writer;

-- The call that closed the quote.
SELECT support.fn_reassign_case(''' OR 1=1 --', 'AGT-99999');

-- DEFECT the-table-has-no-key-so-a-correction-hits-every-copy-of-the-row
--
-- The marketing list membership table has no primary key and holds exact
-- duplicate rows.
--
-- Membership is a list and an account and a date, and the same three were
-- loaded twice by an import that was re-run after a partial failure. With no
-- key there was nothing to stop it and nothing to detect it afterwards. A
-- person asking to be taken off a list is removed with a delete on the three
-- columns, which removes both copies and looks correct. A person whose
-- preferences are corrected with an update gets both copies updated, which also
-- looks correct. What does not work is any count: the list is reported larger
-- than it is, and the send rate against it is reported lower.
--
-- Measured: 6,056 list membership rows with no primary key, of which 956 are
-- exact duplicates of another row in the table.
--
-- A primary key over the three columns, after the duplicates are removed with
-- ctid, is the fix and the duplicates are safe to remove because they are
-- identical. Every operation the marketing team performs on this table gives
-- the right answer, so the table has never been suspected.
CREATE TABLE marketing.list_members (
    list_code   varchar(16) NOT NULL,
    account_ref varchar(12) NOT NULL,
    joined_on   date NOT NULL
);

INSERT INTO marketing.list_members (list_code, account_ref, joined_on)
SELECT 'LST-' || lpad((1 + (g % 30))::text, 5, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       DATE '2025-02-03' + (g % 500)
FROM generate_series(1, 5100) AS g;

-- The re-run of the import that had partly failed.
INSERT INTO marketing.list_members (list_code, account_ref, joined_on)
SELECT list_code, account_ref, joined_on
FROM marketing.list_members
WHERE joined_on < DATE '2025-05-01';

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE marketing.list_members ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('marketing.list_members:' || concat_ws('|', x.list_code, x.account_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.list_members x
)
UPDATE marketing.list_members t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.list_members ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE marketing.list_members ADD CONSTRAINT list_members_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_list_members_customer_id ON marketing.list_members (customer_id);

ALTER TABLE payments.invoice_holds ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('payments.invoice_holds:' || concat_ws('|', x.invoice_ref, x.amount_p, x.released_p, x.hold_total_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.invoice_holds x
)
UPDATE payments.invoice_holds t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.invoice_holds ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE payments.invoice_holds ADD CONSTRAINT invoice_holds_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_invoice_holds_customer_id ON payments.invoice_holds (customer_id);

ALTER TABLE supply.rate_agreements ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.rate_agreements:' || concat_ws('|', x.supplier_ref, x.rate_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.rate_agreements x
)
UPDATE supply.rate_agreements t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.rate_agreements ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.rate_agreements ADD CONSTRAINT rate_agreements_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_rate_agreements_supplier_id ON supply.rate_agreements (supplier_id);

ALTER TABLE support.case_assignments ADD COLUMN case_id integer;

WITH p AS (
    SELECT case_id AS v, row_number() OVER (ORDER BY case_id) - 1 AS k
      FROM support.case_records
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.case_records)
                 * power((abs(hashtext('support.case_assignments:' || concat_ws('|', x.case_ref, x.agent_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.case_assignments x
)
UPDATE support.case_assignments t
   SET case_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.case_assignments ALTER COLUMN case_id SET NOT NULL;
ALTER TABLE support.case_assignments ADD CONSTRAINT case_assignments_case_id_fkey FOREIGN KEY (case_id) REFERENCES support.case_records (case_id);
CREATE INDEX ix_case_assignments_case_id ON support.case_assignments (case_id);
-- <<< relationships
