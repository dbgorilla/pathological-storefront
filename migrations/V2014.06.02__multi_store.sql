-- Cross River Trading Co. -- second and third shop
-- author: D. Achebe
-- postgres: 9.3
--
-- Two new locations. The database has to learn that shops exist.
--
-- ROADMAP.md: "2014 to 2015: the second and third shop"

CREATE TABLE storefront.stores (
    store_id      serial PRIMARY KEY,
    code          varchar(255) NOT NULL UNIQUE,
    name          varchar(255) NOT NULL,
    opened_on     date NOT NULL,
    is_online     boolean NOT NULL DEFAULT false
);

INSERT INTO storefront.stores (store_id, code, name, opened_on, is_online) VALUES
    (1, 'CR-MAIN',   'Cross River (original shop)', DATE '1974-04-01', false),
    (2, 'CR-NORTH',  'Cross River North',           DATE '2014-05-19', false),
    (3, 'CR-WEB',    'crossriver.example web store', DATE '2012-03-01', true);
SELECT setval('storefront.stores_store_id_seq', 3);

-- DEFECT hardcoded-store-one-default
-- store_id 1 is the original shop, and it is the DEFAULT here because in 2014
-- most rows still came from it. That default outlives everyone who knew why.
ALTER TABLE storefront.orders
    ADD COLUMN store_id integer DEFAULT 1 REFERENCES storefront.stores (store_id);

-- DEFECT nullable-store-id-means-original
-- Left nullable on these three because backfilling the history was a phase-two
-- job. Null here means "the original shop", which is written down nowhere
-- except this comment.
ALTER TABLE storefront.products
    ADD COLUMN store_id integer REFERENCES storefront.stores (store_id);
ALTER TABLE storefront.inventory
    ADD COLUMN store_id integer REFERENCES storefront.stores (store_id);
ALTER TABLE storefront.page_views
    ADD COLUMN store_id integer REFERENCES storefront.stores (store_id);

-- DEFECT sku-unique-global
-- A SKU is now only unique within a shop, because the north shop reuses codes
-- from its own supplier catalogue. The table-wide constraint is dropped here.
-- The per-store constraint that should replace it was in the next sprint.
ALTER TABLE storefront.products DROP CONSTRAINT products_sku_key;

COMMENT ON COLUMN storefront.products.store_id IS
    'Null means the original shop. Not enforced anywhere.';
