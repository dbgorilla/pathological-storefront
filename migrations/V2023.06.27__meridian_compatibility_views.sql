-- Cross River Trading Co. -- Project Meridian, phase two: migrate
-- author: K. Ardelean (platform)
-- postgres: 14
--
-- Reads move to the new model. Existing reports cannot all be rewritten at
-- once, so they get a compatibility layer to read through.
--
-- The compatibility layer is itself built on the layer the 2019 reporting work
-- left behind, which is how it ends up three deep.

CREATE SCHEMA analytics;

-- Layer one: the priced order lines.
CREATE VIEW analytics.v_order_lines AS
SELECT
    oi.order_item_id,
    oi.order_id,
    oi.product_id,
    oi.quantity,
    oi.unit_price_cents,
    (oi.quantity * oi.unit_price_cents)::bigint AS line_total_cents
FROM storefront.order_items oi;

-- Layer two: order lines joined to the order.
-- DEFECT view-select-star-drift
-- This view selects o.* from orders. Every column added to orders since 2023
-- has silently appeared in this view, including the Meridian columns it was
-- written to hide and the PostgreSQL 18 generated column added in 2026.
CREATE VIEW analytics.v_orders_expanded AS
SELECT
    o.*,
    l.line_total_cents,
    l.product_id,
    l.quantity
FROM storefront.orders o
JOIN analytics.v_order_lines l ON l.order_id = o.order_id;

-- Layer three: what the old reports actually query.
-- DEFECT views-three-deep
-- v_order_totals over v_orders_expanded over v_order_lines. The planner
-- flattens it, but no human reading v_order_totals can tell which table a
-- column comes from, and a tool that stops at one level of view definition
-- never reaches storefront.order_items.
CREATE VIEW analytics.v_order_totals AS
SELECT
    e.order_id,
    e.customer_id,
    e.store_id,
    e.placed_at,
    sum(e.line_total_cents) AS computed_total_cents,
    max(e.total_cents)      AS recorded_total_cents
FROM analytics.v_orders_expanded e
GROUP BY e.order_id, e.customer_id, e.store_id, e.placed_at;

-- DEFECT unused-view-legacy-revenue
-- Written for a dashboard that was cancelled before launch. Nothing queries it.
CREATE VIEW analytics.v_legacy_revenue AS
SELECT
    date_trunc('month', lo.placed_at) AS month,
    count(*)                          AS order_count,
    sum(lo.order_total)               AS revenue
FROM legacy.orders lo
WHERE lo.is_deleted = false
GROUP BY 1;
