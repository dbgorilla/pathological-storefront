-- Cross River Trading Co. -- Silverback Direct integration, phase two
-- author: M. Ruiz (integration programme)
-- postgres: 14
--
-- The bridge between their customers and ours. Matched on email address where
-- we could, by hand where we could not, and the rest were going to be worked
-- through by the support team.
--
-- This table is temporary.

-- DEFECT customer-bridge-incomplete
-- Coverage is 97%. The remaining 3% of Silverback customers have no Cross
-- River counterpart, so any report that joins through this table silently
-- drops them. Four years on, the same 3% are still unmatched.
CREATE TABLE legacy.customer_map (
    customer_map_id     serial PRIMARY KEY,
    legacy_customer_id  uuid NOT NULL UNIQUE REFERENCES legacy.customers (id),
    -- DEFECT customer-bridge-no-fk-to-storefront
    -- Points at storefront.customers.customer_id. No foreign key, because at
    -- import time some targets did not exist yet and the load had to succeed.
    -- DEFECT unique-permits-duplicate-nulls
    -- The bridge is meant to be one to one, so a unique constraint was added to
    -- say so. In PostgreSQL every null is distinct from every other null, so
    -- this permits any number of unmatched rows and constrains only the rows
    -- that were already matched. The case it was added to prevent, two bridge
    -- rows claiming the same Cross River customer, is the only case it catches;
    -- the unmatched rows it was also meant to police are exempt from it.
    customer_id         integer UNIQUE,
    match_method        varchar(255) NOT NULL
                          CHECK (match_method IN ('email', 'manual', 'unmatched')),
    matched_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_customer_map_customer ON legacy.customer_map (customer_id);

COMMENT ON COLUMN legacy.customer_map.customer_id IS
    'storefront.customers.customer_id. Not enforced. Null where unmatched.';

-- DEFECT two-sources-of-truth-for-customer
-- After this migration a person can exist as a row in storefront.customers, a
-- row in legacy.customers, or both. Nothing keeps the two in step: an address
-- change on one side does not reach the other, and they have been diverging
-- since 2022.
COMMENT ON TABLE legacy.customer_map IS
    'Temporary bridge, 2022. Still the only link between the two customer tables.';
