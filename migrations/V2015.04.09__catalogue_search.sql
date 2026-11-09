-- Cross River Trading Co. -- search box on the catalogue
-- author: D. Achebe
-- postgres: 9.4
--
-- Full text search over product names and descriptions. The search box on the
-- storefront still runs ILIKE; this column was added for the version of the
-- feature that was going to replace it.

ALTER TABLE storefront.products
    ADD COLUMN search_vector tsvector;

-- DEFECT unmaintained-tsvector
-- Nothing populates this. There is no trigger, no generated column, and the
-- application never writes it. The GIN index below indexes an empty column,
-- and the search box went live on ILIKE instead.
CREATE INDEX ix_products_search_vector ON storefront.products USING gin (search_vector);

-- The saved searches feature, which does use tsquery.
CREATE TABLE storefront.saved_searches (
    saved_search_id  serial PRIMARY KEY,
    customer_id      integer NOT NULL REFERENCES storefront.customers (customer_id),
    label            varchar(255) NOT NULL,
    query            tsquery NOT NULL,
    created_at       timestamptz NOT NULL DEFAULT now()
);

COMMENT ON COLUMN storefront.products.search_vector IS
    'Intended for the tsquery search. Never populated; catalogue search uses ILIKE.';

-- DEFECT btree-index-unusable-for-prefix-search
--
-- The warehouse screen looks products up by the start of the SKU, because that
-- is what is printed on the shelf label and what people type. A B-tree index on
-- sku was added for it and the screen stayed slow.
--
-- This database runs under en_US.utf8. A B-tree built in a non-C collation
-- orders values by the collation's rules, and those rules do not agree with
-- byte order, so the planner cannot use the index to satisfy LIKE 'CR-01%': the
-- rows that share a prefix are not guaranteed to be adjacent in it. The index
-- is built, maintained on every write, and ignored by the one query it exists
-- for, which still reads all 2,000 rows.
--
-- The fix is an opclass, varchar_pattern_ops, which builds a second index in
-- byte order for exactly this. Nothing about the CREATE INDEX above suggests
-- one is needed, and the same statement is correct in a C-collation database,
-- which is what the developer who wrote it had locally.
CREATE INDEX ix_products_sku ON storefront.products (sku);
