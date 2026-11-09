-- Cross River Trading Co. -- escalation levels, overseas invoices, exception
-- queue, item search keys, wave closes, sales by region
-- author: T. Marchetti
-- postgres: 18
--
-- How far a case has been escalated, an invoice raised abroad, the exceptions
-- the warehouse has to clear, the keys an item is found by, the closing of a
-- picking wave, and the sales figures cut by region.

-- DEFECT the-enum-ran-out-and-the-overflow-went-into-a-free-text-column
--
-- Escalation levels were an enumerated list of four. A fifth was needed, adding
-- to the enum was a schema change nobody wanted during peak, and a free text
-- column was added beside it to hold the ones that did not fit.
--
-- So the level of an escalation is in one of two columns, and which one depends
-- on when it was raised and how far it went. The enum column is not null, so an
-- escalation at the fifth level holds the fourth in the enum and the real level
-- in the text, and it reads as a level four escalation to everything that does
-- not know about the second column. The queue that the directors watch is
-- filtered on the enum.
--
-- Measured: 3,200 escalations, of which 480 hold an override level in the free
-- text column that contradicts the enum column on the same row.
--
-- One column, with the fifth value added to it, and the schema change taken.
-- Both columns are populated and both are readable, so the contradiction is
-- only visible to somebody who selects them together, which no screen does.
CREATE TYPE support.escalation_level AS ENUM ('none', 'team_lead', 'manager', 'director');

CREATE TABLE support.escalation_levels (
    escalation_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref      varchar(16) NOT NULL,
    level         support.escalation_level NOT NULL,
    level_override varchar(20),
    raised_on     date NOT NULL
);

INSERT INTO support.escalation_levels (case_ref, level, level_override, raised_on)
SELECT 'ESC-' || lpad(g::text, 8, '0'),
       (ARRAY['none', 'team_lead', 'manager', 'director'])[1 + (g % 4)]::support.escalation_level,
       NULL,
       DATE '2025-05-01' + (g % 500)
FROM generate_series(1, 2720) AS g;

-- The fifth level, which did not fit.
INSERT INTO support.escalation_levels (case_ref, level, level_override, raised_on)
SELECT 'ESC-' || lpad((500000 + g)::text, 8, '0'),
       'director'::support.escalation_level,
       'board',
       DATE '2026-01-05' + (g % 250)
FROM generate_series(1, 480) AS g;

-- DEFECT two-currencies-in-one-amount-column-with-no-currency-on-the-row
--
-- Overseas invoices are raised in sterling and in euro. The amount column holds
-- both and there is no currency column.
--
-- The currency was going to be added when the second market opened and the
-- invoice numbering was changed instead, so a euro invoice can be told from a
-- sterling one by the prefix on its reference and by nothing else. Every sum
-- over this column adds sterling to euro. The totals are wrong by the exchange
-- rate on the euro share, they have always been wrong, and they move with the
-- rate in a way that looks like trading performance.
--
-- Measured: 4,000 overseas invoices, of which 1,000 are in euro, identifiable
-- only by the EU prefix on the invoice reference, in a table with no currency
-- column.
--
-- A currency column, NOT NULL, with a constraint on the values it may hold, and
-- the totals grouped by it. The reference prefix works and is used by the three
-- people who know about it, which is why this has never been raised as a data
-- problem rather than a reporting one.
CREATE TABLE payments.overseas_invoices (
    invoice_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_ref varchar(20) NOT NULL UNIQUE,
    account_ref varchar(12) NOT NULL,
    amount      numeric(14,2) NOT NULL,
    raised_on   date NOT NULL
);

INSERT INTO payments.overseas_invoices (invoice_ref, account_ref, amount, raised_on)
SELECT 'GB-' || lpad(g::text, 10, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       (300 + (g % 9000))::numeric(14,2),
       DATE '2025-09-01' + (g % 380)
FROM generate_series(1, 3000) AS g;

INSERT INTO payments.overseas_invoices (invoice_ref, account_ref, amount, raised_on)
SELECT 'EU-' || lpad(g::text, 10, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       (300 + (g % 9000))::numeric(14,2),
       DATE '2025-09-01' + (g % 380)
FROM generate_series(1, 1000) AS g;

-- DEFECT the-partial-index-excludes-exactly-the-rows-the-query-asks-for
--
-- The exception queue has a partial index WHERE cleared_at IS NOT NULL. Every
-- query against the queue asks for the exceptions that are not cleared.
--
-- The index was written the wrong way round. It covers the cleared exceptions,
-- which is the large and growing part of the table and the part nobody reads,
-- and it excludes the open ones, which is the small part every screen in the
-- warehouse polls every thirty seconds. Those polls read the whole table. The
-- index is maintained on every clear and used by nothing.
--
-- Measured: 20,000 exceptions, 19,200 of them cleared and covered by the
-- partial index, and 800 open and excluded from it.
--
-- WHERE cleared_at IS NULL is the index, and it would be eight hundred rows
-- rather than nineteen thousand. There is an index on the column in the
-- catalogue, so the table reads as indexed to anybody checking a list.
CREATE TABLE ops.exception_queue (
    exception_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code   varchar(12) NOT NULL,
    reason       varchar(60) NOT NULL,
    raised_at    timestamptz NOT NULL,
    cleared_at   timestamptz
);

CREATE INDEX exception_queue_cleared_idx
    ON ops.exception_queue (raised_at)
    WHERE cleared_at IS NOT NULL;

INSERT INTO ops.exception_queue (depot_code, reason, raised_at, cleared_at)
SELECT 'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       'Exception ' || (1 + (g % 30)),
       TIMESTAMPTZ '2026-04-01 06:00:00+01' + (g * INTERVAL '7 minutes'),
       CASE WHEN g % 25 = 0 THEN NULL
            ELSE TIMESTAMPTZ '2026-04-01 06:00:00+01' + (g * INTERVAL '7 minutes') + INTERVAL '4 hours'
       END
FROM generate_series(1, 20000) AS g;

-- DEFECT a-generated-column-was-frozen-into-a-plain-one-during-a-restore
--
-- The item search key was a generated column, derived from the description. A
-- restore from a logical dump brought it back as a plain column holding the
-- values it had at the time.
--
-- A generated column is restored as a plain column when the dump is taken with
-- the option that writes data for every column, which is what the restore
-- script used. It looked identical afterwards: same name, same type, same
-- values. It stopped updating. Every description edited since has a search key
-- describing the old description, and there is nothing in the schema to say
-- that column was ever supposed to maintain itself.
--
-- Measured: 5,000 item search keys, of which 1,000 no longer match the
-- description they are derived from, and the column is not generated.
--
-- Recreating it as a generated column recomputes every row and puts the
-- derivation back in the schema where it can be read. The search still finds
-- most things, because most descriptions have not been edited, so it is a
-- search that quietly fails on the newest products.
CREATE TABLE catalog.item_search_keys (
    item_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    description varchar(120) NOT NULL,
    search_key  varchar(120) NOT NULL,
    edited_on   date NOT NULL
);

INSERT INTO catalog.item_search_keys (description, search_key, edited_on)
SELECT 'Item ' || g || ' standard',
       lower('Item ' || g || ' standard'),
       DATE '2024-01-08' + (g % 500)
FROM generate_series(1, 5000) AS g;

-- The descriptions edited after the restore.
UPDATE catalog.item_search_keys
SET description = 'Item ' || item_id || ' revised',
    edited_on   = DATE '2026-04-01' + (item_id % 150)
WHERE item_id % 5 = 0;

-- DEFECT the-procedure-catches-every-error-and-reports-success
--
-- The wave close function wraps its body in an exception handler that catches
-- everything and returns the success value anyway.
--
-- The handler was added because a transient lock timeout was failing the
-- overnight run and somebody wanted the run to finish. It catches the lock
-- timeout and it catches everything else: a wave whose lines cannot be closed
-- because they were never picked returns closed, and the caller records it as
-- closed, and the lines stay open. The only trace is in the wave close log,
-- which stores the reported outcome and not the real one.
--
-- Measured: 900 waves logged as closed, of which 180 still have unpicked lines
-- against them.
--
-- Catching the lock timeout by name, and letting everything else out, is the
-- fix and it is four characters different. The overnight run has not failed in
-- two years, which is the evidence everybody cites for it working.
CREATE TABLE fulfilment.picking_waves (
    wave_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wave_ref   varchar(16) NOT NULL UNIQUE,
    depot_code varchar(12) NOT NULL,
    opened_on  date NOT NULL
);

CREATE TABLE fulfilment.picking_wave_lines (
    line_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wave_id  integer NOT NULL REFERENCES fulfilment.picking_waves (wave_id),
    sku      varchar(20) NOT NULL,
    picked   boolean NOT NULL
);

CREATE TABLE fulfilment.wave_close_log (
    log_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    wave_id    integer NOT NULL,
    outcome    varchar(12) NOT NULL,
    closed_at  timestamptz NOT NULL
);

INSERT INTO fulfilment.picking_waves (wave_ref, depot_code, opened_on)
SELECT 'WAV-' || lpad(g::text, 8, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-05-04' + (g % 120)
FROM generate_series(1, 900) AS g;

INSERT INTO fulfilment.picking_wave_lines (wave_id, sku, picked)
SELECT w.wave_id,
       'SKU-' || lpad((1 + ((w.wave_id * 7 + s) % 700))::text, 6, '0'),
       w.wave_id % 5 <> 0
FROM fulfilment.picking_waves AS w
CROSS JOIN generate_series(1, 8) AS s;

CREATE FUNCTION fulfilment.fn_close_wave(p_wave_id integer) RETURNS varchar
LANGUAGE plpgsql AS $$
BEGIN
    IF EXISTS (SELECT 1 FROM fulfilment.picking_wave_lines
               WHERE wave_id = p_wave_id AND NOT picked) THEN
        RAISE EXCEPTION 'wave % has unpicked lines', p_wave_id;
    END IF;

    RETURN 'closed';
EXCEPTION
    WHEN OTHERS THEN
        RETURN 'closed';
END;
$$;

INSERT INTO fulfilment.wave_close_log (wave_id, outcome, closed_at)
SELECT wave_id,
       fulfilment.fn_close_wave(wave_id),
       TIMESTAMPTZ '2026-09-01 02:00:00+01' + (wave_id * INTERVAL '3 seconds')
FROM fulfilment.picking_waves;

-- DEFECT the-lookup-table-has-no-rows-and-the-join-throws-everything-away
--
-- The sales by region view inner joins the sales rows to a region lookup table.
-- The lookup table is empty.
--
-- It was created by the migration that introduced the view and was to be
-- populated by a separate load that never ran, because the load was owned by
-- the team that was reorganised that quarter. An inner join to an empty table
-- returns nothing, so the view returns nothing, and the report that reads it
-- shows a blank page rather than an error. A blank report reads as a quiet
-- period, and it has read as one for four months.
--
-- Measured: 7,200 regional sales rows, 0 rows in the region lookup, and 0 rows
-- out of the view.
--
-- Populating the lookup is the fix and a left join would at least have shown
-- the sales with an unknown region. The view compiles, runs and returns cleanly
-- every time, which is why nothing monitoring it has ever gone red.
CREATE TABLE analytics.region_lookup (
    region_code varchar(8) PRIMARY KEY,
    region_name varchar(60) NOT NULL
);

CREATE TABLE analytics.regional_sales (
    sale_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    region_code varchar(8) NOT NULL,
    sold_on     date NOT NULL,
    net         numeric(12,2) NOT NULL
);

INSERT INTO analytics.regional_sales (region_code, sold_on, net)
SELECT 'RG-' || lpad((1 + (g % 12))::text, 3, '0'),
       DATE '2026-05-01' + (g % 140),
       (40 + (g % 5000))::numeric(12,2)
FROM generate_series(1, 7200) AS g;

CREATE VIEW analytics.v_sales_by_region AS
SELECT l.region_name,
       sum(s.net) AS net
FROM analytics.regional_sales AS s
JOIN analytics.region_lookup AS l ON l.region_code = s.region_code
GROUP BY l.region_name;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.item_search_keys ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.item_search_keys:' || concat_ws('|', x.description, x.search_key))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.item_search_keys x
)
UPDATE catalog.item_search_keys t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.item_search_keys ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.item_search_keys ADD CONSTRAINT item_search_keys_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_item_search_keys_product_id ON catalog.item_search_keys (product_id);

ALTER TABLE payments.overseas_invoices ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('payments.overseas_invoices:' || concat_ws('|', x.invoice_ref, x.account_ref, x.amount))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.overseas_invoices x
)
UPDATE payments.overseas_invoices t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.overseas_invoices ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE payments.overseas_invoices ADD CONSTRAINT overseas_invoices_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_overseas_invoices_customer_id ON payments.overseas_invoices (customer_id);

ALTER TABLE support.escalation_levels ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.escalation_levels:' || concat_ws('|', x.case_ref, x.level, x.level_override))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.escalation_levels x
)
UPDATE support.escalation_levels t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.escalation_levels ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.escalation_levels ADD CONSTRAINT escalation_levels_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_escalation_levels_ticket_id ON support.escalation_levels (ticket_id);
-- <<< relationships
