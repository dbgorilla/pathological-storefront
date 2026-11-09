-- Cross River Trading Co. -- carrier API integrations
-- author: P. Lindqvist
-- postgres: 9.6
--
-- Each carrier gives us an endpoint, an allowlist of source addresses, and a
-- handheld scanner fleet in the warehouse that talks to it.

CREATE TABLE fulfilment.carrier_endpoints (
    carrier_endpoint_id  serial PRIMARY KEY,
    carrier_id           integer NOT NULL REFERENCES fulfilment.carriers (carrier_id),
    host                 varchar(255) NOT NULL,
    -- The single address the carrier calls us back from.
    callback_address     inet,
    -- The range they told us to expect callbacks from.
    allowed_range        cidr,
    active               boolean NOT NULL DEFAULT true
);

-- DEFECT shared-sequence-across-tables
--
-- Written by copying the CREATE TABLE for fulfilment.carriers out of the 2016
-- migration and editing it. The serial in that file had already been expanded
-- by pg_dump into an explicit DEFAULT nextval(), and the copy kept it, so this
-- table's primary key draws from the sequence that belongs to carriers.
--
-- Two tables now share one counter. Neither has duplicate keys, which is the
-- only thing anybody checks, but the ids interleave: inserting a carrier moves
-- this table's next id, and the gaps in each look like deleted rows that never
-- existed. Any report that counts service levels by id range is wrong.
--
-- The sequence is owned by fulfilment.carriers.carrier_id, so dropping that
-- column or that table drops the sequence with it and leaves this table's
-- default pointing at nothing. The catalogue records the ownership on carriers
-- and records nothing here.
CREATE TABLE fulfilment.carrier_service_levels (
    service_level_id  integer NOT NULL PRIMARY KEY
                        DEFAULT nextval('fulfilment.carriers_carrier_id_seq'),
    -- DEFECT on-delete-set-default-with-no-such-parent
    --
    -- When a carrier is retired its service levels are meant to fall back to
    -- the house carrier, which the 2017 plan said would be carrier 9. ON DELETE
    -- SET DEFAULT plus a default of 9 says exactly that, and it is the tidiest
    -- way anyone found to write it.
    --
    -- Carrier 9 was never created. SET DEFAULT does not check that the default
    -- satisfies the key it is a foreign key for, and PostgreSQL has no way to
    -- check it at definition time, because the parent row could be inserted
    -- later. So this is accepted and sits there.
    --
    -- Retiring a carrier now fails. The delete fires the action, the action
    -- writes 9, and the same foreign key rejects 9 because there is no such
    -- carrier. The error names the foreign key on this table, which sends
    -- whoever is reading it to look for a service level that is wrong rather
    -- than at a default that points at nothing.
    carrier_id        integer NOT NULL DEFAULT 9
                        REFERENCES fulfilment.carriers (carrier_id)
                        ON DELETE SET DEFAULT,
    code              varchar(255) NOT NULL,
    max_days          integer NOT NULL CHECK (max_days > 0)
);

CREATE TABLE fulfilment.scanners (
    scanner_id      serial PRIMARY KEY,
    warehouse_id    integer NOT NULL REFERENCES fulfilment.warehouses (warehouse_id),
    asset_tag       varchar(255) NOT NULL UNIQUE,
    -- DEFECT mixed-macaddr-widths
    -- The 2017 scanners are 48-bit and use macaddr. The 2021 replacements are
    -- EUI-64 and did not fit, so a second column was added beside the first
    -- rather than migrating the type. Every query has to coalesce them.
    hw_address      macaddr,
    hw_address_eui64 macaddr8,
    last_seen_at    timestamptz
);

INSERT INTO fulfilment.carrier_endpoints (carrier_id, host, callback_address, allowed_range) VALUES
    (1, 'api.regionalmail.example',    inet '198.51.100.24',  cidr '198.51.100.0/24'),
    (2, 'edi.northernfreight.example', inet '203.0.113.9',    cidr '203.0.113.0/25'),
    (3, 'hooks.sameday.example',       NULL,                  cidr '192.0.2.0/24');

INSERT INTO fulfilment.carrier_service_levels (carrier_id, code, max_days) VALUES
    (1, 'STANDARD',  4),
    (1, 'TRACKED',   2),
    (2, 'PALLET',    7),
    (3, 'SAMEDAY',   1);

-- DEFECT concat-with-null-blanks-the-value
--
-- The despatch note prints a tracking link per shipment, built by sticking the
-- carrier's tracking URL and the consignment's tracking code together. Both
-- parts are already in the database, so the view is three lines and reads
-- correctly.
--
-- Concatenation in SQL is null-propagating: anything || NULL is NULL, not the
-- other operand. SameDay Couriers were onboarded without a tracking portal, so
-- their tracking_url is null, and every shipment carried by them produces a
-- null link rather than a link with a missing prefix. The tracking code beside
-- it is present and correct on all of them.
--
-- 3,542 of the 10,622 shipments print a blank where the link should be. The
-- despatch note does not error, because a null renders as an empty string on
-- the page; the customer gets a note with nothing to click and rings the
-- support desk, who can see the tracking code on their own screen and cannot
-- work out what the customer is looking at. concat() would return the prefix
-- it has, and coalesce on the URL would make the gap visible.
CREATE VIEW fulfilment.v_shipment_labels AS
SELECT s.shipment_id,
       s.carrier_id,
       s.status,
       s.tracking_code,
       c.tracking_url || s.tracking_code AS tracking_link
FROM fulfilment.shipments s
JOIN fulfilment.carriers c ON c.carrier_id = s.carrier_id;
