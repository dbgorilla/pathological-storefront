# Cross River Trading Co: how the database got this way

Cross River Trading Co. is not a real company. It is the fictional setting for this fixture, which gives each defect in `GROUND-TRUTH.md` a reason rather than placing defects at random.

Fixtures that scatter problems at random are easy to spot and easy to game. Real databases develop through decisions made under deadlines and against the PostgreSQL version available at the time. A schema that developed incorrectly still has a history. This is that history.

The dates are fictional. The mistakes are not. Each one is based on something that happens in real databases, and `GROUND-TRUTH.md` cross-references each defect to the article explaining it.

## Before the database

**1974.** Cross River Trading Co. opens as a single hardware and general goods shop. It uses paper ledgers, then a card index, and, twenty-four years later, a Microsoft Access file on one PC behind the till.

The only relevant detail is that there was one shop. The system therefore never needed to record *which* shop, and that assumption is still present in 2026.

## 2012 to 2013: the web store

A contractor builds the first online store on PostgreSQL 9.1. The project has seven tables, one schema, four weeks, and a fixed price.

The schema meets the original requirements. Every table has a primary key, and the necessary foreign keys are declared. It serves the business for two years without changes.

**What it left behind**

- `serial` primary keys throughout, because identity columns did not exist yet
- `varchar(255)` on every text column, because that is what the ORM generated
- No `store_id` anywhere, because there was one shop
- `products.sku` unique across the whole table, which was true at the time

None of these were wrong in 2012. Three of them are wrong now.

## 2014 to 2015: the second and third shop

Two more locations open, so the database needs to record shops.

A `stores` table is added, and `store_id` is added to the tables that obviously need it. The original shop becomes `store_id = 1` and remains the default in six different places because the default was correct about 80% of the time.

**What it left behind**

- `products.sku` is now unique per store, but the original table-wide `UNIQUE` constraint was dropped rather than replaced, so nothing enforces either rule
- `store_id` is nullable on three tables, where null means "the original shop"
- A hardcoded `store_id = 1` default that remains after the people who understood it have left

This is the first defect to persist because it is usually correct.

## 2016 to 2017: the warehouse

The business outgrows shipping from the back of the shops. A distribution centre opens, along with the first schema that is not `storefront`: `fulfilment`, with carriers, warehouses, shipments and stock locations.

The team now consists of two engineers and a contractor. Shipping goes live three weeks late, and the launch migration is written the night before.

**What it left behind**

- `fulfilment.shipments.order_id` points at `storefront.orders` with no foreign key. The migration that would have added it locked the orders table in staging and was pulled.
- No index on that column, so the shipment lookup sequential-scans
- Returns are added later, which is why the returns tables reference orders and orders reference returns

The circular reference between `orders` and `returns` dates from this period. Both directions were added by the same person, for good reasons, a month apart.

## 2018 to 2019: suppliers, marketing, and the subscription box

Three projects start at once.

Purchasing moves from spreadsheets into a `supply` schema. Marketing gets campaigns and coupons. The company launches a monthly subscription box in 2018.

The subscription product is built by a separate team under a separate deadline. It gets its own tables and conventions, and it writes a `subject_type` of `subscription` into the support ticket table.

**What it left behind**

- `payments.transactions.amount` is `double precision`, because the person who wrote it came from a Python background and treated `float` as the appropriate type for a number with a decimal point. Every other money column in the database is integer cents.
- Product attributes modelled as entity-attribute-value, because the catalogue team could not get schema changes reviewed quickly enough
- The first `jsonb` column, queried with `@>` and given a B-tree index, which does nothing for it

## 2020 to 2021: subscriptions die, the support desk is built

Subscriptions are shut down in March 2021. A tidy-up migration drops the tables.

Nobody checks what referenced them.

**What it left behind**

- `support.tickets.subject_type` still contains `subscription` on historical rows, pointing at a table that no longer exists. This is a polymorphic reference with no target.
- Three columns on `customers` that only the subscription product ever wrote
- `marketing.sms_campaigns`, last written to in 2021, never dropped

The support desk is built in the same period, with a self-referencing ticket table for merges. It also has a trigger that writes an audit row on every update, which becomes important in 2024.

## 2022: the acquisition

Cross River buys **Silverback Direct**, an online-only competitor about a third its size, for the customer base and the warehouse in the north.

Integration is given six months. The decision is to add Silverback's database as its own schema and bridge the two rather than migrate. The bridge is intended to be temporary.

**What it left behind**

- An entire schema written to different conventions: `uuid` primary keys, `timestamp` without time zone, plural table names, `is_deleted` flags instead of status columns
- `legacy.customer_map`, the bridge table, matching Silverback customers to Cross River customers at 97% coverage. The remaining 3% were going to be resolved by hand.
- Two sources of truth for a customer, diverging quietly ever since
- A `money` typed column, which nobody at Cross River would have chosen

This event accounts for more of the structural defects in this database than any other event.

## 2023: Project Meridian

The platform rewrite takes eighteen months of headcount and uses a three-phase migration plan: expand, migrate, contract.

Expand ships. Migrate ships. The team is reassigned in the fourth quarter.

**What it left behind**

- Old and new columns both present on `orders`, both written by a trigger
- The two have drifted apart on 36 of the 5,880 orders that carry both columns, because the trigger has an edge case nobody found
- A `CHECK` constraint added `NOT VALID` to get the deploy out, with a
  `-- TODO: validate` comment that is still there
- Views built over views built over views, because the rewrite added a compatibility layer on top of the old one

Contract was never run. It is still on a backlog.

## 2024 to 2025: analytics and the model

The data team arrives. It creates rollup tables, a materialised view for the daily sales dashboard, and a customer segmentation model.

The dashboard is refreshed by a cron job. The cron job runs on a server that was decommissioned during the 2025 cloud migration.

**What it left behind**

- `analytics.mv_daily_sales`, last refreshed in 2025, still answering questions
- Rollup tables that disagree with the transactional tables they summarise
- `analytics.customer_segments`, created for a model that was never deployed, containing zero rows
- The audit trigger from 2020, now firing on a table with millions of writes a day and feeding a log with no retention policy. It is the largest object in the database, and nobody has ever queried it.

## 2026: the PostgreSQL 18 upgrade

Cross River upgrades from PostgreSQL 14 to 18 in one jump, having skipped three majors. The upgrade itself goes cleanly.

Tables written after the upgrade use the new features. The old ones do not because nobody went back.

**What it left behind**

- Generated columns written as `GENERATED ALWAYS AS (...)` with no keyword. In
  PostgreSQL 18 that means `VIRTUAL`, recomputed on every read and stored
  nowhere. The author had tested on 17, where the same statement was an error,
  and assumed it was stored.
- A `CHECK` constraint added `NOT ENFORCED`, which exists in the catalogue and
  enforces nothing
- A `NOT NULL` constraint set `NOT VALID` during a backfill that was never
  finished, so a column marked `NOT NULL` contains nulls
- Temporal constraints on the new pricing tables, alongside a 2016 table doing
  the same job with a trigger that gets it wrong at boundaries

These are the defects a tool is least likely to find because they are invisible to `information_schema` and to `pg_dump`. They live only in `pg_constraint`, in columns that did not exist before PostgreSQL 18.

## Where the database stands in 2026

Fourteen years, several PostgreSQL upgrades, one acquisition, one abandoned rewrite and one killed product. Twelve schemas, six hundred and eighty five tables, and a migration history that accounts for all of it.

Every defect above is enumerated with its exact numbers in `GROUND-TRUTH.md`, and every one can be traced to the migration that introduced it.

Nobody at Cross River was bad at their job.
