-- Cross River Trading Co. -- stock corrections, saved cards, price cache,
-- generator readings, drop notes, share of spend
-- author: T. Marchetti
-- postgres: 18
--
-- A correction to a stock figure, a card a customer has saved, the prices the
-- storefront reads, the meter on a depot generator, the note that goes with a
-- drop, and how much of an account's spend goes to each category.

-- DEFECT the-trigger-was-disabled-for-a-backfill-and-left-that-way
--
-- The audit trigger on stock corrections was disabled to let a backfill run
-- overnight and nobody enabled it again.
--
-- The backfill rewrote two years of corrections and the trigger would have
-- written an audit row for each one, which would have taken the run past the
-- maintenance window. Disabling it was the right call. Enabling it was a line
-- in a runbook that the person following the runbook had already closed. Every
-- correction made since has no audit row, and the audit table is not empty, so
-- nothing looking at it sees a gap: it sees a table with rows in it that stops
-- partway through last year.
--
-- Measured: 7,200 stock corrections, of which 2,400 have an audit row and
-- 4,800 do not, with the trigger present and disabled.
--
-- ENABLE TRIGGER is one statement and the missing audit rows can be
-- reconstructed from the corrections themselves, which is the argument for
-- leaving it. The trigger shows in every listing of triggers on the table, so
-- a review that asks whether corrections are audited gets a yes.
CREATE TABLE supply.stock_corrections (
    correction_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku           varchar(20) NOT NULL,
    depot_code    varchar(12) NOT NULL,
    delta         integer NOT NULL,
    corrected_on  date NOT NULL
);

CREATE TABLE supply.stock_correction_audit (
    audit_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    correction_id integer NOT NULL,
    written_at    timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION supply.fn_audit_stock_correction() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO supply.stock_correction_audit (correction_id)
    VALUES (NEW.correction_id);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_audit_stock_correction AFTER INSERT ON supply.stock_corrections
    FOR EACH ROW EXECUTE FUNCTION supply.fn_audit_stock_correction();

INSERT INTO supply.stock_corrections (sku, depot_code, delta, corrected_on)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       (g % 41) - 20,
       DATE '2024-11-04' + (g % 300)
FROM generate_series(1, 2400) AS g;

-- Disabled for the backfill.
ALTER TABLE supply.stock_corrections DISABLE TRIGGER trg_audit_stock_correction;

INSERT INTO supply.stock_corrections (sku, depot_code, delta, corrected_on)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       (g % 41) - 20,
       DATE '2025-09-02' + (g % 380)
FROM generate_series(1, 4800) AS g;

-- DEFECT the-grant-was-given-to-a-group-nobody-tracks-membership-of
--
-- Select on the saved cards table was granted to a group role. Nobody keeps a
-- list of who is in that group.
--
-- The group was created to hold the depot staff who needed read access during
-- a stock take, three years ago. Membership is managed by adding a role to it,
-- which anybody with the right to create roles can do, and nothing has ever
-- removed anybody. Two of its members are themselves group roles, so the
-- effective list is longer than the direct membership suggests and reading the
-- grant tells you nothing about who can use it. The table holds card tokens
-- and expiry dates.
--
-- Measured: 3,000 saved card rows, readable through one group grant whose
-- membership is 4 roles directly and 6 roles once nested membership is
-- followed.
--
-- Granting to the two application roles that need it, and dropping the group,
-- makes the access list the grant itself. The grant is to a named role rather
-- than PUBLIC, so it passes every review that looks for public grants.
CREATE ROLE depot_staff NOLOGIN;
CREATE ROLE depot_staff_nights NOLOGIN;
CREATE ROLE depot_staff_days NOLOGIN;
CREATE ROLE stocktake_temp NOLOGIN;
CREATE ROLE stocktake_temp_2024 NOLOGIN;
CREATE ROLE stocktake_temp_2025 NOLOGIN;
CREATE ROLE night_supervisors NOLOGIN;

GRANT depot_staff TO depot_staff_nights;
GRANT depot_staff TO depot_staff_days;
GRANT depot_staff TO stocktake_temp;
GRANT depot_staff TO night_supervisors;
GRANT stocktake_temp TO stocktake_temp_2024;
GRANT stocktake_temp TO stocktake_temp_2025;

CREATE TABLE storefront.saved_cards (
    card_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    card_token  varchar(40) NOT NULL,
    expires_on  date NOT NULL
);

INSERT INTO storefront.saved_cards (account_ref, card_token, expires_on)
SELECT 'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       'tok_' || lpad(g::text, 20, '0'),
       DATE '2027-01-31' + ((g % 36) * 30)
FROM generate_series(1, 3000) AS g;

GRANT SELECT ON storefront.saved_cards TO depot_staff;

-- DEFECT the-cache-table-is-written-by-one-path-and-bypassed-by-another
--
-- The storefront reads prices from a cache table. One of the two things that
-- change a price writes the cache and the other does not.
--
-- The cache is refreshed by the pricing service whenever a price is changed
-- through the pricing screen. Bulk price loads go straight into the price
-- table, because the loader predates the cache and was never told about it.
-- The cache is otherwise correct, so nothing about it looks stale, and the
-- rows it is wrong on are exactly the rows a bulk load touched, which are the
-- seasonal ranges and the clearance lines.
--
-- Measured: 6,000 prices with 6,000 cache rows, of which 1,200 hold a price
-- the price table no longer agrees with.
--
-- One write path, or a trigger on the price table, or dropping the cache and
-- reading the prices. The cache has a row for every product and a recent
-- timestamp on every row, so every check of its completeness and freshness
-- passes.
CREATE TABLE catalog.current_prices (
    price_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku       varchar(20) NOT NULL UNIQUE,
    price_p   integer NOT NULL,
    set_on    date NOT NULL
);

CREATE TABLE catalog.price_cache (
    sku         varchar(20) PRIMARY KEY,
    price_p     integer NOT NULL,
    refreshed_at timestamptz NOT NULL
);

INSERT INTO catalog.current_prices (sku, price_p, set_on)
SELECT 'SKU-' || lpad(g::text, 6, '0'),
       200 + (g % 12000),
       DATE '2026-03-02' + (g % 180)
FROM generate_series(1, 6000) AS g;

INSERT INTO catalog.price_cache (sku, price_p, refreshed_at)
SELECT sku, price_p, TIMESTAMPTZ '2026-09-18 03:00:00+01'
FROM catalog.current_prices;

-- The bulk load, which goes straight into the price table.
UPDATE catalog.current_prices
SET price_p = price_p - 50,
    set_on  = DATE '2026-09-19'
WHERE price_id % 5 = 0;

-- DEFECT the-trigger-fires-per-row-on-a-table-loaded-in-bulk
--
-- The generator readings table has a per-row trigger on it and it is loaded
-- forty eight thousand rows at a time.
--
-- The trigger keeps a per-depot latest reading table up to date, which is the
-- right thing to keep and the wrong place to keep it from. The readings arrive
-- as a nightly file from the telemetry supplier and go in as one COPY. The
-- trigger runs once per row, so the load does forty eight thousand single-row
-- upserts against a forty-row table, every one of them contending on the same
-- forty pages. The load takes hours and the only thing that has changed about
-- it in two years is that it starts earlier.
--
-- Measured: 48,000 generator readings and 48,000 trigger firings recorded
-- against a latest-reading table of 40 rows.
--
-- A statement-level trigger over the transition table does the same work once.
-- The latest reading table is correct after every load, so the trigger is
-- doing its job, which is why the cost of it has never been the thing anybody
-- looked at.
CREATE TABLE ops.generator_readings (
    reading_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code varchar(12) NOT NULL,
    read_at    timestamptz NOT NULL,
    kwh        integer NOT NULL
);

CREATE TABLE ops.generator_latest (
    depot_code   varchar(12) PRIMARY KEY,
    last_read_at timestamptz NOT NULL,
    last_kwh     integer NOT NULL,
    write_count  integer NOT NULL DEFAULT 0
);

CREATE FUNCTION ops.fn_track_generator_reading() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.generator_latest (depot_code, last_read_at, last_kwh, write_count)
    VALUES (NEW.depot_code, NEW.read_at, NEW.kwh, 1)
    ON CONFLICT (depot_code) DO UPDATE
    SET last_read_at = EXCLUDED.last_read_at,
        last_kwh     = EXCLUDED.last_kwh,
        write_count  = ops.generator_latest.write_count + 1;
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_track_generator_reading AFTER INSERT ON ops.generator_readings
    FOR EACH ROW EXECUTE FUNCTION ops.fn_track_generator_reading();

INSERT INTO ops.generator_readings (depot_code, read_at, kwh)
SELECT 'DEP-' || lpad(d::text, 3, '0'),
       TIMESTAMPTZ '2026-08-01 00:00:00+01' + (n * INTERVAL '30 minutes'),
       40 + ((d * 3 + n) % 260)
FROM generate_series(1, 40) AS d
CROSS JOIN generate_series(0, 1199) AS n;

-- DEFECT the-child-rows-were-never-granted-with-the-parent
--
-- The reporting role can read drop notes and cannot read the lines on them.
--
-- The grant was written when the notes table was the whole thing. The lines
-- table came later, in a migration that added the table and forgot the grant,
-- which is easy because nothing ties one to the other. A report that joins the
-- two fails with a permission denied on the lines table, and the report that
-- only reads the header works, so the role appears to have access. The team
-- that owns the reports works around it by reading the header and counting the
-- lines from a different table that happens to hold a line count.
--
-- Measured: 2,400 drop notes and 9,600 lines, where report_reader holds select
-- on the notes and not on the lines.
--
-- One GRANT, and default privileges on the schema so the next table does not
-- repeat it. The header is readable, so every check of the form can this role
-- see drop notes returns true.
CREATE TABLE fulfilment.drop_notes (
    note_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    note_ref   varchar(16) NOT NULL UNIQUE,
    depot_code varchar(12) NOT NULL,
    dropped_on date NOT NULL
);

CREATE TABLE fulfilment.drop_note_lines (
    line_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    note_id  integer NOT NULL REFERENCES fulfilment.drop_notes (note_id),
    sku      varchar(20) NOT NULL,
    quantity integer NOT NULL
);

INSERT INTO fulfilment.drop_notes (note_ref, depot_code, dropped_on)
SELECT 'DRN-' || lpad(g::text, 8, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       DATE '2026-04-06' + (g % 160)
FROM generate_series(1, 2400) AS g;

INSERT INTO fulfilment.drop_note_lines (note_id, sku, quantity)
SELECT n.note_id,
       'SKU-' || lpad((1 + ((n.note_id * 13 + s) % 700))::text, 6, '0'),
       1 + ((n.note_id + s) % 20)
FROM fulfilment.drop_notes AS n
CROSS JOIN generate_series(1, 4) AS s;

GRANT SELECT ON fulfilment.drop_notes TO report_reader;

-- DEFECT the-percentage-is-stored-as-an-integer-so-a-third-is-thirty-three
--
-- The share of spend per category is stored as a whole number of percent. The
-- shares for an account are supposed to add to a hundred and they do not.
--
-- The column is an integer because the first report rounded to whole percent
-- and the column was made to fit the report. Each share is computed and
-- truncated on its own, so an account whose spend splits three ways loses one
-- percent, and an account that splits seven ways loses up to six. The total row
-- is computed separately from the real amounts, so it says a hundred, and the
-- category rows beneath it do not add to it.
--
-- Measured: 2,800 share rows over 400 accounts, of which all 400 accounts
-- have category shares adding to less than 100.
--
-- Storing the amount and computing the share at read time, or a numeric with
-- two decimal places, removes it. Every individual share is within one percent
-- of the truth, which is why this reads as rounding rather than as a column
-- that cannot hold the answer.
CREATE TABLE analytics.share_of_spend (
    share_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref  varchar(12) NOT NULL,
    category     varchar(40) NOT NULL,
    spend_p      integer NOT NULL,
    share_pct    integer NOT NULL
);

INSERT INTO analytics.share_of_spend (account_ref, category, spend_p, share_pct)
WITH spend AS (
    SELECT 'ACC-' || lpad(a::text, 5, '0') AS account_ref,
           'Category ' || c AS category,
           1000 + ((a * 17 + c * 23) % 9000) AS spend_p,
           a AS a
    FROM generate_series(1, 400) AS a
    CROSS JOIN generate_series(1, 7) AS c
)
SELECT account_ref,
       category,
       spend_p,
       (spend_p * 100) / sum(spend_p) OVER (PARTITION BY account_ref)
FROM spend;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.current_prices ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.current_prices:' || concat_ws('|', x.sku, x.price_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.current_prices x
)
UPDATE catalog.current_prices t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.current_prices ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.current_prices ADD CONSTRAINT current_prices_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_current_prices_product_id ON catalog.current_prices (product_id);

ALTER TABLE ops.generator_readings ADD COLUMN meter_id integer;

WITH p AS (
    SELECT meter_id AS v, row_number() OVER (ORDER BY meter_id) - 1 AS k
      FROM ops.meters
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.meters)
                 * power((abs(hashtext('ops.generator_readings:' || concat_ws('|', x.depot_code, x.kwh))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.generator_readings x
)
UPDATE ops.generator_readings t
   SET meter_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.generator_readings ALTER COLUMN meter_id SET NOT NULL;
ALTER TABLE ops.generator_readings ADD CONSTRAINT generator_readings_meter_id_fkey FOREIGN KEY (meter_id) REFERENCES ops.meters (meter_id);
CREATE INDEX ix_generator_readings_meter_id ON ops.generator_readings (meter_id);

ALTER TABLE storefront.saved_cards ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('storefront.saved_cards:' || concat_ws('|', x.account_ref, x.card_token))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.saved_cards x
)
UPDATE storefront.saved_cards t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.saved_cards ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE storefront.saved_cards ADD CONSTRAINT saved_cards_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_saved_cards_customer_id ON storefront.saved_cards (customer_id);

ALTER TABLE supply.stock_corrections ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.stock_corrections:' || concat_ws('|', x.sku, x.depot_code, x.delta))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.stock_corrections x
)
UPDATE supply.stock_corrections t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.stock_corrections ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.stock_corrections ADD CONSTRAINT stock_corrections_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_stock_corrections_purchase_order_id ON supply.stock_corrections (purchase_order_id);
-- <<< relationships
