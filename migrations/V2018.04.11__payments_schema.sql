-- Cross River Trading Co. -- payments off the card terminal integration
-- author: T. Brennan
-- postgres: 10
--
-- Card payments, refunds, and a ledger the finance team can reconcile against
-- the bank statement.

CREATE SCHEMA payments;

CREATE TABLE payments.payment_methods (
    payment_method_id  serial PRIMARY KEY,
    customer_id        integer NOT NULL REFERENCES storefront.customers (customer_id),
    kind               varchar(255) NOT NULL
                         CHECK (kind IN ('card', 'paypal', 'giftcard', 'account')),
    last_four          varchar(255),
    expires_on         date,
    is_default         boolean NOT NULL DEFAULT false
);
CREATE INDEX ix_payment_methods_customer ON payments.payment_methods (customer_id);

-- DEFECT float-money-transactions
-- amount is double precision. Every other money column in this database is
-- integer cents. The author came from a Python background and float looked
-- like the type for a number with a decimal point.
--
-- The consequence is not theoretical: summing this column and summing the
-- matching integer-cent columns give different answers, and the difference
-- grows with the number of rows.
--
-- DEFECT cascade-delete-reaches-refunds
--
-- The 2018 test suite kept failing its teardown, because deleting a test order
-- left a transaction behind and the foreign key refused. Adding ON DELETE
-- CASCADE here, and again on refunds below, made teardown work in one
-- statement. Nobody asked what the same statement does in production.
--
-- Deleting one payments.transactions row now removes every refund issued
-- against it, silently. The refund row is the only record in the database that
-- money went back to a customer; nothing else holds a second copy.
--
-- The hop above it, orders to transactions, is written the same way but does
-- not fire today: storefront.order_items references the order with no action,
-- so the order delete is refused before the cascade is reached. The chain is
-- armed rather than live, and it goes live the day anyone makes order_items
-- cascade too, which is the obvious thing to do when that error appears.
CREATE TABLE payments.transactions (
    transaction_id    serial PRIMARY KEY,
    order_id          integer NOT NULL REFERENCES storefront.orders (order_id)
                        ON DELETE CASCADE,
    payment_method_id integer REFERENCES payments.payment_methods (payment_method_id),
    amount            double precision NOT NULL,
    currency          varchar(255) NOT NULL DEFAULT 'GBP',
    status            varchar(255) NOT NULL DEFAULT 'authorised'
                        CHECK (status IN ('authorised', 'captured', 'failed', 'refunded')),
    processed_at      timestamptz NOT NULL DEFAULT now(),
    provider_ref      varchar(255)
);
CREATE INDEX ix_transactions_order ON payments.transactions (order_id);

COMMENT ON COLUMN payments.transactions.amount IS
    'Major units as a float. Everything else in the database is integer cents.';

CREATE TABLE payments.refunds (
    refund_id       serial PRIMARY KEY,
    transaction_id  integer NOT NULL REFERENCES payments.transactions (transaction_id)
                      ON DELETE CASCADE,
    amount_cents    integer NOT NULL CHECK (amount_cents > 0),
    reason          varchar(255),
    refunded_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_refunds_transaction ON payments.refunds (transaction_id);

-- DEFECT ledger-does-not-balance
-- Double entry, except nothing enforces that the two sides of an entry sum to
-- zero. The reconciliation job that was meant to check it nightly was never
-- scheduled after the 2025 cloud migration.
CREATE TABLE payments.ledger_entries (
    ledger_entry_id  bigserial PRIMARY KEY,
    -- DEFECT deferred-constraint-hides-violation
    --
    -- The posting job writes the ledger pair first and the transaction row
    -- afterwards, because the transaction's status depends on what posted. The
    -- foreign key refused that order, so it was made deferrable rather than the
    -- job being reordered, and it is deferred by default so nothing has to ask.
    --
    -- The reference is now checked once, at commit, instead of at each
    -- statement. For the whole length of every transaction that touches this
    -- table the rows point at a transaction that does not exist yet, and
    -- anything reading in that window -- a trigger, a procedure, another
    -- statement in the same transaction -- sees a broken reference and is
    -- correct to. Every catalogue lists this as an ordinary foreign key.
    transaction_id   integer REFERENCES payments.transactions (transaction_id)
                       DEFERRABLE INITIALLY DEFERRED,
    account          varchar(255) NOT NULL,
    debit_cents      bigint NOT NULL DEFAULT 0,
    credit_cents     bigint NOT NULL DEFAULT 0,
    posted_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_ledger_entries_transaction ON payments.ledger_entries (transaction_id);

-- DEFECT comment-contradicts-constraint
--
-- Written by the person who designed the chargeback flow, describing what the
-- column was going to mean once that flow shipped. The flow never shipped and
-- the comment stayed.
--
-- amount_cents carries CHECK (amount_cents > 0), so a negative value cannot be
-- stored at all. The comment says the opposite, and it is the only description
-- of this column anywhere: it is what psql shows, what the schema browser
-- shows, and what the data dictionary was generated from.
--
-- The chargeback importer was written against it. It has been failing on every
-- chargeback since it was switched on, with a check violation that reads as bad
-- input from the payment provider, and the team maintaining it have been
-- chasing the provider rather than the column, because the column's own
-- documentation agrees with them.
COMMENT ON COLUMN payments.refunds.amount_cents IS
    'Refund amount in cents. Negative for chargebacks reversed by the provider.';

-- DEFECT float-equality-misses-matching-rows
--
-- Finance reconciles the card takings against the orders: a transaction is
-- matched when the amount it captured equals the total on the order it paid
-- for. The amount is in major units and the order total is in cents, so one
-- side is multiplied by a hundred and the two are compared.
--
-- amount is double precision. 213.64 is not representable in binary floating
-- point, and multiplying the nearest value by a hundred does not land on
-- 21364; it lands a fraction away, and = is exact. The row is not matched and
-- there is nothing in the output to say that it nearly was.
--
-- 1,304 of the 12,145 transactions fail to match an order whose total is the
-- same money. They arrive on the unreconciled report every month, in a
-- different set each month as new transactions are written, and they clear
-- themselves the moment someone re-keys the amount by hand. Comparing
-- round(amount::numeric, 2) * 100 matches all of them.
CREATE VIEW payments.v_transaction_reconciliation AS
SELECT t.transaction_id,
       t.order_id,
       t.amount,
       o.total_cents,
       (t.amount * 100 = o.total_cents) AS reconciled
FROM payments.transactions t
JOIN storefront.orders o ON o.order_id = t.order_id;
