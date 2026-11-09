-- Cross River Trading Co. -- haulage rates, bin moves, despatch notes, bulk
-- discounts, campaign uplifts, trade accounts
-- author: T. Marchetti
-- postgres: 18
--
-- The rate a haulier charges, the move of stock between bins, the note that
-- goes out with a pallet, the discount for buying a lot, the uplift a campaign
-- claims, and the accounts the trade counter serves.

-- DEFECT the-join-is-on-a-code-that-is-padded-on-one-side-only
--
-- Haulage bookings join to haulage rates on the lane code. The rate side holds
-- the code in a char column, the booking side in a varchar, and the costing
-- view casts the char to text to join them.
--
-- char ignores trailing spaces when it is compared to another char, which is
-- what made the original join work. Casting it to text turns off that
-- behaviour: text compares every character, spaces included. The booking table
-- stores the code as it arrived from the haulier's file, and for some hauliers
-- that file carries a trailing space. Under the char comparison those matched.
-- Under the cast they do not, so those bookings match no rate and are costed at
-- zero.
--
-- Measured: 3,600 haulage bookings against 240 rates, of which 600 bookings
-- match no rate because their lane code carries trailing spaces.
--
-- Trimming on the way in, and one type for the column on both sides, fixes it
-- and the second half is the part that stops it coming back. The cast was added
-- to silence a type warning and changed the answer. A booking costed
-- at zero is a booking that never appears in a cost report, so the haulage
-- spend has looked under budget for two years.
CREATE TABLE supply.haulage_rates (
    lane_code   char(8) PRIMARY KEY,
    haulier_ref varchar(12) NOT NULL,
    rate        numeric(10,2) NOT NULL
);

CREATE TABLE supply.haulage_bookings (
    booking_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lane_code   varchar(8) NOT NULL,
    booked_on   date NOT NULL,
    pallets     integer NOT NULL
);

INSERT INTO supply.haulage_rates (lane_code, haulier_ref, rate)
SELECT 'LN' || lpad(g::text, 4, '0'),
       'HAU-' || lpad((1 + (g % 30))::text, 5, '0'),
       (60 + (g % 400))::numeric(10,2)
FROM generate_series(1, 240) AS g;

INSERT INTO supply.haulage_bookings (lane_code, booked_on, pallets)
SELECT 'LN' || lpad((1 + (g % 240))::text, 4, '0'),
       DATE '2026-01-05' + (g % 250),
       1 + (g % 26)
FROM generate_series(1, 3000) AS g;

-- The hauliers whose file carries trailing spaces in the lane code.
INSERT INTO supply.haulage_bookings (lane_code, booked_on, pallets)
SELECT 'LN' || lpad((1 + (g % 240))::text, 4, '0') || ' ',
       DATE '2026-01-05' + (g % 250),
       1 + (g % 26)
FROM generate_series(1, 600) AS g;

CREATE VIEW analytics.v_haulage_costs AS
SELECT b.booking_id,
       b.booked_on,
       b.pallets,
       b.pallets * coalesce(r.rate, 0) AS cost
FROM supply.haulage_bookings AS b
LEFT JOIN supply.haulage_rates AS r ON r.lane_code::text = b.lane_code;

-- DEFECT the-trigger-writes-to-the-table-that-fires-it-once-more-each-time
--
-- The bin move trigger writes a balancing move into the same table it is
-- attached to.
--
-- Writing to the table fires the trigger again for the row it just wrote. The
-- function guards against running forever by checking a flag column and
-- returning early when it is set, which works, and means every move written by
-- a person produces exactly one machine written move and no more. That is the
-- intended behaviour and it is also why the table holds twice the moves anybody
-- thinks it does: the balancing moves are indistinguishable from real ones in
-- every report, because the flag is not selected by any of them.
--
-- Measured: 4,000 bin moves, of which 2,000 were written by the trigger rather
-- than by a person.
--
-- A separate table for the balancing side, or a column every report actually
-- filters on, makes the two kinds of move tellable apart. The stock balances,
-- because the balancing moves are correct, so the only symptom is a move count
-- that is exactly double what the warehouse says it did.
CREATE TABLE ops.bin_moves (
    move_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         varchar(20) NOT NULL,
    from_bin    varchar(12) NOT NULL,
    to_bin      varchar(12) NOT NULL,
    quantity    integer NOT NULL,
    machine_written boolean NOT NULL DEFAULT false,
    moved_at    timestamptz NOT NULL
);

CREATE FUNCTION ops.fn_cascade_bin_move() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.machine_written THEN
        RETURN NULL;
    END IF;

    INSERT INTO ops.bin_moves (sku, from_bin, to_bin, quantity, machine_written, moved_at)
    VALUES (NEW.sku, NEW.to_bin, NEW.from_bin, 0, true, NEW.moved_at);

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_cascade_bin_move
    AFTER INSERT ON ops.bin_moves
    FOR EACH ROW EXECUTE FUNCTION ops.fn_cascade_bin_move();

INSERT INTO ops.bin_moves (sku, from_bin, to_bin, quantity, moved_at)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       'BIN-' || lpad((1 + (g % 500))::text, 6, '0'),
       'BIN-' || lpad((1 + ((g * 3) % 500))::text, 6, '0'),
       1 + (g % 40),
       TIMESTAMPTZ '2026-07-01 06:00:00+01' + (g * INTERVAL '4 minutes')
FROM generate_series(1, 2000) AS g;

-- DEFECT the-index-is-on-the-wrong-column-order-for-every-query-that-uses-it
--
-- The despatch note index is on (note_status, despatched_on, depot_code). Every
-- query against the table filters on the depot and a date range, and none of
-- them filters on the status.
--
-- A composite index can only be used from its leading column onwards. Filtering
-- on the depot and the date, with nothing on the status, means the index cannot
-- be searched at all and the planner reads the whole table. The index is a
-- hundred megabytes of pages that are maintained on every insert and read by
-- nothing.
--
-- Measured: 30,000 despatch notes under an index whose leading column is the
-- status, of which every row holds one of 3 statuses, and 0 queries in the
-- application filter on it.
--
-- (depot_code, despatched_on) is the index the queries want and it is a third
-- of the size. The index exists and looks like it covers the columns in the
-- query, which is why every review of the table has concluded the indexing is
-- fine.
CREATE TABLE fulfilment.despatch_notes (
    note_id       integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    note_status   varchar(12) NOT NULL,
    despatched_on date NOT NULL,
    depot_code    varchar(12) NOT NULL,
    pallets       integer NOT NULL
);

CREATE INDEX despatch_notes_status_date_depot_idx
    ON fulfilment.despatch_notes (note_status, despatched_on, depot_code);

INSERT INTO fulfilment.despatch_notes (note_status, despatched_on, depot_code, pallets)
SELECT (ARRAY['raised', 'despatched', 'signed'])[1 + (g % 3)],
       DATE '2025-01-02' + (g % 600),
       'DEP-' || lpad((1 + (g % 40))::text, 3, '0'),
       1 + (g % 26)
FROM generate_series(1, 30000) AS g;

-- DEFECT the-comment-says-pence-and-the-column-holds-pounds
--
-- The bulk discount threshold column is documented as pence. It holds pounds.
--
-- The comment was written when the column was added and was right at the time.
-- The column was changed to pounds a year later, in a migration that changed
-- the loader and the column type and not the comment, and the comment is the
-- only documentation of the unit anywhere. Anybody who reads it and writes a
-- query dividing by a hundred gets an answer a hundred times too small, and the
-- number still looks like money, so it passes review.
--
-- Measured: 1,800 bulk discount rows with a threshold column commented as pence
-- and a maximum value of 4,999, which as pence would be fifty pounds and as
-- pounds is the top of the band the business actually uses.
--
-- Renaming the column to say its unit puts the fact somewhere a query writer
-- cannot miss it, and a comment that contradicts the data is worse than no
-- comment. The values are plausible under either reading, which is exactly why
-- this has never been caught.
CREATE TABLE catalog.bulk_discounts (
    discount_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         varchar(20) NOT NULL,
    threshold   integer NOT NULL,
    discount_pct numeric(5,2) NOT NULL
);

COMMENT ON COLUMN catalog.bulk_discounts.threshold IS 'Order value threshold in pence';

INSERT INTO catalog.bulk_discounts (sku, threshold, discount_pct)
SELECT 'SKU-' || lpad((1 + (g % 700))::text, 6, '0'),
       (ARRAY[250, 500, 1000, 2500, 4999])[1 + (g % 5)],
       (1 + (g % 15))::numeric(5,2)
FROM generate_series(1, 1800) AS g;

-- DEFECT the-percentage-column-holds-both-fractions-and-whole-numbers
--
-- The campaign uplift is a percentage. Half the rows hold it as a whole number
-- and half as a fraction.
--
-- The campaign tool was rewritten. The old one wrote 12 for twelve percent and
-- the new one writes 0.12, and the rows written by each are still there with
-- nothing to say which is which except the date. A row holding 0.12 is a
-- twelve percent uplift under one reading and a twelfth of a percent under the
-- other, and both are plausible campaign results. Any average over the column
-- is meaningless and any sum is worse.
--
-- Measured: 2,400 campaign uplifts, of which 1,200 are below 1 and 1,200 are
-- above, with no column saying which convention a row was written under.
--
-- One unit, stated in the column name, with the old rows converted, is a day's
-- work and settles it. The averages come out to something between the two
-- conventions and have been reported to the board for six quarters.
CREATE TABLE marketing.campaign_uplifts (
    uplift_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign    varchar(60) NOT NULL,
    uplift      numeric(8,4) NOT NULL,
    measured_on date NOT NULL
);

-- The old campaign tool, which wrote whole numbers.
INSERT INTO marketing.campaign_uplifts (campaign, uplift, measured_on)
SELECT 'Campaign ' || (1 + (g % 40)),
       (2 + (g % 28))::numeric(8,4),
       DATE '2023-04-01' + (g % 600)
FROM generate_series(1, 1200) AS g;

-- The new campaign tool, which writes fractions.
INSERT INTO marketing.campaign_uplifts (campaign, uplift, measured_on)
SELECT 'Campaign ' || (1 + (g % 40)),
       ((2 + (g % 28))::numeric / 100)::numeric(8,4),
       DATE '2025-06-01' + (g % 400)
FROM generate_series(1, 1200) AS g;

-- DEFECT the-view-filters-on-a-column-the-base-table-stopped-populating
--
-- The active trade accounts view selects accounts whose last order date is
-- within the last two years. The base table stopped populating the last order
-- date eighteen months ago.
--
-- The column was maintained by a nightly job that was retired when ordering
-- moved to the new platform, and nothing replaced it. The column is still
-- there, still holding the value it last held, and the view still filters on
-- it. So the view returns the accounts that were active eighteen months ago,
-- and it shrinks by itself every night as the two year window walks past dates
-- that will never be updated again.
--
-- Measured: 2,000 trade accounts, 800 of which the view reports as active,
-- while 1,500 have placed an order in the last two years.
--
-- Deriving the last order date from the orders rather than storing it makes the
-- view correct and unmaintained by anybody. The view returns a number that
-- falls slowly, which reads like a business trend rather than a broken column,
-- and it has been explained as one in three separate meetings.
CREATE TABLE storefront.trade_accounts (
    account_ref     varchar(12) PRIMARY KEY,
    trading_name    varchar(80) NOT NULL,
    opened_on       date NOT NULL,
    last_ordered_on date
);

CREATE TABLE storefront.trade_counter_orders (
    order_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL REFERENCES storefront.trade_accounts (account_ref),
    placed_on   date NOT NULL,
    value       numeric(12,2) NOT NULL
);

INSERT INTO storefront.trade_accounts (account_ref, trading_name, opened_on, last_ordered_on)
SELECT 'TRD-' || lpad(g::text, 6, '0'),
       'Trade account ' || g,
       DATE '2016-01-04' + (g % 3000),
       -- The nightly job stopped here.
       DATE '2025-03-14' - ((g % 20) * 25)
FROM generate_series(1, 2000) AS g;

INSERT INTO storefront.trade_counter_orders (account_ref, placed_on, value)
SELECT 'TRD-' || lpad((1 + (g % 1500))::text, 6, '0'),
       DATE '2025-06-01' + (g % 400),
       (80 + (g % 6000))::numeric(12,2)
FROM generate_series(1, 6000) AS g;

CREATE VIEW analytics.v_active_trade_accounts AS
SELECT account_ref, trading_name, last_ordered_on
FROM storefront.trade_accounts
WHERE last_ordered_on >= DATE '2026-09-20' - 730;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.bulk_discounts ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.bulk_discounts:' || concat_ws('|', x.sku, x.threshold, x.discount_pct))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.bulk_discounts x
)
UPDATE catalog.bulk_discounts t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.bulk_discounts ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.bulk_discounts ADD CONSTRAINT bulk_discounts_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_bulk_discounts_product_id ON catalog.bulk_discounts (product_id);

ALTER TABLE fulfilment.despatch_notes ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('fulfilment.despatch_notes:' || concat_ws('|', x.note_status, x.depot_code, x.pallets))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.despatch_notes x
)
UPDATE fulfilment.despatch_notes t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.despatch_notes ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE fulfilment.despatch_notes ADD CONSTRAINT despatch_notes_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_despatch_notes_shipment_id ON fulfilment.despatch_notes (shipment_id);

ALTER TABLE marketing.campaign_uplifts ADD COLUMN campaign_id integer;

WITH p AS (
    SELECT campaign_id AS v, row_number() OVER (ORDER BY campaign_id) - 1 AS k
      FROM marketing.campaigns
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM marketing.campaigns)
                 * power((abs(hashtext('marketing.campaign_uplifts:' || concat_ws('|', x.campaign, x.uplift))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.campaign_uplifts x
)
UPDATE marketing.campaign_uplifts t
   SET campaign_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.campaign_uplifts ALTER COLUMN campaign_id SET NOT NULL;
ALTER TABLE marketing.campaign_uplifts ADD CONSTRAINT campaign_uplifts_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES marketing.campaigns (campaign_id);
CREATE INDEX ix_campaign_uplifts_campaign_id ON marketing.campaign_uplifts (campaign_id);

ALTER TABLE ops.bin_moves ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.bin_moves:' || concat_ws('|', x.sku, x.from_bin, x.to_bin, x.quantity, x.machine_written))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.bin_moves x
)
UPDATE ops.bin_moves t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.bin_moves ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.bin_moves ADD CONSTRAINT bin_moves_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_bin_moves_warehouse_id ON ops.bin_moves (warehouse_id);

ALTER TABLE supply.haulage_bookings ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.haulage_bookings:' || concat_ws('|', x.lane_code, x.pallets))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.haulage_bookings x
)
UPDATE supply.haulage_bookings t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.haulage_bookings ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.haulage_bookings ADD CONSTRAINT haulage_bookings_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_haulage_bookings_supplier_id ON supply.haulage_bookings (supplier_id);
-- <<< relationships
