-- Cross River Trading Co. -- the subscription box
-- author: J. Toomey (new products team)
-- postgres: 11
--
-- The strategic bet of 2018, shipping in 2019. A monthly box, chosen by the
-- customer, billed on a cycle.
--
-- Built by a separate team on a separate deadline, which is why the
-- conventions here do not match the rest of the database.
--
-- ROADMAP.md: this whole schema is dropped in March 2021.

CREATE SCHEMA subscriptions;

CREATE TABLE subscriptions.plans (
    plan_id         serial PRIMARY KEY,
    name            varchar(255) NOT NULL,
    monthly_cents   integer NOT NULL,
    box_size        varchar(255) NOT NULL CHECK (box_size IN ('small', 'medium', 'large'))
);

CREATE TABLE subscriptions.customer_subscriptions (
    customer_subscription_id  serial PRIMARY KEY,
    customer_id               integer NOT NULL REFERENCES storefront.customers (customer_id),
    plan_id                   integer NOT NULL REFERENCES subscriptions.plans (plan_id),
    started_on                date NOT NULL,
    cancelled_on              date,
    next_billing_on           date
);

CREATE TABLE subscriptions.box_shipments (
    box_shipment_id           serial PRIMARY KEY,
    customer_subscription_id  integer NOT NULL
                                REFERENCES subscriptions.customer_subscriptions (customer_subscription_id),
    despatched_on             date,
    value_cents               integer NOT NULL DEFAULT 0
);

-- Columns on the shared customers table that only this product writes.
-- DEFECT orphaned-subscription-columns
-- These survive the 2021 shutdown because the tidy-up migration dropped the
-- subscriptions schema and stopped there.
ALTER TABLE storefront.customers
    ADD COLUMN subscription_tier       varchar(255),
    ADD COLUMN subscription_started_on date,
    ADD COLUMN box_preference          varchar(255);

INSERT INTO subscriptions.plans (name, monthly_cents, box_size) VALUES
    ('River Box Small',  1200, 'small'),
    ('River Box Medium', 2400, 'medium'),
    ('River Box Large',  3600, 'large');

-- DEFECT sequence-orphaned-by-a-dropped-schema
--
-- Box numbers are printed on the label and have to be unique across every box
-- ever sent, so they come from a sequence rather than from a per-table serial.
-- It was created in storefront rather than in subscriptions, because the
-- despatch tooling that reads it lives there and the subscriptions schema was
-- new enough that nobody wanted a cross-schema call in the other direction.
--
-- That choice is what makes it survive. DROP SCHEMA subscriptions CASCADE in
-- 2021 takes everything inside the schema; a default that merely references a
-- sequence in another schema is a dependency in the wrong direction, so
-- dropping the table removes the default and leaves the sequence standing.
--
-- It is owned by nothing, referenced by nothing, and counted by nothing. It
-- appears in every pg_dump, in every schema diff between this database and a
-- rebuilt one, and in the object list any tool produces, with a name that
-- refers to a product shut down five years ago.
CREATE SEQUENCE storefront.box_number_seq;

ALTER TABLE subscriptions.box_shipments
    ADD COLUMN box_number integer NOT NULL DEFAULT nextval('storefront.box_number_seq');

-- Free-text notes the packer left on a customer's box. Wide, rarely read, and
-- written on every dispatch.
ALTER TABLE storefront.customers
    ADD COLUMN box_packing_notes text;
