-- Cross River Trading Co. -- remittance parsing, aliases, weights, help search
-- author: P. Adeyemi
-- postgres: 18
--
-- The remittance file parser finance asked for, the supplier alias list that
-- came out of the 2026 merge, the weights the carrier quote engine reads, the
-- help centre search index, and the category share report.

-- DEFECT position-returns-zero-and-a-negative-substring-start-returns-a-prefix
--
-- A remittance line carries two codes either side of a slash, and the parser
-- lifts the pair out in one go: four characters before the slash, the slash,
-- and three after. The window is eight wide and starts four before the slash.
--
-- position() returns zero when it does not find what it was asked for, and the
-- direct debit file has no slash. Zero minus four is minus four, and substring
-- with a negative start is not an error in PostgreSQL: it takes the part of the
-- window that overlaps the string, so those lines come back with the first
-- three characters of the line. The parser reports a reference for every line
-- it has ever been given.
--
-- Measured: 60 of the 300 lines have no slash at all, and every one
-- of them carries a three character reference cut from the front of the line
-- rather than a null.
--
-- position() returning zero for absent is the older half of this; the newer
-- half is that a start of minus four is accepted. Either one alone would have
-- produced a null or an error. Together they produce a code of the wrong shape
-- that the matching job then fails to find, and the payment sits unallocated
-- with a reference beside it.
CREATE TABLE payments.remittance_lines (
    line_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    line_text      varchar(80) NOT NULL,
    reference_code varchar(8)
);

-- The BACS file, which carries the slash, and the direct debit file, which does
-- not.
INSERT INTO payments.remittance_lines (line_text)
SELECT CASE WHEN g % 5 = 0
            THEN 'DD' || lpad(((g * 13) % 9000 + 1000)::text, 4, '0')
                      || lpad((100 + g)::text, 8, '0')
            ELSE lpad(((g * 13) % 9000 + 1000)::text, 4, '0')
                      || '/' || lpad((100 + g)::text, 8, '0')
       END
FROM generate_series(1, 300) AS g;

UPDATE payments.remittance_lines
   SET reference_code = substring(line_text FROM position('/' IN line_text) - 4 FOR 8);

-- DEFECT unicode-decomposed-form-duplicates-a-name
--
-- Supplier aliases, unique so the same trading name cannot be recorded twice.
-- The list was merged from two systems, one of which writes accented letters as
-- one character and one of which writes them as a letter followed by a
-- combining accent.
--
-- PostgreSQL does not normalise text. The two spellings are different strings
-- to the unique index and the same word to anybody reading them: they are equal
-- under normalize(..., NFC) and not equal under =. The constraint accepted both
-- and the duplicates cannot be seen on screen, because they render identically.
--
-- Measured: 20 of the 60 aliases duplicate another row
-- once both are normalised. Nothing distinguishes them except a length that is
-- one character longer than the letters shown.
--
-- normalize() on the way in, or a unique index over normalize(alias, NFC),
-- settles it. Without one, a search for the supplier by name finds one row or
-- the other depending on which keyboard typed the query.
CREATE TABLE supply.supplier_aliases (
    alias_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    supplier_id integer NOT NULL REFERENCES supply.suppliers(supplier_id),
    alias       varchar(80) NOT NULL UNIQUE
);

-- The first system's export: one accented character.
INSERT INTO supply.supplier_aliases (supplier_id, alias)
SELECT s.supplier_id, U&'Cr\00E8me Fournitures ' || lpad(s.supplier_id::text, 3, '0')
FROM supply.suppliers s;

-- The second system's, loaded after the merge: letter plus combining accent.
INSERT INTO supply.supplier_aliases (supplier_id, alias)
SELECT s.supplier_id,
       'Cr' || U&'\0065\0300' || 'me Fournitures ' || lpad(s.supplier_id::text, 3, '0')
FROM supply.suppliers s
WHERE s.supplier_id % 2 = 0;

-- DEFECT numeric-nan-sorts-above-every-value
--
-- Product weights, read by the carrier quote engine and by the report that
-- lists the heaviest lines so the warehouse can plan pallets. The supplier feed
-- sends a weight per product and sends the string NaN when it has none.
--
-- numeric accepts NaN. It is not null, so nothing about it is missing as far as
-- the database is concerned, and numeric sorts NaN above every real number and
-- treats it as equal to itself. Any ORDER BY weight DESC returns the products
-- with no weight first, and max() over the column returns NaN.
--
-- Measured: 86 products carry NaN. All ten rows of the heaviest products
-- report are products with no weight, and the heaviest real product is not on
-- it.
--
-- A null would have been excluded by every aggregate and sorted last by
-- default. NaN was chosen by the feed, accepted by the column, and is the one
-- value that beats every genuine weight in a comparison.
CREATE TABLE catalog.product_weights (
    product_id integer PRIMARY KEY REFERENCES storefront.products(product_id),
    weight_kg  numeric(8,3) NOT NULL
);

INSERT INTO catalog.product_weights (product_id, weight_kg)
SELECT p.product_id,
       CASE WHEN p.product_id % 23 = 0
            THEN 'NaN'::numeric
            ELSE round((1 + (p.product_id % 40))::numeric / 2, 3)
       END
FROM storefront.products p;

CREATE VIEW analytics.v_heaviest_products AS
SELECT w.product_id,
       p.name,
       w.weight_kg
FROM catalog.product_weights w
JOIN storefront.products p ON p.product_id = w.product_id
ORDER BY w.weight_kg DESC
LIMIT 10;

-- DEFECT text-search-config-simple-does-not-stem
--
-- The help centre index. The vector is built with the simple configuration,
-- which was chosen while the author was testing that the index worked at all,
-- and the application searches with the english configuration, which is the
-- default and is what to_tsquery uses when nothing is said.
--
-- simple lowercases and splits on word boundaries and does nothing else. It
-- keeps returning as returning. english stems it to return, which is what the
-- query contains, so the two never meet. The index is populated, it is used,
-- and it answers correctly for every word that happens to be its own stem.
--
-- Measured: 60 of the 120 articles say returning, and a search for return
-- matches none of them. It finds the other 60, which spell the word as return
-- and need no stemming to match.
--
-- Both sides have to name the same configuration. The half of the vocabulary
-- that is already a stem works perfectly, which is why the search was signed
-- off, and the failures look like missing articles rather than a broken index.
CREATE TABLE catalog.help_articles (
    article_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    title         varchar(120) NOT NULL,
    body          text NOT NULL,
    search_vector tsvector
);

INSERT INTO catalog.help_articles (title, body)
SELECT 'Help article ' || lpad(g::text, 3, '0'),
       CASE WHEN g % 2 = 0
            THEN 'Returning a damaged item to the warehouse, with photographs.'
            ELSE 'How to return an item bought in store, and what the refund covers.'
       END
FROM generate_series(1, 120) AS g;

UPDATE catalog.help_articles
   SET search_vector = to_tsvector('simple', title || ' ' || body);

CREATE INDEX ix_help_articles_search ON catalog.help_articles USING gin (search_vector);

-- DEFECT order-by-in-a-window-turns-a-total-into-a-running-total
--
-- Share of sales by category. The denominator is the total across every
-- category, written as a window sum so the view returns one row per category
-- and each row can carry the whole. The ORDER BY was added so the rows came
-- back in category order.
--
-- A window function with an ORDER BY and no frame clause gets the default
-- frame, which runs from the start of the partition to the current row. The
-- ORDER BY did not sort the output, it turned the denominator into a running
-- total. The first category is divided by itself and reports 100%, and every
-- row after it is divided by a number smaller than the real total.
--
-- Measured: the shares add up to 327.8% instead of 100%. The first
-- category is reported at 100.0% of sales and holds 11.6% of them.
--
-- Removing the ORDER BY gives the total, and an ORDER BY outside the window
-- gives the row order that was wanted. Both were meant. Writing one where the
-- other belongs produces a report where no single row looks impossible.
CREATE VIEW analytics.v_category_share AS
SELECT p.category_id,
       sum(oi.line_total_cents)                                    AS category_cents,
       sum(sum(oi.line_total_cents)) OVER (ORDER BY p.category_id) AS all_categories_cents,
       round(100.0 * sum(oi.line_total_cents)
             / sum(sum(oi.line_total_cents)) OVER (ORDER BY p.category_id), 1) AS share_pct
FROM storefront.order_items oi
JOIN storefront.products p ON p.product_id = oi.product_id
GROUP BY p.category_id;

-- DEFECT update-from-with-many-matches-applies-one-arbitrary-row
--
-- A remittance can be settled in parts, and the settled amount was backfilled
-- from the settlement events with an UPDATE ... FROM, which is the idiomatic
-- way to copy a value across from another table.
--
-- UPDATE ... FROM joins, and when the join matches more than one row the target
-- row is updated once, from one of the matching rows, chosen by whatever the
-- plan happened to do. No error is raised and no warning is given. The parts
-- were meant to be added together, so a remittance settled in three payments
-- now holds the amount of one of them.
--
-- Measured: 133 of the 400 remittances were settled in more than one
-- part, and every one of them holds less than it was paid. The register is
-- 697,850 pennies short against the events it was built from.
--
-- An aggregate in a subquery, or a FROM over a grouped subquery, does what was
-- intended. This statement ran once, reported 400 rows updated, and the
-- difference is only visible against a table nobody reconciles it to.
CREATE TABLE payments.remittances (
    remittance_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    received_on    date NOT NULL,
    settled_cents  integer
);

CREATE TABLE payments.settlement_events (
    event_id      integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    remittance_id integer NOT NULL REFERENCES payments.remittances(remittance_id),
    settled_on    date NOT NULL,
    amount_cents  integer NOT NULL CHECK (amount_cents > 0)
);

INSERT INTO payments.remittances (received_on)
SELECT DATE '2026-01-05' + (g % 180)
FROM generate_series(1, 400) AS g;

INSERT INTO payments.settlement_events (remittance_id, settled_on, amount_cents)
SELECT r.remittance_id,
       r.received_on + part,
       2000 + (r.remittance_id % 11) * 100 + part * 50
FROM payments.remittances r,
     LATERAL generate_series(1, CASE WHEN r.remittance_id % 3 = 0 THEN 3 ELSE 1 END) AS part;

UPDATE payments.remittances r
   SET settled_cents = e.amount_cents
  FROM payments.settlement_events e
 WHERE e.remittance_id = r.remittance_id;

-- >>> relationships (generated, do not edit by hand)
-- Declared, typed to match the parent, indexed and NOT NULL. None of these
-- is a defect, and none is catalogued: a tool that reports one has found
-- something that is not there.
--
-- Deferred checks queued earlier in this migration run now rather than at
-- commit: PostgreSQL will not alter a table with events still pending.
SET CONSTRAINTS ALL IMMEDIATE;

ALTER TABLE catalog.help_articles ADD COLUMN product_id integer;

WITH p AS (
    SELECT product_id AS v, row_number() OVER (ORDER BY product_id) - 1 AS k
      FROM storefront.products
),
c AS (
    SELECT x.tableoid AS roid, x.ctid AS rid,
           floor((SELECT count(*) FROM storefront.products)
                 * power((abs(hashtext('catalog.help_articles:' || concat_ws('|', x.title, x.body, x.search_vector))) % 1000000) / 1000000.0, 2))::bigint AS k
      FROM catalog.help_articles x
)
UPDATE catalog.help_articles t
   SET product_id = p.v
  FROM c JOIN p ON p.k = c.k
 WHERE t.tableoid = c.roid AND t.ctid = c.rid;

ALTER TABLE catalog.help_articles ALTER COLUMN product_id SET NOT NULL;
ALTER TABLE catalog.help_articles ADD CONSTRAINT help_articles_product_id_fkey FOREIGN KEY (product_id) REFERENCES storefront.products (product_id);
CREATE INDEX ix_help_articles_product_id ON catalog.help_articles (product_id);
-- <<< relationships
