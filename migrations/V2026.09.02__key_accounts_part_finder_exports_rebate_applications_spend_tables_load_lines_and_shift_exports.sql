-- Cross River Trading Co. -- key accounts, part finder exports, rebate
-- applications, marketing spend tables, load lines, shift exports
-- author: T. Marchetti
-- postgres: 18
--
-- The accounts with a named manager, what the part finder sent to print, the
-- rebates applied to a supplier, what marketing spent, what went on the
-- trailer, and the shift figures the reporting role pulls.

-- DEFECT three-tables-point-at-each-other-so-nothing-can-be-restored-first
--
-- A key account names a depot, the depot row names an account manager, and the
-- account manager names a key account. Three foreign keys, one cycle, and no
-- order in which the three tables can be loaded.
--
-- Each constraint was added on its own and each is defensible. The account
-- must have a home depot. The depot must have somebody accountable for it. The
-- manager must have a lead account, which is the account their bonus is
-- measured on. Nobody drew the three together. Every column is nullable, which
-- is why the data loaded at all: the loader inserts with nulls and fills them
-- in afterwards, in a second pass that is not in the schema and is not in any
-- migration. A restore into an empty database runs the tables in dependency
-- order, finds there is not one, and either fails or loads them with the
-- references empty.
--
-- Measured: 1,200 key accounts in a three table foreign key cycle.
--
-- One of the three references wants to be a separate table, most naturally the
-- manager's lead account. Every constraint is valid, every row satisfies it,
-- and the cycle is only visible by drawing all three tables at once.
CREATE TABLE storefront.key_accounts (
    account_ref  varchar(12) PRIMARY KEY,
    trading_name varchar(80) NOT NULL,
    home_depot   varchar(12)
);

CREATE TABLE ops.account_depots (
    depot_code   varchar(12) PRIMARY KEY,
    depot_name   varchar(40) NOT NULL,
    manager_ref  varchar(12)
);

CREATE TABLE ops.account_managers (
    manager_ref  varchar(12) PRIMARY KEY,
    manager_name varchar(60) NOT NULL,
    lead_account varchar(12)
);

ALTER TABLE storefront.key_accounts
    ADD CONSTRAINT key_accounts_depot_fk
    FOREIGN KEY (home_depot) REFERENCES ops.account_depots (depot_code);

ALTER TABLE ops.account_depots
    ADD CONSTRAINT account_depots_manager_fk
    FOREIGN KEY (manager_ref) REFERENCES ops.account_managers (manager_ref);

ALTER TABLE ops.account_managers
    ADD CONSTRAINT account_managers_account_fk
    FOREIGN KEY (lead_account) REFERENCES storefront.key_accounts (account_ref);

-- The loader's first pass, with the references left empty.
INSERT INTO storefront.key_accounts (account_ref, trading_name, home_depot)
SELECT 'KEY-' || lpad(g::text, 7, '0'), 'Key account ' || g, NULL
FROM generate_series(1, 1200) AS g;

INSERT INTO ops.account_managers (manager_ref, manager_name, lead_account)
SELECT 'MGR-' || lpad(g::text, 7, '0'), 'Manager ' || g, NULL
FROM generate_series(1, 60) AS g;

INSERT INTO ops.account_depots (depot_code, depot_name, manager_ref)
SELECT 'ADP-' || lpad(g::text, 7, '0'), 'Depot ' || g, NULL
FROM generate_series(1, 40) AS g;

-- The second pass, which is in no migration and in no schema.
UPDATE ops.account_depots
SET manager_ref = 'MGR-' || lpad((1 + (substr(depot_code, 5)::integer % 60))::text, 7, '0');

UPDATE ops.account_managers
SET lead_account = 'KEY-' || lpad((1 + (substr(manager_ref, 5)::integer % 1200))::text, 7, '0');

UPDATE storefront.key_accounts
SET home_depot = 'ADP-' || lpad((1 + (substr(account_ref, 5)::integer % 40))::text, 7, '0');

-- DEFECT the-page-boundaries-were-cut-under-one-collation-and-read-under-another
--
-- The part finder export cuts its pages at a code computed under the C
-- collation and then fetches each page under the database collation. The two
-- orders are not the same, so codes fall through the seams.
--
-- The boundary list is produced by a nightly job that sorts with an explicit
-- COLLATE "C", because the job was written to match a fixed-width file that
-- the printer sorts in byte order. The export then selects each page with a
-- BETWEEN against those boundaries, in the default collation, where the
-- ordering interleaves case and ignores punctuation. Every page still returns
-- rows and every page is the right size, so the export looks healthy. Codes
-- near a boundary either land in two pages or in none.
--
-- Measured: 12,000 part codes exported over 241 pages, of which 240 codes
-- appear on two pages and 240 appear on none.
--
-- Both halves want the same collation named explicitly, or keyset paging on
-- the primary key rather than on the text. Every page is internally sorted and
-- the export total is within two percent of the table, which is the only check
-- anybody runs.
CREATE TABLE catalog.part_finder_index (
    part_code varchar(20) PRIMARY KEY,
    part_name varchar(60) NOT NULL
);

CREATE TABLE catalog.part_finder_exports (
    export_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    page_no   integer NOT NULL,
    part_code varchar(20) NOT NULL,
    printed_at timestamptz NOT NULL
);

INSERT INTO catalog.part_finder_index (part_code, part_name)
SELECT CASE WHEN g % 50 = 0
            THEN lower(upper(substr(md5(g::text), 1, 4))) || '-' || lpad(g::text, 7, '0')
            ELSE upper(substr(md5(g::text), 1, 4)) || '-' || lpad(g::text, 7, '0')
       END,
       'Part ' || g
FROM generate_series(1, 12000) AS g;

-- The pages as the printer cut them.
INSERT INTO catalog.part_finder_exports (page_no, part_code, printed_at)
SELECT 1 + ((g - 1) / 50), part_code,
       TIMESTAMPTZ '2026-09-14 23:00:00+01' + (g * INTERVAL '1 second')
FROM (SELECT part_code, row_number() OVER (ORDER BY part_code COLLATE "C") AS g
      FROM catalog.part_finder_index) AS s
WHERE g % 50 <> 1;

-- The codes that sat on a seam, fetched again by the next page.
INSERT INTO catalog.part_finder_exports (page_no, part_code, printed_at)
SELECT 1 + ((g - 1) / 50) + 1, part_code,
       TIMESTAMPTZ '2026-09-14 23:00:00+01' + (g * INTERVAL '1 second')
FROM (SELECT part_code, row_number() OVER (ORDER BY part_code COLLATE "C") AS g
      FROM catalog.part_finder_index) AS s
WHERE g % 50 = 0;

-- DEFECT the-definer-function-resolves-names-against-a-schema-anyone-can-write
--
-- The rebate function runs as its owner and its search path names public
-- first. Anyone who can create a table in public decides what the function
-- reads.
--
-- Setting a search path on a SECURITY DEFINER function is the right habit, and
-- this one has it, which is why it passes every review. The order is the
-- problem. Name resolution takes the first match, public is ahead of the
-- function's own schema, and CREATE on public is held by PUBLIC in this
-- database. A table called rebate_applications created in public is read by
-- this function in preference to the real one, with the owner's rights, and
-- the function writes its result back through the same name.
--
-- Measured: 4,800 rebate applications behind one SECURITY DEFINER function
-- whose search path names public ahead of its own schema.
--
-- Putting the function's own schema first, and pg_catalog before that, is a
-- one line change. The function is owned correctly, sets a search path, takes
-- typed arguments and builds no dynamic SQL.
CREATE TABLE supply.rebate_applications (
    application_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref   varchar(12) NOT NULL,
    rebate_p       integer NOT NULL,
    applied_on     date NOT NULL
);

INSERT INTO supply.rebate_applications (supplier_ref, rebate_p, applied_on)
SELECT 'SUP-' || lpad((1 + (g % 600))::text, 6, '0'),
       1000 + (g % 60000),
       DATE '2025-10-06' + (g % 340)
FROM generate_series(1, 4800) AS g;

CREATE FUNCTION supply.fn_apply_rebate(p_supplier_ref varchar, p_rebate_p integer)
RETURNS integer
LANGUAGE sql SECURITY DEFINER SET search_path = public, supply AS $$
    INSERT INTO rebate_applications (supplier_ref, rebate_p, applied_on)
    VALUES (p_supplier_ref, p_rebate_p, current_date)
    RETURNING application_id;
$$;

GRANT EXECUTE ON FUNCTION supply.fn_apply_rebate(varchar, integer) TO app_writer;

-- DEFECT the-grant-covered-the-tables-that-existed-that-day
--
-- The portal reporting role was granted SELECT on all tables in the marketing
-- spend set. Two of the five were created afterwards and the role cannot read
-- them.
--
-- GRANT SELECT ON ALL TABLES IN SCHEMA is a loop over the tables that exist
-- when it runs, not a standing rule, and it was run once during the handover
-- week. The two tables added since are the daily and the annual rollups, which
-- are the two the portal's spend page reads first. A default privilege would
-- have covered them and there is not one on this schema. The page catches the
-- permission error per panel and renders the panel empty, so the spend page
-- shows three populated charts and two blank ones, which reads as no spend.
--
-- Measured: 5 marketing spend tables of which 2 are unreadable by the portal
-- reporting role, holding 987 rows between them.
--
-- ALTER DEFAULT PRIVILEGES makes the rule standing, and the two tables want
-- granting now. Every grant that was made is intact, correct and visible.
CREATE TABLE marketing.spend_weekly (
    week_start date PRIMARY KEY,
    spend_p    integer NOT NULL
);

CREATE TABLE marketing.spend_monthly (
    month_start date PRIMARY KEY,
    spend_p     integer NOT NULL
);

CREATE TABLE marketing.spend_quarterly (
    quarter_start date PRIMARY KEY,
    spend_p       integer NOT NULL
);

INSERT INTO marketing.spend_weekly (week_start, spend_p)
SELECT DATE '2024-01-01' + (g * 7), 120000 + (g * 900)
FROM generate_series(0, 139) AS g;

INSERT INTO marketing.spend_monthly (month_start, spend_p)
SELECT (DATE '2024-01-01' + (g || ' months')::interval)::date, 520000 + (g * 4000)
FROM generate_series(0, 32) AS g;

INSERT INTO marketing.spend_quarterly (quarter_start, spend_p)
SELECT (DATE '2024-01-01' + ((g * 3) || ' months')::interval)::date, 1600000 + (g * 12000)
FROM generate_series(0, 10) AS g;

GRANT SELECT ON ALL TABLES IN SCHEMA marketing TO portal_reader;

-- The two rollups that were added the following quarter.
CREATE TABLE marketing.spend_daily (
    spend_day date PRIMARY KEY,
    spend_p   integer NOT NULL
);

CREATE TABLE marketing.spend_annual (
    year_start date PRIMARY KEY,
    spend_p    integer NOT NULL
);

INSERT INTO marketing.spend_daily (spend_day, spend_p)
SELECT DATE '2024-01-01' + g, 17000 + (g * 11)
FROM generate_series(0, 979) AS g;

INSERT INTO marketing.spend_annual (year_start, spend_p)
SELECT (DATE '2019-01-01' + ((g * 12) || ' months')::interval)::date, 6200000 + (g * 140000)
FROM generate_series(0, 6) AS g;

-- DEFECT deleting-by-value-removes-both-copies-of-an-identical-row
--
-- The load line table has no key of any kind, and six hundred lines are
-- character for character identical to another line. The loading screen
-- deletes a line by matching every column.
--
-- A load line is a product, a quantity and a trailer, and the same product can
-- legitimately be loaded twice onto the same trailer, as two pallets from two
-- picks. There is nothing on the row to tell the two apart, because the table
-- was built by a copy out of a spreadsheet and the spreadsheet had no line
-- number either. Removing a line therefore removes both, and the trailer goes
-- out a pallet short, which is found at the far end and put down to a picking
-- error.
--
-- Measured: 9,600 load lines of which 600 are exact duplicates of another
-- line, in a table with no primary key and no unique index.
--
-- A generated identity column is one statement and makes a line addressable.
-- Every line is a true record of something that was loaded, and the totals on
-- the trailer manifest are correct.
CREATE TABLE fulfilment.load_lines (
    trailer_no varchar(10) NOT NULL,
    sku        varchar(16) NOT NULL,
    qty        integer NOT NULL,
    loaded_on  date NOT NULL
);

INSERT INTO fulfilment.load_lines (trailer_no, sku, qty, loaded_on)
SELECT 'TRL-' || lpad((1 + (g % 300))::text, 5, '0'),
       'SKU-' || lpad((1 + (g % 2000))::text, 8, '0'),
       1 + (g % 7),
       DATE '2026-08-03' + (g % 30)
FROM generate_series(1, 9000) AS g;

-- The second pallet of the same product onto the same trailer.
INSERT INTO fulfilment.load_lines (trailer_no, sku, qty, loaded_on)
SELECT 'TRL-' || lpad((1 + (g % 300))::text, 5, '0'),
       'SKU-' || lpad((1 + (g % 2000))::text, 8, '0'),
       1 + (g % 7),
       DATE '2026-08-03' + (g % 30)
FROM generate_series(1, 600) AS g;

-- DEFECT a-reporting-role-may-truncate-the-table-it-reads
--
-- The stock reporting role was granted ALL PRIVILEGES on the shift export
-- table. ALL includes TRUNCATE.
--
-- The grant was written while chasing a permission error in a nightly job that
-- turned out to be about a sequence, and ALL made the error go away. TRUNCATE
-- is not a lot of deletes: it is a single statement that empties the table, it
-- takes an access exclusive lock, it fires no row triggers, and the audit
-- trigger on this table therefore records nothing at all. The table is the
-- source for the shift productivity figures the depot managers are measured
-- on, and it is rebuilt weekly, so an accidental truncate would be noticed
-- next Monday at the earliest.
--
-- Measured: 7,200 shift export rows on a table where the stock reporting role
-- holds TRUNCATE.
--
-- GRANT SELECT is what was meant and is one statement. The role has never
-- issued anything but a select, and the grant was made deliberately by
-- somebody with the right to make it.
CREATE TABLE ops.shift_exports (
    export_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    shift_date date NOT NULL,
    picks      integer NOT NULL,
    hours      integer NOT NULL
);

INSERT INTO ops.shift_exports (depot_code, shift_date, picks, hours)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-03-30' + (g % 180),
       200 + (g % 900),
       6 + (g % 4)
FROM generate_series(1, 7200) AS g;

GRANT ALL PRIVILEGES ON TABLE ops.shift_exports TO stock_reader;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.part_finder_exports ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.part_finder_exports:' || concat_ws('|', x.page_no, x.part_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.part_finder_exports x
)
UPDATE catalog.part_finder_exports t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.part_finder_exports ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.part_finder_exports ADD CONSTRAINT part_finder_exports_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_part_finder_exports_product_id ON catalog.part_finder_exports (product_id);

ALTER TABLE catalog.part_finder_index ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.part_finder_index:' || concat_ws('|', x.part_code, x.part_name))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.part_finder_index x
)
UPDATE catalog.part_finder_index t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.part_finder_index ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.part_finder_index ADD CONSTRAINT part_finder_index_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_part_finder_index_product_id ON catalog.part_finder_index (product_id);

ALTER TABLE fulfilment.load_lines ADD COLUMN sheet_id integer;

WITH p AS (
    SELECT sheet_id AS v, row_number() OVER (ORDER BY sheet_id) - 1 AS k
      FROM ops.load_sheets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.load_sheets)
                 * power((abs(hashtext('fulfilment.load_lines:' || concat_ws('|', x.trailer_no, x.sku, x.qty))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.load_lines x
)
UPDATE fulfilment.load_lines t
   SET sheet_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.load_lines ALTER COLUMN sheet_id SET NOT NULL;
ALTER TABLE fulfilment.load_lines ADD CONSTRAINT load_lines_sheet_id_fkey FOREIGN KEY (sheet_id) REFERENCES ops.load_sheets (sheet_id);
CREATE INDEX ix_load_lines_sheet_id ON fulfilment.load_lines (sheet_id);

ALTER TABLE marketing.spend_annual ADD COLUMN campaign_id integer;

WITH p AS (
    SELECT campaign_id AS v, row_number() OVER (ORDER BY campaign_id) - 1 AS k
      FROM marketing.campaigns
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM marketing.campaigns)
                 * power((abs(hashtext('marketing.spend_annual:' || concat_ws('|', x.spend_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.spend_annual x
)
UPDATE marketing.spend_annual t
   SET campaign_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.spend_annual ALTER COLUMN campaign_id SET NOT NULL;
ALTER TABLE marketing.spend_annual ADD CONSTRAINT spend_annual_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES marketing.campaigns (campaign_id);
CREATE INDEX ix_spend_annual_campaign_id ON marketing.spend_annual (campaign_id);

ALTER TABLE marketing.spend_quarterly ADD COLUMN campaign_id integer;

WITH p AS (
    SELECT campaign_id AS v, row_number() OVER (ORDER BY campaign_id) - 1 AS k
      FROM marketing.campaigns
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM marketing.campaigns)
                 * power((abs(hashtext('marketing.spend_quarterly:' || concat_ws('|', x.spend_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.spend_quarterly x
)
UPDATE marketing.spend_quarterly t
   SET campaign_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.spend_quarterly ALTER COLUMN campaign_id SET NOT NULL;
ALTER TABLE marketing.spend_quarterly ADD CONSTRAINT spend_quarterly_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES marketing.campaigns (campaign_id);
CREATE INDEX ix_spend_quarterly_campaign_id ON marketing.spend_quarterly (campaign_id);

ALTER TABLE supply.rebate_applications ADD COLUMN claim_id integer;

WITH p AS (
    SELECT claim_id AS v, row_number() OVER (ORDER BY claim_id) - 1 AS k
      FROM supply.rebate_claims
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.rebate_claims)
                 * power((abs(hashtext('supply.rebate_applications:' || concat_ws('|', x.supplier_ref, x.rebate_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.rebate_applications x
)
UPDATE supply.rebate_applications t
   SET claim_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.rebate_applications ALTER COLUMN claim_id SET NOT NULL;
ALTER TABLE supply.rebate_applications ADD CONSTRAINT rebate_applications_claim_id_fkey FOREIGN KEY (claim_id) REFERENCES supply.rebate_claims (claim_id);
CREATE INDEX ix_rebate_applications_claim_id ON supply.rebate_applications (claim_id);
-- <<< relationships
