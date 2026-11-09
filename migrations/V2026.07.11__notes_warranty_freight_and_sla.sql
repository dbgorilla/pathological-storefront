-- Cross River Trading Co. -- ticket notes, warranty import, freight rates, SLA
-- author: P. Adeyemi
-- postgres: 18
--
-- The redacted note feed the outsourced desk reads, the 1990s warranty register
-- loaded off the old service system, the freight rate card, the audience
-- segments marketing build by hand, and the resolution time report.

-- DEFECT regexp-replace-without-the-global-flag-redacts-the-first-match-only
--
-- Notes are shown to an outsourced support desk with phone numbers removed.
-- regexp_replace does exactly that, and the redaction was checked against a
-- note containing a phone number, which it redacts perfectly.
--
-- regexp_replace replaces the first match only. The fourth argument 'g' is what
-- makes it replace all of them, and it is optional, so leaving it off is not an
-- error and produces output that looks redacted. Every note carrying a second
-- number publishes that number.
--
-- Measured: 400 of the 600 notes still contain a full phone number
-- after redaction. Every one of them had two numbers in the body.
--
-- Nothing downstream can tell. The field is called body and it visibly contains
-- the string [redacted], so the redaction is assumed to have worked, and the
-- numbers that survive are in the half of the note nobody reads twice.
CREATE TABLE support.ticket_notes (
    note_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket_id integer NOT NULL REFERENCES support.tickets(ticket_id),
    body      text NOT NULL
);

INSERT INTO support.ticket_notes (ticket_id, body)
SELECT t.ticket_id,
       CASE WHEN t.ticket_id % 3 = 0
            THEN 'Customer called from 07700' || lpad((900000 + t.ticket_id)::text, 6, '0')
                 || ', no answer.'
            ELSE 'Customer called from 07700' || lpad((900000 + t.ticket_id)::text, 6, '0')
                 || ', called back on 07700' || lpad((910000 + t.ticket_id)::text, 6, '0') || '.'
       END
FROM support.tickets t;

CREATE VIEW analytics.v_ticket_notes_redacted AS
SELECT n.note_id,
       n.ticket_id,
       regexp_replace(n.body, '07700[0-9]{6}', '[redacted]') AS body
FROM support.ticket_notes n;

COMMENT ON VIEW analytics.v_ticket_notes_redacted IS
    'Notes with phone numbers removed. Safe to share with the outsourced desk.';

-- DEFECT two-digit-year-mask-maps-to-the-wrong-century
--
-- The warranty register came off the service system that was retired in 2001.
-- It stored dates as six digits, and the import parsed them with a YY mask,
-- which is the mask that matches the file.
--
-- to_date with YY has to pick a century, and it picks by a fixed rule: 00 to 69
-- become 2000 to 2069, and 70 to 99 become 1970 to 1999. The rule is right for
-- a file written today and wrong for a file written before 2000, and the
-- registrations from the 1960s are now dated in the 2060s.
--
-- Measured: 55 of 240 registrations carry a date after 2030. The
-- source text is stored beside the date and disagrees with it on every one.
--
-- Nothing rejected them, because a date in 2065 is a perfectly valid date. The
-- warranty expiry report reads this column, so those units are covered for
-- another forty years and the register cannot say which decade they came from
-- without re-reading the text column nobody knew was there.
CREATE TABLE legacy.warranty_registrations (
    registration_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    serial_no       varchar(20) NOT NULL,
    registered_text varchar(8)  NOT NULL,
    registered_on   date        NOT NULL
);

COMMENT ON COLUMN legacy.warranty_registrations.registered_text IS
    'The six digits as they appear in the 2001 export file.';

INSERT INTO legacy.warranty_registrations (serial_no, registered_text, registered_on)
SELECT 'CRT' || lpad(g::text, 6, '0'),
       s.txt,
       to_date(s.txt, 'YY-MM-DD')
FROM generate_series(1, 240) AS g,
     LATERAL (SELECT lpad((62 + (g % 38))::text, 2, '0') || '-'
                     || lpad((1 + (g % 12))::text, 2, '0') || '-'
                     || lpad((1 + (g % 28))::text, 2, '0') AS txt) s;

-- DEFECT order-by-ordinal-points-at-the-wrong-column-after-a-column-was-added
--
-- The ten highest spending customers. The view was written with two columns,
-- the name and the spend, and an ORDER BY 2 DESC over the spend. The email was
-- added later, in front of the name, because two customers shared a name and
-- the account team could not tell which one the report meant.
--
-- An ordinal in ORDER BY names a position in the select list, not a column.
-- Adding a column in front moved every position by one, so ORDER BY 2 now
-- sorts by full_name. The view still returns ten rows and still calls them the
-- top ten by spend. It is ten of the customers last in the alphabet.
--
-- Measured: 49 customers share the last name, Taylor Smith, so which ten come
-- back depends on how the sort runs. None of them belongs in the list. The
-- real top ten account for 40,042,348 pennies, and all ten rows returned fall
-- outside it.
--
-- ORDER BY spend_cents DESC would have survived the edit. The ordinal did not,
-- and the edit that broke it was a correctness fix that was reviewed, merged
-- and tested by opening the report and seeing ten customers.
CREATE VIEW analytics.v_top_customers_by_spend AS
SELECT c.email,
       c.full_name,
       sum(o.total_cents) AS spend_cents
FROM storefront.orders o
JOIN storefront.customers c ON c.customer_id = o.customer_id
GROUP BY c.email, c.full_name
ORDER BY 2 DESC
LIMIT 10;

-- DEFECT numeric-trailing-zeros-split-one-value-into-two-groups
--
-- The rate card, grouped by rate to show how many lanes sit on each one. The
-- rates were loaded from two spreadsheets, one of which writes 0.80 and one of
-- which writes 0.8.
--
-- numeric keeps the scale it was given. 0.80 and 0.8 are equal as numbers and
-- different as text, and casting to text before grouping groups the text. Every
-- rate on the card appears twice, once per spelling, with the lanes split
-- between the two rows.
--
-- Measured: the view reports six rate bands over three
-- distinct rates. No band holds all the lanes charged at its rate.
--
-- Grouping by the numeric column is correct and the cast is what breaks it. The
-- cast was added to control how the rate printed, which it does, and the report
-- has been wrong since the second spreadsheet arrived.
CREATE TABLE supply.freight_rates (
    rate_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    carrier_id  integer NOT NULL REFERENCES fulfilment.carriers(carrier_id),
    lane        varchar(40) NOT NULL,
    rate_per_kg numeric NOT NULL
);

INSERT INTO supply.freight_rates (carrier_id, lane, rate_per_kg)
SELECT c.carrier_id,
       'lane-' || lpad(g::text, 3, '0'),
       CASE g % 6
            WHEN 0 THEN 0.80 WHEN 1 THEN 0.8
            WHEN 2 THEN 1.20 WHEN 3 THEN 1.2
            WHEN 4 THEN 2.50 ELSE 2.5
       END
FROM fulfilment.carriers c,
     generate_series(1, 30) AS g;

CREATE VIEW analytics.v_freight_rate_bands AS
SELECT r.rate_per_kg::text AS rate_per_kg,
       count(*)            AS lanes
FROM supply.freight_rates r
GROUP BY 1;

-- DEFECT array-length-of-an-empty-array-is-null-not-zero
--
-- Audience segments hold their members in an array. The size report calls
-- array_length on it, and the review that follows lists every segment with
-- fewer than ten members so marketing can retire or refill them.
--
-- array_length returns null for an empty array, not zero, because an empty
-- array has no dimensions to measure. A null is not less than ten, so the
-- segments with no members at all are the only ones the review never sees.
--
-- Measured: Eight of the 40 segments are empty and report a null size.
-- The under-ten review lists 21 segments and none of them are the
-- empty ones.
--
-- cardinality() returns zero for an empty array and is the function that was
-- wanted. The report has run monthly for a year and has never once named a
-- segment that would send to nobody.
CREATE TABLE marketing.audience_segments (
    segment_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       varchar(60) NOT NULL,
    member_ids integer[] NOT NULL DEFAULT '{}'
);

INSERT INTO marketing.audience_segments (name, member_ids)
SELECT 'Segment ' || lpad(g::text, 3, '0'),
       CASE WHEN g % 5 = 0
            THEN '{}'::integer[]
            ELSE (SELECT array_agg(m) FROM generate_series(1, 1 + (g % 14)) AS m)
       END
FROM generate_series(1, 40) AS g;

CREATE VIEW analytics.v_audience_segment_sizes AS
SELECT s.segment_id,
       s.name,
       array_length(s.member_ids, 1) AS members
FROM marketing.audience_segments s;

-- DEFECT interval-month-compares-as-thirty-days
--
-- Resolution time against the one month service level. age() gives the gap in
-- months and days, which is how the service level is written, and the view
-- compares it to INTERVAL '1 mon'.
--
-- Comparing two intervals converts a month to thirty days, because an interval
-- on its own has no calendar to measure against. age() has a calendar and
-- returns 1 mon 0 days for the whole of a thirty-one day month, so a ticket
-- open for thirty-one real days compares as thirty and passes. In February the
-- same arithmetic runs the other way and a thirty day ticket breaches.
--
-- Measured: 36 of the 600 resolved tickets are classified the
-- opposite way round from a plain comparison of elapsed days against thirty.
--
-- Whether the service level means calendar months or thirty days is a question
-- for the contract, and either answer can be implemented exactly. This one
-- implements neither: it measures in calendar months and then compares in
-- thirty day units, so the verdict depends on the month the ticket opened in.
CREATE TABLE support.ticket_resolutions (
    ticket_id   integer PRIMARY KEY REFERENCES support.tickets(ticket_id),
    resolved_at timestamptz NOT NULL
);

INSERT INTO support.ticket_resolutions (ticket_id, resolved_at)
SELECT t.ticket_id,
       t.opened_at + ((25 + (t.ticket_id % 12)) * INTERVAL '1 day')
FROM support.tickets t;

CREATE VIEW analytics.v_ticket_sla_breaches AS
SELECT r.ticket_id,
       t.opened_at,
       r.resolved_at,
       age(r.resolved_at, t.opened_at)                      AS time_to_resolve,
       age(r.resolved_at, t.opened_at) > INTERVAL '1 mon'   AS breached_sla
FROM support.ticket_resolutions r
JOIN support.tickets t ON t.ticket_id = r.ticket_id;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE legacy.warranty_registrations ADD COLUMN customer_id uuid;

WITH p AS (
    SELECT id AS v, row_number() OVER (ORDER BY id) - 1 AS k
      FROM legacy.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM legacy.customers)
                 * power((abs(hashtext('legacy.warranty_registrations:' || concat_ws('|', x.serial_no, x.registered_text))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM legacy.warranty_registrations x
)
UPDATE legacy.warranty_registrations t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE legacy.warranty_registrations ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE legacy.warranty_registrations ADD CONSTRAINT warranty_registrations_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES legacy.customers (id);
CREATE INDEX ix_warranty_registrations_customer_id ON legacy.warranty_registrations (customer_id);

ALTER TABLE marketing.audience_segments ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('marketing.audience_segments:' || concat_ws('|', x.name, x.member_ids))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.audience_segments x
)
UPDATE marketing.audience_segments t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.audience_segments ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE marketing.audience_segments ADD CONSTRAINT audience_segments_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_audience_segments_customer_id ON marketing.audience_segments (customer_id);
-- <<< relationships
