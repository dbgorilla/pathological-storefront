-- Cross River Trading Co. -- Project Meridian, deploy fixes
-- author: K. Ardelean (platform)
-- postgres: 14
--
-- Two constraints the new order model needs. Both went in NOT VALID to get the
-- release out on the Thursday; validating them takes a full table scan and the
-- change window had gone.
--
-- The team was reassigned in October. Neither has been validated.

-- DEFECT check-not-valid-order-total
-- Existing rows are not checked. Rows written after this point are. So the
-- constraint is true of new data and false of old data, and pg_constraint
-- records convalidated = false to say so.
--
-- There are rows in this table that violate it right now.
ALTER TABLE storefront.orders
    ADD CONSTRAINT orders_total_minor_non_negative
    CHECK (total_minor >= 0) NOT VALID;
-- TODO: validate once we have a maintenance window
--       VALIDATE CONSTRAINT takes a SHARE UPDATE EXCLUSIVE lock, not ACCESS
--       EXCLUSIVE, so this is safer than it looks. Still not done.

-- DEFECT fk-not-valid-orders-store
-- store_id has pointed at stores since 2014 but the foreign key was only added
-- here, and only for new rows. Older rows were never checked, and some of them
-- point at a store row that was deleted in the 2018 estate tidy-up.
ALTER TABLE storefront.orders
    ADD CONSTRAINT orders_store_fk
    FOREIGN KEY (store_id) REFERENCES storefront.stores (store_id) NOT VALID;

-- Which promotion, if any, discounted a given order line. Meridian needs this
-- to explain a total that does not match the list price.
CREATE TABLE marketing.applied_promotions (
    applied_promotion_id  serial PRIMARY KEY,
    order_item_id         integer NOT NULL REFERENCES storefront.order_items (order_item_id),
    promotion_id          integer,
    product_id            integer,
    discount_cents        integer NOT NULL DEFAULT 0
);
CREATE INDEX ix_applied_promotions_order_item
    ON marketing.applied_promotions (order_item_id);

-- DEFECT fk-composite-match-simple
-- A composite foreign key with the default MATCH SIMPLE. Under MATCH SIMPLE,
-- if ANY column of the key is null the constraint is skipped entirely. So a
-- row carrying a real promotion_id and a null product_id is accepted without
-- any check that the promotion exists.
--
-- MATCH FULL is what was meant: it only permits all-null or all-non-null.
-- The difference is one keyword and it is invisible in a schema diagram.
ALTER TABLE marketing.applied_promotions
    ADD CONSTRAINT applied_promotions_promotion_product_fk
    FOREIGN KEY (promotion_id, product_id)
    REFERENCES marketing.promotion_products (promotion_id, product_id)
    MATCH SIMPLE NOT VALID;
