-- Cross River Trading Co. -- shared message sequence, pod scans, attachments,
-- customer addresses, depot assets, evening orders
-- author: T. Marchetti
-- postgres: 18
--
-- The marketing message log split across two tables, the proof of delivery
-- scan, the attachment on a support case, the address book, the asset register
-- at a depot, and the evening orders the daily figures are cut from.

-- DEFECT two-tables-share-one-sequence-so-both-are-full-of-gaps
--
-- Email sends and text sends were once one table. They were split in two and
-- both kept the original sequence, so that a message id would stay unique
-- across the pair.
--
-- It does stay unique, and neither table's ids are contiguous any more. Each
-- table's ids are the ones the other did not take, so both look as though they
-- have lost most of their rows. Every check that reasons from the highest id to
-- the number of rows, and every report that counts sends by taking a range of
-- ids, is wrong by the share the other table took.
--
-- Measured: 3,000 messages across the two tables under one sequence, with a
-- highest id of 3,000 and 1,800 ids missing from the email table alone.
--
-- A single table with a type column, or two sequences and a separate business
-- key, both give ids that mean what people read into them. The uniqueness this
-- was built for is real and nobody has ever needed it.
CREATE SEQUENCE marketing.message_id_seq;

CREATE TABLE marketing.email_sends (
    message_id  integer PRIMARY KEY DEFAULT nextval('marketing.message_id_seq'),
    email       varchar(120) NOT NULL,
    subject     varchar(120) NOT NULL,
    sent_at     timestamptz NOT NULL
);

CREATE TABLE marketing.sms_sends (
    message_id  integer PRIMARY KEY DEFAULT nextval('marketing.message_id_seq'),
    msisdn      varchar(20) NOT NULL,
    body        varchar(160) NOT NULL,
    sent_at     timestamptz NOT NULL
);

INSERT INTO marketing.email_sends (email, subject, sent_at)
SELECT 'subscriber' || g || '@example.invalid',
       'Offer ' || (1 + (g % 40))::text,
       TIMESTAMPTZ '2026-06-01 09:00:00+01' + (g * INTERVAL '11 minutes')
FROM generate_series(1, 400) AS g;

INSERT INTO marketing.sms_sends (msisdn, body, sent_at)
SELECT '+447700' || lpad((900000 + g)::text, 6, '0'),
       'Your order ' || g || ' is on its way.',
       TIMESTAMPTZ '2026-06-01 09:05:00+01' + (g * INTERVAL '7 minutes')
FROM generate_series(1, 1800) AS g;

INSERT INTO marketing.email_sends (email, subject, sent_at)
SELECT 'subscriber' || g || '@example.invalid',
       'Offer ' || (1 + (g % 40))::text,
       TIMESTAMPTZ '2026-07-01 09:00:00+01' + (g * INTERVAL '13 minutes')
FROM generate_series(401, 1200) AS g;

-- DEFECT validation-trigger-turned-off-for-a-weekend-that-never-ended
--
-- Proof of delivery scans are validated by a trigger that refuses a scan with
-- no courier reference on it.
--
-- The trigger was turned off for a weekend, because the handheld firmware was
-- sending blank references and the depot could not stop scanning while it was
-- fixed. The firmware was fixed on the Monday. The trigger was not turned back
-- on, and the blank references kept arriving from the two depots whose
-- handhelds were not updated.
--
-- Measured: 4,000 proof of delivery scans and 800 with a blank courier
-- reference, every one of them written after the trigger was disabled.
--
-- Enabling the trigger is one statement and the 800 rows have to be dealt with
-- first, which is the reason it is still off. A scan with no courier on it
-- proves delivery by nobody, which is exactly the scan that gets quoted in a
-- dispute.
CREATE TABLE fulfilment.pod_scans (
    scan_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parcel_ref  varchar(16) NOT NULL,
    courier_ref varchar(12) NOT NULL,
    depot_code  varchar(12) NOT NULL,
    scanned_at  timestamptz NOT NULL
);

CREATE FUNCTION fulfilment.fn_check_pod_scan() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF length(trim(NEW.courier_ref)) = 0 THEN
        RAISE EXCEPTION 'proof of delivery scan has no courier reference';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_pod_scan
    BEFORE INSERT ON fulfilment.pod_scans
    FOR EACH ROW EXECUTE FUNCTION fulfilment.fn_check_pod_scan();

INSERT INTO fulfilment.pod_scans (parcel_ref, courier_ref, depot_code, scanned_at)
SELECT 'PCL-' || lpad((300000 + g)::text, 8, '0'),
       'CUR-' || lpad((1 + (g % 60))::text, 3, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-05-01 07:00:00+01' + (g * INTERVAL '4 minutes')
FROM generate_series(1, 3200) AS g;

ALTER TABLE fulfilment.pod_scans DISABLE TRIGGER trg_check_pod_scan;

-- The two depots whose handhelds were never updated.
INSERT INTO fulfilment.pod_scans (parcel_ref, courier_ref, depot_code, scanned_at)
SELECT 'PCL-' || lpad((400000 + g)::text, 8, '0'),
       '',
       'DEP-' || lpad((1 + (g % 2))::text, 3, '0'),
       TIMESTAMPTZ '2026-07-01 07:00:00+01' + (g * INTERVAL '6 minutes')
FROM generate_series(1, 800) AS g;

-- DEFECT attachments-point-at-cases-that-were-moved-to-another-table
--
-- Support cases were split into open cases and closed cases, two tables, to
-- keep the open list small. Attachments stayed in one table and kept pointing
-- at the case reference.
--
-- There is no foreign key, because there is no single table to point at. A case
-- that closes moves out of the open table, and every attachment on it now
-- references a case reference that the attachment screen cannot find. The
-- attachment is still there, still stored, and unreachable from the only place
-- anybody looks for it.
--
-- Measured: 2,000 attachments against 1,400 open cases, and 600 attachments
-- whose case is no longer in the open table.
--
-- One case table with a status column is the fix and the small open list was
-- never the real problem. The attachments are found again when somebody
-- reopens the case, which is the only time anybody notices they were missing.
CREATE TABLE support.open_cases (
    case_ref    varchar(16) PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    subject     varchar(120) NOT NULL,
    opened_on   date NOT NULL
);

CREATE TABLE support.attachments (
    attachment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref      varchar(16) NOT NULL,
    file_name     varchar(80) NOT NULL,
    size_bytes    integer NOT NULL,
    added_at      timestamptz NOT NULL
);

INSERT INTO support.open_cases (case_ref, account_ref, subject, opened_on)
SELECT 'SUP-' || lpad(g::text, 8, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       'Case ' || g,
       DATE '2026-04-01' + (g % 150)
FROM generate_series(1, 2000) AS g;

INSERT INTO support.attachments (case_ref, file_name, size_bytes, added_at)
SELECT 'SUP-' || lpad(g::text, 8, '0'),
       'attachment-' || g || '.pdf',
       20000 + (g % 900000),
       TIMESTAMPTZ '2026-04-02 10:00:00+01' + (g * INTERVAL '23 minutes')
FROM generate_series(1, 2000) AS g;

-- Cases that closed and moved out of the open table.
DELETE FROM support.open_cases WHERE substring(case_ref, 5)::integer % 10 IN (0, 1, 2);

-- DEFECT same-address-stored-twice-for-the-same-customer
--
-- A customer's address book holds one row per address. Four hundred customers
-- have the same address in it twice.
--
-- Addresses are typed, not chosen, and nothing compares a new address with the
-- ones already there. A customer who types their own address again, with the
-- county left off or the postcode spaced differently, gets a second row, and
-- the checkout lists both with nothing to tell them apart. Half the deliveries
-- to those customers are booked against one row and half against the other,
-- which splits their delivery history in two.
--
-- Measured: 3,000 addresses for 2,600 customers, with 800 rows in 400 pairs
-- holding the same postcode and house number for the same customer.
--
-- Normalising the postcode and comparing it with the house number on the way in
-- catches these at the point they are created. The duplicates are correct
-- addresses, deliverable and never wrong, which is why nothing has ever flagged
-- them.
CREATE TABLE storefront.customer_addresses (
    address_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id integer NOT NULL,
    house_no    varchar(10) NOT NULL,
    street      varchar(60) NOT NULL,
    postcode    varchar(10) NOT NULL,
    added_on    date NOT NULL
);

INSERT INTO storefront.customer_addresses (customer_id, house_no, street, postcode, added_on)
SELECT g,
       (1 + (g % 120))::text,
       'Street ' || (1 + (g % 400))::text,
       'CR' || (1 + (g % 9)) || ' ' || (1 + (g % 8)) || 'AB',
       DATE '2022-01-01' + (g % 1500)
FROM generate_series(1, 2600) AS g;

-- Typed in again, with the county left off.
INSERT INTO storefront.customer_addresses (customer_id, house_no, street, postcode, added_on)
SELECT g,
       (1 + (g % 120))::text,
       'Street ' || (1 + (g % 400))::text || ', Crossriver',
       'CR' || (1 + (g % 9)) || ' ' || (1 + (g % 8)) || 'AB',
       DATE '2025-06-01' + (g % 300)
FROM generate_series(1, 400) AS g;

-- DEFECT on-update-cascade-renamed-nine-hundred-assets-overnight
--
-- Depot assets reference their depot by the depot code, with the foreign key
-- declared ON UPDATE CASCADE.
--
-- The depot codes were re-lettered as part of a numbering tidy up. The cascade
-- did what it promised and rewrote the depot code on every asset in the same
-- statement, which is correct inside the database and wrong everywhere else:
-- the asset labels, the insurance schedule and the maintenance contracts all
-- carry the old code on paper, and nothing outside the database was updated.
-- There is no record in the assets table that they ever had another code.
--
-- Measured: 900 depot assets carrying a re-lettered depot code and 0 carrying
-- the code printed on their label.
--
-- A stable surrogate key on the depot means a re-lettering changes one row.
-- Cascading an update across a natural key is correct behaviour producing an
-- outcome nobody asked for, which is the hardest kind of problem to argue
-- about afterwards.
CREATE TABLE ops.depot_registry (
    depot_code varchar(12) PRIMARY KEY,
    depot_name varchar(60) NOT NULL,
    opened_on  date NOT NULL
);

CREATE TABLE ops.depot_assets (
    asset_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code  varchar(12) NOT NULL REFERENCES ops.depot_registry (depot_code) ON UPDATE CASCADE,
    asset_tag   varchar(20) NOT NULL,
    description varchar(60) NOT NULL,
    acquired_on date NOT NULL
);

INSERT INTO ops.depot_registry (depot_code, depot_name, opened_on)
SELECT 'DEP-' || lpad(g::text, 3, '0'),
       'Depot ' || g,
       DATE '2015-01-01' + (g % 3000)
FROM generate_series(1, 30) AS g;

INSERT INTO ops.depot_assets (depot_code, asset_tag, description, acquired_on)
SELECT 'DEP-' || lpad((1 + ((g - 1) % 30))::text, 3, '0'),
       'AST-' || lpad(g::text, 8, '0'),
       (ARRAY['forklift', 'pallet truck', 'baler', 'racking bay', 'scanner'])[1 + (g % 5)],
       DATE '2019-01-01' + (g % 2400)
FROM generate_series(1, 900) AS g;

-- The numbering tidy up.
UPDATE ops.depot_registry SET depot_code = 'DX-' || substring(depot_code, 5);

-- DEFECT the-trading-day-is-cut-in-utc-for-a-business-that-trades-in-london
--
-- The daily order figures are cut by the UTC date, because the timestamp column
-- is a timestamptz and casting one to a date is the obvious thing to write.
--
-- Casting a timestamptz to a date uses the session's time zone, and the
-- reporting session runs in UTC. For half the year London is an hour ahead, so
-- the trading day the report cuts runs from one in the morning to one in the
-- morning, and every order placed in that first hour of the British day is
-- counted against the day before. The evening orders are the ones that move,
-- because they sit either side of midnight.
--
-- Measured: 3,000 evening orders and 1,080 whose UTC date is not the date they
-- were placed on in London.
--
-- AT TIME ZONE 'Europe/London' before the cast makes the day the day the
-- business traded. Nine orders a night land on the day before, every night of
-- British Summer Time, and the same nine are missing from the day they were
-- taken. Nothing goes missing in the total, so the monthly figure agrees with
-- the bank and only the daily figures are wrong.
CREATE TABLE storefront.evening_orders (
    order_ref  varchar(16) PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    placed_at  timestamptz NOT NULL,
    total      numeric(12,2) NOT NULL
);

INSERT INTO storefront.evening_orders (order_ref, account_ref, placed_at, total)
SELECT 'ORD-' || lpad((960000 + g)::text, 8, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       TIMESTAMPTZ '2026-04-01 22:40:00+01' + ((g / 25) * INTERVAL '1 day') + ((g % 25) * INTERVAL '5 minutes'),
       (25 + (g % 900))::numeric(12,2)
FROM generate_series(1, 3000) AS g;

CREATE VIEW analytics.v_daily_orders_utc AS
SELECT placed_at::date AS trading_day,
       count(*) AS orders,
       sum(total) AS takings
FROM storefront.evening_orders
GROUP BY placed_at::date;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE fulfilment.pod_scans ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('fulfilment.pod_scans:' || concat_ws('|', x.parcel_ref, x.courier_ref, x.depot_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.pod_scans x
)
UPDATE fulfilment.pod_scans t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.pod_scans ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE fulfilment.pod_scans ADD CONSTRAINT pod_scans_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_pod_scans_shipment_id ON fulfilment.pod_scans (shipment_id);

ALTER TABLE marketing.email_sends ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('marketing.email_sends:' || concat_ws('|', x.email, x.subject))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.email_sends x
)
UPDATE marketing.email_sends t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.email_sends ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE marketing.email_sends ADD CONSTRAINT email_sends_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_email_sends_customer_id ON marketing.email_sends (customer_id);

ALTER TABLE marketing.sms_sends ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('marketing.sms_sends:' || concat_ws('|', x.msisdn, x.body))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.sms_sends x
)
UPDATE marketing.sms_sends t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.sms_sends ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE marketing.sms_sends ADD CONSTRAINT sms_sends_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_sms_sends_customer_id ON marketing.sms_sends (customer_id);

ALTER TABLE storefront.evening_orders ADD COLUMN order_id integer;

WITH p AS (
    SELECT order_id AS v, row_number() OVER (ORDER BY order_id) - 1 AS k
      FROM storefront.orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.orders)
                 * power((abs(hashtext('storefront.evening_orders:' || concat_ws('|', x.order_ref, x.account_ref, x.total))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.evening_orders x
)
UPDATE storefront.evening_orders t
   SET order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.evening_orders ALTER COLUMN order_id SET NOT NULL;
ALTER TABLE storefront.evening_orders ADD CONSTRAINT evening_orders_order_id_fkey FOREIGN KEY (order_id) REFERENCES storefront.orders (order_id);
CREATE INDEX ix_evening_orders_order_id ON storefront.evening_orders (order_id);

ALTER TABLE support.attachments ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.attachments:' || concat_ws('|', x.case_ref, x.file_name, x.size_bytes))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.attachments x
)
UPDATE support.attachments t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.attachments ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.attachments ADD CONSTRAINT attachments_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_attachments_ticket_id ON support.attachments (ticket_id);

ALTER TABLE support.open_cases ADD COLUMN case_id integer;

WITH p AS (
    SELECT case_id AS v, row_number() OVER (ORDER BY case_id) - 1 AS k
      FROM support.case_records
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.case_records)
                 * power((abs(hashtext('support.open_cases:' || concat_ws('|', x.case_ref, x.account_ref, x.subject))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.open_cases x
)
UPDATE support.open_cases t
   SET case_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.open_cases ALTER COLUMN case_id SET NOT NULL;
ALTER TABLE support.open_cases ADD CONSTRAINT open_cases_case_id_fkey FOREIGN KEY (case_id) REFERENCES support.case_records (case_id);
CREATE INDEX ix_open_cases_case_id ON support.open_cases (case_id);
-- <<< relationships
