-- Cross River Trading Co. -- card disputes, VAT lines, chat transcripts,
-- basket events, unique visitors, supplier lead times
-- author: T. Marchetti
-- postgres: 18
--
-- A customer disputing a card payment, the VAT on a line, what was said in a
-- chat, what a customer did to a basket, how many people came to the site, and
-- how long a supplier takes to deliver.

-- DEFECT the-policy-checks-a-setting-the-application-never-sets
--
-- Row security is on the card disputes table and the policy compares a column
-- to a session setting that nothing sets.
--
-- The setting was to be set by the connection pool on checkout, from the signed
-- in user. The pool change was scoped, estimated and never scheduled. The
-- policy uses the two-argument form of current_setting, which returns null
-- rather than raising when the setting is missing, and a comparison to null is
-- not true, so the policy matches nothing. Every non-owner role sees an empty
-- table. The application connects as the owner, which bypasses row security
-- entirely, so the application sees everything and nobody has noticed that the
-- protection is not protection: it is a table that is either fully visible or
-- fully invisible depending on who you are.
--
-- Measured: 2,400 card disputes under row security with one policy whose
-- setting has no default at database or role level, so it evaluates to null
-- for every session.
--
-- Setting the variable on checkout makes the policy work; until then the policy
-- is decoration. Row security shows as enabled with a policy attached, which is
-- what every security review checks for.
CREATE TABLE payments.card_disputes (
    dispute_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_ref varchar(12) NOT NULL,
    amount_p    integer NOT NULL,
    raised_on   date NOT NULL
);

INSERT INTO payments.card_disputes (account_ref, amount_p, raised_on)
SELECT 'ACC-' || lpad((1 + (g % 400))::text, 5, '0'),
       500 + (g % 30000),
       DATE '2025-11-03' + (g % 320)
FROM generate_series(1, 2400) AS g;

ALTER TABLE payments.card_disputes ENABLE ROW LEVEL SECURITY;

CREATE POLICY card_disputes_own_account ON payments.card_disputes
    FOR ALL
    USING (account_ref = current_setting('app.account_ref', true));

-- DEFECT the-two-systems-disagree-about-which-side-rounds-the-vat
--
-- VAT is computed on the line by the storefront and on the invoice total by the
-- finance system. They round in different places and the two do not agree.
--
-- The storefront rounds each line to the penny and adds them up. Finance adds
-- the net lines, applies the rate once and rounds at the end. Both are
-- defensible and one of them has to be the one on the invoice. The table holds
-- both numbers, on the same row, because a reconciliation project put them
-- there to measure the gap and then ended. The gap is a penny or two per
-- invoice and it is real money that neither system will admit to.
--
-- Measured: 6,000 VAT lines, of which 2,402 hold a line VAT figure that does
-- not match the invoice VAT figure apportioned back to the line.
--
-- One of the two rounding rules, written down, with the other system reading
-- the first one's number. Both columns are correct by their own rule, so every
-- test of either system passes.
CREATE TABLE payments.vat_lines (
    line_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_ref  varchar(20) NOT NULL,
    net_p        integer NOT NULL,
    line_vat_p   integer NOT NULL,
    invoice_vat_p integer NOT NULL
);

INSERT INTO payments.vat_lines (invoice_ref, net_p, line_vat_p, invoice_vat_p)
SELECT 'INV-' || lpad((1 + (g % 1500))::text, 10, '0'),
       137 + (g % 4863),
       round((137 + (g % 4863)) * 0.20)::integer,
       floor((137 + (g % 4863)) * 0.20)::integer
FROM generate_series(1, 6000) AS g;

-- DEFECT the-index-was-built-on-the-column-the-query-sorts-not-filters
--
-- The chat transcript table is filtered by case reference and sorted by time.
-- The index is on the time.
--
-- The index was added after a complaint that the transcript screen was slow,
-- and it was added on the column in the ORDER BY because that is the column
-- somebody read off the slow query. Sorting was never the cost. The filter is
-- on the case reference, which has no index, so every transcript load scans the
-- table, and the index on the timestamp is maintained on every insert and used
-- by nothing that matters.
--
-- Measured: 30,000 chat transcript rows over 6,000 cases, with an index on the
-- timestamp and none on the case reference.
--
-- An index on (case_ref, said_at) serves the filter and the sort together. The
-- screen did get faster after the index was added, because the table was small
-- then, which is the evidence that closed the ticket.
CREATE TABLE support.chat_transcripts (
    message_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    case_ref   varchar(16) NOT NULL,
    said_at    timestamptz NOT NULL,
    speaker    varchar(12) NOT NULL,
    body       varchar(400) NOT NULL
);

CREATE INDEX chat_transcripts_said_at_idx ON support.chat_transcripts (said_at);

INSERT INTO support.chat_transcripts (case_ref, said_at, speaker, body)
SELECT 'CAS-' || lpad((1 + (g % 6000))::text, 8, '0'),
       TIMESTAMPTZ '2026-06-01 08:00:00+01' + (g * INTERVAL '90 seconds'),
       CASE WHEN g % 2 = 0 THEN 'agent' ELSE 'customer' END,
       'Message ' || g || ' on case ' || (1 + (g % 6000))
FROM generate_series(1, 30000) AS g;

-- DEFECT the-same-index-exists-twice-under-two-names
--
-- There are two indexes on the basket events table over the same column in the
-- same order. One of them is never chosen.
--
-- The first was added with the table. The second was added two years later by a
-- migration written against a schema dump that predated the first, by somebody
-- who checked whether the column was indexed by reading the migration history
-- rather than the database. Postgres will happily build both. Every insert into
-- the table maintains two identical B-trees, the planner picks one and the other
-- costs write throughput, disk and vacuum time for nothing.
--
-- Measured: 24,000 basket events carrying 2 indexes over the same single
-- column, one of which is redundant.
--
-- Dropping one is a single statement with no risk, once somebody establishes
-- that they really are the same, which needs the index definitions compared
-- rather than the names. Both have plausible names, so a list of indexes on the
-- table reads as two sensible entries.
CREATE TABLE storefront.basket_events (
    event_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    basket_ref  varchar(16) NOT NULL,
    event_type  varchar(20) NOT NULL,
    happened_at timestamptz NOT NULL
);

CREATE INDEX basket_events_basket_idx ON storefront.basket_events (basket_ref);
CREATE INDEX basket_events_basket_ref_idx ON storefront.basket_events (basket_ref);

INSERT INTO storefront.basket_events (basket_ref, event_type, happened_at)
SELECT 'BSK-' || lpad((1 + (g % 4000))::text, 8, '0'),
       (ARRAY['add', 'remove', 'update', 'checkout', 'abandon'])[1 + (g % 5)],
       TIMESTAMPTZ '2026-07-01 07:00:00+01' + (g * INTERVAL '100 seconds')
FROM generate_series(1, 24000) AS g;

-- DEFECT the-count-distinct-is-over-a-column-that-is-not-the-entity
--
-- The unique visitors figure counts distinct sessions. A session is not a
-- visitor.
--
-- The visitor identifier is on the row, in the visitor_ref column, and the view
-- counts session_ref instead. A visitor who comes back the next day is two
-- sessions and one visitor, and the figure the board sees is the first. It has
-- been called unique visitors since it was built, it goes up when people come
-- back more often, and coming back more often is what the marketing team is
-- measured on, so the number moves in the direction that confirms the work.
--
-- Measured: 36,000 site visits from 3,000 visitors over 12,000 sessions, where
-- the view reports 12,000 unique visitors.
--
-- count(DISTINCT visitor_ref) is the change and it will cut the headline number
-- by three quarters, which is the real reason it has not been made. Every other
-- figure in the same view is correct.
CREATE TABLE analytics.site_visits (
    visit_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    visitor_ref varchar(16) NOT NULL,
    session_ref varchar(16) NOT NULL,
    visited_on  date NOT NULL,
    pages       integer NOT NULL
);

INSERT INTO analytics.site_visits (visitor_ref, session_ref, visited_on, pages)
SELECT 'VIS-' || lpad((1 + (g % 3000))::text, 8, '0'),
       'SES-' || lpad((1 + (g % 12000))::text, 8, '0'),
       DATE '2026-08-03' + (g % 40),
       1 + (g % 18)
FROM generate_series(1, 36000) AS g;

CREATE VIEW analytics.v_unique_visitors AS
SELECT count(DISTINCT session_ref) AS unique_visitors,
       sum(pages) AS pages
FROM analytics.site_visits;

-- DEFECT the-not-null-was-added-with-a-default-that-hid-the-missing-rows
--
-- The supplier lead time was made not null with a default of seven days. The
-- rows that had no lead time now say seven.
--
-- Making a column not null needs the existing nulls dealt with, and the
-- migration dealt with them by filling in the default. Seven days was chosen
-- because it was the median. It is now indistinguishable from a real lead time
-- of seven days, and the planning system treats it as measured rather than
-- assumed. The suppliers whose lead time was never recorded are the small ones
-- and the new ones, which are the ones where the true figure is most often
-- longer than seven days.
--
-- Measured: 1,800 supplier lead times, of which 540 are exactly 7 and were
-- written by the migration rather than measured, against a column that is now
-- not null with a default of 7.
--
-- A nullable column, or a flag saying the figure is assumed, keeps the two
-- apart. Every row has a plausible number in it and the column is not null,
-- which is what the data quality check was asking for.
CREATE TABLE catalog.supplier_lead_times (
    supplier_ref varchar(12) PRIMARY KEY,
    lead_days    integer,
    recorded_on  date NOT NULL
);

INSERT INTO catalog.supplier_lead_times (supplier_ref, lead_days, recorded_on)
SELECT 'SUP-' || lpad(g::text, 5, '0'),
       CASE WHEN g % 10 < 3 THEN NULL ELSE 8 + (g % 20) END,
       DATE '2021-05-04' + (g % 1600)
FROM generate_series(1, 1800) AS g;

-- The migration that made the column not null.
UPDATE catalog.supplier_lead_times SET lead_days = 7 WHERE lead_days IS NULL;

ALTER TABLE catalog.supplier_lead_times
    ALTER COLUMN lead_days SET DEFAULT 7,
    ALTER COLUMN lead_days SET NOT NULL;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.supplier_lead_times ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.supplier_lead_times:' || concat_ws('|', x.supplier_ref, x.lead_days))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.supplier_lead_times x
)
UPDATE catalog.supplier_lead_times t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.supplier_lead_times ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.supplier_lead_times ADD CONSTRAINT supplier_lead_times_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_supplier_lead_times_product_id ON catalog.supplier_lead_times (product_id);

ALTER TABLE payments.card_disputes ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.card_disputes:' || concat_ws('|', x.account_ref, x.amount_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.card_disputes x
)
UPDATE payments.card_disputes t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.card_disputes ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.card_disputes ADD CONSTRAINT card_disputes_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_card_disputes_transaction_id ON payments.card_disputes (transaction_id);

ALTER TABLE payments.vat_lines ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.vat_lines:' || concat_ws('|', x.invoice_ref, x.net_p, x.line_vat_p, x.invoice_vat_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.vat_lines x
)
UPDATE payments.vat_lines t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.vat_lines ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.vat_lines ADD CONSTRAINT vat_lines_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_vat_lines_transaction_id ON payments.vat_lines (transaction_id);

ALTER TABLE support.call_summaries ADD COLUMN message_id integer;

WITH p AS (
    SELECT message_id AS v, row_number() OVER (ORDER BY message_id) - 1 AS k
      FROM support.chat_transcripts
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.chat_transcripts)
                 * power((abs(hashtext('support.call_summaries:' || concat_ws('|', x.case_ref, x.body))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.call_summaries x
)
UPDATE support.call_summaries t
   SET message_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.call_summaries ALTER COLUMN message_id SET NOT NULL;
ALTER TABLE support.call_summaries ADD CONSTRAINT call_summaries_message_id_fkey FOREIGN KEY (message_id) REFERENCES support.chat_transcripts (message_id);
CREATE INDEX ix_call_summaries_message_id ON support.call_summaries (message_id);

ALTER TABLE support.chat_transcripts ADD COLUMN ticket_id integer;

WITH p AS (
    SELECT ticket_id AS v, row_number() OVER (ORDER BY ticket_id) - 1 AS k
      FROM support.tickets
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM support.tickets)
                 * power((abs(hashtext('support.chat_transcripts:' || concat_ws('|', x.case_ref, x.speaker, x.body))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM support.chat_transcripts x
)
UPDATE support.chat_transcripts t
   SET ticket_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE support.chat_transcripts ALTER COLUMN ticket_id SET NOT NULL;
ALTER TABLE support.chat_transcripts ADD CONSTRAINT chat_transcripts_ticket_id_fkey FOREIGN KEY (ticket_id) REFERENCES support.tickets (ticket_id);
CREATE INDEX ix_chat_transcripts_ticket_id ON support.chat_transcripts (ticket_id);
-- <<< relationships
