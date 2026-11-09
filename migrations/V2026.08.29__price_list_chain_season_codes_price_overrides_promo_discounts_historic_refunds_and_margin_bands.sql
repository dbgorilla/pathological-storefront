-- Cross River Trading Co. -- price list chain, season codes, price overrides,
-- promotion discounts, historic refunds, margin bands
-- author: T. Marchetti
-- postgres: 18
--
-- Which price list replaced which, the code on a season, who moved a price by
-- hand, what a promotion takes off, what was refunded before the migration,
-- and where a product sits on margin.

-- DEFECT fifty-price-lists-supersede-each-other-in-a-ring
--
-- Each price list names the list it supersedes. Two hundred of them are
-- arranged in fifty rings of four, so the walk back to the original never
-- reaches one.
--
-- The rings came out of a reissue. A batch of lists was reissued under new
-- numbers, and the script that wired up the supersedes column was run twice
-- with the batch ordered differently each time, which pointed the oldest list
-- in each group at the newest. The foreign key is satisfied, because every
-- list named exists. The pricing tool walks the chain to find what a product
-- used to cost and stops after twenty hops, which it calls a deep history, and
-- returns whatever it was holding.
--
-- Measured: 4,000 price lists of which 200 sit in a ring where four supersede
-- steps return to the list they started from.
--
-- A recursive check with a cycle clause finds them in a second and the rings
-- want breaking by hand, because which of the four is the original is a
-- pricing question. Every row passes its foreign key and the chain looks
-- perfectly ordinary from any single list.
CREATE TABLE catalog.price_list_chain (
    list_id        integer PRIMARY KEY,
    list_name      varchar(40) NOT NULL,
    effective_from date NOT NULL,
    supersedes_id  integer REFERENCES catalog.price_list_chain (list_id)
);

-- The lists that were superseded once, in order.
INSERT INTO catalog.price_list_chain (list_id, list_name, effective_from, supersedes_id)
SELECT g, 'Price list ' || g, DATE '2019-01-07' + (g % 2500),
       CASE WHEN g > 201 THEN g - 1 ELSE NULL END
FROM generate_series(201, 4000) AS g;

INSERT INTO catalog.price_list_chain (list_id, list_name, effective_from, supersedes_id)
SELECT g, 'Price list ' || g, DATE '2024-03-04' + (g % 400), NULL
FROM generate_series(1, 200) AS g;

-- The reissue, run a second time with the batch in another order.
UPDATE catalog.price_list_chain
SET supersedes_id = CASE WHEN list_id % 4 = 0 THEN list_id - 3 ELSE list_id + 1 END
WHERE list_id <= 200;

-- DEFECT the-check-constraint-admits-the-codes-it-was-written-to-reject
--
-- The season code is constrained to the range A to Z so that codes are always
-- capitals. Six hundred lowercase codes are in the table and every one of them
-- satisfies the constraint.
--
-- A range comparison on text is answered by the database collation, and in
-- en_US.utf8 the letters interleave, so b through z all fall between A and Z.
-- The constraint therefore rejects almost nothing. It was written by someone
-- reasoning in ASCII, where the range would have held, and it was tested with
-- codes that were already capitals. The season code is the join key to the
-- buying system, which is case sensitive, so a lowercase code matches no
-- season there and the product drops out of the buy.
--
-- Measured: 3,000 season codes under one check constraint, of which 600 are
-- not equal to their own uppercase form.
--
-- The constraint wants to be code = upper(code), or a regular expression, both
-- of which are collation independent. The constraint is declared, valid and
-- enforced, so it appears on every schema report as a column that is
-- constrained.
CREATE TABLE catalog.season_codes (
    code        varchar(6) PRIMARY KEY CHECK (code BETWEEN 'A' AND 'Z'),
    season_name varchar(40) NOT NULL,
    starts_on   date NOT NULL
);

INSERT INTO catalog.season_codes (code, season_name, starts_on)
SELECT CASE WHEN g % 5 = 0
            THEN lower((ARRAY['SS', 'HO', 'MD', 'PR'])[1 + (g % 4)] || lpad(g::text, 4, '0'))
            ELSE (ARRAY['SS', 'HO', 'MD', 'PR'])[1 + (g % 4)] || lpad(g::text, 4, '0')
       END,
       'Season ' || g,
       DATE '2018-02-05' + (g % 2900)
FROM generate_series(1, 3000) AS g;

-- DEFECT anyone-who-can-connect-can-override-a-price
--
-- The price override function runs as its owner and its execute privilege is
-- held by PUBLIC. Every role in the database can set the selling price of
-- anything.
--
-- The function was written so that the merchandising application could
-- override a price without holding write access to the price tables, which is
-- the right shape. The grant was the last line of the migration and it was
-- written to PUBLIC because the migration ran before the application role
-- existed and PUBLIC made it work that morning. The function records the
-- caller in the override row, so the audit is honest, and it has never
-- recorded a caller nobody expected, which is the only thing anybody checks.
--
-- Measured: 2,400 price overrides behind one SECURITY DEFINER function whose
-- access control list grants EXECUTE to PUBLIC.
--
-- Revoking from PUBLIC and granting to the application role is two statements
-- and nothing legitimate loses access. The function is owned correctly, sets
-- its search path, and does exactly one well scoped thing.
CREATE TABLE catalog.price_overrides (
    override_id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         varchar(16) NOT NULL,
    price_p     integer NOT NULL,
    set_by      varchar(20) NOT NULL,
    set_at      timestamptz NOT NULL
);

CREATE FUNCTION catalog.fn_apply_price_override(p_sku varchar, p_price_p integer)
RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = pg_catalog, catalog AS $$
    INSERT INTO catalog.price_overrides (sku, price_p, set_by, set_at)
    VALUES (p_sku, p_price_p, current_user, now());
$$;

GRANT EXECUTE ON FUNCTION catalog.fn_apply_price_override(varchar, integer) TO PUBLIC;

INSERT INTO catalog.price_overrides (sku, price_p, set_by, set_at)
SELECT 'SKU-' || lpad((1 + (g % 2000))::text, 8, '0'),
       400 + (g % 18000),
       'USR-' || lpad((1 + (g % 45))::text, 4, '0'),
       TIMESTAMPTZ '2026-02-09 09:00:00+00' + (g * INTERVAL '37 minutes')
FROM generate_series(1, 2400) AS g;

-- DEFECT discounts-under-one-percent-are-stored-as-no-discount
--
-- The promotion rate arrives in basis points and is stored as a whole
-- percentage. Twelve hundred promotions with a real rate are stored as no
-- discount at all.
--
-- Basis points were chosen upstream so that a rate could be finer than a
-- percent, which is the whole reason the unit exists. The column here was
-- declared as an integer percentage because every promotion at the time was a
-- round five or ten percent, and the load divides by a hundred in integer
-- arithmetic. A rate of eighty five basis points, which is a real promotion
-- the pricing team ran, becomes zero. The basket applies it, takes nothing
-- off, and the promotion reports a hundred percent redemption with no cost.
--
-- Measured: 4,800 promotion discounts of which 1,200 hold a whole percent of
-- zero against a basis point rate above zero.
--
-- The stored percentage wants to be the basis points, or numeric, and the
-- source column is already on the row so nothing needs re-importing. Every
-- promotion is present, active and internally consistent, and a zero is a
-- legitimate value for the column.
CREATE TABLE marketing.promo_discounts (
    promo_ref    varchar(16) PRIMARY KEY,
    discount_bps integer NOT NULL,
    discount_pct integer NOT NULL,
    runs_from    date NOT NULL
);

INSERT INTO marketing.promo_discounts (promo_ref, discount_bps, discount_pct, runs_from)
SELECT 'PRM-' || lpad(g::text, 10, '0'),
       CASE WHEN g % 4 = 0 THEN 10 + (g % 80) ELSE 100 + (g % 900) END,
       (CASE WHEN g % 4 = 0 THEN 10 + (g % 80) ELSE 100 + (g % 900) END) / 100,
       DATE '2025-01-06' + (g % 600)
FROM generate_series(1, 4800) AS g;

-- DEFECT the-unit-fix-ran-twice-over-the-same-fortnight
--
-- Historic refunds were held in pounds and converted to pence. The conversion
-- was run twice over an overlapping range, so fifteen hundred refunds are a
-- hundred times what they should be.
--
-- The first run covered everything up to the end of the month. The second run
-- was written to cover the same month again because the first was believed to
-- have failed part way, and it had not: it had finished and reported nothing,
-- because the log was going to a file nobody had opened. Multiplying by a
-- hundred is not idempotent and nothing on the row records whether it has been
-- converted. The refunds are historic and are read only by the annual return,
-- which is where a fifteen thousand pound refund on a forty pound order will
-- eventually be read out loud.
--
-- Measured: 6,000 historic refunds of which 1,500 exceed a million pence
-- against a genuine maximum of 6,499.
--
-- Dividing the affected rows by a hundred is safe only because the genuine
-- rows are two orders of magnitude away, which is luck rather than design.
-- Every amount is a positive integer in the right column and no total has ever
-- failed to balance, because the refunds balance against themselves.
CREATE TABLE payments.historic_refunds (
    refund_ref varchar(16) PRIMARY KEY,
    order_ref  varchar(16) NOT NULL,
    amount_p   integer NOT NULL,
    refunded_on date NOT NULL
);

INSERT INTO payments.historic_refunds (refund_ref, order_ref, amount_p, refunded_on)
SELECT 'HRF-' || lpad(g::text, 10, '0'),
       'ORD-' || lpad((1 + (g % 5000))::text, 10, '0'),
       CASE WHEN g % 4 = 0
            THEN (15000 + (g % 20000)) * 100
            ELSE 500 + (g % 40000)
       END,
       DATE '2021-04-06' + (g % 900)
FROM generate_series(1, 6000) AS g;

-- DEFECT the-view-is-readable-and-the-function-inside-it-is-not
--
-- The buying role has SELECT on the margin band view. The view calls a
-- function the buying role may not execute, so every select fails.
--
-- The function had its execute privilege revoked from PUBLIC during a
-- tightening exercise, which was correct, and the grants that were meant to
-- follow covered the roles that called the function directly. Nobody called
-- this one directly. It is called from inside a view, and a view runs its body
-- as whoever selects from it, so the privilege that matters belongs to the
-- caller and not to the view's owner. The grant on the view is real, recorded
-- and visible in every privilege report, which is why the access review passes
-- and the buying team cannot open the report.
--
-- Measured: 6,000 margin band rows behind a view the buying role may select
-- and a function the buying role may not execute.
--
-- One GRANT EXECUTE fixes it, or the view becomes security_invoker = false and
-- runs as its owner. The table grant is correct, the view grant is correct,
-- and the missing privilege is on an object no grant report lists beside them.
CREATE TABLE catalog.margin_bands (
    sku     varchar(16) PRIMARY KEY,
    cost_p  integer NOT NULL,
    sell_p  integer NOT NULL
);

INSERT INTO catalog.margin_bands (sku, cost_p, sell_p)
SELECT 'SKU-' || lpad(g::text, 8, '0'),
       200 + (g % 9000),
       1200 + (g % 26000)
FROM generate_series(1, 6000) AS g;

CREATE FUNCTION catalog.fn_margin_band(p_margin_pct integer)
RETURNS varchar
LANGUAGE sql IMMUTABLE AS $$
    SELECT (CASE WHEN p_margin_pct < 10 THEN 'thin'
                 WHEN p_margin_pct < 30 THEN 'standard'
                 ELSE 'strong' END)::varchar;
$$;

REVOKE EXECUTE ON FUNCTION catalog.fn_margin_band(integer) FROM PUBLIC;

CREATE VIEW analytics.v_margin_bands AS
    SELECT sku,
           sell_p - cost_p AS margin_p,
           catalog.fn_margin_band(((sell_p - cost_p) * 100) / sell_p) AS band
    FROM catalog.margin_bands;

GRANT SELECT ON analytics.v_margin_bands TO buyer_reader;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.price_overrides ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.price_overrides:' || concat_ws('|', x.sku, x.price_p, x.set_by))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.price_overrides x
)
UPDATE catalog.price_overrides t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.price_overrides ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.price_overrides ADD CONSTRAINT price_overrides_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_price_overrides_product_id ON catalog.price_overrides (product_id);

ALTER TABLE marketing.promo_discounts ADD COLUMN promotion_id integer;

WITH p AS (
    SELECT promotion_id AS v, row_number() OVER (ORDER BY promotion_id) - 1 AS k
      FROM marketing.promotions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM marketing.promotions)
                 * power((abs(hashtext('marketing.promo_discounts:' || concat_ws('|', x.promo_ref, x.discount_bps, x.discount_pct))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM marketing.promo_discounts x
)
UPDATE marketing.promo_discounts t
   SET promotion_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE marketing.promo_discounts ALTER COLUMN promotion_id SET NOT NULL;
ALTER TABLE marketing.promo_discounts ADD CONSTRAINT promo_discounts_promotion_id_fkey FOREIGN KEY (promotion_id) REFERENCES marketing.promotions (promotion_id);
CREATE INDEX ix_promo_discounts_promotion_id ON marketing.promo_discounts (promotion_id);

ALTER TABLE payments.historic_refunds ADD COLUMN transaction_id integer;

WITH p AS (
    SELECT transaction_id AS v, row_number() OVER (ORDER BY transaction_id) - 1 AS k
      FROM payments.transactions
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM payments.transactions)
                 * power((abs(hashtext('payments.historic_refunds:' || concat_ws('|', x.refund_ref, x.order_ref, x.amount_p))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM payments.historic_refunds x
)
UPDATE payments.historic_refunds t
   SET transaction_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE payments.historic_refunds ALTER COLUMN transaction_id SET NOT NULL;
ALTER TABLE payments.historic_refunds ADD CONSTRAINT historic_refunds_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES payments.transactions (transaction_id);
CREATE INDEX ix_historic_refunds_transaction_id ON payments.historic_refunds (transaction_id);
-- <<< relationships
