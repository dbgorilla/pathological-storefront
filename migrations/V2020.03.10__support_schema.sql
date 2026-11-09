-- Cross River Trading Co. -- support desk
-- author: A. Fenwick
-- postgres: 12
--
-- Customer service moves off a shared mailbox. Tickets can be about an order,
-- a shipment, a product, a return or a subscription, and tickets can be merged
-- into one another.
--
-- ROADMAP.md: "2020 to 2021: subscriptions die, the support desk is built"

CREATE SCHEMA support;

CREATE TABLE support.agents (
    agent_id     serial PRIMARY KEY,
    email        varchar(255) NOT NULL UNIQUE,
    full_name    varchar(255) NOT NULL,
    team         varchar(255) NOT NULL DEFAULT 'general',
    active       boolean NOT NULL DEFAULT true
);

-- DEFECT polymorphic-subject-no-target
-- subject_type and subject_id are a polymorphic reference: the target table
-- depends on the value in subject_type. Nothing can declare a foreign key for
-- this, which is the usual objection to the pattern.
--
-- The specific problem here arrives in March 2021. 'subscription' is one of the
-- permitted values, and the table it points at is dropped that month. The rows
-- stay.
CREATE TABLE support.tickets (
    ticket_id       serial PRIMARY KEY,
    customer_id     integer REFERENCES storefront.customers (customer_id),
    assigned_agent_id integer REFERENCES support.agents (agent_id),
    subject_type    varchar(255) NOT NULL
                      CHECK (subject_type IN ('order', 'shipment', 'product', 'return', 'subscription')),
    subject_id      integer NOT NULL,
    status          varchar(255) NOT NULL DEFAULT 'open'
                      CHECK (status IN ('open', 'pending', 'resolved', 'closed')),
    priority        smallint NOT NULL DEFAULT 3 CHECK (priority BETWEEN 1 AND 5),
    -- Self-reference: a duplicate ticket points at the one it was merged into.
    merged_into_ticket_id integer REFERENCES support.tickets (ticket_id),
    opened_at       timestamptz NOT NULL DEFAULT now(),
    resolved_at     timestamptz
);
CREATE INDEX ix_tickets_customer ON support.tickets (customer_id);
CREATE INDEX ix_tickets_subject ON support.tickets (subject_type, subject_id);

COMMENT ON COLUMN support.tickets.subject_type IS
    'Names the table subject_id points at. No foreign key is possible.';

CREATE TABLE support.ticket_messages (
    ticket_message_id  bigserial PRIMARY KEY,
    ticket_id          integer NOT NULL REFERENCES support.tickets (ticket_id),
    agent_id           integer REFERENCES support.agents (agent_id),
    body               text NOT NULL,
    is_internal        boolean NOT NULL DEFAULT false,
    sent_at            timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_ticket_messages_ticket ON support.ticket_messages (ticket_id);

CREATE TABLE support.ticket_links (
    ticket_link_id  serial PRIMARY KEY,
    from_ticket_id  integer NOT NULL REFERENCES support.tickets (ticket_id),
    to_ticket_id    integer NOT NULL REFERENCES support.tickets (ticket_id),
    relation        varchar(255) NOT NULL
                      CHECK (relation IN ('duplicate', 'related', 'blocks', 'caused_by')),
    CONSTRAINT ticket_links_no_self CHECK (from_ticket_id <> to_ticket_id)
);

INSERT INTO support.agents (email, full_name, team) VALUES
    ('rota@crossriver.example',   'Support Rota',      'general'),
    ('escal@crossriver.example',  'Escalations Desk',  'escalations');

-- DEFECT trigger-order-decided-by-name
--
-- Two BEFORE INSERT triggers on the same table, written eight months apart by
-- two people, each correct on its own.
--
-- PostgreSQL fires row triggers on the same event in alphabetical order of
-- trigger name. Nothing in either CREATE TRIGGER says so and nothing warns that
-- two of them now depend on each other. trg_a_derive_visibility sorts first, so
-- it decides whether a message is internal from an agent_id that
-- trg_b_default_agent has not filled in yet.
--
-- Every message that arrives without an agent is therefore stamped external and
-- then given an agent, which is the one combination the rule was written to
-- rule out. Renaming either trigger fixes it and changes no logic at all, which
-- is also why nobody reviewing either function would find it.
CREATE FUNCTION support.derive_visibility() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.is_internal := (NEW.agent_id IS NOT NULL);
    RETURN NEW;
END;
$$;

CREATE FUNCTION support.default_agent() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.agent_id := coalesce(NEW.agent_id, 1);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_a_derive_visibility BEFORE INSERT ON support.ticket_messages
    FOR EACH ROW EXECUTE FUNCTION support.derive_visibility();

CREATE TRIGGER trg_b_default_agent BEFORE INSERT ON support.ticket_messages
    FOR EACH ROW EXECUTE FUNCTION support.default_agent();

-- DEFECT partial-index-narrower-than-query
--
-- The queue screen reads support.v_ticket_queue, which shows open tickets and
-- tickets waiting on the customer. The index was written from the ticket that
-- asked for it, which said "open tickets, oldest first", and the query that
-- shipped a week later said open or pending.
--
-- A partial index can only answer a query whose filter the planner can prove
-- implies the predicate. `status IN ('open','pending')` does not imply
-- `status = 'open'`, so the index is never used by the view it exists for, and
-- the queue scans the table. Nothing errors and nothing warns. The index is
-- listed, it is maintained on every write, and it is 150 pending tickets away
-- from being the one the query wanted.
CREATE INDEX ix_tickets_queue ON support.tickets (opened_at) WHERE status = 'open';

-- DEFECT updatable-view-no-check-option
--
-- The queue view has a WHERE clause and selects from one table without
-- grouping it, so PostgreSQL makes it automatically updatable. Nobody asked for
-- that; it is what happens when a view is simple enough. The queue screen was
-- granted this view and nothing else, so the screen's "close ticket" button
-- writes through it.
--
-- WITH CHECK OPTION is the clause that stops a write through a view from
-- producing a row the view can no longer see. Without it an UPDATE that sets
-- status to 'closed' succeeds and the row leaves the queue mid-transaction, so
-- the screen's own re-read finds nothing and reports the ticket as missing
-- rather than closed. An INSERT of a resolved ticket lands in support.tickets
-- and is invisible from the only object the screen can read.
--
-- Nothing errors in either case, and the view definition gives no sign that it
-- is writable at all.
CREATE VIEW support.v_ticket_queue AS
SELECT ticket_id, customer_id, assigned_agent_id, status, priority, opened_at
FROM support.tickets
WHERE status IN ('open', 'pending');

-- DEFECT rls-enabled-no-policy
--
-- Ticket bodies carry customer addresses and order values, so the 2020 review
-- asked that an agent see only the tickets assigned to their own team. Turning
-- row security on was the first half of that change. The policy was the second
-- half, and it was left for the follow-up that the support launch swallowed.
--
-- A table with row security on and no policy grants nothing. It looks empty.
-- The application never noticed, because it connects as the owner of the table
-- and the owner is exempt unless FORCE is set. The day anyone points a reporting
-- role or a read-only analyst at support.ticket_messages, it returns zero rows
-- and no error, and the obvious reading of that is that the table is empty.
ALTER TABLE support.ticket_messages ENABLE ROW LEVEL SECURITY;

-- DEFECT view-bypasses-row-security
--
-- The reporting team needed message volumes and could not read the table, for
-- the reason directly above. A view was the quick way to give them something.
--
-- A view runs as its owner unless it is created WITH (security_invoker = true),
-- which was not a thing anyone had to think about before PostgreSQL 15 and is
-- still off by default. This view is owned by the owner of the table, and the
-- owner is exempt from row security, so the view returns every row to anyone
-- granted SELECT on it. It is a hole in exactly the control the ALTER above was
-- opened to add, and it was cut by the team that hit the control.
--
-- The two statements are twenty lines apart and neither mentions the other.
CREATE VIEW support.v_ticket_message_log AS
SELECT ticket_message_id, ticket_id, agent_id, is_internal, sent_at, body
FROM support.ticket_messages;

-- DEFECT distinct-on-without-deterministic-order
--
-- The last message on each ticket, for the list screen. DISTINCT ON is the
-- PostgreSQL way to write one-row-per-group and this is how it is usually
-- written.
--
-- DISTINCT ON keeps the first row of each group as the ORDER BY presents them,
-- so the ORDER BY has to say which row is wanted. This one orders by ticket_id
-- alone, which only groups the rows; within a ticket the order is whatever the
-- plan produces. PostgreSQL does not warn, because the statement is legal and
-- there is no way for it to know that "first" was meant to mean "latest".
--
-- 600 of the 1,800 messages sit on a ticket that has more than one, so 600
-- tickets show an arbitrary message as their most recent. It is stable while
-- the plan is stable, which is why it survives testing, and it changes when the
-- table is vacuumed, when the statistics move, or when the plan goes parallel.
-- ORDER BY ticket_id, sent_at DESC is the fix and is not in the statement.
CREATE VIEW support.v_ticket_latest_message AS
SELECT DISTINCT ON (ticket_id)
       ticket_id, ticket_message_id, agent_id, body
FROM support.ticket_messages
ORDER BY ticket_id;

-- DEFECT recursive-view-without-cycle-detection
--
-- Follows merged_into_ticket_id up to the ticket a duplicate was finally merged
-- into, so the agent screen can show one conversation instead of a chain. The
-- recursive CTE is the standard shape and it terminates on any chain that ends.
--
-- Six tickets in this database are in a merge cycle: a points at b and b points
-- at a, which the self-reference permits and nothing checks. This query has no
-- CYCLE clause and no depth guard, so on those six it does not return. It
-- allocates until the session is killed or the machine runs out, and it takes
-- the connection pool with it.
--
-- Every other ticket works. The view was tested on a chain, because a chain is
-- what it is for, and the cycles were created later by two agents merging in
-- opposite directions within a minute of each other. PostgreSQL has had the
-- CYCLE clause since version 14 and this was written in 2020.
CREATE VIEW support.v_ticket_merge_root AS
WITH RECURSIVE chain AS (
    SELECT ticket_id, merged_into_ticket_id, ticket_id AS root_ticket_id
    FROM support.tickets
    WHERE merged_into_ticket_id IS NOT NULL
    UNION ALL
    SELECT c.ticket_id, t.merged_into_ticket_id, t.ticket_id
    FROM chain c
    JOIN support.tickets t ON t.ticket_id = c.merged_into_ticket_id
)
SELECT ticket_id, root_ticket_id FROM chain WHERE merged_into_ticket_id IS NULL;
