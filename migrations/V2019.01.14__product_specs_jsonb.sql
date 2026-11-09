-- Cross River Trading Co. -- supplier spec sheets
-- author: S. Okonjo
-- postgres: 11
--
-- Suppliers send a spec sheet as JSON. Rather than map every field, we keep
-- the document and query into it.

ALTER TABLE storefront.products
    ADD COLUMN spec jsonb;

-- DEFECT jsonb-duplicate-keys-silently-dropped
--
-- The raw document is kept beside the parsed one, so a bad parse can be
-- compared against what the supplier actually sent. That part was a good idea.
--
-- Some suppliers send the same key twice. Their sheets list a packed weight and
-- a unit weight and both are labelled weight_kg, which is their bug, not ours.
-- JSON does not forbid it, so nothing rejects the document.
--
-- jsonb keeps the last value for a duplicated key and discards the rest. Not an
-- error, not a warning, not a log line: the second weight silently replaces the
-- first at parse time. The catalogue shows the unit weight where the shipping
-- calculator needs the packed one, and the difference is only recoverable
-- because this column happens to still hold the original text. json rather than
-- jsonb would have preserved both, and so would text.
ALTER TABLE storefront.products
    ADD COLUMN spec_source text;

-- DEFECT wrong-index-type-on-jsonb
-- The catalogue filters with spec @> '{"voltage": "240V"}'. A B-tree index
-- cannot answer a containment query: @> is not a B-tree operator, so this
-- index is never used for the query it was created for. It needs GIN.
--
-- It does get used for whole-document equality, which nothing asks for.
CREATE INDEX ix_products_spec ON storefront.products (spec);

-- A second document column, this one with the right index, so the two can be
-- compared directly.
ALTER TABLE catalog.product_variants
    ADD COLUMN attributes jsonb;
CREATE INDEX ix_product_variants_attributes ON catalog.product_variants USING gin (attributes);

COMMENT ON COLUMN storefront.products.spec IS
    'Supplier spec sheet. Filtered with @>, which the btree index cannot serve.';

-- DEFECT jsonb-arrow-returns-quoted-json
--
-- The catalogue feed reads this view for the spec fields the marketplace wants
-- as columns. -> is the operator everybody reaches for, and the one every
-- example uses, because it is the one that navigates a document.
--
-- -> returns jsonb and ->> returns text. A string pulled out with -> keeps its
-- JSON quoting, so the origin of a product made in the UK is the four
-- characters "UK" with the quotes included rather than the two anybody wants.
-- The column's type is jsonb, which is correct and is not what the feed
-- declares, and every comparison against a plain string fails: origin = 'UK'
-- is false for all 500 products that have one.
--
-- Nothing errors, because the view never compares anything itself. The
-- marketplace rejects the quoted values as unknown countries and the feed logs
-- them as rejected rows, which reads as the marketplace being strict about a
-- country list. The whole fix is one extra angle bracket, three times.
CREATE VIEW storefront.v_product_spec_fields AS
SELECT product_id,
       sku,
       spec -> 'origin'    AS origin,
       spec -> 'voltage'   AS voltage,
       spec -> 'weight_kg' AS weight_kg
FROM storefront.products
WHERE spec IS NOT NULL;

-- DEFECT jsonb-key-typo-returns-null
--
-- Shipping weight out of the spec document, for the carrier rate card. The
-- operator is right this time and the cast is right; the key is 'weight' and
-- the document calls it 'weight_kg'.
--
-- A jsonb lookup for a key that is not there returns null. It is not an error
-- and it cannot be one: a document type has no schema, so there is nothing
-- against which a missing key is wrong. The view compiles, runs, and returns a
-- column of nulls.
--
-- Measured: all 500 products with a spec have a null shipping weight here, and
-- every one of them has a weight_kg in the document. The rate card treats a
-- null weight as the lowest band, so every parcel is quoted at the cheapest
-- rate and the carrier invoices the real one. The difference has been booked
-- as a carrier billing discrepancy since 2019.
CREATE VIEW storefront.v_product_shipping_weight AS
SELECT product_id,
       sku,
       (spec ->> 'weight')::numeric AS weight_kg
FROM storefront.products
WHERE spec IS NOT NULL;
