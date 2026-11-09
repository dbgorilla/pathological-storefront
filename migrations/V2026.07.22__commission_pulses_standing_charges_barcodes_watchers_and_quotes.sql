-- Cross River Trading Co. -- commission runs, meter pulses, standing charges,
-- scanner barcodes, case watchers, vendor quotes
-- author: P. Adeyemi
-- postgres: 18
--
-- The commission statement the agents are paid from, the daily meter totals the
-- energy report charts, the standing charge diary finance works to, the barcode
-- cleanup the handhelds rely on, the watcher list on a support case, and the
-- quote file the buying system imports.

-- DEFECT numeric-cast-without-a-scale-rounds-to-whole-units
--
-- Commission is sales times the agent's rate. The rate comes off the agency
-- agreement with trailing noise on it, so the view normalises it to numeric(3)
-- before multiplying, meaning three decimal places.
--
-- numeric(3) is numeric(3,0). The number in the brackets is the precision, the
-- total count of digits, and a precision with no scale means a scale of zero.
-- So the cast does not trim the rate to three decimal places, it rounds it to a
-- whole percent: 1.50 and 2.25 both become 2, and 2.75 becomes 3. The rate is
-- still a plausible commission rate and every agent is paid against it.
--
-- Measured: 800 commission runs on seven distinct rates between 1.50 and 3.00
-- percent. 571 runs are paid at a rate the agreement does not carry, and the
-- statement total is 108,946 pounds against the 100,905 that was earned.
--
-- numeric(6,3) is three decimal places. The precision and scale read in the
-- opposite order from the way people say them out loud, which is why this is
-- worth writing out rather than trusting: numeric(3) looks like it says three
-- of something, and what it says is that there is no fractional part at all.
CREATE TABLE payments.commission_runs (
    run_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_ref   varchar(16) NOT NULL,
    period      varchar(7) NOT NULL,
    sales_cents integer NOT NULL CHECK (sales_cents >= 0),
    rate_pct    numeric(5,2) NOT NULL
);

INSERT INTO payments.commission_runs (agent_ref, period, sales_cents, rate_pct)
SELECT 'AG' || lpad((1 + g % 100)::text, 4, '0'),
       '2026-' || lpad((1 + (g / 100))::text, 2, '0'),
       120000 + (g * 4397) % 880000,
       1.50 + (g % 7) * 0.25
FROM generate_series(1, 800) AS g;

CREATE VIEW analytics.v_commission_due AS
SELECT c.run_id,
       c.agent_ref,
       c.period,
       c.sales_cents * c.rate_pct::numeric(3) / 10000 AS commission_pounds
FROM payments.commission_runs c;

-- DEFECT join-between-a-timestamp-and-a-date-matches-only-the-midnight-rows
--
-- Meter pulses carry a timestamp. The daily energy report joins them to the
-- working calendar so it can label each day, with the timestamp equated to the
-- calendar date.
--
-- Comparing a timestamp to a date promotes the date to midnight on that day, so
-- the equality holds only for a pulse recorded at exactly midnight. Every pulse
-- taken during the day fails the join and is dropped. The report is not empty,
-- because the overnight pulses do match, and it charts a plausible curve made
-- out of one reading a day.
--
-- Measured: 2,400 pulses carrying 1,438,800 units. The daily report totals
-- 59,600 units from the 100 pulses recorded at midnight and silently drops the
-- other 2,300.
--
-- The join wanted pulsed_at::date = cal_date, or a range test if the index
-- matters. A comparison between two different types that PostgreSQL will
-- promote for you is the most dangerous kind of predicate, because it neither
-- errors nor warns and the thing it does instead is nearly always wrong.
CREATE TABLE ops.working_calendar (
    cal_date   date PRIMARY KEY,
    is_working boolean NOT NULL
);

INSERT INTO ops.working_calendar (cal_date, is_working)
SELECT d::date, extract(isodow FROM d) < 6
FROM generate_series(DATE '2026-01-01', DATE '2026-12-31', INTERVAL '1 day') AS d;

CREATE TABLE ops.meter_pulses (
    pulse_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    meter_ref varchar(16) NOT NULL,
    pulsed_at timestamp NOT NULL,
    units     integer NOT NULL
);

INSERT INTO ops.meter_pulses (meter_ref, pulsed_at, units)
SELECT 'MTR-' || lpad((1 + g % 8)::text, 3, '0'),
       TIMESTAMP '2026-01-01 00:00:00' + ((g / 24) || ' days')::interval
                                       + ((g % 24) || ' hours')::interval,
       200 + (g * 137) % 800
FROM generate_series(1, 2400) AS g;

CREATE VIEW analytics.v_daily_pulse_totals AS
SELECT c.cal_date,
       c.is_working,
       sum(p.units) AS units
FROM ops.working_calendar c
JOIN ops.meter_pulses p ON p.pulsed_at = c.cal_date
GROUP BY c.cal_date, c.is_working;

-- DEFECT interval-month-arithmetic-clamps-to-the-end-of-a-short-month
--
-- The standing charge diary is built by adding one month at a time to the
-- previous due date, twelve times, starting from the first due date on the
-- account.
--
-- Adding a month to the 31st of a month lands on the last day of the next month
-- when that month is shorter, and PostgreSQL clamps rather than overflowing into
-- the month after. Because each date is computed from the one before it rather
-- than from the start, the clamp is permanent: an account due on the 31st is
-- pulled back to the 28th in February and stays on the 28th for the rest of the
-- year. It never climbs back.
--
-- Measured: 600 accounts and 7,200 due dates, of which 2,200 fall on a
-- different day of the month from the one the account was set up on. The 200
-- accounts due on the 31st are collected three days early for eleven months of
-- the year.
--
-- Computing each date from the start date, first_due + (n || ' months')::interval,
-- clamps only in the short months and recovers afterwards, which is what a
-- monthly schedule means. Every date in the diary is a real date on a plausible
-- day, and the direct debit goes out on it.
CREATE TABLE payments.standing_charges (
    charge_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(16) NOT NULL UNIQUE,
    first_due   date NOT NULL,
    amount_cents integer NOT NULL
);

INSERT INTO payments.standing_charges (account_ref, first_due, amount_cents)
SELECT 'AC' || lpad(g::text, 6, '0'),
       DATE '2026-01-01' + ((ARRAY[13, 27, 30])[1 + (g % 3)]),
       1500 + (g % 40) * 25
FROM generate_series(1, 600) AS g;

CREATE VIEW analytics.v_standing_charge_dates AS
WITH RECURSIVE diary(charge_id, n, due_on) AS (
    SELECT s.charge_id, 1, s.first_due
    FROM payments.standing_charges s
    UNION ALL
    SELECT d.charge_id, d.n + 1, (d.due_on + INTERVAL '1 month')::date
    FROM diary d
    WHERE d.n < 12
)
SELECT charge_id, n, due_on FROM diary;

-- DEFECT regexp-replace-without-the-global-flag-replaces-only-the-first-match
--
-- Barcodes come off the handhelds with stray separators in them, and the lookup
-- strips everything that is not a digit or a capital before matching.
--
-- regexp_replace replaces the first match only. The g flag is what makes it
-- replace all of them, and the fourth argument here is an empty string rather
-- than 'g'. So the first stray character is removed and every one after it
-- stays, the cleaned code still does not match the catalogue, and the scan comes
-- back as an unknown item.
--
-- Measured: 1,200 scans, 900 of which carry more than one stray character. All
-- 900 still contain one after the cleanup has run, so none of them matches the
-- catalogue and every one of them comes back as an unknown item.
--
-- The flag is one character and its absence is invisible in review, which is why
-- the argument is better left off entirely when no flags are wanted and written
-- as 'g' when they are. An empty string in the flags position reads as
-- deliberate and does nothing.
CREATE TABLE ops.scanner_barcodes (
    scan_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raw_code varchar(40) NOT NULL
);

INSERT INTO ops.scanner_barcodes (raw_code)
SELECT CASE WHEN g % 4 = 0
            THEN 'CRT-' || lpad(g::text, 6, '0')
            ELSE 'CRT-' || lpad(g::text, 6, '0') || ' /' || (g % 9)
       END
FROM generate_series(1, 1200) AS g;

CREATE VIEW analytics.v_cleaned_barcodes AS
SELECT b.scan_id,
       b.raw_code,
       regexp_replace(b.raw_code, '[^0-9A-Z]', '', '') AS cleaned_code
FROM ops.scanner_barcodes b;

-- DEFECT array-agg-over-a-left-join-produces-an-array-holding-null
--
-- The watcher list on a support case is built by aggregating the watchers over a
-- left join, so cases with nobody watching still appear.
--
-- array_agg does not skip nulls the way sum() and count() do. A case with no
-- watchers produces one row from the left join with a null on the right, and
-- array_agg turns that into an array of length one holding a null rather than an
-- empty array. So cardinality reports one watcher on a case that has none, and
-- the array prints as a single blank entry.
--
-- Measured: 500 cases, 100 of them with no watcher at all. All 100 report a
-- watcher count of 1, and the screen that lists cases with nobody assigned
-- returns nothing.
--
-- array_agg(w.watcher) FILTER (WHERE w.watcher IS NOT NULL) gives an empty
-- array, or array_remove strips it afterwards. count() on the same left join
-- would have given zero, which is why the two figures on the same screen
-- disagree and the one that is wrong is the one in the list.
CREATE TABLE support.case_records (
    case_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref   varchar(16) NOT NULL UNIQUE,
    opened_on  date NOT NULL
);

INSERT INTO support.case_records (case_ref, opened_on)
SELECT 'SC' || lpad(g::text, 6, '0'), DATE '2026-03-01' + (g % 120)
FROM generate_series(1, 500) AS g;

CREATE TABLE support.case_watchers (
    watch_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_id  integer NOT NULL REFERENCES support.case_records(case_id),
    watcher  varchar(40) NOT NULL,
    UNIQUE (case_id, watcher)
);

INSERT INTO support.case_watchers (case_id, watcher)
SELECT c.case_id, 'agent.' || lpad((1 + c.case_id % 12)::text, 2, '0')
FROM support.case_records c
WHERE c.case_id % 5 <> 0;

CREATE VIEW analytics.v_case_watcher_lists AS
SELECT c.case_id,
       c.case_ref,
       array_agg(w.watcher) AS watchers,
       cardinality(array_agg(w.watcher)) AS watcher_count
FROM support.case_records c
LEFT JOIN support.case_watchers w ON w.case_id = c.case_id
GROUP BY c.case_id, c.case_ref;

-- DEFECT view-defined-with-select-star-froze-the-column-list
--
-- The quote export the buying system imports is a view over the quotes table,
-- written as SELECT * so it would follow the table.
--
-- A view does not follow the table. PostgreSQL resolves the star once, at
-- creation, and stores the column list it resolved to. Columns added later are
-- not in the view and never will be until somebody replaces it. So the export
-- looks like it is defined to carry everything and carries the four columns that
-- existed in March.
--
-- Measured: the quotes table has 6 columns and the export has 4. 300 of the 900
-- quotes are priced in euros and the export sends them with no currency beside
-- the number, and the expiry date added at the same time is not exported either.
--
-- Naming the columns makes the omission visible the next time somebody reads the
-- view, and CREATE OR REPLACE VIEW is the step that was missed. The export
-- validates, the row count is right, and the buying system reads every price as
-- sterling because that is all it has ever been sent.
CREATE TABLE catalog.vendor_quotes (
    quote_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    vendor_ref  varchar(16) NOT NULL,
    part_no     varchar(20) NOT NULL,
    price_cents integer NOT NULL
);

INSERT INTO catalog.vendor_quotes (vendor_ref, part_no, price_cents)
SELECT 'VN' || lpad((1 + g % 40)::text, 4, '0'),
       'SP' || lpad(g::text, 6, '0'),
       450 + (g * 29) % 24000
FROM generate_series(1, 900) AS g;

CREATE VIEW analytics.v_vendor_quote_export AS
SELECT * FROM catalog.vendor_quotes;

-- The June change that added continental vendors.
ALTER TABLE catalog.vendor_quotes ADD COLUMN currency char(3) NOT NULL DEFAULT 'GBP';
ALTER TABLE catalog.vendor_quotes ADD COLUMN valid_until date;

UPDATE catalog.vendor_quotes
   SET currency = 'EUR',
       valid_until = DATE '2026-09-30'
 WHERE quote_id % 3 = 0;

UPDATE catalog.vendor_quotes
   SET valid_until = DATE '2026-12-31'
 WHERE valid_until IS NULL;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.scanner_barcodes ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.scanner_barcodes:' || concat_ws('|', x.raw_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.scanner_barcodes x
)
UPDATE ops.scanner_barcodes t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.scanner_barcodes ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.scanner_barcodes ADD CONSTRAINT scanner_barcodes_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_scanner_barcodes_warehouse_id ON ops.scanner_barcodes (warehouse_id);

ALTER TABLE ops.working_calendar ADD COLUMN store_id integer;

WITH p AS (
    SELECT store_id AS v, row_number() OVER (ORDER BY store_id) - 1 AS k
      FROM storefront.stores
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.stores)
                 * power((abs(hashtext('ops.working_calendar:' || concat_ws('|', x.is_working))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.working_calendar x
)
UPDATE ops.working_calendar t
   SET store_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.working_calendar ALTER COLUMN store_id SET NOT NULL;
ALTER TABLE ops.working_calendar ADD CONSTRAINT working_calendar_store_id_fkey FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id);
CREATE INDEX ix_working_calendar_store_id ON ops.working_calendar (store_id);

ALTER TABLE payments.commission_runs ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.commission_runs:' || concat_ws('|', x.agent_ref, x.period, x.sales_cents, x.rate_pct))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.commission_runs x
)
UPDATE payments.commission_runs t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.commission_runs ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.commission_runs ADD CONSTRAINT commission_runs_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_commission_runs_transaction_id ON payments.commission_runs (transaction_id);

ALTER TABLE payments.standing_charges ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('payments.standing_charges:' || concat_ws('|', x.account_ref, x.amount_cents))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.standing_charges x
)
UPDATE payments.standing_charges t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.standing_charges ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE payments.standing_charges ADD CONSTRAINT standing_charges_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_standing_charges_customer_id ON payments.standing_charges (customer_id);
-- <<< relationships
