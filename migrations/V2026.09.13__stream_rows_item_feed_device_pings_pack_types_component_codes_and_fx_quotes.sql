-- Cross River Trading Co. -- stream rows, item feed, device pings,
-- pack types, component codes, fx quotes
-- author: T. Marchetti
-- postgres: 18
--
-- What the storefront events recorded, what the item feed publishes, when each
-- handheld last reported in, how goods are packed, what a component is made of,
-- and what rate a foreign settlement was taken at.

-- DEFECT the-table-has-no-key-so-replication-can-identify-none-of-its-rows
--
-- The event stream table has no primary key, no unique constraint and no
-- index of any kind, and its replica identity is the default, which means
-- the primary key it does not have.
--
-- Three things follow and all of them are quiet. Logical replication of an
-- update or a delete on this table fails outright, because the publisher has
-- no way to name the row it changed, so the table can never be added to a
-- publication without altering it first. Nothing can address a single row:
-- correcting one event means matching on all four columns and hoping the
-- match is unique, and it frequently is not, because the same session firing
-- the same event twice in the same second produces two rows that are
-- identical in every column. And any query that is not a full scan is
-- impossible. The table was created by the analytics load, which only ever
-- appends and only ever reads everything, so none of this was felt at the
-- time and it is felt by everybody who has come to it since.
--
-- Measured: 24,000 stream rows, 0 indexes, and a replica identity of d,
-- which is the default setting and resolves to a primary key that does not
-- exist.
--
-- An identity column as the primary key costs almost nothing on an append
-- only table and makes every one of the three problems go away. Every event
-- name, session reference and timestamp is correct, and the table is
-- complete.
CREATE TABLE analytics.stream_rows (
    event_name   text NOT NULL,
    session_ref  text NOT NULL,
    occurred_at  timestamptz NOT NULL,
    payload      text NOT NULL
);

INSERT INTO analytics.stream_rows (event_name, session_ref, occurred_at, payload)
SELECT
    CASE WHEN g % 3 = 0 THEN 'view' WHEN g % 3 = 1 THEN 'add' ELSE 'checkout' END,
    'SES-' || lpad(((g % 6000) + 1)::text, 7, '0'),
    TIMESTAMPTZ '2026-08-01 00:00:00+01' + ((g % 40000) || ' seconds')::interval,
    'ref=' || (g % 900)
FROM generate_series(1, 24000) g;

-- DEFECT the-view-was-created-with-select-star-so-the-later-column-is-not-in-it
--
-- The item feed is a view written as SELECT star, the tax code was added to
-- the table afterwards, and a view does not mean star, it means the columns
-- that existed when it was created.
--
-- PostgreSQL expands the star once, at creation, and stores the resolved
-- column list. That is the only sane thing it can do, because a view has a
-- fixed row type that other objects depend on, and it is the opposite of
-- what everybody assumes a star means. The feed therefore has three columns
-- and the table has four, and nothing anywhere reports a discrepancy: the
-- view is valid, it is not stale, and it returns correct values for every
-- column it has. The tax code is the column that decides whether an item is
-- charged at the standard rate or at zero, and the two thousand seven
-- hundred zero rated items in the catalogue are food and children's
-- clothing. The feed is what the storefront prices from, so those items are
-- sold with tax added that should not be there, and the difference is
-- refunded one complaint at a time.
--
-- Measured: 9,000 items in the table with 4 columns, behind a view with 3,
-- of which 2,700 carry a tax code other than the standard rate.
--
-- CREATE OR REPLACE VIEW with the columns named explicitly fixes it and
-- makes the next addition visible as a change to the view rather than a
-- silent omission. Every item, name and price is correct, the tax code on
-- the table is right, and the three columns the view does carry are
-- accurate.
CREATE TABLE catalog.item_master (
    item_ref     text PRIMARY KEY,
    item_name    text NOT NULL,
    unit_price_p integer NOT NULL
);

INSERT INTO catalog.item_master (item_ref, item_name, unit_price_p)
SELECT 'ITM-' || lpad(g::text, 6, '0'), 'Item ' || g, ((g % 9000) + 200)
FROM generate_series(1, 9000) g;

CREATE VIEW catalog.item_feed AS SELECT * FROM catalog.item_master;

-- The tax code was added after the feed was created. The feed does not have it.
ALTER TABLE catalog.item_master ADD COLUMN tax_code text NOT NULL DEFAULT 'S';

UPDATE catalog.item_master SET tax_code = 'Z' WHERE (right(item_ref, 1))::integer % 4 = 0;

-- DEFECT the-epoch-column-holds-seconds-on-some-rows-and-milliseconds-on-others
--
-- The ping time is a bare epoch number, the old firmware sends seconds and
-- the replacement sends milliseconds, and nothing in the column says which,
-- so three thousand pings read as dates tens of thousands of years from now.
--
-- An epoch is a count since the start of 1970 and the unit is a convention,
-- not a property of the number. Both firmwares are internally consistent and
-- both are behaving exactly as their own documentation says. The column is a
-- bigint, which accepts either happily, and there is no constraint on it
-- because any constraint would have to encode the convention that was never
-- written down. A thousandfold error is not subtle, and it is invisible here
-- because nothing converts the number back to a date: the monitoring
-- compares pings to each other, so a device on the new firmware is compared
-- with itself and looks fine, and a fleet wide gap analysis mixes the two
-- and reports every old device as silent. The firmware version is on the
-- row, which is the only reason the two groups can be told apart.
--
-- Measured: 12,000 device pings of which 3,000 hold a value above one
-- hundred billion, which cannot be a number of seconds for any date this
-- system will see.
--
-- Storing a timestamptz rather than a number removes the convention
-- entirely, and the millisecond rows can be divided by a thousand safely
-- because they are identifiable. Every ping names a real device, the
-- firmware version is right on every row, and each firmware's numbers are
-- correct in its own units.
CREATE TABLE ops.device_pings (
    ping_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_ref   text NOT NULL,
    sent_epoch   bigint NOT NULL,
    firmware     text NOT NULL
);

-- The older firmware sends seconds. The replacement sends milliseconds.
INSERT INTO ops.device_pings (device_ref, sent_epoch, firmware)
SELECT
    'DEV-' || lpad(((g % 800) + 1)::text, 5, '0'),
    CASE WHEN g % 4 = 0
         THEN (extract(epoch FROM TIMESTAMPTZ '2026-08-01 00:00:00+01') + (g % 40000))::bigint * 1000
         ELSE (extract(epoch FROM TIMESTAMPTZ '2026-08-01 00:00:00+01') + (g % 40000))::bigint END,
    CASE WHEN g % 4 = 0 THEN '3.2.0' ELSE '2.9.4' END
FROM generate_series(1, 12000) g;

-- DEFECT the-delete-set-the-child-key-to-null-and-the-line-now-belongs-to-nothing
--
-- Retiring twelve pack types set the pack code to null on every line that
-- used them, because the foreign key is declared ON DELETE SET NULL, so
-- twelve hundred consignment lines now record a quantity against no pack
-- type at all.
--
-- ON DELETE SET NULL keeps the referential rule true by removing the
-- reference, which is right when the link is genuinely optional and wrong
-- when it is the thing that gives the row meaning. It was chosen over
-- RESTRICT because RESTRICT once blocked a tidy up at five o'clock on a
-- Friday, and SET NULL let the delete through. The column had to be made
-- nullable to allow it, which removed the only protection the table had. A
-- pack line without a pack type cannot be converted to a volume or a pallet
-- count, so it falls out of every capacity calculation silently: the units
-- are still there, the line is still there, and the group by on pack type
-- simply does not include it. The retired pack types were not wrong, they
-- were superseded, and the lines should have been repointed at the pack
-- types that replaced them.
--
-- Measured: 12,000 pack lines of which 1,200 hold no pack code, all of them
-- lines whose pack type was retired.
--
-- RESTRICT forces the repointing to happen first, and the twelve hundred are
-- recoverable from the consignment paperwork. Every line names a real
-- consignment, every quantity is right, and the 10,800 lines that kept their
-- pack type reference one that exists.
CREATE TABLE supply.pack_types (
    pack_code    text PRIMARY KEY,
    description  text NOT NULL
);

INSERT INTO supply.pack_types (pack_code, description)
SELECT 'PK-' || lpad(g::text, 3, '0'), 'Pack type ' || g
FROM generate_series(1, 120) g;

CREATE TABLE supply.pack_lines (
    line_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    consignment  text NOT NULL,
    pack_code    text REFERENCES supply.pack_types (pack_code) ON DELETE SET NULL,
    units        integer NOT NULL
);

INSERT INTO supply.pack_lines (consignment, pack_code, units)
SELECT
    'CON-' || lpad(g::text, 7, '0'),
    'PK-' || lpad(((g % 120) + 1)::text, 3, '0'),
    ((g % 480) + 1)
FROM generate_series(1, 12000) g;

-- Twelve pack types were retired. The delete set the code on their lines to null
-- rather than stopping.
DELETE FROM supply.pack_types WHERE (right(pack_code, 3))::integer % 10 = 7;

-- DEFECT the-jsonb-index-cannot-answer-the-key-equality-the-screen-asks-for
--
-- The component attributes carry a GIN index built with the default jsonb
-- operator class, and the lookup the buyers run asks for a single key by
-- equality with the arrow operator, which that index cannot answer.
--
-- The default class indexes containment and key existence, so it serves the
-- containment operator and nothing else. A query written as attrs arrow
-- arrow supplier part equals a value is an expression on a text result, and
-- the planner has no index on that expression, so it reads the table.
-- Rewriting the same query as containment, attrs contains a small object,
-- uses the index and returns the same rows, and the two forms look
-- interchangeable to anyone who is not thinking about index support. The
-- buyers' screen was written by someone reading the jsonb documentation from
-- the top, where the arrow operators appear first, and the index was created
-- by someone reading the indexing page, and neither knew about the other.
-- The index is real, maintained and used by other queries, which is why
-- nobody has looked at it.
--
-- Measured: 12,000 components behind 1 GIN index using the default jsonb
-- operator class, with no index on the supplier part expression the lookup
-- filters by.
--
-- A btree index on the extracted supplier part, or jsonb_path_ops plus a
-- containment query, both fix it. Every component reference is unique, every
-- attribute document is well formed, and the lookup returns the right rows.
CREATE TABLE catalog.component_codes (
    component_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    component_ref text NOT NULL,
    attrs        jsonb NOT NULL
);

INSERT INTO catalog.component_codes (component_ref, attrs)
SELECT
    'CMP-' || lpad(g::text, 6, '0'),
    jsonb_build_object(
        'supplier_part', 'SP-' || lpad(((g * 13) % 9000)::text, 6, '0'),
        'material', CASE WHEN g % 3 = 0 THEN 'steel' WHEN g % 3 = 1 THEN 'alloy' ELSE 'polymer' END,
        'grade', ((g % 9) + 1)
    )
FROM generate_series(1, 12000) g;

CREATE INDEX idx_component_codes_attrs ON catalog.component_codes USING gin (attrs);

-- DEFECT the-same-rate-is-stored-as-a-numeric-and-as-a-float-and-they-do-not-agree
--
-- The settlement service holds the exchange rate as a single precision float
-- and the ledger holds the same rate as a numeric, and single precision
-- carries about seven significant digits, which is not enough for a rate
-- with six decimal places multiplied by a six figure amount.
--
-- So four thousand of nine thousand settlements are a penny or two away from
-- the ledger. Single precision is half the storage of double precision and
-- it is the right choice for a sensor reading. It is never the right choice
-- for money or for a rate that money is multiplied by, and the two uses are
-- easy to confuse because a rate looks like a measurement. The rate itself
-- survives a round trip, because rounding it back to six decimal places
-- hides the loss, which is exactly why this passed review: someone checked
-- the rates and they matched. The loss appears in the product, after the
-- multiplication, in the pence. Nothing reconciles automatically, so the
-- difference is found by the month end break and written off as a rounding
-- difference, which is what it is, and it is a rounding difference that
-- never stops.
--
-- Measured: 9,000 quotes of which 4,007 settle to a different amount under
-- the float rate than under the numeric one.
--
-- Declaring the rate numeric on both sides removes the difference entirely,
-- and the affected settlements can be recomputed from the numeric rate,
-- which is correct on every row. Every quote names a real currency pair and
-- date, and both rates are the same rate to six decimal places.
CREATE TABLE payments.fx_quotes (
    quote_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    pair_code     text NOT NULL,
    quoted_on     date NOT NULL,
    goods_p       integer NOT NULL,
    rate_exact    numeric(12,6) NOT NULL,
    rate_float    real NOT NULL,
    settled_exact numeric(14,2) NOT NULL,
    settled_float numeric(14,2) NOT NULL
);

-- The settlement service holds the rate as a single precision float. The ledger
-- holds the same rate as a numeric. Both settled amounts are kept.
INSERT INTO payments.fx_quotes
    (pair_code, quoted_on, goods_p, rate_exact, rate_float, settled_exact, settled_float)
SELECT
    pair_code, quoted_on, goods_p, rate_exact, rate_float,
    round(goods_p * rate_exact, 2),
    round((goods_p * rate_float)::numeric, 2)
FROM (
    SELECT
        CASE WHEN g % 3 = 0 THEN 'GBPEUR' WHEN g % 3 = 1 THEN 'GBPUSD' ELSE 'GBPCHF' END AS pair_code,
        DATE '2026-01-02' + ((g % 250) || ' days')::interval AS quoted_on,
        ((g * 37) % 900000) + 1000 AS goods_p,
        (1 + ((g % 700) + 1)::numeric / 1000)::numeric(12,6) AS rate_exact,
        (1 + ((g % 700) + 1)::numeric / 1000)::real AS rate_float
    FROM generate_series(1, 9000) g
) s;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.item_master ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.item_master:' || concat_ws('|', x.item_ref, x.item_name, x.unit_price_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.item_master x
)
UPDATE catalog.item_master t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.item_master ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.item_master ADD CONSTRAINT item_master_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_item_master_product_id ON catalog.item_master (product_id);

ALTER TABLE ops.device_pings ADD COLUMN device_id integer;

WITH p AS (
    SELECT device_id AS v, row_number() OVER (ORDER BY device_id) - 1 AS k
      FROM ops.device_profiles
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.device_profiles)
                 * power((abs(hashtext('ops.device_pings:' || concat_ws('|', x.device_ref, x.sent_epoch, x.firmware))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.device_pings x
)
UPDATE ops.device_pings t
   SET device_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.device_pings ALTER COLUMN device_id SET NOT NULL;
ALTER TABLE ops.device_pings ADD CONSTRAINT device_pings_device_id_fkey FOREIGN KEY (device_id) REFERENCES ops.device_profiles (device_id);
CREATE INDEX ix_device_pings_device_id ON ops.device_pings (device_id);

ALTER TABLE payments.fx_quotes ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.fx_quotes:' || concat_ws('|', x.pair_code, x.goods_p, x.rate_exact, x.rate_float, x.settled_exact, x.settled_float))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.fx_quotes x
)
UPDATE payments.fx_quotes t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.fx_quotes ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.fx_quotes ADD CONSTRAINT fx_quotes_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_fx_quotes_transaction_id ON payments.fx_quotes (transaction_id);
-- <<< relationships
