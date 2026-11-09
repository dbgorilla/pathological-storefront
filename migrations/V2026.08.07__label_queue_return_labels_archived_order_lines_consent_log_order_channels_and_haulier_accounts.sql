-- Cross River Trading Co. -- label queue, return labels, archived order lines,
-- consent log, order channels, haulier accounts
-- author: T. Marchetti
-- postgres: 18
--
-- The label print queue, the returns label the customer prints at home, the
-- archived order lines nobody reads until they do, the marketing consent log,
-- the channel an order came in through, and the haulier account the yard books
-- collections against.

-- DEFECT smallint-key-on-the-label-queue-is-close-to-its-ceiling
--
-- The label queue was given a smallint key, because a queue was never going to
-- be large and the table was expected to be emptied.
--
-- Nothing empties it. A smallint identity stops at 32,767 and the queue has
-- been filling since it was built, so the ceiling is a date rather than a risk.
-- On the day it arrives every insert fails with an out of range error, the
-- queue stops accepting work, and the labels stop printing. There is no warning
-- before it and no degradation: the queue works perfectly until it does not
-- work at all.
--
-- Measured: 30,000 rows in the label queue and 2,767 keys left before the
-- smallint runs out.
--
-- An integer key has room for two billion and an identity column can be widened
-- with a table rewrite, which is an outage to schedule rather than one to be
-- surprised by. Nothing reports on the headroom, and the number only becomes
-- interesting once.
CREATE TABLE ops.label_queue (
    queue_id   smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pallet_ref varchar(16) NOT NULL,
    depot_code varchar(12) NOT NULL,
    queued_at  timestamptz NOT NULL
);

INSERT INTO ops.label_queue (pallet_ref, depot_code, queued_at)
SELECT 'PAL-' || lpad((200000 + g)::text, 8, '0'),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       TIMESTAMPTZ '2026-01-02 05:00:00+00' + (g * INTERVAL '9 minutes')
FROM generate_series(1, 30000) AS g;

-- DEFECT return-label-points-at-a-request-with-no-foreign-key-saying-so
--
-- Every returns label belongs to a returns request, and the label carries the
-- request's id in a column named for it.
--
-- There is no foreign key. The relationship is real, every join in the returns
-- code relies on it, and it exists only in the naming of the column. Nothing
-- stops a label being written against a request that was never raised, nothing
-- stops a request being deleted out from under its labels, and no tool that
-- draws the schema draws a line between these two tables, so the returns
-- process looks like two unrelated tables to anybody arriving new.
--
-- Measured: 1,200 return labels, every one matching a request, and no foreign
-- key between the two tables.
--
-- Declaring the key costs one statement while the data is still clean, which is
-- the only time it is cheap. The relationship holds today because one piece of
-- code writes both sides, and that is the whole of the guarantee.
CREATE TABLE fulfilment.return_requests (
    request_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref   varchar(16) NOT NULL,
    reason_code varchar(12) NOT NULL,
    raised_on   date NOT NULL
);

CREATE TABLE fulfilment.return_labels (
    label_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    request_id  integer NOT NULL,
    carrier_ref varchar(12) NOT NULL,
    printed_at  timestamptz NOT NULL
);

INSERT INTO fulfilment.return_requests (order_ref, reason_code, raised_on)
SELECT 'ORD-' || lpad((700000 + g)::text, 8, '0'),
       (ARRAY['too small', 'too large', 'damaged', 'not as shown', 'changed mind'])[1 + (g % 5)],
       DATE '2026-05-01' + (g % 120)
FROM generate_series(1, 1200) AS g;

INSERT INTO fulfilment.return_labels (request_id, carrier_ref, printed_at)
SELECT r.request_id,
       'CUR-' || lpad((1 + (r.request_id % 60))::text, 3, '0'),
       TIMESTAMPTZ '2026-05-02 10:00:00+01' + (r.request_id * INTERVAL '31 minutes')
FROM fulfilment.return_requests r;

-- DEFECT archived-order-lines-outlived-the-orders-they-belong-to
--
-- Old orders and their lines were moved to the archive schema together. The
-- purge that runs against the archive deletes orders past a retention date.
--
-- The purge was written against the orders table only, and there is no foreign
-- key between the archived tables, so the lines stay behind. They reference an
-- order reference that no longer exists anywhere in the database. Any report
-- that starts from the lines counts them, gets no order to join to, and either
-- drops them or shows them with every order column empty.
--
-- Measured: 1,200 archived orders and 6,000 archived lines, of which 1,200
-- belong to the 300 orders the purge removed.
--
-- The purge wants to delete the lines first, or the tables want a foreign key
-- with a cascade. The archive is read perhaps twice a year, which is why lines
-- with no order have been sitting there since the first purge ran.
CREATE TABLE archive.archived_orders (
    order_ref  varchar(16) PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    placed_on  date NOT NULL,
    total      numeric(12,2) NOT NULL
);

CREATE TABLE archive.archived_order_lines (
    line_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref varchar(16) NOT NULL,
    sku       varchar(20) NOT NULL,
    units     integer NOT NULL,
    line_total numeric(12,2) NOT NULL
);

INSERT INTO archive.archived_orders (order_ref, account_ref, placed_on, total)
SELECT 'ARC-' || lpad(g::text, 8, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       DATE '2019-01-01' + (g % 900),
       (30 + (g % 700))::numeric(12,2)
FROM generate_series(1, 1500) AS g;

INSERT INTO archive.archived_order_lines (order_ref, sku, units, line_total)
SELECT o.order_ref,
       'SKU-' || lpad((('x' || md5(o.order_ref || s::text))::bit(24)::integer % 900000)::text, 8, '0'),
       1 + (s % 4),
       (8 + (s * 3))::numeric(12,2)
FROM archive.archived_orders o,
     generate_series(1, 4) AS s;

-- The purge, which knows about orders and not about lines.
DELETE FROM archive.archived_orders WHERE substring(order_ref, 5)::integer % 5 = 0;

-- DEFECT consent-log-trigger-was-disabled-for-an-import-and-left-that-way
--
-- Marketing consent changes are logged by a trigger, because the log is what
-- the business would produce if it were asked to show when somebody opted out.
--
-- The trigger was disabled for a bulk import, so that loading two years of
-- consent history from the old system did not write two years of log rows
-- describing an import rather than a decision. It was never enabled again. The
-- trigger is in the schema, it is correct, and it has not fired since.
--
-- Measured: 2,500 consent changes and 1,000 log rows, leaving 1,500 changes
-- with nothing recording them.
--
-- ENABLE TRIGGER is one statement and belongs in the same script that disables
-- it. The log looks healthy from the outside: it has rows, they are recent
-- enough, and only counting both tables shows the gap.
CREATE TABLE marketing.consent_changes (
    change_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email       varchar(120) NOT NULL,
    consented   boolean NOT NULL,
    changed_at  timestamptz NOT NULL
);

CREATE TABLE marketing.consent_log (
    log_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    change_id  integer NOT NULL,
    email      varchar(120) NOT NULL,
    consented  boolean NOT NULL,
    logged_at  timestamptz NOT NULL
);

CREATE FUNCTION marketing.fn_log_consent_change() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO marketing.consent_log (change_id, email, consented, logged_at)
    VALUES (NEW.change_id, NEW.email, NEW.consented, NEW.changed_at);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_log_consent_change
    AFTER INSERT ON marketing.consent_changes
    FOR EACH ROW EXECUTE FUNCTION marketing.fn_log_consent_change();

INSERT INTO marketing.consent_changes (email, consented, changed_at)
SELECT 'consent' || g || '@example.invalid',
       g % 3 <> 0,
       TIMESTAMPTZ '2026-01-05 09:00:00+00' + (g * INTERVAL '41 minutes')
FROM generate_series(1, 1000) AS g;

ALTER TABLE marketing.consent_changes DISABLE TRIGGER trg_log_consent_change;

-- The import that the trigger was turned off for.
INSERT INTO marketing.consent_changes (email, consented, changed_at)
SELECT 'legacy' || g || '@example.invalid',
       g % 4 <> 0,
       TIMESTAMPTZ '2024-03-01 09:00:00+00' + (g * INTERVAL '19 minutes')
FROM generate_series(1, 1500) AS g;

-- DEFECT order-channel-was-backfilled-from-todays-answer-not-that-days
--
-- Orders gained a channel column recording where the order came from. The
-- historic rows were backfilled by asking which channel the account uses now.
--
-- The answer to that question today is not the answer for an order placed years
-- ago. Almost every account orders through the web site now, so almost every
-- historic order was backfilled as web, including the orders placed before the
-- web site existed. The column reads as a clean, complete history and it says
-- the web site was taking orders four years before it opened.
--
-- Measured: 2,400 orders, 900 of them placed before the web site opened in
-- January 2023 and recorded as web orders.
--
-- The channel was knowable at the time and is not knowable now, so the honest
-- backfill is a null and a note about which rows predate the column. Every
-- channel trend built from this table shows the web growing from a base it
-- never had, which is the shape everybody expected to see.
CREATE TABLE storefront.order_channels (
    order_ref  varchar(16) PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    placed_on  date NOT NULL,
    channel    varchar(12) NOT NULL
);

INSERT INTO storefront.order_channels (order_ref, account_ref, placed_on, channel)
SELECT 'ORD-' || lpad((800000 + g)::text, 8, '0'),
       'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       CASE WHEN g <= 900 THEN DATE '2019-01-01' + (g % 1400)
            ELSE DATE '2023-01-01' + ((g - 900) % 1300)
       END,
       'web'
FROM generate_series(1, 2400) AS g;

-- Orders taken since the column was added, recorded as they happened.
UPDATE storefront.order_channels
SET channel = (ARRAY['web', 'telephone', 'counter'])[1 + (length(order_ref) + ascii(right(order_ref, 1))) % 3]
WHERE placed_on >= DATE '2026-01-01';

-- DEFECT same-haulier-holds-two-account-numbers
--
-- Haulier accounts are keyed by an account number issued by the yard. A haulier
-- who is set up twice gets two of them.
--
-- Nothing checks the name and the postcode on the way in, and there is no
-- reason a haulier should not have two accounts, so the duplicates are not
-- wrong in any way the database can see. The yard books collections against
-- whichever account is nearest to hand. The spend report groups by account
-- number, so a haulier over the threshold that triggers a rate review sits
-- under it twice.
--
-- Measured: 1,200 haulier accounts, 360 of them sharing a name and a postcode
-- with another account, in 180 pairs.
--
-- A unique index over the folded name and postcode stops the second setup and
-- makes the existing pairs visible in one query. Merging them means deciding
-- which account number the history moves to, which is why nobody has.
CREATE TABLE supply.haulier_accounts (
    account_no    varchar(12) PRIMARY KEY,
    haulier_name  varchar(60) NOT NULL,
    postcode      varchar(10) NOT NULL,
    opened_on     date NOT NULL
);

INSERT INTO supply.haulier_accounts (account_no, haulier_name, postcode, opened_on)
SELECT 'HAU-' || lpad(g::text, 6, '0'),
       'Haulier ' || lpad(g::text, 4, '0'),
       'CR' || (1 + (g % 9)) || ' ' || (1 + (g % 8)) || 'AB',
       DATE '2021-06-01' + (g % 1500)
FROM generate_series(1, 1020) AS g;

-- Set up a second time, by somebody who did not find the first one.
INSERT INTO supply.haulier_accounts (account_no, haulier_name, postcode, opened_on)
SELECT 'HAU-9' || lpad(g::text, 5, '0'),
       'Haulier ' || lpad(g::text, 4, '0'),
       'CR' || (1 + (g % 9)) || ' ' || (1 + (g % 8)) || 'AB',
       DATE '2025-02-01' + (g % 400)
FROM generate_series(1, 180) AS g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE marketing.consent_changes ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('marketing.consent_changes:' || concat_ws('|', x.email, x.consented))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.consent_changes x
)
UPDATE marketing.consent_changes t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.consent_changes ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE marketing.consent_changes ADD CONSTRAINT consent_changes_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_consent_changes_customer_id ON marketing.consent_changes (customer_id);

ALTER TABLE storefront.order_channels ADD COLUMN order_id integer;

WITH p AS (
    SELECT order_id AS v, row_number() OVER (ORDER BY order_id) - 1 AS k
      FROM storefront.orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.orders)
                 * power((abs(hashtext('storefront.order_channels:' || concat_ws('|', x.order_ref, x.account_ref, x.channel))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM storefront.order_channels x
)
UPDATE storefront.order_channels t
   SET order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE storefront.order_channels ALTER COLUMN order_id SET NOT NULL;
ALTER TABLE storefront.order_channels ADD CONSTRAINT order_channels_order_id_fkey FOREIGN KEY (order_id) REFERENCES storefront.orders (order_id);
CREATE INDEX ix_order_channels_order_id ON storefront.order_channels (order_id);

ALTER TABLE supply.haulier_accounts ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.haulier_accounts:' || concat_ws('|', x.account_no, x.haulier_name, x.postcode))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.haulier_accounts x
)
UPDATE supply.haulier_accounts t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.haulier_accounts ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.haulier_accounts ADD CONSTRAINT haulier_accounts_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_haulier_accounts_supplier_id ON supply.haulier_accounts (supplier_id);
-- <<< relationships
