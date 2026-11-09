-- Cross River Trading Co. -- commissions, label prints, weighbridge, bundles
-- author: P. Adeyemi
-- postgres: 18
--
-- The commission register purchasing keep, the label print log, the weighbridge
-- tickets from the yard system, the contact screen the cleanup ran through, the
-- subscriber list, and the bundle picking labels.

-- DEFECT percent-column-holds-both-fractions-and-percentages
--
-- Supplier commission, one row per agreement. The 2019 agreements were typed in
-- as the percentage everybody says out loud, so two and a half per cent is 2.5.
-- The 2024 agreements were loaded from a feed that sends a fraction, so the
-- same rate is 0.025.
--
-- The column holds both and cannot tell them apart, because both are valid
-- numbers in range and the check constraint only says the rate is positive.
-- Anything that multiplies by the column is right for one convention and out by
-- a hundred for the other, in whichever direction the row happens to use.
--
-- Measured: 20 of the 60 agreements are stored as fractions and the other 40
-- as percentages. 20 suppliers hold one of each, so the same supplier is
-- billed two ways depending on which agreement the job reads.
--
-- The column needs one convention and a comment saying which, or a name that
-- carries it: rate_fraction or rate_percent. Nothing here is a database fault
-- and nothing in the database can detect it, because 0.025 and 2.5 are both
-- perfectly good commission rates.
CREATE TABLE supply.commission_rates (
    rate_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id integer NOT NULL REFERENCES supply.suppliers(supplier_id),
    agreed_on   date NOT NULL,
    rate        numeric(6,4) NOT NULL CHECK (rate > 0)
);

-- The 2019 agreements, typed in as percentages.
INSERT INTO supply.commission_rates (supplier_id, agreed_on, rate)
SELECT s.supplier_id, DATE '2019-04-01', 1.5 + (s.supplier_id % 6) * 0.25
FROM supply.suppliers s;

-- The 2024 feed, which sends fractions.
INSERT INTO supply.commission_rates (supplier_id, agreed_on, rate)
SELECT s.supplier_id, DATE '2024-09-01', (1.5 + (s.supplier_id % 6) * 0.25) / 100
FROM supply.suppliers s
WHERE s.supplier_id % 2 = 1;

-- DEFECT smallint-key-fed-by-a-sequence-that-outgrows-it
--
-- The label print log. The key was made a smallint because the first version
-- printed a few hundred labels a week and a smallint holds thirty two thousand.
-- It has printed about a hundred and twenty a day since the second warehouse
-- opened.
--
-- The identity sequence stops at the column's maximum, so the failure is not a
-- wrapped key or a duplicate: it is an insert that raises out of range, on the
-- day the counter reaches 32,767, for every label printed after it. The
-- warehouse cannot print a label and cannot dispatch.
--
-- Measured: the counter stands at 30,000, which leaves 2,767 before the
-- column's limit of 32,767, or about 23 days at the rate the log has filled.
--
-- Widening the column is an ALTER TABLE that rewrites the table and a lock on
-- the busiest table in the warehouse. Doing it now costs a quiet hour; doing it
-- on the day it fails costs the same hour with the warehouse stopped.
CREATE TABLE ops.label_prints (
    print_id    smallint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_id integer NOT NULL,
    printed_at  timestamptz NOT NULL
);

INSERT INTO ops.label_prints (shipment_id, printed_at)
SELECT 1 + (g % 900),
       TIMESTAMPTZ '2026-01-02 06:00+00' + (g * INTERVAL '12 minutes')
FROM generate_series(1, 30000) AS g;

-- DEFECT primary-key-on-a-double-precision-column
--
-- Weighbridge tickets, keyed by the ticket number the yard system exports. That
-- system builds the number from the site code and the millisecond the bridge
-- settled, so it is sixteen digits, and it exports every number as a floating
-- point value. The column was created to match the file.
--
-- A double precision value holds integers exactly only up to about nine
-- thousand million million. Above that the representable values are two apart,
-- so an odd ticket number cannot be stored and becomes the neighbour. The key
-- in the table is not the number the yard sent, and two consecutive yard
-- tickets can land on the same key, which a primary key will then reject as a
-- duplicate of a ticket it is not a duplicate of.
--
-- Measured: all 600 tickets read back as a different number from the one the
-- yard sent, which is kept beside them. The smallest is sent as
-- 9007199254740997 and stored as 9007199254741000.
--
-- The ticket number is an identifier, not a measurement, so numeric or text is
-- the type for it. Nothing failed at load, every row is there, every join
-- works, and the key matches nothing in the yard's own system.
CREATE TABLE legacy.weighbridge_tickets (
    ticket_no     double precision PRIMARY KEY,
    ticket_source numeric(16,0) NOT NULL,
    gross_kg      numeric(10,2) NOT NULL,
    weighed_on    date NOT NULL
);

COMMENT ON COLUMN legacy.weighbridge_tickets.ticket_source IS
    'The ticket number exactly as it appears in the yard export file.';

INSERT INTO legacy.weighbridge_tickets (ticket_no, ticket_source, gross_kg, weighed_on)
SELECT (9007199254740993 + 4 * g)::numeric(16,0)::double precision,
       (9007199254740993 + 4 * g)::numeric(16,0),
       1200 + (g % 700),
       DATE '2026-02-02' + (g % 150)
FROM generate_series(1, 600) AS g;

-- DEFECT instead-of-trigger-ignores-a-column
--
-- The contact screen writes through a view, which needs an INSTEAD OF trigger
-- because a view over a join is not updatable on its own. The trigger sets the
-- columns the screen sends.
--
-- It sets the ones the screen sent when it was written. A column added later is
-- not in the trigger body, so an update that changes it succeeds, reports one
-- row updated, and leaves the column exactly as it was. The write goes through
-- the view, the view reads the table, and the value the caller wrote is never
-- anywhere.
--
-- Measured: a cleanup lowercased every email and reformatted every phone number
-- through the view. All 780 emails changed. None of the 780 phone numbers did.
--
-- A trigger that writes some of the columns of a view is the failure mode the
-- view was supposed to prevent. The caller has no way to know: there is no
-- error, the row count is right, and reading the row back through the same view
-- is the only thing that would show it, which nothing does.
CREATE TABLE storefront.customer_contacts (
    contact_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id integer NOT NULL REFERENCES storefront.customers(customer_id),
    email       varchar(255) NOT NULL,
    phone       varchar(30) NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO storefront.customer_contacts (customer_id, email, phone)
SELECT c.customer_id,
       'Contact.' || c.customer_id || '@Example.COM',
       '01772 ' || lpad((500000 + c.customer_id)::text, 6, '0')
FROM storefront.customers c
WHERE c.customer_id % 4 = 0;

CREATE VIEW storefront.v_contact_details AS
SELECT cc.contact_id,
       cc.customer_id,
       cc.email,
       cc.phone
FROM storefront.customer_contacts cc;

CREATE FUNCTION storefront.fn_contact_details_write()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE storefront.customer_contacts
       SET email = NEW.email,
           updated_at = now()
     WHERE contact_id = OLD.contact_id;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_contact_details_write
    INSTEAD OF UPDATE ON storefront.v_contact_details
    FOR EACH ROW EXECUTE FUNCTION storefront.fn_contact_details_write();

-- The cleanup that ran through the screen.
UPDATE storefront.v_contact_details
   SET email = lower(email),
       phone = '0161 ' || substring(phone FROM 7);

-- DEFECT unique-index-includes-soft-deleted-rows
--
-- The subscriber list never deletes a row, because the unsubscribe has to be
-- provable for as long as the marketing rules say. The email is unique, which
-- is the rule the list is for.
--
-- The unique index covers every row, including the unsubscribed ones. So an
-- address that has unsubscribed cannot subscribe again: the insert raises a
-- unique violation, the signup form reports that something went wrong, and the
-- row that blocks it is one the application considers deleted.
--
-- Measured: 80 of the 400 rows are unsubscribed, and each one holds its
-- address against a new signup. The unique index has no predicate.
--
-- A unique index WHERE deleted_at IS NULL enforces the rule that was meant and
-- leaves the history alone. Every report on this table already filters the
-- deleted rows out, so the index is the only thing in the database that still
-- treats them as live.
CREATE TABLE marketing.subscriber_list (
    subscriber_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         varchar(255) NOT NULL UNIQUE,
    subscribed_at timestamptz NOT NULL,
    deleted_at    timestamptz
);

INSERT INTO marketing.subscriber_list (email, subscribed_at, deleted_at)
SELECT 'subscriber.' || lpad(g::text, 4, '0') || '@example.com',
       TIMESTAMPTZ '2025-06-01 09:00+00' + (g * INTERVAL '3 hours'),
       CASE WHEN g % 5 = 0
            THEN TIMESTAMPTZ '2026-02-01 09:00+00' + (g * INTERVAL '1 hour')
       END
FROM generate_series(1, 400) AS g;

-- DEFECT array-to-string-silently-drops-null-elements
--
-- Bundle picking labels. The components are an array of skus and the label is
-- the array joined with a plus, beside the number of components, so the picker
-- can check they have them all.
--
-- array_to_string drops null elements. It does not render them, does not put an
-- empty gap where they were, and does not take the optional third argument
-- unless it is given one. A bundle whose component was discontinued has a null
-- in the array, and its label lists one component fewer than the count printed
-- next to it.
--
-- Measured: 30 of the 120 bundles print a label with two components beside a
-- count of three. The label is the part the picker reads.
--
-- The third argument to array_to_string renders nulls as whatever is given, and
-- the honest fix is not to keep nulls in the array at all. The count and the
-- label disagree on the same row of the same label, which is the one place
-- somebody might have noticed, and nobody has.
CREATE TABLE catalog.product_bundles (
    bundle_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name           varchar(80) NOT NULL,
    component_skus text[] NOT NULL
);

INSERT INTO catalog.product_bundles (name, component_skus)
SELECT 'Bundle ' || lpad(g::text, 3, '0'),
       CASE WHEN g % 4 = 0
            THEN ARRAY['CRT-' || lpad(g::text, 5, '0'), NULL, 'CRT-' || lpad((g + 900)::text, 5, '0')]
            ELSE ARRAY['CRT-' || lpad(g::text, 5, '0'), 'CRT-' || lpad((g + 500)::text, 5, '0'),
                       'CRT-' || lpad((g + 900)::text, 5, '0')]
       END
FROM generate_series(1, 120) AS g;

CREATE VIEW analytics.v_bundle_labels AS
SELECT b.bundle_id,
       b.name,
       array_to_string(b.component_skus, ' + ') AS label,
       cardinality(b.component_skus)            AS component_count
FROM catalog.product_bundles b;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.product_bundles ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.product_bundles:' || concat_ws('|', x.name, x.component_skus))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.product_bundles x
)
UPDATE catalog.product_bundles t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.product_bundles ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.product_bundles ADD CONSTRAINT product_bundles_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_product_bundles_product_id ON catalog.product_bundles (product_id);

ALTER TABLE marketing.subscriber_list ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('marketing.subscriber_list:' || concat_ws('|', x.email))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.subscriber_list x
)
UPDATE marketing.subscriber_list t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.subscriber_list ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE marketing.subscriber_list ADD CONSTRAINT subscriber_list_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_subscriber_list_customer_id ON marketing.subscriber_list (customer_id);
-- <<< relationships
