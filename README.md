# pathological-storefront

Two things in one repository:

1. **A curated list of example databases available for download:** teaching
   samples, benchmarks, real-world dumps, text-to-SQL sets, and collections
   built around known problems.
2. **The Cross River storefront:** a PostgreSQL 18 database built to be wrong on
   purpose, with all 699 defects documented and counted.

The list is useful on its own. The storefront does a different job: it records,
object by object and number by number, what is wrong with a realistic database,
so that a tool that claims to find problems can be scored.

- [Example databases](#example-databases)
- [How the storefront differs](#how-the-storefront-differs)
- [The storefront database](#the-storefront-database)

## Example databases

Checked in October 2026. Sizes are approximate and change between releases.
"Check source" means the licence of the downloadable data was unclear from
its publisher; read the notices in the copy you download. Pull requests adding
or correcting a database are welcome.

### Teaching and sample databases

Small, clean, well-documented models of a business. They are common starting
points for learning databases.

| Database | Engines | What it models | Size | Licence |
|---|---|---|---|---|
| [Northwind](https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/northwind-pubs) | SQL Server; community ports to most engines | Food wholesaler | 13 tables, about 3,300 rows | MIT |
| [pubs](https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/northwind-pubs) | SQL Server | Book publisher | 11 tables, hundreds of rows | MIT |
| [AdventureWorks](https://learn.microsoft.com/en-us/sql/samples/adventureworks-install-configure) (OLTP, LT, DW) | SQL Server, Azure SQL; community PostgreSQL port | Bicycle manufacturer | About 70 tables, about 1 million rows (OLTP) | MIT |
| [WideWorldImporters](https://github.com/microsoft/sql-server-samples/tree/master/samples/databases/wide-world-importers) (OLTP, DW) | SQL Server 2016+, Azure SQL | Wholesale importer | About 31 tables plus history tables, millions of rows | MIT |
| [Contoso Retail DW](https://www.microsoft.com/en-us/download/details.aspx?id=18279) | SQL Server | Multichannel retailer, data warehouse | About 26 tables, over 34 million rows | Microsoft download terms |
| [Sakila](https://dev.mysql.com/doc/sakila/en/) | MySQL; community ports | DVD rental shops | 16 tables, about 47,000 rows | BSD |
| [Pagila](https://github.com/devrimgunduz/pagila) | PostgreSQL | Sakila, rebuilt around PostgreSQL features | About 16 tables, about 120,000 rows (4.x) | PostgreSQL |
| [dvdrental](https://www.postgresqltutorial.com/postgresql-getting-started/postgresql-sample-database/) | PostgreSQL | Another Sakila derivative | 15 tables, about 45,000 rows | Check source |
| [Chinook](https://github.com/lerocha/chinook-database) | PostgreSQL, MySQL, SQL Server, SQLite, Oracle, DB2 | Digital music store | 11 tables, about 15,000 rows | MIT |
| [Employees (test_db)](https://github.com/datacharmer/test_db) | MySQL, MariaDB, PostgreSQL | Staff, departments, salary history | 6 tables, about 3.9 million rows | CC BY-SA 3.0 |
| [classicmodels](https://www.mysqltutorial.org/getting-started-with-mysql/mysql-sample-database/) | MySQL | Scale-model retailer | 8 tables, about 3,900 rows | Check source |
| [world](https://dev.mysql.com/doc/world-setup/en/) | MySQL | Countries, cities, languages | 3 tables, about 5,300 rows | Check source |
| [Airlines demo](https://postgrespro.com/community/demodb) | PostgreSQL | Flights, bookings, boarding passes | 9 tables, 1.3 to 5.4 GB editions | MIT |
| [postgres_air](https://github.com/hettie-d/postgres_air) | PostgreSQL | Air travel, built for query-tuning teaching | About 9 tables, about 1.4 GB dump | BSD-3-Clause |
| [Lahman Baseball](https://sabr.org/lahman-database/) | SQL, Access, CSV; loads into most engines | Baseball statistics | About 27 tables | CC BY-SA |
| [Mondial](https://www.dbis.informatik.uni-goettingen.de/Mondial/) | Oracle, PostgreSQL, SQL Server, MySQL | World geography | About 40 tables | CC BY 3.0 |
| [SportsDB](https://sportsdb.org/) | PostgreSQL, MySQL, SQL Server | Multi-sport results | Over 100 tables, about 80,000 rows | Check source |
| [Dell DVD Store](https://linux.dell.com/dvdstore/) | PostgreSQL, MySQL, SQL Server, Oracle | Online DVD shop, with a load driver | 8 tables, generated to any size | Check source |

### Benchmarks

Generated data plus a fixed workload for measuring speed. The data is
deliberately uniform or skewed, but not deliberately wrong.

| Benchmark | What it measures | Data | Licence |
|---|---|---|---|
| [TPC-H](https://www.tpc.org/tpch/) | 22 decision-support queries | Synthetic, 1 GB to 100 TB | TPC terms |
| [TPC-DS](https://www.tpc.org/tpcds/) | 99 retail analytics query templates | Synthetic, scaled | TPC terms |
| [TPC-C](https://www.tpc.org/tpcc/) | Order-entry transactions under concurrency | Synthetic, scaled by warehouse | TPC terms |
| [TPC-E](https://www.tpc.org/tpce/) | Brokerage transactions | Synthetic, scaled by customer | TPC terms |
| [Star Schema Benchmark](https://www.cs.umb.edu/~poneil/StarSchemaB.PDF) | 13 star-join queries | Synthetic, from TPC-H | Depends on implementation |
| [Join Order Benchmark](https://github.com/gregrahn/join-order-benchmark) | Join ordering and cardinality estimation | Real IMDb snapshot from 2013, 21 tables, about 74 million rows | Queries open; IMDb data non-commercial |
| [DSB](https://github.com/microsoft/dsb) | TPC-DS with correlated, skewed data and shifting workloads | Synthetic | MIT, TPC notices apply |
| [CH-benCHmark](https://db.in.tum.de/research/projects/CHbenCHmark/index.shtml?lang=en) | Transactions and analytics on the same tables at once | Synthetic | Depends on implementation |
| [pgbench](https://www.postgresql.org/docs/current/pgbench.html) | PostgreSQL transaction throughput | Synthetic, 4 tables | PostgreSQL |
| [sysbench](https://github.com/akopytov/sysbench) | Scripted OLTP load, plus CPU, memory and disk tests | Synthetic | GPL-2.0 |
| [HammerDB](https://www.hammerdb.com/) | TPC-C-like and TPC-H-like workloads | Synthetic | GPL-3.0 |
| [YCSB](https://github.com/brianfrankcooper/YCSB) | Key-value read, write and scan mixes | Synthetic | Apache-2.0 |
| [LDBC SNB](https://ldbcouncil.org/benchmarks/snb/) | Social-network graph queries and updates | Synthetic | CC BY 4.0 spec, Apache-2.0 code |

### Real-world data

Real distributions and real messiness, but no workload and no list of what is
wrong. You bring the questions.

| Dataset | What it holds | Size | Licence |
|---|---|---|---|
| [Stack Exchange data dump](https://archive.org/details/stackexchange) | Posts, users, comments, votes | Varies by site and snapshot | CC BY-SA 4.0 |
| [Stack Overflow for SQL Server](https://www.brentozar.com/archive/2015/10/how-to-download-the-stack-overflow-database-via-bittorrent/) | The same data, ready to attach | 10 GB to about 200 GB | CC BY-SA 4.0 |
| [MusicBrainz](https://musicbrainz.org/doc/MusicBrainz_Database/Download) | Artists, releases, recordings, credits | Tens of millions of rows, updated twice weekly | CC0 core, CC BY-NC-SA supplementary |
| [OpenStreetMap](https://planet.openstreetmap.org/) | The world's map | About 88 GB compressed | ODbL |
| [IMDb datasets](https://developer.imdb.com/non-commercial-datasets/) | Titles, people, ratings | Seven daily files | Non-commercial terms |

### Text-to-SQL and AI agent benchmarks

Databases paired with questions and the SQL that answers them. The answer key
concerns queries, not the database.

| Benchmark | Databases | Engines | Notes | Licence |
|---|---|---|---|---|
| [Spider](https://yale-lily.github.io/spider) | 200 | SQLite | Small curated schemas | CC BY-SA 4.0 |
| [Spider 2.0](https://github.com/xlang-ai/Spider2) | About 150 to 210, by setting | BigQuery, Snowflake, SQLite, DuckDB | Enterprise-scale; notes that many tables lack declared foreign keys | MIT |
| [BIRD](https://bird-bench.github.io/) | 95 | SQLite, about 33 GB | Dirty values on purpose; keys were added by hand | CC BY-SA 4.0 |
| [LiveSQLBench](https://github.com/bird-bench/livesqlbench) | 18 to 22 per release | PostgreSQL | The full release adds nulls, duplicates and noisy schemas | CC BY-SA 4.0 |
| [BIRD-Interact](https://github.com/bird-bench/BIRD-Interact) | Built on LiveSQLBench | PostgreSQL | Interactive tasks with a simulated user | CC BY-SA 4.0 |
| [KaggleDBQA](https://github.com/Chia-Hsuan-Lee/KaggleDBQA) | 8 | SQLite | Real Kaggle databases, some with no key metadata | Mixed, per source |
| [WikiSQL](https://github.com/salesforce/WikiSQL) | 24,241 single tables | SQLite | One table per question | BSD-3-Clause |
| [EHRSQL](https://github.com/glee4810/EHRSQL) | 2 | SQLite | Clinical records, shuffled | CC BY 4.0 |
| [BEAVER](https://github.com/peterbaile/beaver) | 6 | MySQL, Oracle | Real enterprise warehouses; labels the join keys each query uses | MIT |
| [ScienceBenchmark](https://github.com/ckosten/sciencebenchmark_dataset) | 3 | PostgreSQL | Scientific databases | Check source |
| [Archer](https://sig4kg.github.io/archer-bench/) | 20 | Not stated | Arithmetic and commonsense reasoning | CC BY 4.0 |

### Databases and fixtures built around known problems

These are the closest relatives of the storefront. Each covers one kind of
problem well.

| Project | What it contains | A runnable database? | An answer key? |
|---|---|---|---|
| [BIRD-Critic](https://github.com/bird-bench/BIRD-CRITIC-1) | Real user SQL bugs, each with a fix and tests | Yes: PostgreSQL, MySQL, SQL Server, Oracle | Per task, on request |
| [DBPA](https://github.com/hjhhsy120/DBPA) | Nine injected performance problems: missing indexes, lock waits, vacuum and more | Reproduction scripts | Per experiment |
| [SchemaAnalyst](https://github.com/schemaanalyst/schemaanalyst) | Constraint mutations, such as a dropped NOT NULL | PostgreSQL, SQLite, HSQLDB | Per mutation |
| [sqlcheck](https://github.com/jarulraj/sqlcheck) | A catalogue of SQL anti-patterns with examples | No, SQL text | Unit tests |
| [SQLFluff](https://github.com/sqlfluff/sqlfluff/blob/main/test/fixtures/rules/std_rule_cases/README.md) | Rule fixtures for its SQL linter | No, SQL text | Per rule |
| [Squawk](https://github.com/sbdchd/squawk) | Risky PostgreSQL migration patterns | No, SQL text | Snapshot tests |
| [pglinter](https://github.com/pmpetit/pglinter) | A PostgreSQL extension that checks schema rules | Its own tests | Not as a separate list |
| [DbDeo](https://github.com/tushartushar/dbdeo) and [study data](https://github.com/tushartushar/dbSmellsData) | Schema smells mined from 2,925 real systems | No | Detector output, not hand-checked labels |

## How the storefront differs

Everything above answers one of three questions: How fast is this engine? Can
this model turn a question into SQL? Did this tool flag this one pattern?

None answers the question a schema advisor, a database linter or an AI agent
working on a real database must answer: **of everything wrong with this
database, how much did the tool find, and how much did it invent?**
Answering that requires a realistic database and a complete list of its
problems.

| | Teaching samples | Benchmarks | Real-world data | Text-to-SQL sets | Problem fixtures | The storefront |
|---|---|---|---|---|---|---|
| Runnable database | Yes | Yes | Yes, after import | Yes | Some | Yes |
| Realistic application across many schemas | A few | No | Yes | Some | No | Yes: 12 schemas, 685 tables |
| Complete list of what is wrong with the database | No | No | No | No | One slice each | Yes: 699 defects |
| Exact expected value per defect, with the query that measures it | No | No | No | No | Per task or experiment | Yes |
| Objects that are correct on purpose, so false positives count | No | No | No | No | Some rule fixtures | Yes: 16 tables |
| Design, behaviour and operational defects together | No | No | No | No | No | Yes: 39 kinds |
| A reason behind every defect | No | No | No | No | No | Yes: a 14-year company history |
| Same rows on every build | Yes | With a fixed seed | Pinned snapshot | Yes | Varies | Yes: 2,705,802 every time |

Three things follow from that.

**A score, not an impression.** Every defect has an id, a kind, the objects it
sits on, and a query that returns its exact count. A tool's report is matched
against that list by `scripts/score.py`, and the result is a number of defects
found, missed, and claimed against something correct.

**False positives cost something.** A tool that reports everything finds
everything. The `conformance` schema holds every constraint and nearly every
data type used correctly, and any finding against it counts against the tool.

**The defects look like real ones.** They were not sprinkled at random, which
is easy to spot and easy to game. Each one is what a sensible decision on the
day became after fourteen years nobody revisited it, and the migrations replay
those fourteen years in order, phase by phase.

### When to use something else

- **Measuring speed:** use TPC-H, TPC-DS, pgbench or HammerDB. The storefront
  holds 2.7 million rows, which is too small to say anything about throughput.
- **Text-to-SQL:** use BIRD, Spider 2.0 or LiveSQLBench. The storefront has no
  question-and-answer set.
- **Fixing SQL rather than finding problems:** use BIRD-Critic, which checks
  each repair with tests.
- **Real data distributions:** use the Stack Overflow dump or MusicBrainz. The
  storefront's data is generated, deterministically, so its counts can be exact.
- **MySQL or SQL Server:** the storefront is PostgreSQL 18 only. Four of its
  defects cannot exist on any earlier version.

The storefront's defects were written by people who knew the answers. Real
damage is messier. The storefront tells you what a tool misses on problems
known to be present, not everything a real database could contain.

## The storefront database

A Postgres database built to be wrong on purpose, with its defects documented.

It is an ordinary e-commerce schema with customers, orders, products and
inventory. It carries a catalogue of real defects: relationships that are not
declared, identifiers that are only unique per store, configuration tables full
of blanks, tables that grow and are never cleaned, stale statistics, and
queries that cannot use the index beside them.

Every defect is deliberate and written down in `GROUND-TRUTH.md`, with numbers.

### Why

Tools that read a database, including linters, advisors, schema explainers and
AI coding agents, are usually judged by whether their output looks plausible.
That is not the same as correctness. Checking correctness requires a database
where someone already knows the answer.

That is the purpose of this database. Point a tool at it, run its output
through the scorer, and get a number rather than an impression.

### Running it

You need Docker to start the database. Scoring a tool against it also needs
Python.

```
docker compose up
```

That starts PostgreSQL 18, applies 134 Flyway migrations in order, and leaves a
populated database behind. It takes three to seven minutes, depending on the
machine. Connect with:

```
psql -h localhost -p 55432 -U crossriver -d crossriver     # password: crossriver
```

Set `PGPORT_HOST` if 55432 is taken. To start over:

```
docker compose down -v && docker compose up
```

### Checking it

```
docker compose up -d db
./scripts/verify-ground-truth.sh
```

This runs the detection query for every defect and reports which are present
and which numbers disagree. A correctly built fixture reports 699 of 699
matching and nothing mismatched.

### Building it somewhere else

To build the same fixture into a database that is not the compose one:

```
PGHOST=... PGPORT=5432 PGUSER=... PGPASSWORD=... PGDATABASE=... ./scripts/deploy.sh
```

It checks that the target is PostgreSQL 18, is empty, and uses the en_US.utf8
collation, applies the migrations with Flyway, then runs the verification above
against it. The migrations create roles, and roles belong to the cluster rather
than to a database, so the target cluster must not already hold a copy of this
fixture. Set `DOCKER_PGHOST` when the Flyway container reaches the target under
a different name than your shell does.

### Scoring a tool

Point your tool at the database, save its output as JSON, and score it:

```
./scripts/score.py report.json
your-tool --json | ./scripts/score.py -
```

Python 3.9 or newer, with no packages to install. It prints one line per
defect found, missed, or claimed against something correct on purpose, and
exits non-zero if anything was missed. `--json` gives the same result in
machine-readable form.

Your JSON can have any shape. The scorer walks the whole document and treats
every object carrying a `kind` field as one claim, so the nesting and the name
of the list are yours to choose. A claim needs two things:

```json
{ "kind": "unenforced-constraint",
  "objects": ["payments.ledger_entries.ledger_entries_single_sided"] }
```

`kind` is one of the 39 kinds listed in `GROUND-TRUTH.md`, and `objects` names
what the claim concerns, as `schema.table` or `schema.table.column`. Object
names can also be given as `schema` and `table` fields, or in any of the other
field names the scorer understands.

A claim matches a defect when the kind is the same and the objects overlap,
with one asymmetry: a claim naming only a table matches a defect on any column
of that table, but a claim naming a column must name the same column. Reporting
`ops.event_log` finds the defect recorded against `ops.event_log.entity_id`;
reporting `ops.event_log.actor` does not.

The scoring is not hidden. It reads `ground-truth.json` directly, and
`scripts/score.py` is 265 lines you can read in a sitting.

### What is in it

685 tables across 12 schemas, 2,705,802 rows, and 699 catalogued defects. Flyway's
own history table in `public` is not counted in either figure. That row count is
exact and the same on every build: the seed migrations derive every value
arithmetically and nothing in the load is random.

Close to every data type PostgreSQL 18 ships is used somewhere, and every kind
of constraint appears at least once used correctly, so a tool can be checked
for false positives as well as misses. Those correct examples live in the
`conformance` schema, which is labelled as not part of the story and is listed
under `clean` in `ground-truth.json`. Anything a tool reports against those
16 tables is a false positive, and a score that ignores false positives rewards
reporting everything.

Four defects are specific to PostgreSQL 18 and cannot be reproduced on any
earlier version:

- a `CHECK` constraint that is `NOT ENFORCED`, so it is listed everywhere and
  checks nothing
- a second one, over 17 rows that already violate it, added without error
  because nothing was checked
- a `NOT NULL` that is `NOT VALID` over 9,460 real nulls, which `psql` and
  `information_schema` both report as a plain `NOT NULL`
- a generated column that is `VIRTUAL` because the `STORED` keyword was left
  off, which was a syntax error before 18 and is now a silent difference

None of those appear in `pg_dump` or in `information_schema`. A tool that reads
only those sources cannot find them.

### The history

The defects are not scattered at random. Random defects are easy to spot and
easy to game. These belong to a company.

`ROADMAP.md` is the history of Cross River Trading Co., a hardware shop that
opened in 1974, put a web store up in 2012, and spent fourteen years growing
into something much larger. The migrations follow that history in date order:
the 2012 schema uses 2012 conventions, the 2022 acquisition brings in a schema
that does not match anything around it, and the rewrite that started in 2023
added its new columns and never removed the old ones.

Read the two side by side and every defect has a reason. Each one is what you
get when a decision that was correct on the day it was made is never revisited.

`PHASES.md` is the same history as something to step through rather than read.
It splits the migrations into seventeen phases from 2012 to 2026, and for each
one says what the application could do at the time and what its traffic looked
like. It is there for anyone who wants a database that appears to have been in
production for fourteen years rather than one built this morning.

### Layout

```
migrations/          Flyway migrations, in the order the history says they happened
ROADMAP.md           The Cross River Trading Co. story
PHASES.md            The same history, as seventeen steppable phases
GROUND-TRUTH.md      Every defect, readable
ground-truth.json    Every defect, machine-readable, with a detection query each
scripts/             Verification, scoring and rendering
```

Every defect is also marked in the SQL. Searching for its id finds the statement
that created it:

```
grep -rn "DEFECT not-null-not-valid-over-real-nulls" migrations/
```

### Using it in your own project

If you maintain a tool that reads Postgres, check this into your test suite,
pin a commit, and score against `ground-truth.json`. The answer key is public
domain, so copying it needs no notice; the migrations and scripts are MIT,
which asks you to keep the licence notice with them. A link back is welcome.

### Status

Early but usable. The migrations, the ground truth, the verification script and
the scorer all work. The fixture ships at one size, because every count in the
ground truth is exact. Planned next: a larger fixture with its own measured
ground truth, and a query workload that exercises the defects.

The issue tracker is closed. Pull requests are welcome, particularly "here is a
defect class you are missing" with the migration and the
`ground-truth.json` entry that catalogues it.

## Licence

The migrations, scripts and everything else that is code: MIT, in `LICENSE`.

The answer key, `ground-truth.json` and `GROUND-TRUTH.md`: dedicated to the
public domain under CC0 1.0, in `LICENSE-DATA`. Every row in the database is
generated by the migrations, so it is covered by the MIT licence with them.
