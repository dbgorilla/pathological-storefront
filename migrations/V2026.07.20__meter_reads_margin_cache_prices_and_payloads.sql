-- Cross River Trading Co. -- meter reads, margin cache, price versions,
-- price feed notifications, webhook payloads, device reports
-- author: P. Adeyemi
-- postgres: 18
--
-- The meter reads from the depot submeters, the margin cache the pricing team
-- rebuild, the price screen the counter reads, the price feed notifications,
-- the webhook payload feed, and the device report deduplication.

-- DEFECT foreign-key-points-at-one-partition-not-the-parent
--
-- Meter reads are partitioned by year. The parent has no key of its own, so
-- each partition declares a primary key on the read id, and the read ids start
-- again at one in every year.
--
-- The flags table has a foreign key, and it names a partition rather than the
-- partitioned table, because a partitioned table could not be referenced when
-- this was written. So the constraint is satisfied by the 2025 read with that
-- id, whatever year the flag was actually about, and the flag is attached to a
-- row nobody chose. Every join back to the parent finds both rows.
--
-- Measured: 400 flags join to 800 meter reads, one in each year. The foreign
-- key validated every one of them against 2025.
--
-- A foreign key onto the partitioned table needs the partition key in the
-- child, which is the column that was left out: a flag is about a read in a
-- year, and the year is what makes the id mean anything. The constraint is
-- present, it is valid, and it is checking the wrong table.
CREATE TABLE archive.meter_reads (
    read_id    integer NOT NULL,
    read_year  integer NOT NULL,
    depot      varchar(20) NOT NULL,
    kwh        numeric(10,2) NOT NULL
) PARTITION BY LIST (read_year);

CREATE TABLE archive.meter_reads_2025 PARTITION OF archive.meter_reads
    FOR VALUES IN (2025);
CREATE TABLE archive.meter_reads_2026 PARTITION OF archive.meter_reads
    FOR VALUES IN (2026);

ALTER TABLE archive.meter_reads_2025 ADD PRIMARY KEY (read_id);
ALTER TABLE archive.meter_reads_2026 ADD PRIMARY KEY (read_id);

INSERT INTO archive.meter_reads (read_id, read_year, depot, kwh)
SELECT g, y, CASE WHEN g % 2 = 0 THEN 'preston' ELSE 'leeds' END,
       200 + (g % 700) + y - 2025
FROM generate_series(1, 600) AS g,
     (VALUES (2025), (2026)) AS years(y);

CREATE TABLE archive.meter_read_flags (
    flag_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    read_id integer NOT NULL REFERENCES archive.meter_reads_2025 (read_id),
    reason  varchar(40) NOT NULL
);

-- The flags the 2026 review raised.
INSERT INTO archive.meter_read_flags (read_id, reason)
SELECT g, 'reading above expected range'
FROM generate_series(1, 400) AS g;

-- DEFECT temp-table-in-a-function-survives-into-the-next-call
--
-- The margin cache is rebuilt by a function that stages its working rows in a
-- temporary table. The table is created IF NOT EXISTS, because the first
-- version of this failed on the second call of the day with a message saying
-- the relation already existed.
--
-- A temporary table lives for the session, not the call. IF NOT EXISTS stopped
-- the error and kept the rows: the second call stages its working set on top of
-- the first one's, and every call after that adds another copy. The cache is
-- rebuilt from a table that holds every run this connection has made, so the
-- longer a pooled connection lives the more copies the cache has.
--
-- Measured: two calls in one session leave 2 rows in the cache for every
-- product, 2,000 rows where there are 1,000 products.
--
-- ON COMMIT DROP, or a TRUNCATE at the top of the function, or no temporary
-- table at all, each fix it. The second call reports success and the cache has
-- the right numbers in it twice, so anything reading one product is right and
-- anything summing the cache is out by the number of calls.
CREATE TABLE analytics.margin_cache (
    product_id   integer NOT NULL,
    margin_cents integer NOT NULL,
    built_at     timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION analytics.fn_rebuild_margin_cache()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS tmp_margins (
        product_id   integer,
        margin_cents integer
    );

    INSERT INTO tmp_margins (product_id, margin_cents)
    SELECT p.product_id, 100 + (p.product_id * 13) % 4000
    FROM storefront.products p
    WHERE p.product_id % 2 = 0;

    DELETE FROM analytics.margin_cache;

    INSERT INTO analytics.margin_cache (product_id, margin_cents)
    SELECT t.product_id, t.margin_cents FROM tmp_margins t;
END;
$$;

-- The rebuild runs after the morning feed and again after the afternoon one.
SELECT analytics.fn_rebuild_margin_cache();
SELECT analytics.fn_rebuild_margin_cache();

-- DEFECT more-than-one-row-flagged-current
--
-- Prices are versioned, and the row the counter screen shows is the one flagged
-- current. Nothing in the table says only one version of a product may be
-- flagged.
--
-- The flag is maintained by the application, which clears the old row and sets
-- the new one in two statements. A run that fails between them, or two price
-- loads overlapping, leaves both flagged, and the screen shows whichever the
-- planner returns first. That is stable enough to look deliberate and changes
-- the day the table is vacuumed or the plan changes.
--
-- Measured: 60 of the 600 products have more than one current version, so the
-- screen shows whichever of the two the planner reaches first.
--
-- A unique index on (product_id) WHERE is_current makes the second row
-- impossible and costs nothing. Without it the table can hold a contradiction,
-- and the only place it shows is the price the customer is quoted.
CREATE TABLE catalog.price_versions (
    version_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id   integer NOT NULL,
    price_cents  integer NOT NULL,
    valid_from   date NOT NULL,
    is_current   boolean NOT NULL DEFAULT false
);

INSERT INTO catalog.price_versions (product_id, price_cents, valid_from, is_current)
SELECT p, 1000 + (p * 37) % 8000, DATE '2025-09-01', true
FROM generate_series(1, 600) AS p;

-- The February repricing, which set the new rows current and did not always
-- clear the old ones.
INSERT INTO catalog.price_versions (product_id, price_cents, valid_from, is_current)
SELECT p, 1200 + (p * 41) % 8000, DATE '2026-02-01', true
FROM generate_series(1, 600) AS p
WHERE p % 5 = 0;

UPDATE catalog.price_versions
   SET is_current = false
 WHERE valid_from = DATE '2025-09-01'
   AND product_id % 5 = 0
   AND product_id % 10 = 0;

CREATE VIEW analytics.v_current_price_screen AS
SELECT v.product_id, v.price_cents, v.valid_from
FROM catalog.price_versions v
WHERE v.is_current;

-- DEFECT before-insert-trigger-fires-for-rows-that-become-updates
--
-- The price feed is applied with an upsert, and a BEFORE INSERT trigger queues
-- a notification for every new item so the catalogue team can review it.
--
-- A BEFORE INSERT trigger fires for every row the statement attempts, including
-- the ones that go on to conflict and become updates. Postgres cannot know
-- which will conflict until it tries. So the queue holds a new item
-- notification for every row in the feed, and the ones for items that already
-- existed are indistinguishable from the real ones.
--
-- Measured: the feed carried 900 rows of which 300 were new, and the queue
-- holds 900 notifications. The catalogue team review 600 items that did not
-- change.
--
-- The notification belongs in an AFTER trigger, where the row that survived the
-- conflict is known, or in the RETURNING clause of the upsert with a test on
-- xmax. Nothing about the queue looks wrong: every notification names a real
-- item, and the count matches the size of the feed.
CREATE TABLE catalog.price_feed_items (
    sku         varchar(20) PRIMARY KEY,
    price_cents integer NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE catalog.price_feed_notifications (
    notification_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku             varchar(20) NOT NULL,
    queued_at       timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION catalog.fn_queue_new_item()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO catalog.price_feed_notifications (sku) VALUES (NEW.sku);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_price_feed_new_item
    BEFORE INSERT ON catalog.price_feed_items
    FOR EACH ROW EXECUTE FUNCTION catalog.fn_queue_new_item();

-- The items already on file before this morning's feed.
INSERT INTO catalog.price_feed_items (sku, price_cents)
SELECT 'PF-' || lpad(g::text, 6, '0'), 500 + (g * 19) % 6000
FROM generate_series(1, 600) AS g;

DELETE FROM catalog.price_feed_notifications;

-- This morning's feed: 900 rows, 300 of them new.
INSERT INTO catalog.price_feed_items (sku, price_cents)
SELECT 'PF-' || lpad(g::text, 6, '0'), 600 + (g * 23) % 6000
FROM generate_series(1, 900) AS g
ON CONFLICT (sku) DO UPDATE
    SET price_cents = excluded.price_cents,
        updated_at  = now();

-- DEFECT jsonb-array-elements-drops-rows-with-no-array
--
-- Webhook payloads are stored whole and the line items are read out of them by
-- expanding the items array in the FROM clause.
--
-- Expanding a set returning function in the FROM clause is an inner join
-- against it. A payload with no items array expands to no rows, so the payload
-- is not in the result at all: not with a null item, not as a row with nothing
-- beside it. It is simply absent, and the absence looks the same as a payload
-- that was never received.
--
-- Measured: 240 of the 1,200 payloads carry no items array and none of them
-- appears in the view. The view reports 2,880 item rows from 960 payloads.
--
-- LEFT JOIN LATERAL keeps the payload and leaves the item null, which is the
-- difference between a delivery with no lines and a delivery that never
-- arrived. The reconciliation counts what the view returns and the payloads it
-- cannot see are the ones that failed to parse upstream.
CREATE TABLE ops.webhook_payloads (
    payload_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    received_at timestamptz NOT NULL,
    body       jsonb NOT NULL
);

INSERT INTO ops.webhook_payloads (received_at, body)
SELECT TIMESTAMPTZ '2026-06-01 08:00+00' + (g * INTERVAL '7 minutes'),
       CASE WHEN g % 5 = 0
            THEN jsonb_build_object('order_ref', 'SO' || g, 'status', 'received')
            ELSE jsonb_build_object('order_ref', 'SO' || g,
                                    'items', jsonb_build_array(
                                        jsonb_build_object('sku', 'CRT-' || g, 'qty', 1),
                                        jsonb_build_object('sku', 'CRT-' || (g + 1), 'qty', 2),
                                        jsonb_build_object('sku', 'CRT-' || (g + 2), 'qty', 3)))
       END
FROM generate_series(1, 1200) AS g;

CREATE VIEW analytics.v_webhook_items AS
SELECT p.payload_id,
       p.body ->> 'order_ref' AS order_ref,
       i ->> 'sku'            AS sku,
       (i ->> 'qty')::integer AS qty
FROM ops.webhook_payloads p,
     jsonb_array_elements(p.body -> 'items') AS i;

-- DEFECT dedupe-on-a-json-payload-compares-text-not-structure
--
-- Device reports arrive as json and the duplicate suppression groups them by
-- the payload, casting it to text because json has no equality operator.
--
-- json keeps the text it was given: the key order, the spacing, the whole
-- document as it arrived. Two reports that say the same thing in a different
-- order are different text and are not duplicates. The cast that was added to
-- make the group by work is what makes it compare formatting.
--
-- Measured: the estate sent 900 reports carrying 80 distinct states, and the
-- deduplicated view returns 160 rows. Every state is in it twice, once per
-- key order.
--
-- jsonb normalises on the way in, has an equality operator, and would have made
-- the group by work without a cast. The column was made json to keep the
-- payload exactly as the device sent it, which is a reasonable thing to want
-- and the reason the deduplication cannot work.
CREATE TABLE ops.device_reports (
    report_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    asset_tag   varchar(20) NOT NULL,
    reported_at timestamptz NOT NULL,
    payload     json NOT NULL
);

INSERT INTO ops.device_reports (asset_tag, reported_at, payload)
SELECT 'HH' || lpad((1 + g % 450)::text, 5, '0'),
       TIMESTAMPTZ '2026-06-10 06:00+00' + (g * INTERVAL '4 minutes'),
       CASE WHEN g % 3 = 0
            THEN ('{"battery": ' || (20 + g % 80) || ', "firmware": "4.2"}')::json
            ELSE ('{"firmware": "4.2", "battery": ' || (20 + g % 80) || '}')::json
       END
FROM generate_series(1, 900) AS g;

CREATE VIEW analytics.v_distinct_device_reports AS
SELECT min(r.report_id)      AS report_id,
       r.payload::text       AS payload_text,
       count(*)              AS seen
FROM ops.device_reports r
GROUP BY r.payload::text;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.price_feed_items ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.price_feed_items:' || concat_ws('|', x.sku, x.price_cents))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.price_feed_items x
)
UPDATE catalog.price_feed_items t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.price_feed_items ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.price_feed_items ADD CONSTRAINT price_feed_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_price_feed_items_product_id ON catalog.price_feed_items (product_id);

ALTER TABLE catalog.price_feed_notifications ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.price_feed_notifications:' || concat_ws('|', x.sku))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.price_feed_notifications x
)
UPDATE catalog.price_feed_notifications t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.price_feed_notifications ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.price_feed_notifications ADD CONSTRAINT price_feed_notifications_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_price_feed_notifications_product_id ON catalog.price_feed_notifications (product_id);

ALTER TABLE ops.device_reports ADD COLUMN device_id integer;

WITH p AS (
    SELECT device_id AS v, row_number() OVER (ORDER BY device_id) - 1 AS k
      FROM ops.device_profiles
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.device_profiles)
                 * power((abs(hashtext('ops.device_reports:' || concat_ws('|', x.asset_tag, x.payload))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.device_reports x
)
UPDATE ops.device_reports t
   SET device_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.device_reports ALTER COLUMN device_id SET NOT NULL;
ALTER TABLE ops.device_reports ADD CONSTRAINT device_reports_device_id_fkey FOREIGN KEY (device_id) REFERENCES ops.device_profiles (device_id);
CREATE INDEX ix_device_reports_device_id ON ops.device_reports (device_id);

ALTER TABLE ops.webhook_deliveries ADD COLUMN payload_id integer;

WITH p AS (
    SELECT payload_id AS v, row_number() OVER (ORDER BY payload_id) - 1 AS k
      FROM ops.webhook_payloads
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM ops.webhook_payloads)
                 * power((abs(hashtext('ops.webhook_deliveries:' || concat_ws('|', x.endpoint, x.status_code))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.webhook_deliveries x
)
UPDATE ops.webhook_deliveries t
   SET payload_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.webhook_deliveries ALTER COLUMN payload_id SET NOT NULL;
ALTER TABLE ops.webhook_deliveries ADD CONSTRAINT webhook_deliveries_payload_id_fkey FOREIGN KEY (payload_id) REFERENCES ops.webhook_payloads (payload_id);
CREATE INDEX ix_webhook_deliveries_payload_id ON ops.webhook_deliveries (payload_id);
-- <<< relationships
