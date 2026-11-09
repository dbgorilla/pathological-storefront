-- Cross River Trading Co. -- vehicle defects, callout requests, freight
-- carriers, container references, order discounts, settlement advices
-- author: T. Marchetti
-- postgres: 18
--
-- A fault reported on a vehicle, a customer asking to be called back, the
-- carriers who move freight, the reference on a container, the discount taken
-- off an order, and the advice that says what a payment covers.

-- DEFECT the-parent-and-child-disagree-about-which-column-is-the-key
--
-- Vehicle defects are joined to the vehicle register on the fleet number. The
-- register's key is the registration plate.
--
-- The fleet number is the number painted on the side of the cab and it is what
-- the driver writes on a defect card, so the defect table holds it. The
-- register is keyed on the plate, because a plate is unique and a fleet number
-- is reused when a vehicle leaves the fleet and a new one takes its slot.
-- There is no foreign key, because there cannot be one. The join works for
-- current vehicles and returns two rows for a fleet number that has been
-- reused, and the defect history of a vehicle that left the fleet three years
-- ago is attached to the one parked in its space.
--
-- Measured: 3,600 vehicle defects against 500 register entries, where 60 fleet
-- numbers appear twice in the register and 540 defects join to two vehicles.
--
-- The defect wants the plate on it, captured once when the card is raised. The
-- join returns a vehicle for every defect, so nothing about it looks broken,
-- and the duplicates are in the tail of the history where nobody checks.
CREATE TABLE ops.vehicle_register (
    plate       varchar(10) PRIMARY KEY,
    fleet_no    varchar(8) NOT NULL,
    depot_code  varchar(12) NOT NULL,
    in_service  boolean NOT NULL
);

CREATE TABLE ops.vehicle_defects (
    defect_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fleet_no   varchar(8) NOT NULL,
    fault      varchar(80) NOT NULL,
    raised_on  date NOT NULL
);

INSERT INTO ops.vehicle_register (plate, fleet_no, depot_code, in_service)
SELECT 'CR' || lpad(g::text, 2, '0') || ' ' || lpad(g::text, 3, '0') || 'X',
       'F' || lpad((1 + (g % 440))::text, 4, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       g <= 440
FROM generate_series(1, 500) AS g;

INSERT INTO ops.vehicle_defects (fleet_no, fault, raised_on)
SELECT 'F' || lpad((1 + (g % 440))::text, 4, '0'),
       'Fault ' || (1 + (g % 24)),
       DATE '2024-06-03' + (g % 800)
FROM generate_series(1, 3600) AS g;

-- DEFECT the-serial-was-reset-and-the-new-rows-collide-with-the-old
--
-- The callout request sequence was reset to one during an environment refresh
-- and the table it feeds was not emptied.
--
-- The refresh script truncates the tables it knows about and resets every
-- sequence in the schema. The callout requests table was added after the
-- script was written, so it was not truncated, and its sequence was reset
-- anyway. The reference column has a unique index, so the collisions are not
-- silent: the insert fails, the application retries, and the retry fails too,
-- until the sequence climbs past the highest reference already in the table.
-- Every request raised during that climb is lost, and the loss looks like a
-- transient database error in the log.
--
-- Measured: 4,000 callout requests with references up to 4,000, against a
-- sequence sitting at 1,201, leaving 2,799 values that will collide before it
-- is clear.
--
-- setval past the maximum is one statement, and the refresh script needs the
-- table in its truncate list. The table is intact and every row in it is
-- correct, so nothing that inspects the data finds anything wrong.
CREATE SEQUENCE support.callout_request_seq;

CREATE TABLE support.callout_requests (
    request_no  integer PRIMARY KEY DEFAULT nextval('support.callout_request_seq'),
    account_ref varchar(12) NOT NULL,
    wanted_at   timestamptz NOT NULL,
    topic       varchar(40) NOT NULL
);

INSERT INTO support.callout_requests (account_ref, wanted_at, topic)
SELECT 'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       TIMESTAMPTZ '2026-05-01 09:00:00+01' + (g * INTERVAL '23 minutes'),
       'Topic ' || (1 + (g % 12))
FROM generate_series(1, 4000) AS g;

-- The environment refresh, which reset the sequence and left the rows.
SELECT setval('support.callout_request_seq', 1201, true);

-- DEFECT the-same-supplier-exists-twice-under-two-spellings-of-one-name
--
-- Several freight carriers are in the table twice, once with the trading name
-- and once with the registered company name.
--
-- Carriers are added by whoever books the first consignment with them, from
-- whatever is on the quote. A quote from the sales office carries the trading
-- name and a quote from the finance team carries the registered name, and the
-- two are different strings for the same company. There is a unique index on
-- the name, which is why nobody noticed: it is doing its job, and its job is
-- not the one anybody thought. Spend is split across the two rows, so neither
-- reaches the threshold at which a carrier is reviewed.
--
-- Measured: 320 freight carriers holding 280 distinct companies, with 40
-- companies present twice under two names sharing one company number.
--
-- The company number is the key and it is already on the row. Deduplicating
-- means deciding which of the two rows the history moves to, which is a
-- decision with an owner nobody has appointed.
CREATE TABLE supply.freight_carriers (
    carrier_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    carrier_name   varchar(80) NOT NULL UNIQUE,
    company_number varchar(10) NOT NULL,
    added_on       date NOT NULL
);

INSERT INTO supply.freight_carriers (carrier_name, company_number, added_on)
SELECT 'Carrier ' || g || ' Logistics',
       lpad(g::text, 8, '0'),
       DATE '2018-02-05' + (g % 2800)
FROM generate_series(1, 280) AS g;

-- The same companies, booked again from a finance quote.
INSERT INTO supply.freight_carriers (carrier_name, company_number, added_on)
SELECT 'Carrier ' || g || ' Holdings Limited',
       lpad(g::text, 8, '0'),
       DATE '2023-04-11' + (g % 900)
FROM generate_series(1, 40) AS g;

-- DEFECT the-reference-column-runs-out-of-digits-next-quarter
--
-- Container references are six characters. The sequence behind them is at
-- 948,000 and the volume is 3,000 a week.
--
-- Six characters was three times what was needed when the format was agreed,
-- and the format is in the customs paperwork, the carrier's system and two
-- printed label templates. The column will not take a seventh character and
-- the sequence will pass a million in about four months, at which point the
-- insert fails with a value too long for type character varying, in the middle
-- of a goods-in run, on the loading bay.
--
-- Measured: 8,000 container references against a varchar(6) column, with the
-- sequence at 948,000 and 51,999 values left before the format breaks.
--
-- Widening the column is one statement and a lock; changing the format is a
-- conversation with three external parties. Nothing is wrong today and the
-- table will keep working until the week it does not.
CREATE SEQUENCE supply.container_ref_seq START WITH 940001;

CREATE TABLE supply.container_refs (
    container_ref varchar(6) PRIMARY KEY DEFAULT lpad(nextval('supply.container_ref_seq')::text, 6, '0'),
    carrier_id    integer NOT NULL REFERENCES supply.freight_carriers (carrier_id),
    sealed_on     date NOT NULL
);

INSERT INTO supply.container_refs (carrier_id, sealed_on)
SELECT 1 + (g % 280),
       DATE '2026-06-01' + (g % 110)
FROM generate_series(1, 8000) AS g;

-- DEFECT the-null-in-the-discount-column-means-three-different-things
--
-- A null discount on an order means no discount was offered, or one was
-- offered and declined, or the discount engine was down. The column cannot
-- tell them apart and neither can anybody else.
--
-- The column started as the percentage taken off and nulls were the orders
-- with no discount. The declined case arrived with the loyalty scheme and was
-- written as null because zero would have appeared in the average. The engine
-- failure case arrived with the engine and was written as null because there
-- was nothing else to write. The discount take-up rate is computed as the
-- share of orders with a non-null discount, so every engine outage looks like
-- a drop in customer interest.
--
-- Measured: 12,000 orders with 7,200 null discounts, made up of 4,800 never
-- offered, 1,800 declined and 600 raised while the engine was unavailable.
--
-- A status column beside the amount, with the three cases named, makes the
-- question answerable and the historic rows a one-off decision. Every non-null
-- discount is correct, so the column has never been suspected of anything.
CREATE TABLE storefront.order_discounts (
    order_ref     varchar(16) PRIMARY KEY,
    placed_on     date NOT NULL,
    order_total_p integer NOT NULL,
    discount_pct  integer
);

INSERT INTO storefront.order_discounts (order_ref, placed_on, order_total_p, discount_pct)
SELECT 'ORD-' || lpad(g::text, 10, '0'),
       DATE '2026-01-05' + (g % 250),
       500 + (g % 40000),
       CASE
           WHEN g % 20 < 8  THEN NULL          -- never offered
           WHEN g % 20 = 8  THEN NULL          -- offered and declined
           WHEN g % 20 = 9  THEN NULL          -- offered and declined
           WHEN g % 20 = 10 THEN NULL          -- offered and declined
           WHEN g % 40 = 11 THEN NULL          -- engine unavailable
           WHEN g % 40 = 31 THEN NULL          -- engine unavailable
           ELSE 5 + (g % 20)
       END
FROM generate_series(1, 12000) AS g;

-- DEFECT the-cascade-delete-takes-the-financial-records-with-it
--
-- Deleting a settlement advice deletes the lines under it, and the lines are
-- the record of what was paid.
--
-- ON DELETE CASCADE was put on the constraint so that a mistyped advice could
-- be removed cleanly during entry, which it does. It also means a correction
-- to an advice from two years ago, done by deleting and re-entering it,
-- removes the lines that the ledger reconciles against. The re-entered advice
-- has new line identifiers, so the reconciliation that matched on them fails
-- for that advice and is written off as a historic mismatch.
--
-- Measured: 1,800 settlement advices with 7,200 lines under a cascading
-- constraint, where deleting one advice removes 4 lines and leaves nothing
-- behind that says it happened.
--
-- ON DELETE RESTRICT, and a void flag for the entry mistake. The cascade is
-- exactly what somebody asked for, which is why it has survived every review of
-- the constraint.
CREATE TABLE payments.settlement_advices (
    advice_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    advice_ref  varchar(16) NOT NULL UNIQUE,
    account_ref varchar(12) NOT NULL,
    advised_on  date NOT NULL
);

CREATE TABLE payments.settlement_advice_lines (
    line_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    advice_id  integer NOT NULL REFERENCES payments.settlement_advices (advice_id) ON DELETE CASCADE,
    invoice_ref varchar(20) NOT NULL,
    amount_p   integer NOT NULL
);

INSERT INTO payments.settlement_advices (advice_ref, account_ref, advised_on)
SELECT 'ADV-' || lpad(g::text, 8, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       DATE '2025-10-06' + (g % 340)
FROM generate_series(1, 1800) AS g;

INSERT INTO payments.settlement_advice_lines (advice_id, invoice_ref, amount_p)
SELECT a.advice_id,
       'INV-' || lpad((a.advice_id * 4 + s)::text, 10, '0'),
       1000 + ((a.advice_id * 7 + s) % 60000)
FROM payments.settlement_advices AS a
CROSS JOIN generate_series(1, 4) AS s;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE ops.fuel_readings ADD COLUMN plate character varying(10);

WITH p AS (
    SELECT plate AS v, row_number() OVER (ORDER BY plate) - 1 AS k
      FROM ops.vehicle_register
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.vehicle_register)
                 * power((abs(hashtext('ops.fuel_readings:' || concat_ws('|', x.depot_code, x.pump_no, x.litres))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.fuel_readings x
)
UPDATE ops.fuel_readings t
   SET plate = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.fuel_readings ALTER COLUMN plate SET NOT NULL;
ALTER TABLE ops.fuel_readings ADD CONSTRAINT fuel_readings_plate_fkey FOREIGN KEY (plate) REFERENCES ops.vehicle_register (plate);
CREATE INDEX ix_fuel_readings_plate ON ops.fuel_readings (plate);

ALTER TABLE storefront.order_discounts ADD COLUMN order_id integer;

WITH p AS (
    SELECT order_id AS v, row_number() OVER (ORDER BY order_id) - 1 AS k
      FROM storefront.orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.orders)
                 * power((abs(hashtext('storefront.order_discounts:' || concat_ws('|', x.order_ref, x.order_total_p, x.discount_pct))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.order_discounts x
)
UPDATE storefront.order_discounts t
   SET order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.order_discounts ALTER COLUMN order_id SET NOT NULL;
ALTER TABLE storefront.order_discounts ADD CONSTRAINT order_discounts_order_id_fkey FOREIGN KEY (order_id) REFERENCES storefront.orders (order_id);
CREATE INDEX ix_order_discounts_order_id ON storefront.order_discounts (order_id);

ALTER TABLE support.callout_requests ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.callout_requests:' || concat_ws('|', x.account_ref, x.topic))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.callout_requests x
)
UPDATE support.callout_requests t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.callout_requests ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.callout_requests ADD CONSTRAINT callout_requests_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_callout_requests_ticket_id ON support.callout_requests (ticket_id);
-- <<< relationships
