-- Cross River Trading Co. -- scheduled promotions
-- author: T. Brennan
-- postgres: 11
--
-- Promotions run for a window and apply to a band of prices. Ranges are the
-- right type for both, and this is where the database starts using them.

CREATE TABLE marketing.promotions (
    promotion_id   serial PRIMARY KEY,
    name           varchar(255) NOT NULL,
    -- When the promotion is live.
    active_during  daterange NOT NULL,
    -- Which prices it applies to.
    price_band     numrange,
    -- Which basket sizes qualify.
    qty_band       int4range,
    percent_off    integer NOT NULL CHECK (percent_off BETWEEN 1 AND 100)
);

-- DEFECT promotions-overlap-unenforced
-- Two promotions on the same products with overlapping active_during windows
-- give a different answer depending on which one the application finds first.
-- An exclusion constraint would stop it. In 2019 nobody thought to add one,
-- and by the time the 2026 pricing tables got it right this table was too busy
-- to lock.
CREATE INDEX ix_promotions_active_during ON marketing.promotions USING gist (active_during);

CREATE TABLE marketing.promotion_products (
    promotion_id  integer NOT NULL REFERENCES marketing.promotions (promotion_id),
    product_id    integer NOT NULL REFERENCES storefront.products (product_id),
    PRIMARY KEY (promotion_id, product_id)
);

-- DEFECT missing-index-promotion-products-product
-- The composite primary key indexes (promotion_id, product_id). Lookups by
-- product_id alone cannot use it, and the catalogue page does exactly that on
-- every product view.

CREATE TABLE storefront.price_history (
    price_history_id  bigserial PRIMARY KEY,
    product_id        integer NOT NULL REFERENCES storefront.products (product_id),
    price_cents       integer NOT NULL,
    -- The window this price was in force. Half-open by convention.
    in_force          tstzrange NOT NULL,
    -- Every window this price has ever applied, including re-runs.
    all_windows       tstzmultirange,
    changed_by        varchar(255)
);
CREATE INDEX ix_price_history_product ON storefront.price_history (product_id);

-- DEFECT price-history-boundary-convention-undocumented
-- in_force is written as [start, end) by the pricing job and read as
-- [start, end] by the reporting queries. A price that changed at midnight is
-- counted in both days by one of them.
COMMENT ON COLUMN storefront.price_history.in_force IS
    'Half-open window. Some reports read it as closed.';
