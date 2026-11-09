-- Cross River Trading Co. -- pallet plans, part numbers, address imports,
-- campaign targets, install ages, device profiles
-- author: P. Adeyemi
-- postgres: 18
--
-- The pallet figure the transport desk books lorries against, the part number
-- roots the catalogue groups on, the address file from the depot handhelds, the
-- mailing list the campaign goes to, the install age the service desk reads,
-- and the device settings the depot pushes out.

-- DEFECT cast-to-integer-rounds-instead-of-truncating
--
-- Pallets required for an order line, worked out as the quantity over the
-- number of units a pallet holds. The result is cast to integer because a
-- pallet count is a whole number.
--
-- A cast from numeric to integer rounds to the nearest whole number. It does
-- not truncate and it does not round up. A line needing two and a bit pallets
-- comes back as two, so the transport desk books space for less than the order
-- occupies, and the remainder is left on the dock.
--
-- Measured: 248 of the 600 lines report fewer pallets than the goods need, all
-- of them by one pallet. 23 lines report zero pallets for goods that are on the
-- order and have to go on the lorry.
--
-- ceil() is the function for this, and it is the only one of the three that is
-- right for a count of containers. The figure is plausible on every line, it is
-- never negative, and it is only ever wrong by one, which is exactly the size
-- that gets blamed on the loaders.
CREATE TABLE supply.pallet_plans (
    plan_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref   varchar(16) NOT NULL,
    qty         integer NOT NULL,
    pallet_size integer NOT NULL CHECK (pallet_size > 0)
);

INSERT INTO supply.pallet_plans (order_ref, qty, pallet_size)
SELECT 'SO' || lpad(g::text, 6, '0'),
       40 + (g * 17) % 260,
       100
FROM generate_series(1, 600) AS g;

CREATE VIEW analytics.v_pallets_required AS
SELECT p.plan_id,
       p.order_ref,
       p.qty,
       (p.qty::numeric / p.pallet_size)::integer AS pallets_required
FROM supply.pallet_plans p;

-- DEFECT trim-with-a-character-set-removes-more-than-the-suffix
--
-- Part numbers carry a size suffix, and the catalogue groups the sizes of one
-- part together by stripping it. The stripping is done with rtrim and the
-- suffix as its second argument.
--
-- The second argument to rtrim is a set of characters, not a suffix. It removes
-- every trailing character that appears in the set, repeatedly, until it meets
-- one that does not. So it strips the suffix from the parts that have it and
-- keeps going into the parts that end in one of those letters anyway, taking
-- digits and letters that are part of the number itself.
--
-- Measured: 300 of the 900 part numbers produce a root that is not the one the
-- catalogue holds. CRT-4001L becomes CRT-4001 and is grouped with a part it has
-- nothing to do with.
--
-- rtrim is for padding. Removing a known suffix is regexp_replace with an
-- anchored pattern, or a length test. Every root it produces looks like a part
-- number, so the grouping is wrong and nothing about it looks wrong.
CREATE TABLE supply.part_numbers (
    part_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    part_no        varchar(24) NOT NULL UNIQUE,
    catalogue_root varchar(24) NOT NULL
);

COMMENT ON COLUMN supply.part_numbers.catalogue_root IS
    'The grouping root as the printed catalogue prints it.';

INSERT INTO supply.part_numbers (part_no, catalogue_root)
SELECT base || suffix,
       CASE WHEN suffix = 'XL' THEN base ELSE base || suffix END
FROM (SELECT 'CRT-' || lpad((4000 + g)::text, 4, '0') AS base
      FROM generate_series(1, 300) AS g) b,
     (VALUES ('XL'), ('L'), ('')) AS s(suffix);

CREATE VIEW analytics.v_part_number_roots AS
SELECT p.part_id,
       p.part_no,
       rtrim(p.part_no, 'XL') AS root
FROM supply.part_numbers p;

-- DEFECT split-part-returns-an-empty-string-for-a-missing-field
--
-- Addresses come off the depot handhelds as one pipe delimited line, and the
-- import splits them into columns with split_part.
--
-- split_part returns an empty string when the field is not there, not null. So
-- a line sent with two fields instead of three produces an address with a
-- postcode that is present and blank. Every check written as postcode IS NULL
-- passes, the column is not nullable and does not need to be, and the delivery
-- run sorts by a postcode that is the empty string.
--
-- Measured: 250 of the 1,000 imported addresses have no postcode, and none of
-- them is null. A count of missing postcodes written the obvious way returns 0.
--
-- nullif(split_part(...), '') is the whole fix, and it belongs in the import,
-- not in every query downstream. The distinction between absent and empty is
-- the one the import threw away, and the database has no way to get it back.
CREATE TABLE ops.address_imports (
    import_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    raw_line  varchar(200) NOT NULL
);

INSERT INTO ops.address_imports (raw_line)
SELECT CASE WHEN g % 4 = 0
            THEN g || ' Mill Lane|Preston'
            ELSE g || ' Mill Lane|Preston|PR' || (1 + g % 9) || ' ' || (1 + g % 7) || 'AB'
       END
FROM generate_series(1, 1000) AS g;

CREATE VIEW analytics.v_delivery_addresses AS
SELECT a.import_id,
       split_part(a.raw_line, '|', 1) AS street,
       split_part(a.raw_line, '|', 2) AS town,
       split_part(a.raw_line, '|', 3) AS postcode
FROM ops.address_imports a;

-- DEFECT intersect-binds-tighter-than-union
--
-- The campaign goes to everyone on the newsletter or in the catalogue segment,
-- restricted to the ones who can be mailed. Three selects, a UNION and an
-- INTERSECT, no parentheses.
--
-- INTERSECT binds tighter than UNION, the way multiplication binds tighter than
-- addition. So the restriction applies to the catalogue branch only, and the
-- newsletter branch goes through untouched. The query is valid, it returns a
-- list of customers, and it is the list somebody would expect if they read it
-- left to right.
--
-- Measured: 1,560 customers are on the target list. 624 of them are not
-- mailable and are on it because they are on the newsletter.
--
-- Parentheses round the UNION are the fix and they belong there whether or not
-- they change anything, because nobody reading this can tell without looking up
-- the precedence. Nothing errors and nothing is missing from the list. There
-- are people on it who opted out.
CREATE TABLE marketing.campaign_audiences (
    entry_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id integer NOT NULL REFERENCES storefront.customers(customer_id),
    segment     varchar(20) NOT NULL,
    UNIQUE (customer_id, segment)
);

INSERT INTO marketing.campaign_audiences (customer_id, segment)
SELECT c.customer_id, 'newsletter'
FROM storefront.customers c
WHERE c.customer_id % 5 IN (0, 1);

INSERT INTO marketing.campaign_audiences (customer_id, segment)
SELECT c.customer_id, 'catalogue'
FROM storefront.customers c
WHERE c.customer_id % 5 IN (1, 2);

INSERT INTO marketing.campaign_audiences (customer_id, segment)
SELECT c.customer_id, 'mailable'
FROM storefront.customers c
WHERE c.customer_id % 2 = 0;

CREATE VIEW marketing.v_campaign_targets AS
SELECT a.customer_id FROM marketing.campaign_audiences a WHERE a.segment = 'newsletter'
UNION
SELECT a.customer_id FROM marketing.campaign_audiences a WHERE a.segment = 'catalogue'
INTERSECT
SELECT a.customer_id FROM marketing.campaign_audiences a WHERE a.segment = 'mailable';

-- DEFECT extract-day-from-age-drops-the-months
--
-- How long a machine has been installed, in days, for the service desk. The
-- gap is taken with age() and the days pulled out of it.
--
-- age() returns an interval in years, months and days, so its day field is the
-- day part of that breakdown and never exceeds thirty. Extracting it gives the
-- days left over after whole months, not the number of days between the two
-- dates. A machine installed fourteen months ago reads as eleven days old.
--
-- Measured: all 400 installs report an age under 31 days, and 388 of them
-- disagree with the real gap. The oldest machine in the table was installed 810
-- days before the report date and reports 18.
--
-- Subtracting one date from another gives an integer number of days and is the
-- whole answer. Every age on the screen is a small plausible number, every
-- machine looks recently installed, and the warranty report reads from it.
CREATE TABLE support.equipment_installs (
    install_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    serial_no    varchar(20) NOT NULL UNIQUE,
    installed_on date NOT NULL
);

INSERT INTO support.equipment_installs (serial_no, installed_on)
SELECT 'EQ' || lpad(g::text, 6, '0'),
       DATE '2026-09-01' - (g * 2 + (g % 13))
FROM generate_series(1, 400) AS g;

-- The report is run against a fixed as-at date so a reprint matches the print.
CREATE VIEW analytics.v_install_age AS
SELECT i.install_id,
       i.serial_no,
       i.installed_on,
       extract(day FROM age(DATE '2026-09-01', i.installed_on))::integer AS age_days
FROM support.equipment_installs i;

-- DEFECT jsonb-concatenation-replaces-a-nested-object
--
-- Device settings for the depot handhelds, kept as one jsonb document per
-- device. A settings push applies the change by concatenating the new fragment
-- onto the stored document.
--
-- The jsonb concatenation operator merges at the top level only. A fragment
-- carrying a nested object replaces the whole object of that name rather than
-- merging into it, so every sibling key under it is gone. The statement reports
-- the rows updated, the document is still valid, and the key that was not in
-- the fragment is not anywhere.
--
-- Measured: the push that set the network name removed the proxy setting from
-- all 240 devices that had one. No device on the estate now has a proxy
-- configured and none was meant to change.
--
-- jsonb_set writes one path and leaves the rest of the document alone, which is
-- what a settings push does. Concatenation is right for a flat document and
-- silently destructive for a nested one, and the two read the same in a diff.
CREATE TABLE ops.device_profiles (
    device_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    asset_tag varchar(20) NOT NULL UNIQUE,
    settings  jsonb NOT NULL
);

INSERT INTO ops.device_profiles (asset_tag, settings)
SELECT 'HH' || lpad(g::text, 5, '0'),
       jsonb_build_object(
           'network', jsonb_build_object('ssid', 'depot-legacy',
                                         'proxy', 'proxy.crossriver.internal:8080'),
           'scanner', jsonb_build_object('beep', true),
           'locale',  'en-GB')
FROM generate_series(1, 240) AS g;

-- The push that moved the estate onto the new wireless network.
UPDATE ops.device_profiles
   SET settings = settings || '{"network": {"ssid": "depot-2026"}}'::jsonb;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE supply.pallet_plans ADD COLUMN purchase_order_id integer;

WITH p AS (
    SELECT purchase_order_id AS v, row_number() OVER (ORDER BY purchase_order_id) - 1 AS k
      FROM supply.purchase_orders
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.purchase_orders)
                 * power((abs(hashtext('supply.pallet_plans:' || concat_ws('|', x.order_ref, x.qty, x.pallet_size))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.pallet_plans x
)
UPDATE supply.pallet_plans t
   SET purchase_order_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.pallet_plans ALTER COLUMN purchase_order_id SET NOT NULL;
ALTER TABLE supply.pallet_plans ADD CONSTRAINT pallet_plans_purchase_order_id_fkey FOREIGN KEY (purchase_order_id) REFERENCES supply.purchase_orders (purchase_order_id);
CREATE INDEX ix_pallet_plans_purchase_order_id ON supply.pallet_plans (purchase_order_id);

ALTER TABLE support.equipment_installs ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.equipment_installs:' || concat_ws('|', x.serial_no))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.equipment_installs x
)
UPDATE support.equipment_installs t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.equipment_installs ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.equipment_installs ADD CONSTRAINT equipment_installs_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_equipment_installs_ticket_id ON support.equipment_installs (ticket_id);
-- <<< relationships
