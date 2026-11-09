# Phases: stepping the database through fourteen years

`ROADMAP.md` describes how Cross River's database reached its current state. This
file is the operational version. For each step, it lists the migrations to
apply, the application capabilities they enable, and the resulting traffic.

It allows a staging environment to be advanced one step at a time until it
resembles a database that has been in production since 2012, rather than one
created this morning.

## The shape of it

Three things advance at each step, but remain separate:

1. **Schema.** Flyway migrations, applied in order. Already built.
2. **Application capability.** What the app offers, and which query shapes reach
   the database. One application, controlled by a phase number.
3. **Traffic.** Rate, mix, and growth. One workload engine, with one profile per
   phase.

Two design decisions govern the project.

**One application, not seventeen.** A phase number selects enabled features and
the query shapes used by the workload. Building a separate app per era would
leave the project unfinished.

**Volume ramps independently of features.** Every phase has a traffic index,
where 2026 is 100. Tables grow whether or not the phase adds a feature. A
database with fourteen years of history is recognisable by its size distribution
as well as its schema.

## How a step is applied

Flyway takes a target, so each phase is one command:

```
flyway migrate -target=2014.11.18
```

Then set the app's phase gate and switch the traffic profile.

Stored procedures are versioned with the migrations they were written with, so a
step adds only the procedures that existed by that date.

## Mapping fourteen years onto wall clock

The system watching the database records each change when it occurs, so its
history uses wall clock time rather than the fictional dates. The fictional
dates live in the migration versions and in the Flyway history table.

Recommended: **one phase per day**, seventeen days to walk the whole history,
with traffic running continuously at the current phase's profile. This provides
real telemetry with a daily pattern and preserves the order of the schema
history. Shorter steps work, but anything under a few hours stops producing a
believable daily curve.

---

## Phase 1: the web store

**2012 to 2013.** Migrations `V2012.03.01`, `V2012.09.14`, `V2013.02.20`.

**What the app can do.** Browse a catalogue, add items to a cart, check out, and
pay. One shop. Gift messages and order notes. A marketing opt-in checkbox on the
checkout form. Seven tables, one schema, built by a contractor in four weeks for
a fixed price. It is a suitable schema for its original requirements.

**Traffic.** The simplest profile in the sequence.

| Workload | Share |
|---|---|
| Catalogue browse | 60% |
| Cart and checkout | 30% |
| Back office order admin | 10% |

There is no search, fulfilment, or support desk. Traffic runs during business
hours, with a long overnight gap. There are no background jobs.

**Traffic index.** 3.

---

## Phase 2: the second and third shop

**2014 to 2015.** Migrations `V2014.06.02`, `V2014.11.18`, `V2015.04.09`.

**What the app gains.** Stores exist. Stock, pricing, and orders are per store,
and the store picker appears in the UI. Opening hours drive a "collect from
store" option. Catalogue search arrives.

**How traffic changes.** Catalogue and order queries gain a `store_id` predicate,
except where they do not. The default is correct about 80% of the time, and
nobody notices the other 20%. Search adds the first `ILIKE '%term%'` to the
workload, where it remains for twelve years.

**Traffic index.** 8.

---

## Phase 3: the warehouse

**2016 to 2017.** Migrations `V2016.02.15`, `V2016.08.03`, `V2017.05.22`,
`V2017.09.30`.

**What the app gains.** Shipping from a distribution centre rather than the back
of a shop. Pick, pack, dispatch, and tracking. Returns are added as an
afterthought and shipped three weeks late. Carrier integrations provide rate
lookups and label generation.

**How traffic changes.** Two schemas are in use for the first time, and the
shipment lookup joins them without a foreign key or index. The lookup runs on
every order status page, so it remains in the workload from this phase onward.

**What a monitoring tool should start seeing.** The missing index on
`fulfilment.shipments.order_id`, under real read pressure rather than in theory.

**Traffic index.** 15.

---

## Phase 4: suppliers, payments, marketing, catalogue

**2018.** Migrations `V2018.01.16`, `V2018.04.11`, `V2018.07.25`, `V2018.10.02`.

**What the app gains.** Four things at once, which is how much of this debt was
created. Purchasing moves off spreadsheets. Payments become a real schema with
transactions rather than a column on the order. Marketing gets campaigns and
coupons. The catalogue team gets its own schema with entity-attribute-value
product attributes because schema changes could not be reviewed quickly enough.

**How traffic changes.** EAV attribute reads enter the workload and immediately
become some of the most expensive queries on the product page. Coupon validation
runs on every checkout. Purchase order writes add a low-rate back office
pattern that runs during business hours only.

**Traffic index.** 28.

---

## Phase 5: jsonb, the subscription box, promotions

**2019.** Migrations `V2019.01.14`, `V2019.05.06`, `V2019.11.20`.

**What the app gains.** Product specifications as `jsonb`, queried with `@>`.
The monthly subscription box, the strategic bet of 2018, is built quickly by a
separate team with its own conventions. Promotions and price history are added.

**How traffic changes.** A recurring monthly billing run appears. It is the
first workload job with a monthly rather than daily period. The `jsonb`
containment queries run against a B-tree index that cannot serve them.

**Traffic index.** 38.

---

## Phase 6: the support desk

**2020.** Migrations `V2020.03.10`, `V2020.06.18`.

**What the app gains.** A support desk with ticket threads, merges through a
self-referencing table, and agent assignment. It is one of the better-designed
parts of the database. An operations event log is added alongside it, fed by a
trigger that writes an audit row on every update.

**How traffic changes.** Online retail volume jumps this year and the whole
profile rises with it. The audit trigger means every write in the covered
tables becomes two writes, and the event log starts growing without a retention
policy.

**Traffic index.** 50.

---

## Phase 7: subscriptions die

**2021.** Migrations `V2021.03.04`, `V2021.12.01`.

**What the app gains.** Nothing. It loses the subscription box, which is shut
down in March and removed in a tidy-up migration that everyone agrees is
overdue. The monthly billing run disappears from the workload.

**How traffic changes.** The monthly job stops. Support tickets with
`subject_type = 'subscription'` are still read, now pointing at a table that no
longer exists.

`V2021.12.01` is a data load rather than a schema change: nine years of trading
history, so every migration after this point operates on real rows.

**Traffic index.** 55.

---

## Phase 8: the acquisition

**2022.** Migrations `V2022.05.09`, `V2022.05.30`, `V2022.06.01`.

**What the app gains.** Silverback Direct customers can sign in. The app checks
`legacy.customer_map` on every authenticated request to decide whether a
customer is Cross River, Silverback, or both. Order history becomes a union
across two schemas with two sets of conventions. A "claim your old account"
flow appears for the 3% the bridge did not match.

**How traffic changes.** Cross-schema joins enter the workload and remain there,
joining `uuid` to `integer`. A nightly reconciliation job tries to match the
unmatched 36, finds nothing, and runs again the next night. Customer rows rise
by about a third overnight without a corresponding rise in orders.

**Traffic index.** 75.

---

## Phase 9: Meridian expand

**2023 Q1.** Migration `V2023.02.13`.

**What the app gains.** Nothing visible to customers. The order writer starts
dual-writing: old money columns and new bigint minor units, old status text and
new enum, both maintained by a trigger.

**How traffic changes.** Write volume per order roughly doubles without an
increase in orders placed. This is the telemetry pattern to preserve: the
business did not get busier, but the database did.

**Traffic index.** 80, with write cost per checkout doubled.

---

## Phase 10: Meridian migrate

**2023 Q2.** Migration `V2023.06.27`.

**What the app gains.** Reads switch to the new columns through a compatibility
view layer, so reporting queries do not need to change. Nothing is rewritten,
which was the purpose of the layer and the reason it remains.

**How traffic changes.** Every order read now passes through views over views.
Plans get deeper, row estimates get worse, and no individual query looks wrong.

**Traffic index.** 80. The change is in plan shape, not volume.

---

## Phase 11: constraints, and the team is reassigned

**2023 Q3.** Migration `V2023.09.11`.

**What the app gains.** Nothing.

**How traffic changes.** Nothing.

This step is included because nothing observable changes. A `CHECK` is added
`NOT VALID` to get a deployment out, with a `TODO` beside it, and the team
moves off the project that quarter. The constraint is never run. A tool that
only finds problems by watching traffic finds nothing here, although there is
something to find.

**Traffic index.** 80.

---

## Phase 12: the data team arrives

**2024 Q2.** Migration `V2024.04.02`.

**What the app gains.** Internal dashboards over rollup tables. A customer
segmentation table is created for a model that is still being built.

**How traffic changes.** A nightly rollup job filters on
`placed_at >= last run`, which misses backdated orders. A morning read spike
occurs as the dashboards open. This is the first phase with a pronounced daily
pattern: quiet overnight except for the job, followed by a spike at 08:00.

`analytics.customer_segments` stays at zero rows. The model is never deployed.

**Traffic index.** 88.

---

## Phase 13: the daily sales dashboard

**2024 Q3.** Migration `V2024.08.19`.

**What the app gains.** A materialised view behind the executive dashboard,
refreshed by a cron job at 02:00.

**How traffic changes.** A refresh runs every night, followed by a read spike
when the dashboard opens. Both are unremarkable, which is what makes phase 15
work.

**Traffic index.** 88.

---

## Phase 14: configuration moves into the database

**2025 Q1.** Migration `V2025.01.27`.

**What the app gains.** Settings move out of environment variables so ops can
change them without a deployment. The app reads its configuration from a small
table.

**How traffic changes.** A high-frequency point lookup on a small table enters
the workload and dominates every "most frequent query" list from this point
onward. It is fast and correct, but will bury more interesting queries in any
report sorted by call count.

**Traffic index.** 93, plus a config read on every request.

---

## Phase 15: the cloud migration

**2025 Q2.** Migration `V2025.06.15`.

**What the app gains.** Reporting reads reach into the `archive` schema for old
orders, across an inheritance parent and its year tables.

**How traffic changes.** Two things happen, and only one is a migration.

1. Archive reads join across the inheritance hierarchy.
2. **The matview refresh cron stops running.** The server where it ran was
   decommissioned during the migration. Nobody notices because the dashboard
   continues to answer.

The second is a **scripted event, not a migration**, and the stepper has to
support it. Some database changes result from a job stopping rather than from a
migration being applied. From this point, the daily sales dashboard is quietly
wrong and becomes more wrong each day.

**Traffic index.** 93.

---

## Phase 16: the PostgreSQL 18 upgrade

**2026 H1.** Migrations `V2026.01.15`, `V2026.02.03`, `V2026.03.17`,
`V2026.04.21`, `V2026.05.12`.

**What the app gains.** New pricing with temporal constraints. Generated columns
on the newer tables. The older tables retain their 2016 trigger, which performs
the same job but is slightly wrong at boundaries because nobody revised it.

**How traffic changes.** Reads touching the generated columns cost more than they
appear to: the columns are virtual, recomputed on every read, and stored
nowhere. Nothing in the query text indicates this.

**Traffic index.** 100.

---

## Phase 17: the 2026 backlog

**2026 H2.** Migrations `V2026.06.08`, `V2026.06.09`, `V2026.07.01`,
`V2026.07.02`, `V2026.07.03`, `V2026.07.04`, `V2026.07.05`, `V2026.07.06`, `V2026.07.07`, `V2026.07.08`, `V2026.07.09`, `V2026.07.10`, `V2026.07.11`, `V2026.07.12`, `V2026.07.13`, `V2026.07.14`, `V2026.07.15`, `V2026.07.16`, `V2026.07.17`, `V2026.07.18`, `V2026.07.19`, `V2026.07.20`, `V2026.07.21`, `V2026.07.22`, `V2026.07.23`, `V2026.07.24`, `V2026.07.25`, `V2026.07.26`, `V2026.07.27`, `V2026.07.28`, `V2026.07.29`, `V2026.07.30`, `V2026.07.31`, `V2026.08.01`, `V2026.08.02`, `V2026.08.03`, `V2026.08.04`, `V2026.08.05`, `V2026.08.06`, `V2026.08.07`, `V2026.08.08`, `V2026.08.09`, `V2026.08.10`, `V2026.08.11`, `V2026.08.12`, `V2026.08.13`, `V2026.08.14`, `V2026.08.15`, `V2026.08.16`, `V2026.08.17`, `V2026.08.18`, `V2026.08.19`, `V2026.08.20`, `V2026.08.21`, `V2026.08.22`, `V2026.08.23`, `V2026.08.24`, `V2026.08.25`, `V2026.08.26`, `V2026.08.27`, `V2026.08.28`, `V2026.08.29`, `V2026.08.30`, `V2026.08.31`, `V2026.09.01`, `V2026.09.02`, `V2026.09.03`, `V2026.09.04`, `V2026.09.05`, `V2026.09.06`, `V2026.09.07`, `V2026.09.08`, `V2026.09.09`, `V2026.09.10`, `V2026.09.11`, `V2026.09.12`, `V2026.09.13`, `V2026.09.14`, `V2026.09.15`, `V2026.09.16`, `V2026.09.17`.

**What the app gains.** The partner API with per-token scopes. The carrier
dispatch board. The escalation dashboard. The reordering report. A contact
extract for the reporting role that the reporting role cannot actually read.

**How traffic changes.** The most recent defects start here:

- The **dispatch board** reads a third of the shipments table and sorts it to
  return fifty rows because the index direction does not match the order by.
- The **escalation dashboard** calls a function once per ticket rather than once
  per matching ticket because its cost is understated.
- The **reordering report** silently drops the 800 products it exists to find.
- The **partner API** answers reads for tokens carrying no scopes at all.

**Traffic index.** 100. This is the present day.

---

## What still needs building

The schema half is done. The other two halves are not, and this repo does not
ship either of them. The following describes what an implementation needs, so
that it does not have to derive the requirements from the migrations.

**An application.** One codebase with a phase gate, reaching the eleven schemas
beyond `storefront` that phases 3 onward introduce. The per-phase capability
lists above are the specification.

**A workload generator.** One profile per phase, driven by the mix and traffic
index above. It does not need to be an HTTP application. What reaches the
database is query shapes at a rate, and that is all a monitoring tool sees.

**A stepper.** A thin script taking a phase number and doing three things:
apply that phase's migrations through Flyway `target`, set the app's phase gate,
and switch the traffic profile. It also needs to support scripted events that
are not migrations, of which phase 15's dead cron is the first.

## The part that does not come free

Stepping through the phases gives real schema history and real traffic from the
start of each phase. It does not give fourteen years of metric depth because
the metrics begin only when the traffic does.

Backfilling that depth is a separate effort against the observability system
being used, and is not required for the phases to be useful.
