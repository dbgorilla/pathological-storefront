-- Cross River Trading Co. -- card entries, short names, holdback rows,
-- intake tokens, month totals, contact addresses
-- author: T. Marchetti
-- postgres: 18
--
-- How a card payment is taken and recorded, what a product is called on the
-- shelf label, what is being held back from a depot, what lets goods in
-- through the gate, what each month came to, and who to write to at a supplier.

-- DEFECT the-audit-trigger-fires-before-the-masking-trigger-and-keeps-the-clear-value
--
-- Two BEFORE INSERT triggers run on the card entries, one writing the row to
-- the audit table and one masking the card number, and they fire in name
-- order, so the audit is written from the unmasked value every time.
--
-- PostgreSQL fires triggers of the same type in alphabetical order by
-- trigger name. That is the whole rule, it is documented, and it is a
-- property of the names rather than of the order the triggers were created
-- in or written down in. The masking trigger was added second and given a
-- name that happens to sort second, and the masking works perfectly on the
-- table everybody looks at. The audit table is not looked at, because it is
-- an audit table, so nothing has ever compared the two. The result is that
-- the database holds every card number in the clear in a table nobody
-- remembers exists, under a schema that is granted more widely than the card
-- table is, and every compliance review that checks the card column passes.
--
-- Measured: 11,000 card entries, all masked on the table, and 11,000 audit
-- rows holding the unmasked number.
--
-- Renaming the masking trigger so it sorts first, or better, doing the
-- masking in the audit function itself so the order stops mattering, closes
-- it. Every order reference is correct, the audit is complete and no entry
-- is missing.
CREATE TABLE payments.card_entries (
    entry_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref    text NOT NULL,
    card_digits  text NOT NULL,
    taken_at     timestamptz NOT NULL
);

CREATE TABLE payments.card_entry_audit (
    audit_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_ref    text NOT NULL,
    card_digits  text NOT NULL,
    seen_at      timestamptz NOT NULL
);

CREATE FUNCTION payments.fn_audit_card_entry() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO payments.card_entry_audit (order_ref, card_digits, seen_at)
    VALUES (NEW.order_ref, NEW.card_digits, NEW.taken_at);
    RETURN NEW;
END;
$$;

CREATE FUNCTION payments.fn_mask_card_entry() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.card_digits := '****-****-****-' || right(NEW.card_digits, 4);
    RETURN NEW;
END;
$$;

CREATE TRIGGER a_audit_card_entry BEFORE INSERT ON payments.card_entries
    FOR EACH ROW EXECUTE FUNCTION payments.fn_audit_card_entry();

CREATE TRIGGER b_mask_card_entry BEFORE INSERT ON payments.card_entries
    FOR EACH ROW EXECUTE FUNCTION payments.fn_mask_card_entry();

INSERT INTO payments.card_entries (order_ref, card_digits, taken_at)
SELECT
    'ORD-' || lpad(g::text, 7, '0'),
    '4' || lpad(((g * 7919) % 1000000000000000)::text, 15, '0'),
    TIMESTAMPTZ '2026-08-01 00:00:00+01' + ((g % 30000) || ' seconds')::interval
FROM generate_series(1, 11000) g;

-- DEFECT the-explicit-cast-to-a-narrow-varchar-truncates-without-complaint
--
-- The short name column is a varchar of twelve and the load writes the long
-- name into it with an explicit cast, and an explicit cast to a length
-- limited type truncates rather than raising an error.
--
-- This is the one place PostgreSQL will quietly lose characters. An ordinary
-- assignment of an over long string to a varchar column fails with a clear
-- message about the value being too long. Writing the same string with a
-- cast to the same type does not: the cast is read as an instruction to make
-- it fit, so it cuts. The load was written with the cast precisely because
-- the unqualified version kept failing, and the failures stopped, which was
-- taken as the fix. The short name is what the shelf label and the till
-- display print, so three quarters of the products are labelled with a
-- fragment that stops mid word, and two products whose names share an
-- opening are labelled identically.
--
-- Measured: 10,000 products of which 7,500 hold a short name that differs
-- from the long name it was cut from.
--
-- Generating the short name deliberately, with a rule about where to cut and
-- what to do about collisions, is the fix; the cast only hides the question.
-- Every product reference is correct and every long name is intact, which is
-- why the short name can be regenerated.
CREATE TABLE catalog.short_names (
    name_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_ref  text NOT NULL,
    long_name    text NOT NULL,
    name_short   varchar(12) NOT NULL
);

INSERT INTO catalog.short_names (product_ref, long_name, name_short)
SELECT
    'PRD-' || lpad(g::text, 6, '0'),
    ln,
    ln::varchar(12)
FROM generate_series(1, 10000) g
CROSS JOIN LATERAL (
    SELECT CASE WHEN g % 4 = 0
                THEN 'Item ' || g
                ELSE 'Long product title ' || g END AS ln
) t;

-- DEFECT row-security-is-on-but-not-forced-so-the-owner-still-sees-everything
--
-- Row level security is enabled on the holdback table and there is a policy
-- restricting each depot to its own rows, but it is not forced, and an
-- unforced policy does not apply to the table's owner.
--
-- Row security in PostgreSQL has two switches. ENABLE turns the policies on
-- for everybody except the owner. FORCE turns them on for the owner as well.
-- Only the first was set, which is the default and the one every example
-- uses, so the policy is real and correct and simply does not run for the
-- account that owns the table. That account is the one the application
-- connects as, because the application also creates and alters these tables.
-- So the protection works exactly when it is tested, by a depot login, and
-- does not work at all in production traffic. Nothing warns: the policy
-- exists, the table shows row security enabled, and a review that lists
-- policies sees a correct one.
--
-- Measured: 13,000 holdbacks on a table with row security enabled, 1 select
-- policy, and force row security off.
--
-- FORCE ROW LEVEL SECURITY on the table, plus a separate owner for DDL,
-- makes the policy mean what it says. Every holdback names a real depot,
-- every reason code is valid, and every amount is right.
CREATE TABLE ops.holdback_rows (
    holdback_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    depot_code   text NOT NULL,
    reason_code  text NOT NULL,
    amount_p     integer NOT NULL
);

INSERT INTO ops.holdback_rows (depot_code, reason_code, amount_p)
SELECT
    'DEP-' || lpad(((g % 40) + 1)::text, 3, '0'),
    CASE WHEN g % 3 = 0 THEN 'damage' WHEN g % 3 = 1 THEN 'shortage' ELSE 'dispute' END,
    ((g % 90000) + 100)
FROM generate_series(1, 13000) g;

ALTER TABLE ops.holdback_rows ENABLE ROW LEVEL SECURITY;

CREATE POLICY holdback_rows_by_depot ON ops.holdback_rows
    FOR SELECT TO depot_staff
    USING (depot_code = current_setting('app.depot_code', true));

GRANT SELECT ON ops.holdback_rows TO depot_staff;

-- DEFECT insert-was-granted-on-the-table-and-not-on-the-sequence-it-needs
--
-- The goods in writer has INSERT on the intake tokens and no USAGE on the
-- sequence the token id defaults from, so every insert it attempts fails on
-- a permission error about the sequence, not about the table.
--
-- A column defaulting to nextval evaluates that default as the inserting
-- role, so the role needs USAGE on the sequence as well as INSERT on the
-- table. An identity column would not need it, because an identity sequence
-- is owned by the column and inherits its permissions, and that difference
-- is the whole trap: the same table written two ways needs two different
-- grants. This table was written the older way, with an explicit sequence
-- and a default, and the grant script was written against a table that used
-- identity. The error message names the sequence, which is an object the
-- person reading it has usually never heard of, so the ticket is filed as a
-- database fault rather than a missing grant and sits.
--
-- Measured: 9,000 intake tokens on a table where goods_in_writer holds
-- INSERT and does not hold USAGE on the sequence the default calls.
--
-- Granting USAGE on the sequence, or converting the column to an identity
-- column, fixes it. Every token is unique, every issue time is right, and
-- nothing already loaded is affected.
CREATE SEQUENCE ops.intake_token_seq;

CREATE TABLE ops.intake_tokens (
    token_id     bigint NOT NULL DEFAULT nextval('ops.intake_token_seq') PRIMARY KEY,
    token_text   text NOT NULL,
    issued_at    timestamptz NOT NULL
);

INSERT INTO ops.intake_tokens (token_text, issued_at)
SELECT
    'TOK-' || lpad(g::text, 8, '0'),
    TIMESTAMPTZ '2026-07-01 00:00:00+01' + ((g % 40000) || ' seconds')::interval
FROM generate_series(1, 9000) g;

GRANT INSERT ON ops.intake_tokens TO goods_in_writer;

-- DEFECT the-month-range-stops-at-midnight-so-the-last-day-is-left-out
--
-- The monthly total sums everything between the first of the month and the
-- last day of it, and the last day of it as a timestamp means midnight at
-- the start of that day, so all but the first instant of the last day of
-- every month is left out.
--
-- BETWEEN is inclusive at both ends, which is why it reads as safe, and the
-- upper end here is a point in time rather than a day. Comparing a timestamp
-- against a date promotes the date to midnight. So the range closes twenty
-- four hours early, every month, and it is the last day that goes, which is
-- the busiest day of the month in a business that settles monthly. The
-- totals are close enough to look right and they are never reconciled
-- against the lines, because reconciling them is what the totals table is
-- for.
--
-- Measured: 12 monthly totals of which 11 are short, by 1,307,067 pence in
-- all.
--
-- A half open range, greater than or equal to the first of the month and
-- strictly less than the first of the next, is the form that has no end to
-- get wrong. Every line is correct and carries the right instant and amount,
-- so every total can be recomputed exactly.
CREATE TABLE analytics.month_lines (
    line_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    line_at      timestamptz NOT NULL,
    amount_p     integer NOT NULL
);

INSERT INTO analytics.month_lines (line_at, amount_p)
SELECT
    TIMESTAMPTZ '2026-01-01 00:00:00+00' + ((g % 8640) || ' hours')::interval,
    ((g % 5000) + 1)
FROM generate_series(1, 20000) g;

CREATE TABLE analytics.month_totals (
    month_start  date PRIMARY KEY,
    total_p      bigint NOT NULL
);

-- The window runs from the first of the month to the last day of it.
INSERT INTO analytics.month_totals (month_start, total_p)
SELECT
    m::date,
    coalesce((
        SELECT sum(l.amount_p) FROM analytics.month_lines l
        WHERE l.line_at BETWEEN m AND (m + INTERVAL '1 month' - INTERVAL '1 day')
    ), 0)
FROM generate_series(TIMESTAMPTZ '2026-01-01 00:00:00+00',
                     TIMESTAMPTZ '2026-12-01 00:00:00+00',
                     INTERVAL '1 month') m;

-- DEFECT the-same-address-is-on-file-twice-in-two-different-cases
--
-- The unique index on the contact address is on the text exactly as stored,
-- the portal re registration sent every address back in upper case, and an
-- upper case address is a different string, so three thousand buyers are now
-- on file twice.
--
-- The domain part of an email address is defined to be case insensitive and
-- the local part is, in practice, treated that way by every mail server
-- anybody uses. The database has no such opinion: it compares text, the
-- strings differ, and the unique index is satisfied. So the constraint that
-- was put there to stop exactly this did not fire, and it did not fire
-- correctly, by its own rules. Every mailing now goes twice to the same
-- person, which reads as carelessness and gets the sender marked as spam.
-- Worse, the two rows carry different added dates and either can be picked
-- as the current contact, so a change of address applied to one leaves the
-- other in place.
--
-- Measured: 11,000 contact addresses of which 6,000 have a counterpart
-- differing only in case, under 1 unique index on the exact text.
--
-- A unique index on lower of the address, or citext, enforces what was
-- meant. Every address belongs to a real supplier, every address is well
-- formed, and the 5,000 with no counterpart are correct as they stand.
CREATE TABLE supply.contact_addresses (
    address_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_ref text NOT NULL,
    email_text   text NOT NULL,
    added_on     date NOT NULL
);

CREATE UNIQUE INDEX idx_contact_addresses_email ON supply.contact_addresses (email_text);

INSERT INTO supply.contact_addresses (supplier_ref, email_text, added_on)
SELECT
    'SUP-' || lpad(((g % 500) + 1)::text, 4, '0'),
    'buyer' || g || '@crossriver.example',
    DATE '2026-02-01' + ((g % 180) || ' days')::interval
FROM generate_series(1, 8000) g;

-- The portal re-registration sent every address back in upper case.
INSERT INTO supply.contact_addresses (supplier_ref, email_text, added_on)
SELECT
    'SUP-' || lpad(((g % 500) + 1)::text, 4, '0'),
    upper('buyer' || g || '@crossriver.example'),
    DATE '2026-08-01' + ((g % 30) || ' days')::interval
FROM generate_series(1, 3000) g;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.short_names ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.short_names:' || concat_ws('|', x.product_ref, x.long_name, x.name_short))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.short_names x
)
UPDATE catalog.short_names t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.short_names ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.short_names ADD CONSTRAINT short_names_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_short_names_product_id ON catalog.short_names (product_id);

ALTER TABLE ops.holdback_rows ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('ops.holdback_rows:' || concat_ws('|', x.depot_code, x.reason_code, x.amount_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.holdback_rows x
)
UPDATE ops.holdback_rows t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.holdback_rows ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE ops.holdback_rows ADD CONSTRAINT holdback_rows_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_holdback_rows_customer_id ON ops.holdback_rows (customer_id);

ALTER TABLE ops.intake_tokens ADD COLUMN customer_id integer;

WITH p AS (
    SELECT customer_id AS v, row_number() OVER (ORDER BY customer_id) - 1 AS k
      FROM storefront.customers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.customers)
                 * power((abs(hashtext('ops.intake_tokens:' || concat_ws('|', x.token_text))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM ops.intake_tokens x
)
UPDATE ops.intake_tokens t
   SET customer_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE ops.intake_tokens ALTER COLUMN customer_id SET NOT NULL;
ALTER TABLE ops.intake_tokens ADD CONSTRAINT intake_tokens_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES storefront.customers (customer_id);
CREATE INDEX ix_intake_tokens_customer_id ON ops.intake_tokens (customer_id);

ALTER TABLE payments.card_entries ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.card_entries:' || concat_ws('|', x.order_ref, x.card_digits))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.card_entries x
)
UPDATE payments.card_entries t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.card_entries ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.card_entries ADD CONSTRAINT card_entries_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_card_entries_transaction_id ON payments.card_entries (transaction_id);

ALTER TABLE supply.contact_addresses ADD COLUMN supplier_id integer;

WITH p AS (
    SELECT supplier_id AS v, row_number() OVER (ORDER BY supplier_id) - 1 AS k
      FROM supply.suppliers
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM supply.suppliers)
                 * power((abs(hashtext('supply.contact_addresses:' || concat_ws('|', x.supplier_ref, x.email_text))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM supply.contact_addresses x
)
UPDATE supply.contact_addresses t
   SET supplier_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE supply.contact_addresses ALTER COLUMN supplier_id SET NOT NULL;
ALTER TABLE supply.contact_addresses ADD CONSTRAINT contact_addresses_supplier_id_fkey FOREIGN KEY (supplier_id) REFERENCES supply.suppliers (supplier_id);
CREATE INDEX ix_contact_addresses_supplier_id ON supply.contact_addresses (supplier_id);
-- <<< relationships
