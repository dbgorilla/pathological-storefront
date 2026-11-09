-- Cross River Trading Co. -- online store, first release
-- author: R. Vance (contractor)
-- postgres: 9.1
--
-- Four weeks, fixed price. Catalogue, basket, checkout, and enough order
-- history for the shop to chase a delivery. Anything past that is phase two.
--
-- ROADMAP.md: "2012 to 2013: the web store"

CREATE SCHEMA storefront;

-- The host preloads the statistics module; without the extension in this
-- database there is no per-query record to read, so nothing that watches the
-- shop can say which statement is slow.
CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;

-- Identity columns do not exist on 9.1, so every key here is a serial.
-- varchar(255) throughout because that is what the ORM emits.

CREATE TABLE storefront.categories (
    category_id   serial PRIMARY KEY,
    name          varchar(255) NOT NULL,
    slug          varchar(255) NOT NULL UNIQUE
);

-- DEFECT sku-unique-global (2014.06.02 drops this and replaces it with nothing)
-- One shop, so a SKU identifies a product outright.
CREATE TABLE storefront.products (
    product_id    serial PRIMARY KEY,
    sku           varchar(255) NOT NULL UNIQUE,
    name          varchar(255) NOT NULL,
    description   text,
    category_id   integer NOT NULL REFERENCES storefront.categories (category_id),
    price_cents   integer NOT NULL CHECK (price_cents >= 0),
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_products_category ON storefront.products (category_id);

CREATE TABLE storefront.inventory (
    product_id          integer PRIMARY KEY REFERENCES storefront.products (product_id),
    quantity_available  integer NOT NULL DEFAULT 0 CHECK (quantity_available >= 0),
    updated_at          timestamptz NOT NULL DEFAULT now()
);

-- DEFECT email-case-sensitive-unique
-- UNIQUE on varchar compares byte by byte, so Alice@ and alice@ are two
-- customers. Nobody notices until the support desk arrives in 2020.
CREATE TABLE storefront.customers (
    customer_id   serial PRIMARY KEY,
    email         varchar(255) NOT NULL UNIQUE,
    full_name     varchar(255) NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE storefront.orders (
    order_id      serial PRIMARY KEY,
    customer_id   integer NOT NULL REFERENCES storefront.customers (customer_id),
    status        varchar(255) NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'paid', 'shipped', 'cancelled')),
    total_cents   integer NOT NULL DEFAULT 0,
    placed_at     timestamptz NOT NULL DEFAULT now()
);

-- Customer order history rides this all day. It is the hot index.
CREATE INDEX ix_orders_customer ON storefront.orders (customer_id);
CREATE INDEX ix_orders_placed_at ON storefront.orders (placed_at);

CREATE TABLE storefront.order_items (
    order_item_id     serial PRIMARY KEY,
    order_id          integer NOT NULL REFERENCES storefront.orders (order_id),
    product_id        integer NOT NULL REFERENCES storefront.products (product_id),
    quantity          integer NOT NULL CHECK (quantity > 0),
    unit_price_cents  integer NOT NULL
);
CREATE INDEX ix_order_items_order ON storefront.order_items (order_id);

-- Every browse writes a row here. No retention, because in 2012 the table
-- was never going to get big.
CREATE TABLE storefront.page_views (
    page_view_id  bigserial PRIMARY KEY,
    customer_id   integer REFERENCES storefront.customers (customer_id),
    product_id    integer REFERENCES storefront.products (product_id),
    viewed_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_page_views_product ON storefront.page_views (product_id);

-- DEFECT unused-index-page-views-viewed-at
-- Added for a "recently viewed" feature that shipped using the product index
-- instead. Never scanned since.
CREATE INDEX ix_page_views_viewed_at ON storefront.page_views (viewed_at);
