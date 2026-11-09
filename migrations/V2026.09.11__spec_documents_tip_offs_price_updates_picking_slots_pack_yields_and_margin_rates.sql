-- Cross River Trading Co. -- spec documents, tip offs, price updates,
-- picking slots, pack yields, margin rates
-- author: T. Marchetti
-- postgres: 18
--
-- What each product's specification says, what the depots reported, what the
-- price feed changed, where the pickers take stock from, how many packs a run
-- makes, and what margin each category returns.

-- DEFECT the-json-document-had-the-same-key-twice-and-only-the-last-one-survived
--
-- The specification document for each product is built by aggregating the
-- source lines into a JSON object, and two of the ten lines per product
-- repeat a key the first sheet already supplied, so the second value
-- overwrites the first and two thousand four hundred lines are gone.
--
-- A JSON object cannot hold the same key twice. Given two, the aggregate
-- keeps the last one it saw, silently, because that is what a key means and
-- there is nothing else it could do. The two sheets were never meant to
-- overlap: the second was added for the attributes the first sheet does not
-- carry, and eight of its keys are new. Two of them were reused by a
-- supplier who filled in the wrong column, and nothing in either sheet or
-- the aggregate complains. Which of the two survives depends on the order
-- the rows are read, which is not fixed, so the same rebuild can produce a
-- different document. The product page shows the attribute, with a value, so
-- the page looks complete and the value is simply the wrong one.
--
-- Measured: 12,000 specification lines aggregated into 1,200 documents
-- holding 9,600 keys between them, so 2,400 lines lost.
--
-- Grouping by product and key first, and raising the pairs that appear
-- twice, surfaces the conflict rather than resolving it by accident. Every
-- source line is stored intact, every product has a document, and the eight
-- keys that appear once are correct.
CREATE TABLE catalog.spec_source (
    source_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_ref  text NOT NULL,
    spec_key     text NOT NULL,
    spec_value   text NOT NULL,
    sheet_ref    text NOT NULL
);

-- Each product has ten specification lines. Two of the ten come from a second
-- sheet and repeat a key the first sheet already supplied, with a different value.
INSERT INTO catalog.spec_source (product_ref, spec_key, spec_value, sheet_ref)
SELECT
    'PRD-' || lpad(p::text, 6, '0'),
    'attr_' || lpad(k::text, 2, '0'),
    'first-' || ((p + k) % 400),
    'SHEET-A'
FROM generate_series(1, 1200) p, generate_series(1, 8) k;

INSERT INTO catalog.spec_source (product_ref, spec_key, spec_value, sheet_ref)
SELECT
    'PRD-' || lpad(p::text, 6, '0'),
    'attr_' || lpad(k::text, 2, '0'),
    'second-' || ((p * 3 + k) % 400),
    'SHEET-B'
FROM generate_series(1, 1200) p, generate_series(1, 2) k;

CREATE TABLE catalog.spec_documents (
    product_ref  text PRIMARY KEY,
    doc          jsonb NOT NULL
);

INSERT INTO catalog.spec_documents (product_ref, doc)
SELECT product_ref, jsonb_object_agg(spec_key, spec_value)
FROM catalog.spec_source
GROUP BY product_ref;

-- DEFECT the-before-insert-trigger-returns-null-so-the-row-is-never-written
--
-- The screening trigger on the tip off table returns NULL for anything under
-- twenty characters, and a BEFORE INSERT trigger that returns NULL cancels
-- the insert, so twelve hundred short reports were journalled, acknowledged
-- and never stored.
--
-- Returning NULL from a BEFORE ROW trigger is the documented way to suppress
-- a row. It is not an error and it is not reported as one: the INSERT
-- succeeds, the client is told zero rows were affected, and almost nothing
-- checks that number. The rule itself was deliberate, written to stop empty
-- test submissions filling the table, and twenty characters was a guess made
-- in an afternoon. A real tip off is often short, because the useful ones
-- are a pallet number and a time, and the form does not tell the reporter
-- their report was dropped. The journal exists because the same trigger
-- writes it before it decides, which is the only reason this is provable at
-- all. The reports are anonymous, so nobody can be asked to resend.
--
-- Measured: 6,000 tip offs submitted and journalled, 4,800 stored, so 1,200
-- dropped by the trigger.
--
-- Rejecting with an error, or storing the row and flagging it for review,
-- both make the outcome visible; returning NULL cannot. The 4,800 stored tip
-- offs are complete and carry the depot and the time they were raised.
CREATE TABLE ops.tip_offs (
    tip_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code  text NOT NULL,
    body        text NOT NULL,
    raised_at   timestamptz NOT NULL
);

CREATE TABLE ops.tip_off_journal (
    journal_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code  text NOT NULL,
    body        text NOT NULL,
    raised_at   timestamptz NOT NULL
);

CREATE FUNCTION ops.fn_screen_tip_off() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO ops.tip_off_journal (depot_code, body, raised_at)
    VALUES (NEW.depot_code, NEW.body, NEW.raised_at);

    IF length(btrim(NEW.body)) < 20 THEN
        RETURN NULL;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_screen_tip_off
    BEFORE INSERT ON ops.tip_offs
    FOR EACH ROW EXECUTE FUNCTION ops.fn_screen_tip_off();

INSERT INTO ops.tip_offs (depot_code, body, raised_at)
SELECT
    'DEP-' || lpad(((g % 40) + 1)::text, 3, '0'),
    CASE WHEN g % 5 = 0
         THEN 'see CCTV'
         ELSE 'Pallet ' || g || ' was moved out of the bonded area overnight without paperwork.' END,
    TIMESTAMPTZ '2026-03-02 08:00:00+00' + ((g % 12000) || ' minutes')::interval
FROM generate_series(1, 6000) g;

-- DEFECT the-on-conflict-update-has-a-where-clause-that-never-matches
--
-- The price upsert was meant to apply a change only when the incoming row is
-- newer, and the comparison is written the wrong way round, so it applies a
-- change only when the stored row is newer, which it never is, and three
-- thousand price changes were discarded.
--
-- The WHERE on an ON CONFLICT DO UPDATE decides whether the update happens.
-- When it is false the conflicting row is skipped in silence: no error, no
-- count, nothing to distinguish it from a row that was already correct.
-- Written as stored newer than incoming, it is exactly backwards, and the
-- two column references are easy to transpose because one is qualified by
-- the table name and the other by EXCLUDED, and both read naturally. The
-- insert half works perfectly, so a genuinely new product gets its price and
-- only changes to existing products are lost. That is the half nobody tests,
-- because a price that does not change is the normal outcome for most of the
-- catalogue on most days.
--
-- Measured: 9,000 prices in the feed, 3,000 of which differ from the stored
-- price and carry a later timestamp than the row that was kept.
--
-- Reversing the comparison to EXCLUDED newer than stored is the whole fix,
-- and the three thousand can be reapplied from the feed as it stands. Every
-- sku exists, every price in the feed is correct, and the 6,000 prices the
-- feed did not change are right.
CREATE TABLE supply.price_updates (
    sku          text PRIMARY KEY,
    price_p      integer NOT NULL,
    updated_at   timestamptz NOT NULL
);

CREATE TABLE supply.price_feed (
    sku          text PRIMARY KEY,
    price_p      integer NOT NULL,
    updated_at   timestamptz NOT NULL
);

INSERT INTO supply.price_updates (sku, price_p, updated_at)
SELECT
    'SKU-' || lpad(g::text, 6, '0'),
    ((g % 5000) + 100),
    TIMESTAMPTZ '2026-06-01 02:00:00+01'
FROM generate_series(1, 9000) g;

-- The feed is newer than everything already stored, and changes 3,000 prices.
INSERT INTO supply.price_feed (sku, price_p, updated_at)
SELECT
    'SKU-' || lpad(g::text, 6, '0'),
    CASE WHEN g % 3 = 0 THEN ((g % 5000) + 100) + 55 ELSE ((g % 5000) + 100) END,
    TIMESTAMPTZ '2026-06-08 02:00:00+01'
FROM generate_series(1, 9000) g;

INSERT INTO supply.price_updates (sku, price_p, updated_at)
SELECT sku, price_p, updated_at FROM supply.price_feed
ON CONFLICT (sku) DO UPDATE
    SET price_p = EXCLUDED.price_p,
        updated_at = EXCLUDED.updated_at
    WHERE supply.price_updates.updated_at > EXCLUDED.updated_at;

-- DEFECT fillfactor-was-set-to-a-hundred-on-an-index-over-a-column-that-keeps-changing
--
-- The index over the time a picking slot was last touched was built with
-- fillfactor set to a hundred, so every page was packed solid at build time,
-- and the column it indexes changes on every pick.
--
-- A btree index defaults to ninety for exactly this reason: the ten per cent
-- left free absorbs the entries that arrive after the build without
-- splitting a page. Packed to a hundred, the first new entry on a full page
-- splits it, and a split is a page allocation, two page writes and a parent
-- update. The setting was applied because the index is read far more than it
-- is written, which is true, and because a denser index is a smaller index,
-- which is also true, and both are reasons that apply to a static table.
-- This table is the opposite of static: the touched time is rewritten every
-- time a picker takes a unit, which is the highest write rate in the
-- warehouse. So the index is now a long chain of half full pages, larger
-- than it would have been at ninety, and it is rebuilt by hand every few
-- months.
--
-- Measured: 18,000 picking slots behind 1 index whose storage options pin
-- fillfactor at 100.
--
-- Dropping the option and reindexing returns it to the default and the
-- rebuilds stop. Every slot names a real aisle and sku, the unit counts are
-- right, and the index answers every query correctly.
CREATE TABLE ops.picking_slots (
    slot_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    aisle_code   text NOT NULL,
    sku          text NOT NULL,
    units_held   integer NOT NULL,
    touched_at   timestamptz NOT NULL
);

INSERT INTO ops.picking_slots (aisle_code, sku, units_held, touched_at)
SELECT
    'AIS-' || lpad(((g % 60) + 1)::text, 3, '0'),
    'SKU-' || lpad(((g % 9000) + 1)::text, 6, '0'),
    (g % 400),
    TIMESTAMPTZ '2026-07-01 05:00:00+01' + ((g % 18000) || ' minutes')::interval
FROM generate_series(1, 18000) g;

CREATE INDEX idx_picking_slots_touched ON ops.picking_slots (touched_at)
    WITH (fillfactor = 100);

-- DEFECT the-stored-generated-column-divides-two-integers-and-truncates
--
-- The number of packs is a stored generated column that divides the total
-- units by the pack size, both of them integers, so the division truncates
-- and the part pack at the end of every run is not counted.
--
-- Integer division in PostgreSQL discards the remainder. It does not round
-- and it does not warn, and the expression reads as ordinary arithmetic to
-- anyone reviewing the table. It is a generated column, which makes it worse
-- in one specific way: the value is computed by the database and stored, so
-- it carries the authority of a column rather than the suspicion of a
-- report, and nothing downstream recomputes it. The part pack is real
-- product. It is packed, labelled and shipped, and it is the pack that makes
-- a promotion run short, because a promotion is quoted in packs and picked
-- in units.
--
-- Measured: 9,000 pack yields of which 7,284 have units left over after the
-- division and therefore understate the packs by one.
--
-- Casting one side to numeric and applying ceil gives the number of packs
-- that actually leave the line, and the column can be redefined in place.
-- Every total and every pack size is correct, and the 1,716 products whose
-- run divides exactly are right.
CREATE TABLE catalog.pack_yields (
    yield_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_ref  text NOT NULL,
    total_units  integer NOT NULL,
    pack_size    integer NOT NULL,
    packs        integer GENERATED ALWAYS AS (total_units / pack_size) STORED
);

INSERT INTO catalog.pack_yields (product_ref, total_units, pack_size)
SELECT
    'PRD-' || lpad(g::text, 6, '0'),
    ((g * 7) % 900) + 20,
    ((g % 11) + 2)
FROM generate_series(1, 9000) g;

-- DEFECT the-same-column-holds-a-fraction-on-some-rows-and-a-percentage-on-others
--
-- Two loaders write the margin rate into the same column and they disagree
-- about the units, so four thousand eight hundred rows hold a percentage and
-- the rest hold a fraction, and nothing in the column says which is which.
--
-- The column is a plain numeric and both values are valid numerics. A rate
-- of 0.32 and a rate of 32 are the same margin, and the only way to tell
-- them apart is to know which system wrote the row, which is recorded but is
-- not something any report consults. The finance sheet has always quoted
-- percentages and the margin service has always quoted fractions, and they
-- were pointed at the same table when the reporting was consolidated, on the
-- assumption that a rate is a rate. Every consumer picks one convention and
-- is wrong about two rows in five. The category comparison is the visible
-- damage: a category loaded by the sheet appears to out-earn one loaded by
-- the service by a factor of a hundred, which is large enough that the chart
-- is dismissed as broken rather than read.
--
-- Measured: 12,000 margin rates of which 4,800 are greater than 1 and
-- therefore cannot be fractions.
--
-- Dividing the percentage rows by a hundred and constraining the column to
-- the range a fraction can take stops it recurring. Every rate names a real
-- category and period, and each loader's rows are internally consistent and
-- correct in its own units.
CREATE TABLE analytics.margin_rates (
    rate_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category_ref text NOT NULL,
    period_start date NOT NULL,
    margin_rate  numeric(8,4) NOT NULL,
    loaded_by    text NOT NULL
);

-- One loader writes the rate as a fraction. The other writes it as a percentage.
INSERT INTO analytics.margin_rates (category_ref, period_start, margin_rate, loaded_by)
SELECT
    'CAT-' || lpad(((g % 60) + 1)::text, 3, '0'),
    DATE '2026-01-01' + (((g % 8) * 30) || ' days')::interval,
    CASE WHEN g % 5 IN (0, 1)
         THEN (((g % 45) + 5))::numeric
         ELSE (((g % 45) + 5))::numeric / 100 END,
    CASE WHEN g % 5 IN (0, 1) THEN 'FINANCE-SHEET' ELSE 'MARGIN-SERVICE' END
FROM generate_series(1, 12000) g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.pack_yields ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.pack_yields:' || concat_ws('|', x.product_ref, x.total_units, x.pack_size))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.pack_yields x
)
UPDATE catalog.pack_yields t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.pack_yields ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.pack_yields ADD CONSTRAINT pack_yields_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_pack_yields_product_id ON catalog.pack_yields (product_id);

ALTER TABLE catalog.spec_documents ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.spec_documents:' || concat_ws('|', x.product_ref, x.doc))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.spec_documents x
)
UPDATE catalog.spec_documents t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.spec_documents ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.spec_documents ADD CONSTRAINT spec_documents_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_spec_documents_product_id ON catalog.spec_documents (product_id);

ALTER TABLE catalog.spec_source ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.spec_source:' || concat_ws('|', x.product_ref, x.spec_key, x.spec_value, x.sheet_ref))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.spec_source x
)
UPDATE catalog.spec_source t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.spec_source ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.spec_source ADD CONSTRAINT spec_source_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_spec_source_product_id ON catalog.spec_source (product_id);

ALTER TABLE ops.picking_slots ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.picking_slots:' || concat_ws('|', x.aisle_code, x.sku, x.units_held))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.picking_slots x
)
UPDATE ops.picking_slots t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.picking_slots ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.picking_slots ADD CONSTRAINT picking_slots_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_picking_slots_warehouse_id ON ops.picking_slots (warehouse_id);

ALTER TABLE ops.tip_offs ADD COLUMN warehouse_id integer;

WITH p AS (
    SELECT warehouse_id AS v, row_number() OVER (ORDER BY warehouse_id) - 1 AS k
      FROM fulfilment.warehouses
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.warehouses)
                 * power((abs(hashtext('ops.tip_offs:' || concat_ws('|', x.depot_code, x.body))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.tip_offs x
)
UPDATE ops.tip_offs t
   SET warehouse_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.tip_offs ALTER COLUMN warehouse_id SET NOT NULL;
ALTER TABLE ops.tip_offs ADD CONSTRAINT tip_offs_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES fulfilment.warehouses (warehouse_id);
CREATE INDEX ix_tip_offs_warehouse_id ON ops.tip_offs (warehouse_id);

ALTER TABLE supply.price_feed ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.price_feed:' || concat_ws('|', x.sku, x.price_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.price_feed x
)
UPDATE supply.price_feed t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.price_feed ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.price_feed ADD CONSTRAINT price_feed_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_price_feed_supplier_id ON supply.price_feed (supplier_id);

ALTER TABLE supply.price_updates ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.price_updates:' || concat_ws('|', x.sku, x.price_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.price_updates x
)
UPDATE supply.price_updates t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.price_updates ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.price_updates ADD CONSTRAINT price_updates_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_price_updates_supplier_id ON supply.price_updates (supplier_id);
-- <<< relationships
