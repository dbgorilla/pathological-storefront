-- Cross River Trading Co. -- blocklist, agent logins, category tree, events
-- author: P. Adeyemi
-- postgres: 18
--
-- The domains marketing are not allowed to mail, the support agent logins, the
-- notes a policy was written for, the category tree the homepage reads, the
-- order preference documents, and the shipment status the tracking page shows.

-- DEFECT not-equals-any-over-a-blocklist-matches-everything
--
-- Marketing may not mail certain domains: competitors, one regulator, and the
-- addresses legal asked for by name. The mailable list excludes them with a
-- not equals against the blocklist.
--
-- ANY means at least one. x <> ANY (list) asks whether there is at least one
-- entry x differs from, which is true for every x the moment the list holds two
-- different entries. The filter that reads as is not on the blocklist is
-- satisfied by every address in the table, including the blocked ones. With a
-- single-entry blocklist it works, which is what it was tested against.
--
-- Measured: all 300 subscribers are mailable according to the view, and 90 of
-- them are on a blocked domain.
--
-- ALL is the quantifier for the question being asked, and NOT IN or NOT EXISTS
-- say it without a quantifier at all. The filter is present, it is in the
-- WHERE clause, and it has never removed a row.
CREATE TABLE marketing.blocked_domains (
    domain      varchar(80) PRIMARY KEY,
    blocked_on  date NOT NULL,
    reason      varchar(60) NOT NULL
);

INSERT INTO marketing.blocked_domains (domain, blocked_on, reason)
VALUES ('rivalgoods.example',  DATE '2024-02-11', 'competitor'),
       ('marketwatch.example', DATE '2024-02-11', 'competitor'),
       ('regulator.example',   DATE '2025-06-30', 'regulator request'),
       ('noreply.example',     DATE '2025-11-02', 'legal');

CREATE TABLE marketing.subscriber_domains (
    subscriber_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         varchar(255) NOT NULL UNIQUE,
    email_domain  varchar(80) NOT NULL
);

INSERT INTO marketing.subscriber_domains (email, email_domain)
SELECT 'reader.' || lpad(g::text, 4, '0') || '@' || d.domain, d.domain
FROM generate_series(1, 300) AS g,
     LATERAL (SELECT CASE g % 10
                          WHEN 0 THEN 'rivalgoods.example'
                          WHEN 3 THEN 'regulator.example'
                          WHEN 7 THEN 'noreply.example'
                          ELSE 'example.com'
                     END AS domain) d;

CREATE VIEW marketing.v_mailable_subscribers AS
SELECT s.subscriber_id,
       s.email,
       s.email_domain
FROM marketing.subscriber_domains s
WHERE s.email_domain <> ANY (SELECT b.domain FROM marketing.blocked_domains b);

COMMENT ON VIEW marketing.v_mailable_subscribers IS
    'Subscribers not on a blocked domain. The send job reads this and nothing else.';

-- DEFECT invalid-unique-index-left-by-a-failed-concurrent-build
--
-- Agent logins are unique by email. The index was rebuilt with CREATE INDEX
-- CONCURRENTLY during a release, because a concurrent build does not lock the
-- table, and the build failed part way through.
--
-- A failed concurrent build leaves the index behind, marked invalid and not
-- ready. Nothing removes it and nothing reports it. The planner will not use
-- it, so queries that used to be index lookups are sequential scans, and more
-- to the point it does not enforce anything: the uniqueness the table is meant
-- to have stopped existing the moment the build failed, and the constraint is
-- still listed when anybody looks at the table.
--
-- Measured: 60 agent accounts share an email address with another account,
-- across 30 addresses. The index reports indisvalid false.
--
-- DROP INDEX and a fresh build is the whole fix, and it has to be done before
-- the duplicates are cleaned up rather than after. A password reset sent to a
-- duplicated address updates one of the two accounts, chosen by whichever row
-- the query reached first.
CREATE TABLE support.agent_accounts (
    agent_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email      varchar(255) NOT NULL,
    full_name  varchar(80) NOT NULL,
    created_on date NOT NULL
);

CREATE UNIQUE INDEX ux_agent_accounts_email ON support.agent_accounts (email);

INSERT INTO support.agent_accounts (email, full_name, created_on)
SELECT 'agent.' || lpad(g::text, 3, '0') || '@crossriver.example',
       'Agent ' || lpad(g::text, 3, '0'),
       DATE '2025-09-01' + (g % 200)
FROM generate_series(1, 120) AS g;

-- The state a failed CREATE INDEX CONCURRENTLY leaves the index in. It cannot
-- be reproduced inside a migration, because a concurrent build cannot run in a
-- transaction, so the catalog is set to the same thing by hand.
--
-- Writing pg_index needs a real superuser, which managed PostgreSQL never hands
-- out, so the write is guarded. The duplicate accounts below depend on it: they
-- only insert because the unique index stopped enforcing, so where the catalog
-- cannot be written the index stays valid and the duplicates are skipped. The
-- alternative is a unique violation that stops the whole build.
DO $$
BEGIN
    UPDATE pg_index
       SET indisvalid = false,
           indisready = false
     WHERE indexrelid = 'support.ux_agent_accounts_email'::regclass;

    -- The re-onboarding after the release, which created a second account for
    -- everybody whose login had not been migrated.
    INSERT INTO support.agent_accounts (email, full_name, created_on)
    SELECT 'agent.' || lpad(g::text, 3, '0') || '@crossriver.example',
           'Agent ' || lpad(g::text, 3, '0'),
           DATE '2026-04-14'
    FROM generate_series(1, 120) AS g
    WHERE g % 4 = 0;
EXCEPTION WHEN insufficient_privilege THEN
    RAISE NOTICE
        'no privilege to write pg_index; ux_agent_accounts_email stays valid and the duplicate agent accounts are skipped';
END $$;

-- DEFECT self-referencing-set-null-promotes-children-to-roots
--
-- The category tree. A category has a parent, the parent is a category, and the
-- foreign key says ON DELETE SET NULL so retiring a category does not take its
-- children with it.
--
-- A null parent does not mean orphaned in this table. It means top level, and
-- the homepage reads exactly that: every category with no parent. Retiring a
-- middle category therefore does not leave its children dangling, which would
-- at least be visible. It promotes them to the front of the shop.
--
-- Measured: 16 categories now have no parent. One of them is the real root.
-- The other 15 are the aisles of the 3 departments retired in June, and the
-- homepage lists them beside All departments.
--
-- ON DELETE RESTRICT would have refused the delete and made somebody decide
-- where the children go. The retirement ran, reported success, and the shop
-- rearranged itself overnight with no error anywhere.
CREATE TABLE catalog.category_tree (
    category_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    parent_id   integer REFERENCES catalog.category_tree(category_id) ON DELETE SET NULL,
    name        varchar(60) NOT NULL
);

COMMENT ON COLUMN catalog.category_tree.parent_id IS
    'Null means top level. The homepage lists every category with a null parent.';

INSERT INTO catalog.category_tree (parent_id, name) VALUES (NULL, 'All departments');

INSERT INTO catalog.category_tree (parent_id, name)
SELECT 1, 'Department ' || lpad(g::text, 2, '0')
FROM generate_series(1, 8) AS g;

INSERT INTO catalog.category_tree (parent_id, name)
SELECT d.category_id, d.name || ' aisle ' || lpad(g::text, 2, '0')
FROM catalog.category_tree d,
     generate_series(1, 5) AS g
WHERE d.parent_id = 1;

-- The June retirement of three departments.
DELETE FROM catalog.category_tree
 WHERE parent_id = 1
   AND category_id % 3 = 0;

CREATE VIEW catalog.v_top_level_categories AS
SELECT c.category_id, c.name
FROM catalog.category_tree c
WHERE c.parent_id IS NULL;

-- DEFECT jsonb-set-on-a-missing-path-changes-nothing
--
-- Order preferences are a document, and the migration that added a delivery
-- preference set it on every order with jsonb_set.
--
-- jsonb_set will create a missing last key, which is what the author tested. It
-- will not create a missing parent: given a path of two keys where the first
-- does not exist, it returns the document exactly as it was. It does not raise,
-- it does not return null, and the UPDATE reports every row as updated, because
-- every row was written, with the value it already had.
--
-- Measured: 2,082 of the 2,776 orders have no delivery preference, which is
-- every one whose document had no delivery object. The statement reported all
-- 2,776 rows updated.
--
-- jsonb_set with the parent created first, or a merge with ||, sets it on every
-- row. The rows that took the value are the ones that already had the object,
-- so the new preference is present exactly where it was least needed.
CREATE TABLE storefront.order_preferences (
    order_id    integer PRIMARY KEY REFERENCES storefront.orders(order_id),
    preferences jsonb NOT NULL
);

INSERT INTO storefront.order_preferences (order_id, preferences)
SELECT o.order_id,
       CASE WHEN o.order_id % 4 = 0
            THEN jsonb_build_object('contact', 'email', 'delivery', jsonb_build_object('window', 'anytime'))
            ELSE jsonb_build_object('contact', 'email')
       END
FROM storefront.orders o
WHERE o.order_id % 5 = 0;

-- The backfill that added the delivery preference.
UPDATE storefront.order_preferences
   SET preferences = jsonb_set(preferences, '{delivery,leave_safe}', 'true'::jsonb);

-- DEFECT row-security-not-forced-so-the-owner-bypasses-every-policy
--
-- Agent notes carry what the customer said before the call was transferred, so
-- a policy restricts each agent to their own. The policy is written, it is
-- enabled, and it is correct.
--
-- Row security does not apply to the owner of the table unless the table is
-- also set to FORCE ROW LEVEL SECURITY. The application connects as the owner.
-- The policy is therefore never consulted for the connection that does all the
-- reading, and every agent screen can read every note. Nothing about the table
-- looks wrong: row security is on, a policy exists, and psql shows both.
--
-- Measured: the table has row security enabled and forced off, and holds 300
-- notes across 6 agents. The owning role reads all 300.
--
-- ALTER TABLE ... FORCE ROW LEVEL SECURITY is the missing line, and the
-- application should not be connecting as the owner either. Whichever is fixed
-- first, the policy starts applying that day, which is the reason neither has
-- been.
CREATE TABLE support.agent_notes (
    note_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    agent_id   integer NOT NULL,
    ticket_id  integer NOT NULL REFERENCES support.tickets(ticket_id),
    body       text NOT NULL,
    written_at timestamptz NOT NULL
);

ALTER TABLE support.agent_notes ENABLE ROW LEVEL SECURITY;

CREATE POLICY agent_notes_own_rows ON support.agent_notes
    FOR SELECT
    USING (agent_id = current_setting('app.agent_id', true)::integer);

INSERT INTO support.agent_notes (agent_id, ticket_id, body, written_at)
SELECT 1 + (t.ticket_id % 12),
       t.ticket_id,
       'Caller gave a card number over the phone; not recorded.',
       t.opened_at + INTERVAL '2 hours'
FROM support.tickets t
WHERE t.ticket_id % 2 = 0;

-- DEFECT upsert-without-a-recency-guard-applies-the-older-event
--
-- The carrier sends shipment events over a webhook and the current status is
-- kept in its own table, one row per shipment, maintained by an upsert.
--
-- The upsert takes whatever arrives last. The carrier does not promise order,
-- and after an outage it replays: an in transit event from Tuesday arrives
-- after the delivered event from Wednesday, and the status goes backwards. The
-- event table is complete and correct, because it keeps everything. The status
-- table is what the tracking page reads.
--
-- Measured: 100 of the 400 shipments hold a status older than their latest
-- event. All 100 are the replayed ones, and every one of them reads accepted
-- on the tracking page after being delivered.
--
-- A WHERE clause on the DO UPDATE, comparing the stored timestamp against the
-- proposed one, discards the late arrival. Without it the table is a record of
-- arrival order rather than of what happened, and the two agree for as long as
-- the carrier's queue is empty.
CREATE TABLE fulfilment.shipment_state_events (
    event_id     integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    shipment_ref varchar(16) NOT NULL,
    status       varchar(20) NOT NULL,
    occurred_at  timestamptz NOT NULL,
    received_at  timestamptz NOT NULL
);

CREATE TABLE fulfilment.shipment_state (
    shipment_ref varchar(16) PRIMARY KEY,
    status       varchar(20) NOT NULL,
    occurred_at  timestamptz NOT NULL
);

-- Three events per shipment. Every fourth shipment was in the replay, where the
-- earlier events were delivered last.
INSERT INTO fulfilment.shipment_state_events (shipment_ref, status, occurred_at, received_at)
SELECT 'SH' || lpad(s::text, 8, '0'),
       CASE step WHEN 1 THEN 'accepted' WHEN 2 THEN 'in transit' ELSE 'delivered' END,
       TIMESTAMPTZ '2026-06-01 08:00+00' + (s * INTERVAL '1 hour') + (step * INTERVAL '1 day'),
       CASE WHEN s % 4 = 0
            THEN TIMESTAMPTZ '2026-06-08 09:00+00' + (s * INTERVAL '1 hour') + ((4 - step) * INTERVAL '1 minute')
            ELSE TIMESTAMPTZ '2026-06-01 08:05+00' + (s * INTERVAL '1 hour') + (step * INTERVAL '1 day')
       END
FROM generate_series(1, 400) AS s,
     generate_series(1, 3) AS step;

-- The handler runs once per delivered event, in the order they arrive. Three
-- statements here, one per arrival, because a single statement cannot upsert
-- the same key twice and the webhook never does.
INSERT INTO fulfilment.shipment_state (shipment_ref, status, occurred_at)
SELECT e.shipment_ref, e.status, e.occurred_at
FROM (SELECT *, row_number() OVER (PARTITION BY shipment_ref ORDER BY received_at, event_id) AS arrival
      FROM fulfilment.shipment_state_events) e
WHERE e.arrival = 1
ON CONFLICT (shipment_ref) DO UPDATE
   SET status      = EXCLUDED.status,
       occurred_at = EXCLUDED.occurred_at;

INSERT INTO fulfilment.shipment_state (shipment_ref, status, occurred_at)
SELECT e.shipment_ref, e.status, e.occurred_at
FROM (SELECT *, row_number() OVER (PARTITION BY shipment_ref ORDER BY received_at, event_id) AS arrival
      FROM fulfilment.shipment_state_events) e
WHERE e.arrival = 2
ON CONFLICT (shipment_ref) DO UPDATE
   SET status      = EXCLUDED.status,
       occurred_at = EXCLUDED.occurred_at;

INSERT INTO fulfilment.shipment_state (shipment_ref, status, occurred_at)
SELECT e.shipment_ref, e.status, e.occurred_at
FROM (SELECT *, row_number() OVER (PARTITION BY shipment_ref ORDER BY received_at, event_id) AS arrival
      FROM fulfilment.shipment_state_events) e
WHERE e.arrival = 3
ON CONFLICT (shipment_ref) DO UPDATE
   SET status      = EXCLUDED.status,
       occurred_at = EXCLUDED.occurred_at;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE fulfilment.shipment_state ADD COLUMN shipment_id integer;

WITH p AS (
    SELECT shipment_id AS v, row_number() OVER (ORDER BY shipment_id) - 1 AS k
      FROM fulfilment.shipments
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM fulfilment.shipments)
                 * power((abs(hashtext('fulfilment.shipment_state:' || concat_ws('|', x.shipment_ref, x.status))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM fulfilment.shipment_state x
)
UPDATE fulfilment.shipment_state t
   SET shipment_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE fulfilment.shipment_state ALTER COLUMN shipment_id SET NOT NULL;
ALTER TABLE fulfilment.shipment_state ADD CONSTRAINT shipment_state_shipment_id_fkey FOREIGN KEY (shipment_id) REFERENCES fulfilment.shipments (shipment_id);
CREATE INDEX ix_shipment_state_shipment_id ON fulfilment.shipment_state (shipment_id);
-- <<< relationships
