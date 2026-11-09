-- Cross River Trading Co. -- contracted pricing, on PostgreSQL 18
-- author: K. Ardelean (platform)
-- postgres: 18
--
-- Cross River upgraded from 14 to 18 in January, skipping three majors. This
-- is the first migration written against the new version.
--
-- Supplier contracts fix a price for a period. Two contracts for the same
-- supplier and product must not overlap. Before 18 that meant an exclusion
-- constraint; 18 lets it be a primary key.
--
-- ROADMAP.md: "2026: the PostgreSQL 18 upgrade"

CREATE EXTENSION IF NOT EXISTS btree_gist;

-- A temporal primary key. The last key column must be a range or multirange,
-- and WITHOUT OVERLAPS makes the whole key a non-overlap constraint.
--
-- pg_constraint records this with conperiod = true, which is a column that did
-- not exist before PostgreSQL 18.
CREATE TABLE supply.contract_prices (
    supplier_id   integer NOT NULL REFERENCES supply.suppliers (supplier_id),
    product_id    integer NOT NULL REFERENCES storefront.products (product_id),
    price_cents   integer NOT NULL CHECK (price_cents >= 0),
    valid_during  daterange NOT NULL,
    PRIMARY KEY (supplier_id, product_id, valid_during WITHOUT OVERLAPS)
);

-- A temporal foreign key. The PERIOD part is not an equality test: the parent
-- rows matching on supplier_id and product_id must between them cover the
-- whole of the child's period.
-- DEFECT no-primary-key-contract-price-reviews
-- The temporal foreign key below took all the attention and nobody noticed the
-- table has no primary key. Two reviewers covering the same supplier, product
-- and window produce two identical rows that no constraint refuses and no
-- statement can tell apart.
CREATE TABLE supply.contract_price_reviews (
    supplier_id     integer NOT NULL,
    product_id      integer NOT NULL,
    reviewed_during daterange NOT NULL,
    reviewer        varchar(255),
    FOREIGN KEY (supplier_id, product_id, PERIOD reviewed_during)
        REFERENCES supply.contract_prices (supplier_id, product_id, PERIOD valid_during)
);

-- DEFECT temporal-constraint-inconsistent-with-2019-table
-- marketing.promotions does exactly the same job as contract_prices: a window
-- during which something applies. It was written in 2019 on PostgreSQL 11,
-- where none of this existed, and it protects itself with nothing at all.
--
-- So the database now enforces non-overlap correctly in one place and not at
-- all in another, for the same kind of data. A tool that checks only the new
-- table concludes the schema is careful about temporal data.

COMMENT ON TABLE supply.contract_prices IS
    'Non-overlap enforced by a temporal primary key. marketing.promotions does not.';
