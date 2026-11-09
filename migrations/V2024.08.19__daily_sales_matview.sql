-- Cross River Trading Co. -- daily sales dashboard
-- author: N. Farrell (data)
-- postgres: 15
--
-- A materialised view behind the dashboard everyone opens on Monday morning.
-- Refreshed by a cron job on the reporting box.

-- DEFECT stale-materialised-view
-- The cron job that refreshed this lived on the reporting server, which was
-- decommissioned during the 2025 cloud migration. Nothing replaced it.
--
-- The view still answers every query, instantly, with 2025 data. It carries no
-- indication of when it was last refreshed, so the dashboard looks healthy.
CREATE MATERIALIZED VIEW analytics.mv_daily_sales AS
SELECT
    date_trunc('day', o.placed_at)::date AS sales_day,
    o.store_id,
    count(*)                             AS order_count,
    sum(o.total_cents)::bigint           AS revenue_cents,
    count(DISTINCT o.customer_id)        AS customer_count
FROM storefront.orders o
WHERE o.status IN ('paid', 'shipped')
GROUP BY 1, 2
WITH NO DATA;

CREATE UNIQUE INDEX ux_mv_daily_sales ON analytics.mv_daily_sales (sales_day, store_id);

COMMENT ON MATERIALIZED VIEW analytics.mv_daily_sales IS
    'Refreshed by cron on the reporting box until that box was decommissioned in 2025.';

-- A second view over the materialised view, so the staleness propagates.
CREATE VIEW analytics.v_store_performance AS
SELECT
    s.store_id,
    s.name AS store_name,
    coalesce(sum(m.revenue_cents), 0) AS revenue_cents,
    coalesce(sum(m.order_count), 0)   AS order_count
FROM storefront.stores s
LEFT JOIN analytics.mv_daily_sales m ON m.store_id = s.store_id
GROUP BY s.store_id, s.name;
