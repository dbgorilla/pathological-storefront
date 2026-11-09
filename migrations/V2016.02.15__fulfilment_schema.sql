-- Cross River Trading Co. -- distribution centre
-- author: P. Lindqvist
-- postgres: 9.5
--
-- Shipping moves out of the back of the shops and into a real warehouse.
-- Three weeks late. This migration was written the night before launch.
--
-- ROADMAP.md: "2016 to 2017: the warehouse"

CREATE SCHEMA fulfilment;

CREATE TABLE fulfilment.carriers (
    carrier_id     serial PRIMARY KEY,
    code           varchar(255) NOT NULL UNIQUE,
    name           varchar(255) NOT NULL,
    tracking_url   varchar(255)
);

CREATE TABLE fulfilment.warehouses (
    warehouse_id   serial PRIMARY KEY,
    code           varchar(255) NOT NULL UNIQUE,
    name           varchar(255) NOT NULL,
    opened_on      date NOT NULL
);

CREATE TABLE fulfilment.stock_locations (
    stock_location_id  serial PRIMARY KEY,
    warehouse_id       integer NOT NULL REFERENCES fulfilment.warehouses (warehouse_id),
    aisle              varchar(255) NOT NULL,
    bay                varchar(255) NOT NULL,
    -- Product is referenced across schemas, and this one is declared.
    product_id         integer REFERENCES storefront.products (product_id),
    quantity           integer NOT NULL DEFAULT 0
);
CREATE INDEX ix_stock_locations_warehouse ON fulfilment.stock_locations (warehouse_id);

-- DEFECT shipments-order-fk-missing
-- DEFECT shipments-order-index-missing
--
-- order_id points at storefront.orders. The foreign key was in this migration
-- until the Tuesday before launch, when adding it took an ACCESS EXCLUSIVE lock
-- on orders in staging for four minutes. It was pulled to get the deploy out
-- and never went back in.
--
-- The index went with it, because it was created as part of the same statement.
-- Shipment lookup by order sequential-scans as a result.
CREATE TABLE fulfilment.shipments (
    shipment_id     serial PRIMARY KEY,
    order_id        integer NOT NULL,
    carrier_id      integer NOT NULL REFERENCES fulfilment.carriers (carrier_id),
    warehouse_id    integer NOT NULL REFERENCES fulfilment.warehouses (warehouse_id),
    tracking_code   varchar(255),
    status          varchar(255) NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'picked', 'dispatched', 'delivered', 'lost')),
    dispatched_at   timestamptz,
    delivered_at    timestamptz
);

-- DEFECT set-null-on-not-null-shipment-items
--
-- Editing an order used to delete its lines and write them again. That failed
-- on any line already picked, because a shipment line pointed at it. ON DELETE
-- SET NULL was added so the shipment line would survive with a blank link
-- rather than block the edit.
--
-- order_item_id is NOT NULL, so the set to null cannot succeed either. The
-- delete now fails with a not-null violation instead of a foreign key
-- violation: the same block, under a message that points at the wrong column.
CREATE TABLE fulfilment.shipment_items (
    shipment_item_id  serial PRIMARY KEY,
    shipment_id       integer NOT NULL REFERENCES fulfilment.shipments (shipment_id),
    order_item_id     integer NOT NULL REFERENCES storefront.order_items (order_item_id)
                        ON DELETE SET NULL,
    quantity          integer NOT NULL CHECK (quantity > 0)
);
CREATE INDEX ix_shipment_items_shipment ON fulfilment.shipment_items (shipment_id);

COMMENT ON COLUMN fulfilment.shipments.order_id IS
    'storefront.orders.order_id. Not enforced -- see the 2016 launch notes.';

INSERT INTO fulfilment.carriers (code, name, tracking_url) VALUES
    ('RMAIL', 'Regional Mail',      'https://example.invalid/track/'),
    ('NFRT',  'Northern Freight',   'https://example.invalid/nf/'),
    ('SDAY',  'SameDay Couriers',   NULL);

INSERT INTO fulfilment.warehouses (code, name, opened_on) VALUES
    ('DC1', 'Cross River DC1', DATE '2016-02-15');

-- DEFECT delivered-at-never-populated
--
-- delivered_at was added with the rest of the table, for the delivery
-- confirmation the carriers send back. The webhook that would write it was
-- the next sprint's work and the warehouse launched without it.
--
-- Nothing has ever written the column. dispatched_at is set by the picking
-- system, which is inside the building, so the shipment lifecycle looks
-- complete right up to the last step. There is no error and no gap in the
-- table: the column is nullable, which is correct for a shipment that has not
-- arrived yet, and it is indistinguishable from a column that is correct and
-- merely waiting.
--
-- Measured: 10,622 shipments dispatched, none delivered. Every report that
-- filters on delivery returns nothing, which reads as a report with a bug
-- rather than as a column with no data, and the delivery performance figure
-- the carriers are paid against has been taken from their own files since
-- 2016 for exactly this reason.
CREATE VIEW fulfilment.v_delivered_shipments AS
SELECT shipment_id, order_id, carrier_id, dispatched_at, delivered_at
FROM fulfilment.shipments
WHERE delivered_at IS NOT NULL;
