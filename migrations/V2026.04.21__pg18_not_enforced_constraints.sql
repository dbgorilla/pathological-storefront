-- Cross River Trading Co. -- reinstate the ledger balance rule
-- author: T. Brennan
-- postgres: 18
--
-- Finance want the ledger rule written down in the database. The rule is that
-- an entry is either a debit or a credit, never both.
--
-- It cannot be turned on: there are years of rows that break it, and fixing
-- them is a finance project rather than an engineering one. PostgreSQL 18 adds
-- NOT ENFORCED, which was read as a way to record the intent now and switch it
-- on later.

-- DEFECT check-not-enforced-ledger
--
-- The second important one.
--
-- NOT ENFORCED means exactly what it says. The constraint exists, it has a
-- name, it appears in \d output, it is in pg_constraint, and it is applied to
-- nothing. Neither existing rows nor new ones are checked.
--
-- This is different from NOT VALID. NOT VALID skips the existing rows and
-- still checks every new one. NOT ENFORCED checks nothing, ever.
--
-- pg_constraint.conenforced distinguishes them, and that column did not exist
-- before PostgreSQL 18. information_schema has no equivalent, and pg_dump
-- emits the constraint without making the distinction obvious. A tool reading
-- either concludes the ledger is protected.
ALTER TABLE payments.ledger_entries
    ADD CONSTRAINT ledger_entries_single_sided
    CHECK (NOT (debit_cents > 0 AND credit_cents > 0)) NOT ENFORCED;

-- DEFECT check-not-enforced-refund-bound
--
-- The same mistake a second time, by someone who saw the pattern above in a
-- code review and copied it.
--
-- The rule they were asked for was that a refund must not exceed the
-- transaction it refunds. A CHECK cannot read another table, so they settled
-- for a flat ceiling of one million pounds and kept the name they had already
-- written. The name says one rule and the expression says another, and because
-- the constraint is NOT ENFORCED neither rule is applied to anything.
--
-- The 2019 double-conversion refunds are above the ceiling. They were here
-- before this constraint was added and adding it did not fail, which is the
-- whole point of NOT ENFORCED and the reason nobody noticed.
ALTER TABLE payments.refunds
    ADD CONSTRAINT refunds_within_transaction
    CHECK (amount_cents <= 100000000) NOT ENFORCED;

COMMENT ON CONSTRAINT ledger_entries_single_sided ON payments.ledger_entries IS
    'NOT ENFORCED. Present in the catalogue, applied to nothing.';
