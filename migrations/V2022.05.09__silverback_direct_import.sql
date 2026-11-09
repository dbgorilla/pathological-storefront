-- Cross River Trading Co. -- Silverback Direct integration, phase one
-- author: M. Ruiz (integration programme)
-- postgres: 14
--
-- Cross River has acquired Silverback Direct. Six months to integrate.
--
-- The decision, which was the right one given that timeline, is to bring their
-- database in as its own schema and bridge the two rather than migrate. Their
-- conventions are not ours and this migration does not change them, because
-- changing them means touching every one of their queries.
--
-- The bridge is temporary.
--
-- ROADMAP.md: "2022: the acquisition"

CREATE SCHEMA legacy;

-- Silverback convention: uuid primary keys, plural table names, timestamp
-- without time zone, is_deleted flags rather than a status column.

-- DEFECT legacy-uuid-v4-primary-keys
-- Random v4 UUIDs as the primary key on their largest tables. Every insert
-- lands at a random point in the B-tree, so the index does not stay warm and
-- the table has poor insert locality. Cross River uses sequential integers
-- everywhere else.
CREATE TABLE legacy.customers (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- DEFECT collation-mismatch-on-bridged-email
    -- Silverback ran their database under the C locale and the import kept the
    -- column's collation so their own ordering did not change underneath them.
    -- Every Cross River text column uses the database default.
    --
    -- Nothing errors. Comparing this column to storefront.customers.email uses
    -- C, which is not the collation customers_email_key was built in, so that
    -- index cannot answer the comparison and a lookup of one customer reads
    -- every row of storefront.customers. The same lookup written against a
    -- literal uses the index. The bridge is the one query in the system that
    -- does this join, and it is the one query nobody profiled.
    email_address varchar(255) COLLATE "C" NOT NULL,
    display_name  varchar(255),
    -- DEFECT legacy-timestamp-without-timezone
    -- Their application wrote local time with no offset. After the acquisition
    -- it is read by Cross River code that assumes UTC. Rows written during
    -- British Summer Time are an hour out and nothing marks which ones.
    created_at    timestamp NOT NULL DEFAULT now(),
    updated_at    timestamp,
    is_deleted    boolean NOT NULL DEFAULT false
);
CREATE INDEX ix_legacy_customers_email ON legacy.customers (email_address);

CREATE TABLE legacy.orders (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id    uuid NOT NULL REFERENCES legacy.customers (id),
    order_number   varchar(255) NOT NULL UNIQUE,
    -- DEFECT legacy-money-type
    -- The money type is locale dependent: its output format and its parsing
    -- both depend on lc_monetary, so the same value renders differently on two
    -- servers. Nobody at Cross River would have chosen it.
    order_total    money NOT NULL,
    placed_at      timestamp NOT NULL,
    -- DEFECT epoch-integer-timestamps
    --
    -- Silverback's API returned every time as Unix epoch seconds. The import
    -- kept that column as it came and added placed_at beside it, so the two
    -- carry the same instant in two shapes. Silverback's own reports still read
    -- the epoch column and the migration plan never got as far as retiring it.
    --
    -- Stored as integer, so it stops working in January 2038 and gives no sign
    -- before then. No time zone, so the conversion back depends on whoever
    -- writes the query. No interval arithmetic, no BETWEEN on dates, no index
    -- that a date range query can use without a cast.
    placed_at_epoch integer NOT NULL,
    is_deleted     boolean NOT NULL DEFAULT false
);
CREATE INDEX ix_legacy_orders_customer ON legacy.orders (customer_id);

CREATE TABLE legacy.order_lines (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id     uuid NOT NULL REFERENCES legacy.orders (id),
    -- DEFECT legacy-product-reference-untyped
    -- Their product catalogue was never imported. This column holds their
    -- product code as text and points at nothing in this database.
    product_code varchar(255) NOT NULL,
    quantity     integer NOT NULL,
    line_total   money NOT NULL
);
CREATE INDEX ix_legacy_order_lines_order ON legacy.order_lines (order_id);

CREATE TABLE legacy.addresses (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id  uuid NOT NULL REFERENCES legacy.customers (id),
    line_one     varchar(255) NOT NULL,
    city         varchar(255) NOT NULL,
    postcode     varchar(255) NOT NULL,
    country_code char(2) NOT NULL DEFAULT 'GB',
    is_deleted   boolean NOT NULL DEFAULT false
);
CREATE INDEX ix_legacy_addresses_customer ON legacy.addresses (customer_id);

-- DEFECT correlated-columns-no-extended-stats
-- city and postcode are almost perfectly correlated: a postcode implies a city.
-- The planner assumes independence and multiplies the two selectivities, so a
-- query filtering on both underestimates its row count by roughly a hundred
-- times. CREATE STATISTICS would fix it. Nobody has created any.

COMMENT ON SCHEMA legacy IS
    'Silverback Direct, acquired 2022. Their conventions, not ours. Bridged, not migrated.';
