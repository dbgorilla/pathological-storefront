-- Cross River Trading Co. -- campaigns and coupons
-- author: T. Brennan
-- postgres: 10

CREATE SCHEMA marketing;

CREATE TABLE marketing.campaigns (
    campaign_id   serial PRIMARY KEY,
    name          varchar(255) NOT NULL,
    channel       varchar(255) NOT NULL
                    CHECK (channel IN ('email', 'sms', 'post', 'display')),
    starts_on     date NOT NULL,
    ends_on       date,
    budget_cents  integer NOT NULL DEFAULT 0,
    -- DEFECT json-in-text-column
    --
    -- The targeting rules the campaign tool sends are JSON. The column is text,
    -- because the tool posts a string and text takes a string. jsonb was in
    -- PostgreSQL by 2018 and would have rejected the malformed ones on the way
    -- in; text accepts anything and stores it.
    --
    -- Nothing validates these. Nothing can index into them without parsing
    -- first, and a parse of a column that is not all valid JSON fails on the
    -- whole query rather than on the row, so the usual way of finding out is a
    -- report that used to work breaking after a new campaign is added.
    targeting     text,
    -- DEFECT array-column-as-foreign-key-list
    --
    -- The three products a campaign features. A join table was the obvious
    -- shape and it was rejected as heavy for three ids, which it is.
    --
    -- An array cannot carry a foreign key. PostgreSQL has no syntax for "every
    -- element of this array references that table", so nothing stops an id
    -- here from naming a product that was deleted, or a product that never
    -- existed, and nothing will ever tell you which. Deleting a product
    -- succeeds and leaves the campaign pointing at it.
    --
    -- It also cannot be joined without unnesting, so the report that lists
    -- campaigns by featured product scans every campaign, expands every array
    -- and joins the result. There is no index that helps: a GIN index answers
    -- "which campaigns contain product 7", which is the question nobody asks.
    featured_product_ids integer[]
);

CREATE TABLE marketing.coupons (
    coupon_id       serial PRIMARY KEY,
    campaign_id     integer REFERENCES marketing.campaigns (campaign_id),
    code            varchar(255) NOT NULL UNIQUE,
    percent_off     integer CHECK (percent_off BETWEEN 1 AND 100),
    amount_off_cents integer CHECK (amount_off_cents > 0),
    max_redemptions integer,
    expires_at      timestamptz
);

CREATE TABLE marketing.coupon_redemptions (
    coupon_redemption_id  serial PRIMARY KEY,
    coupon_id             integer NOT NULL REFERENCES marketing.coupons (coupon_id),
    order_id              integer NOT NULL REFERENCES storefront.orders (order_id),
    customer_id           integer NOT NULL REFERENCES storefront.customers (customer_id),
    redeemed_at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ix_coupon_redemptions_coupon ON marketing.coupon_redemptions (coupon_id);

-- DEFECT redundant-index-coupon-redemptions
-- Added by a different engineer six weeks later, for a report that was already
-- served by ix_coupon_redemptions_coupon above. A B-tree on (coupon_id) is
-- redundant against a B-tree whose leading column is coupon_id.
CREATE INDEX ix_coupon_redemptions_coupon_order
    ON marketing.coupon_redemptions (coupon_id, order_id);

-- DEFECT dead-table-sms-campaigns
-- The SMS channel ran from 2018 until the subscription box was killed in 2021.
-- Nothing has written to this table since, and nothing reads it.
CREATE TABLE marketing.sms_campaigns (
    sms_campaign_id  serial PRIMARY KEY,
    campaign_id      integer NOT NULL REFERENCES marketing.campaigns (campaign_id),
    shortcode        varchar(255) NOT NULL,
    body             varchar(255) NOT NULL,
    sent_at          timestamptz
);

-- DEFECT after-trigger-assigns-to-new
--
-- Coupon codes are entered by hand by the marketing team and looked up by an
-- application that uppercases whatever the customer typed. The fix was a
-- trigger that uppercases the code on the way in, and the function is right.
--
-- The trigger is AFTER INSERT. By then the row has been written and NEW is a
-- copy: assigning to it is legal, the assignment runs, and PostgreSQL discards
-- the result. Only a BEFORE trigger's NEW is the row that gets stored. There is
-- no error, no warning and no return value to ignore, so the trigger passes
-- every test that inserts a row and then reads it back through the same
-- uppercasing application code.
--
-- Every hand-entered lowercase code is therefore stored lowercase and can never
-- be redeemed, because the lookup uppercases first. The coupon exists, the
-- campaign reports it as live, and the customer is told it is not valid.
CREATE FUNCTION marketing.normalise_coupon_code() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    NEW.code := upper(NEW.code);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_coupons_normalise_code AFTER INSERT ON marketing.coupons
    FOR EACH ROW EXECUTE FUNCTION marketing.normalise_coupon_code();

-- DEFECT array-index-zero-is-always-null
--
-- The campaign list shows one headline product per campaign, taken as the
-- first element of the featured array. It was written by someone whose last
-- ten years were in application code, where the first element is element zero.
--
-- SQL arrays are one-based. PostgreSQL does not treat a subscript below the
-- lower bound as an error: reading outside an array returns null, the same as
-- reading a null column, so the statement runs and the column is typed
-- correctly and every row comes back empty.
--
-- All 60 campaigns have featured products and all 60 report no headline
-- product. The list screen renders the blank as "none selected", which is a
-- state the campaign tool can genuinely produce, so the page looks like a
-- marketing problem rather than a query one. Changing the 0 to a 1 fixes every
-- row.
CREATE VIEW marketing.v_campaign_headline AS
SELECT campaign_id,
       name,
       channel,
       featured_product_ids[0] AS headline_product_id
FROM marketing.campaigns;

-- DEFECT implicit-cross-join-in-a-view
--
-- Campaigns and the products they feature, for the merchandising export. The
-- comma between the two tables is the old join syntax and means the same thing
-- as CROSS JOIN: the predicate that ties the two together belongs in the WHERE
-- clause, and this one has a WHERE that filters campaigns and joins nothing.
--
-- There is no error and no warning. Comma syntax cannot distinguish a join
-- somebody forgot to write from a cross join somebody wanted, and the plan is
-- correct for what was asked.
--
-- Measured: 54 campaigns pass the filter and there are 2,000 products, so the
-- view is 108,000 rows, every product against every campaign. The export reads
-- as a campaign featuring the whole catalogue, which is what a sitewide sale
-- looks like, so the first people to see it assumed the campaigns had been set
-- up that way. The join belongs through marketing.promotion_products and is
-- one line.
CREATE VIEW marketing.v_campaign_products AS
SELECT c.campaign_id,
       c.name AS campaign_name,
       p.product_id,
       p.sku
FROM marketing.campaigns c, storefront.products p
WHERE c.ends_on >= DATE '2019-01-01';
