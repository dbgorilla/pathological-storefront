-- Cross River Trading Co. -- Silverback Direct data load
-- author: (fixture data)
-- postgres: 14
--
-- The acquired customer base, their orders, and the bridge table that was
-- meant to be temporary.
--
-- UUIDs are derived from md5 of a counter rather than gen_random_uuid(), so
-- two builds of this fixture produce identical keys. Silverback's own database
-- used random v4 values, which is the defect the 2022 migration describes;
-- these are v4-shaped and just as random-looking, but reproducible.

INSERT INTO legacy.customers (id, email_address, display_name, created_at, updated_at, is_deleted)
SELECT
    md5('sbc' || g)::uuid,
    -- The first 900 use the same addresses as Cross River customers, which is
    -- how the email match found them. Case differs on some, deliberately.
    CASE
        WHEN g <= 900 AND g % 7 = 0 THEN 'Customer' || g || '@Example.invalid'
        WHEN g <= 900              THEN 'customer' || g || '@example.invalid'
        ELSE 'silverback' || g || '@example.invalid'
    END,
    'SB ' || (ARRAY['Ade','Bo','Cai','Dee','Eli','Fay','Gus','Hal'])[1 + (g % 8)]
        || ' ' || (ARRAY['Ward','Hale','Moss','Reid','Frye','Dunn'])[1 + (g % 6)],
    -- Local time, no offset. Half of these fall inside British Summer Time.
    TIMESTAMP '2016-01-01 09:00' + make_interval(days => (g * 97) % 2300, mins => (g * 13) % 1440),
    -- DEFECT updated-at-precedes-created-at
    --
    -- created_at and updated_at came out of Silverback's exporter as two
    -- independent columns, written by two different parts of their
    -- application, and the export carried whatever each one held.
    --
    -- Measured: 87 of these 1,200 rows have an updated_at earlier than their
    -- created_at. A row cannot be modified before it is made. Nothing in the
    -- schema says so: neither column is checked against the other, and no
    -- CHECK constraint anywhere in this database compares two timestamps on
    -- the same row.
    --
    -- The rows are otherwise ordinary and the values are otherwise
    -- plausible, so nothing flags them. They break anything that treats the
    -- pair as an interval -- an age report returns a negative duration, a
    -- "changed since creation" filter written as updated_at > created_at
    -- silently drops all 87, and a migration that takes the later of the two
    -- as a watermark takes created_at for those rows and re-imports them
    -- every run.
    --
    -- The bridge into storefront.customers copies neither column, so the
    -- contradiction stays in legacy and is never reconciled against
    -- anything that would expose it.
    TIMESTAMP '2021-06-01 09:00' + make_interval(days => (g * 11) % 300),
    (g % 25 = 0)
FROM generate_series(1, 1200) AS g;

INSERT INTO legacy.addresses (id, customer_id, line_one, city, postcode, country_code)
SELECT
    md5('sba' || g)::uuid,
    md5('sbc' || g)::uuid,
    (1 + (g % 120)) || ' ' || (ARRAY['High Street','Mill Lane','Quarry Road','Bridge Way'])[1 + (g % 4)],
    -- city and postcode move together. That is the correlation the planner
    -- cannot see without extended statistics.
    (ARRAY['Leeds','Bristol','Cardiff','Norwich','Dundee','Exeter'])[1 + (g % 6)],
    (ARRAY['LS','BS','CF','NR','DD','EX'])[1 + (g % 6)] || (1 + (g % 30)) || ' ' ||
        (1 + (g % 9)) || chr(65 + (g % 26)) || chr(65 + ((g * 3) % 26)),
    'GB'
FROM generate_series(1, 1200) AS g;

INSERT INTO legacy.orders (id, customer_id, order_number, order_total, placed_at, placed_at_epoch, is_deleted)
SELECT
    md5('sbo' || g)::uuid,
    md5('sbc' || (1 + (g % 1200)))::uuid,
    'SB-' || lpad(g::text, 7, '0'),
    ((500 + (g * 311) % 40000)::numeric / 100)::money,
    TIMESTAMP '2016-02-01 10:00' + make_interval(days => (g * 53) % 2200, mins => (g * 19) % 1440),
    -- The same instant as placed_at, read as UTC, which is the reading
    -- Silverback's exporter used and not the one anyone at Cross River would
    -- assume from a column named placed_at with no offset on it.
    extract(epoch FROM (TIMESTAMP '2016-02-01 10:00'
        + make_interval(days => (g * 53) % 2200, mins => (g * 19) % 1440)) AT TIME ZONE 'UTC')::integer,
    (g % 40 = 0)
FROM generate_series(1, 4000) AS g;

INSERT INTO legacy.order_lines (id, order_id, product_code, quantity, line_total)
SELECT
    md5('sbl' || g || '-' || s.n)::uuid,
    md5('sbo' || g)::uuid,
    -- Silverback product codes. Nothing in this database defines them.
    'SBP-' || lpad(((g * s.n * 7) % 900)::text, 5, '0'),
    1 + (s.n % 3),
    ((200 + (g * 97) % 9000)::numeric / 100)::money
FROM generate_series(1, 4000) AS g
CROSS JOIN generate_series(1, 2) AS s(n);

-- ---------------------------------------------------------------------------
-- The bridge, at 97% coverage
-- ---------------------------------------------------------------------------
--
-- 1200 Silverback customers. 1164 carry a Cross River customer_id, 36 do not.
-- That is exactly 97.00%, and it has not moved since 2022.

INSERT INTO legacy.customer_map (legacy_customer_id, customer_id, match_method, matched_at)
SELECT
    md5('sbc' || g)::uuid,
    CASE WHEN g <= 1164 THEN g ELSE NULL END,
    CASE
        WHEN g > 1164    THEN 'unmatched'
        WHEN g % 11 = 0  THEN 'manual'
        ELSE 'email'
    END,
    TIMESTAMPTZ '2022-06-01 12:00' + make_interval(mins => g)
FROM generate_series(1, 1200) AS g;
