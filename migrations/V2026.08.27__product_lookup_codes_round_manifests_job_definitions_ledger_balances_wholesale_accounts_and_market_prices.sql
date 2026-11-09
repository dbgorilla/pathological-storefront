-- Cross River Trading Co. -- product lookup codes, round manifests, job
-- definitions, ledger balances, wholesale accounts, market prices
-- author: T. Marchetti
-- postgres: 18
--
-- The code a picker types to find a product, the drops on a delivery round,
-- the jobs the scheduler runs, the balance on a ledger, the accounts a trade
-- customer holds, and what the market paid that week.

-- DEFECT the-prefix-search-cannot-use-the-index-the-column-already-has
--
-- The picking terminal searches by typing the first few characters of a code.
-- The column is indexed, and the index cannot answer that search.
--
-- A B-tree on a text column is built under the database collation, and the
-- comparisons that collation defines are not the byte-order comparisons a
-- prefix match needs. Postgres will only use an index for LIKE 'ABC%' when the
-- index is built with text_pattern_ops, and this one is not. So the terminal
-- scans fifteen thousand rows for every keystroke after the third, and the
-- index sits beside it being maintained and never chosen. The column was
-- indexed because somebody asked whether it was indexed, and the answer was
-- yes.
--
-- Measured: 15,000 product lookup codes behind one non-primary index on the
-- code, built under the default operator class rather than text_pattern_ops.
--
-- A second index with text_pattern_ops serves the prefix search and the first
-- one still serves equality. The search returns the right products, the
-- terminal is merely slow, and slow on a handheld reads as the wireless.
CREATE TABLE catalog.product_lookup_codes (
    lookup_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lookup_code text NOT NULL,
    sku         varchar(16) NOT NULL,
    added_on    date NOT NULL
);

INSERT INTO catalog.product_lookup_codes (lookup_code, sku, added_on)
SELECT upper(substr(md5(g::text), 1, 3)) || '-' || lpad(g::text, 7, '0'),
       'SKU-' || lpad((1 + (g % 6000))::text, 8, '0'),
       DATE '2019-07-22' + (g % 2400)
FROM generate_series(1, 15000) AS g;

CREATE INDEX product_lookup_codes_code_idx
    ON catalog.product_lookup_codes (lookup_code);

-- DEFECT the-children-are-listed-in-a-comma-separated-column-on-the-parent
--
-- The drops on a round are held as a comma separated list of references in one
-- column on the round. Nothing can join to them and nothing checks them.
--
-- The manifest was built to be printed, and a printed manifest is a line of
-- text, so a line of text is what was stored. Reporting then needed the drops
-- individually and got them by splitting the string, which works until a
-- reference is mistyped, at which point the split produces a value that looks
-- like a drop reference and matches no drop. There is no foreign key because a
-- foreign key cannot be declared on a substring, and there is no constraint
-- because whatever the loader writes is by definition well formed text.
--
-- Measured: 3,600 round manifests naming 18,000 drop references, of which 720
-- match no row in the drop point table.
--
-- The list wants to be a table with one row per drop and a foreign key. The
-- manifest still prints correctly, because printing is concatenation and the
-- bad references print exactly as well as the good ones.
CREATE TABLE fulfilment.drop_points (
    drop_ref   varchar(12) PRIMARY KEY,
    postcode   varchar(10) NOT NULL,
    depot_code varchar(12) NOT NULL
);

CREATE TABLE ops.round_manifests (
    manifest_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    round_ref   varchar(16) NOT NULL,
    run_on      date NOT NULL,
    drop_refs   varchar(80) NOT NULL
);

INSERT INTO fulfilment.drop_points (drop_ref, postcode, depot_code)
SELECT 'DRP-' || lpad(g::text, 6, '0'),
       'CR' || lpad((g % 90)::text, 2, '0') || ' ' || (1 + (g % 9)) || 'JT',
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0')
FROM generate_series(1, 4000) AS g;

-- Five drops a round. Every fifth one was typed from a paper note.
INSERT INTO ops.round_manifests (round_ref, run_on, drop_refs)
SELECT 'RND-' || lpad(g::text, 8, '0'),
       DATE '2026-04-01' + (g % 170),
       'DRP-' || lpad((1 + (g % 4000))::text, 6, '0') || ',' ||
       'DRP-' || lpad((1 + ((g + 800) % 4000))::text, 6, '0') || ',' ||
       'DRP-' || lpad((1 + ((g + 1600) % 4000))::text, 6, '0') || ',' ||
       'DRP-' || lpad((1 + ((g + 2400) % 4000))::text, 6, '0') || ',' ||
       CASE WHEN g % 5 = 0
            THEN 'DRP-' || lpad((9000 + (g % 600))::text, 6, '0')
            ELSE 'DRP-' || lpad((1 + ((g + 3200) % 4000))::text, 6, '0')
       END
FROM generate_series(1, 3600) AS g;

-- DEFECT the-job-table-names-functions-that-no-longer-exist
--
-- The scheduler reads the job table and calls what it finds there by name.
-- Sixty of the two hundred and forty rows name a function that was dropped.
--
-- Jobs are added to the table by whoever writes the function and removed from
-- it by nobody. Dropping the function is a migration; deleting the row is a
-- data change in a table no migration touches, and the two were never done
-- together. The scheduler builds the call with EXECUTE, so a missing function
-- is a runtime error rather than something the database could have refused
-- when the job was written. The error is caught by the scheduler's retry loop,
-- which retries it every fifteen minutes for ever.
--
-- Measured: 240 job definitions of which 60 name a function that does not
-- exist in the catalogue.
--
-- The names want resolving to regprocedure at write time, or the table wants
-- to hold nothing but jobs the scheduler has proved it can call. Every row is
-- well formed and the enabled flag is true, so the table reads as a list of
-- two hundred and forty working jobs.
CREATE TABLE ops.job_definitions (
    job_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    job_name      varchar(40) NOT NULL,
    routine_name  varchar(80) NOT NULL,
    every_minutes integer NOT NULL,
    enabled       boolean NOT NULL
);

INSERT INTO ops.job_definitions (job_name, routine_name, every_minutes, enabled)
SELECT 'Job ' || g,
       CASE WHEN g % 4 = 0
            THEN 'ops.fn_retired_rollup_' || (1 + (g % 15)) || '()'
            ELSE (ARRAY['ops.fn_purge_old_events(timestamptz)',
                        'supply.fn_rebuild_reorder_points()',
                        'ops.fn_rebuild_pick_faces()'])[1 + (g % 3)]
       END,
       15 * (1 + (g % 8)),
       true
FROM generate_series(1, 240) AS g;

-- DEFECT the-running-balance-is-an-integer-and-is-close-to-its-ceiling
--
-- The running ledger balance is held in pence in a four byte integer. The
-- largest balance is two thousand and sixty million and the ceiling is two
-- thousand one hundred and forty seven million.
--
-- Pence in an integer is a sound choice up to about twenty one million pounds,
-- which was comfortable when the ledger held one trading company. It now holds
-- the group, the balance is cumulative and never resets, and it has grown by
-- about a hundred and forty million pence a year for the last three years. The
-- overflow is not a wrong answer: it is an error at insert time, in the
-- overnight ledger run, which stops the run and leaves the day half posted.
--
-- Measured: 1,200 ledger balances whose maximum is 2,060,000,000 pence against
-- an integer ceiling of 2,147,483,647.
--
-- The column wants to be bigint, which is a rewrite of a small table and an
-- hour of downtime nobody has scheduled. Nothing is wrong today and every
-- balance in the table is correct.
CREATE TABLE payments.ledger_running_totals (
    ledger_ref varchar(12) PRIMARY KEY,
    balance_p  integer NOT NULL,
    as_at      date NOT NULL
);

INSERT INTO payments.ledger_running_totals (ledger_ref, balance_p, as_at)
SELECT 'LGR-' || lpad(g::text, 6, '0'),
       2060000000 - ((g - 1) * 1000000),
       DATE '2026-09-01'
FROM generate_series(1, 1200) AS g;

-- DEFECT the-merge-marked-the-loser-and-nothing-reads-the-mark
--
-- Six hundred wholesale accounts were merged into another account. The merge
-- wrote the target on the losing row and left it active, and nothing since
-- reads that column.
--
-- The merge was designed in two halves: mark the loser, then move its history
-- and deactivate it. The second half was a separate job that was run once, on
-- a sample, and then the project moved to another team. Every screen that
-- lists accounts filters on the active flag, which is still true on all six
-- hundred, so the same customer appears twice in the account picker with two
-- credit limits, and which one a salesperson picks decides how much that
-- customer can order.
--
-- Measured: 4,800 wholesale accounts of which 600 name a merge target and are
-- still marked active.
--
-- Deactivating the marked rows is one statement, and it is one statement
-- nobody will run without knowing which of the two accounts the open orders
-- are on. Both rows are valid accounts with valid histories, so no integrity
-- check has ever objected.
CREATE TABLE storefront.wholesale_accounts (
    account_ref  varchar(12) PRIMARY KEY,
    trading_name varchar(80) NOT NULL,
    credit_p     integer NOT NULL,
    merged_into  varchar(12),
    is_active    boolean NOT NULL
);

INSERT INTO storefront.wholesale_accounts (account_ref, trading_name, credit_p, merged_into, is_active)
SELECT 'WHL-' || lpad(g::text, 7, '0'),
       'Trading name ' || g,
       50000 + (g % 900000),
       CASE WHEN g % 8 = 0
            THEN 'WHL-' || lpad((1 + ((g + 3) % 4800))::text, 7, '0')
            ELSE NULL
       END,
       true
FROM generate_series(1, 4800) AS g;

-- DEFECT the-extract-kept-the-test-filter-so-only-one-region-ever-loaded
--
-- The market price extract was written with a region filter so that it could
-- be tested against one region. The filter is still there.
--
-- The filter was in the WHERE clause of the source query, hard coded to the
-- north west because that was the smallest region and the test ran in a
-- minute. It was never taken out, and the load has run nightly ever since,
-- reporting the number of rows it loaded, which is a real number and is
-- consistent night to night. The pricing team compares Cross River's prices
-- against the market and the market it compares against is one region of
-- eight. Where that region is cheap, the whole estate is repriced down.
--
-- Measured: 1,800 market price rows covering 1 region of the 8 the extract is
-- documented as loading.
--
-- Removing the filter is a one line change and it will multiply the table by
-- eight, which is why it needs a conversation about what happens to the
-- comparisons already published. The table is complete and correct for the
-- region it holds, so every check of its contents passes.
CREATE TABLE analytics.market_prices (
    price_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region_code varchar(4) NOT NULL,
    sku         varchar(16) NOT NULL,
    price_p     integer NOT NULL,
    week_start  date NOT NULL
);

INSERT INTO analytics.market_prices (region_code, sku, price_p, week_start)
SELECT 'NW',
       'SKU-' || lpad((1 + (g % 600))::text, 8, '0'),
       300 + (g % 12000),
       DATE '2026-01-05' + ((g % 36) * 7)
FROM generate_series(1, 1800) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.job_runs ADD COLUMN job_id integer;

WITH p AS (
    SELECT job_id AS v, row_number() OVER (ORDER BY job_id) - 1 AS k
      FROM ops.job_definitions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.job_definitions)
                 * power((abs(hashtext('ops.job_runs:' || concat_ws('|', x.job_name, x.status, x.attempt, x.detail, x.outcome_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.job_runs x
)
UPDATE ops.job_runs t
   SET job_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.job_runs ALTER COLUMN job_id SET NOT NULL;
ALTER TABLE ops.job_runs ADD CONSTRAINT job_runs_job_id_fkey FOREIGN KEY (job_id) REFERENCES ops.job_definitions (job_id);
CREATE INDEX ix_job_runs_job_id ON ops.job_runs (job_id);

ALTER TABLE payments.ledger_running_totals ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.ledger_running_totals:' || concat_ws('|', x.ledger_ref, x.balance_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.ledger_running_totals x
)
UPDATE payments.ledger_running_totals t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.ledger_running_totals ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.ledger_running_totals ADD CONSTRAINT ledger_running_totals_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_ledger_running_totals_transaction_id ON payments.ledger_running_totals (transaction_id);

ALTER TABLE storefront.trade_account_contacts ADD COLUMN account_ref character varying(12);

WITH p AS (
    SELECT account_ref AS v, row_number() OVER (ORDER BY account_ref) - 1 AS k
      FROM storefront.wholesale_accounts
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.wholesale_accounts)
                 * power((abs(hashtext('storefront.trade_account_contacts:' || concat_ws('|', x.account_no, x.full_name, x.email))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.trade_account_contacts x
)
UPDATE storefront.trade_account_contacts t
   SET account_ref = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.trade_account_contacts ALTER COLUMN account_ref SET NOT NULL;
ALTER TABLE storefront.trade_account_contacts ADD CONSTRAINT trade_account_contacts_account_ref_fkey FOREIGN KEY (account_ref) REFERENCES storefront.wholesale_accounts (account_ref);
CREATE INDEX ix_trade_account_contacts_account_ref ON storefront.trade_account_contacts (account_ref);

ALTER TABLE storefront.wholesale_accounts ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('storefront.wholesale_accounts:' || concat_ws('|', x.account_ref, x.trading_name, x.credit_p, x.merged_into, x.is_active))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.wholesale_accounts x
)
UPDATE storefront.wholesale_accounts t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.wholesale_accounts ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE storefront.wholesale_accounts ADD CONSTRAINT wholesale_accounts_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_wholesale_accounts_customer_id ON storefront.wholesale_accounts (customer_id);
-- <<< relationships
