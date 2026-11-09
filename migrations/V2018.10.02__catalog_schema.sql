-- Cross River Trading Co. -- brands, variants and attributes
-- author: S. Okonjo
-- postgres: 10
--
-- The catalogue team needs to add fields to products without waiting on a
-- schema review, so attributes are modelled as rows rather than columns.

CREATE SCHEMA catalog;

CREATE TABLE catalog.brands (
    brand_id     serial PRIMARY KEY,
    name         varchar(255) NOT NULL UNIQUE,
    website      varchar(255)
);

CREATE TABLE catalog.product_variants (
    product_variant_id  serial PRIMARY KEY,
    product_id          integer NOT NULL REFERENCES storefront.products (product_id),
    variant_sku         varchar(255) NOT NULL,
    size                varchar(255),
    colour              varchar(255),
    price_cents         integer CHECK (price_cents >= 0)
);
CREATE INDEX ix_product_variants_product ON catalog.product_variants (product_id);

-- DEFECT eav-product-attributes
-- Entity-attribute-value. Every filter on the catalogue becomes a self-join,
-- the planner cannot estimate any of it, and nothing constrains what an
-- attribute means. Added because schema changes took three weeks to review and
-- the catalogue team had a supplier feed to load on Monday.
CREATE TABLE catalog.product_attributes (
    product_attribute_id  serial PRIMARY KEY,
    product_id            integer NOT NULL REFERENCES storefront.products (product_id),
    attribute_name        varchar(255) NOT NULL,
    attribute_value       text,
    -- What the value is supposed to be parsed as. Advisory only.
    value_kind            varchar(255) DEFAULT 'text'
);
CREATE INDEX ix_product_attributes_product ON catalog.product_attributes (product_id);
CREATE INDEX ix_product_attributes_name ON catalog.product_attributes (attribute_name);

CREATE TABLE catalog.media_assets (
    media_asset_id  serial PRIMARY KEY,
    product_id      integer NOT NULL REFERENCES storefront.products (product_id),
    url             varchar(255) NOT NULL,
    alt_text        varchar(255),
    -- Small images were going to be stored inline. Two were, then the idea was
    -- dropped in favour of the CDN.
    thumbnail       bytea,
    sort_order      integer NOT NULL DEFAULT 0
);
CREATE INDEX ix_media_assets_product ON catalog.media_assets (product_id);

ALTER TABLE storefront.products
    ADD COLUMN brand_id integer REFERENCES catalog.brands (brand_id);

-- DEFECT missing-index-products-brand
-- The brand filter on the catalogue page joins on this column. No index was
-- added, because the column was added in a hurry and the filter shipped a
-- fortnight later in a different pull request.

-- DEFECT nullable-boolean-excluded-from-both-branches
--
-- Discontinuation moves out of the buyers' spreadsheet. The column is nullable
-- because the import could only classify the products it found in the
-- spreadsheet, and the rest were left for someone to decide later.
--
-- Nobody decided. A null boolean is not false, it is unknown, and three-valued
-- logic makes that bite in a way a null anything else does not: WHERE
-- is_discontinued returns neither the nulls nor an error, and WHERE NOT
-- is_discontinued does not return them either. The two branches the
-- application believes are exhaustive both drop the same rows.
--
-- So a product with a null here is absent from the live catalogue and absent
-- from the discontinued list, and the only way to notice is to add the two
-- counts and compare them against the table. Nobody adds them, because the
-- whole point of a boolean is that there are two cases.
ALTER TABLE storefront.products
    ADD COLUMN is_discontinued boolean;

-- DEFECT text-comparison-on-a-numeric-attribute
--
-- Heavy items need a two-person lift, so the warehouse asked for a list of
-- everything over five kilos. weight_kg is one of the attributes, the filter
-- is the number they asked for, and the view was signed off against a sample
-- of ten products that all came back correct.
--
-- attribute_value is text. Comparing text to text compares it character by
-- character, so '14.5' is less than '5' for the same reason that 'ab' is less
-- than 'b', and every weight that does not start with a digit above five falls
-- out of the list. The ten sampled products were all single-digit weights,
-- which is the range where the two comparisons agree.
--
-- 36 products are listed. 250 weigh more than five kilos. The 214 missing are
-- the ones from ten kilos up, so the list omits precisely the items it exists
-- to flag, and the heavier the item the more certain it is to be left off.
-- Casting the value to numeric fixes it and makes the view fail on the rows
-- whose value is not a number, which is the other half of what this column
-- allows.
CREATE VIEW catalog.v_heavy_products AS
SELECT product_id, attribute_value AS weight_kg
FROM catalog.product_attributes
WHERE attribute_name = 'weight_kg'
  AND attribute_value > '5';

-- DEFECT array-agg-without-order-by
--
-- The variant codes for a product, as one value, for the feed the marketplace
-- takes. array_agg is the right function and the grouping is right.
--
-- An aggregate with no ORDER BY inside it consumes its rows in whatever order
-- the plan delivers them, so the array's order is a property of the plan and
-- not of the data. The feed writes the array out as a joined string and the
-- marketplace stores that string as the product's variant list, comparing it
-- against the one it holds to decide whether anything changed.
--
-- Nothing changes and the string changes anyway, whenever the plan does: after
-- a vacuum, after the statistics move, when the scan goes parallel. Every
-- product is then republished and re-reviewed at the marketplace's end, which
-- has been put down to their side being flaky. ORDER BY variant_sku inside the
-- aggregate makes it stable and is four words.
CREATE VIEW catalog.v_product_variant_skus AS
SELECT product_id,
       array_agg(variant_sku) AS variant_skus
FROM catalog.product_variants
GROUP BY product_id;
