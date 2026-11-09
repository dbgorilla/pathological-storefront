#!/usr/bin/env bash
#
# Builds the fixture into an existing, empty PostgreSQL 18 database and then
# verifies it. Same migrations and same ground truth as the local compose
# fixture; only the target changes.
#
# Usage:
#   PGHOST=... PGPORT=5432 PGUSER=... PGPASSWORD=... PGDATABASE=... ./scripts/deploy.sh
#
# VERIFY_ENV passes straight through to verify-ground-truth.sh. On managed
# PostgreSQL set VERIFY_ENV=rds, so the two defects that need a real superuser
# report as n/a rather than as failures.
#
# The target must be PostgreSQL 18, must be empty, and PGUSER must own it.
# Several defects are recorded against roles (depot_staff, goods_in_writer,
# report_reader and others) that earlier migrations create, so the role must be
# able to CREATE ROLE. Nothing here drops anything.
#
# Roles in PostgreSQL belong to the cluster, not to a database, so the target
# cluster must not already hold those roles. In practice that means one fixture
# per cluster: a second database alongside an existing fixture fails on
# V2025.01.27 with 'role "reporting_ro" already exists'.
#
# Exit code is 0 when Flyway applies cleanly and all 699 defects match.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PGHOST="${PGHOST:?PGHOST is required}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:?PGUSER is required}"
PGDATABASE="${PGDATABASE:?PGDATABASE is required}"
PGPASSWORD="${PGPASSWORD:?PGPASSWORD is required}"
export PGPASSWORD

psql_t() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAX -c "$1"; }

server_version="$(psql_t 'SHOW server_version_num')" || {
    echo "Cannot reach $PGUSER@$PGHOST:$PGPORT/$PGDATABASE." >&2
    exit 2
}
if [ "$server_version" -lt 180000 ]; then
    echo "Target is server_version_num $server_version. This fixture needs PostgreSQL 18." >&2
    echo "Several defects depend on 18-only syntax, including NOT NULL ... NOT VALID." >&2
    exit 2
fi

collate="$(psql_t "SELECT datcollate FROM pg_database WHERE datname = current_database()")"
if [ "$collate" != "en_US.utf8" ] && [ "$collate" != "en_US.UTF-8" ]; then
    echo "Target database collation is '$collate'. This fixture expects en_US.utf8." >&2
    echo "One defect turns on a column collated C differing from the database default," >&2
    echo "so on a C or ICU cluster it measures zero and verification fails." >&2
    exit 2
fi

existing="$(psql_t "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE c.relkind IN ('r','p') AND n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_%'")"
if [ "$existing" != "0" ]; then
    echo "Target already holds $existing tables. Deploy into an empty database." >&2
    exit 2
fi

# Flyway runs in a container, so it may need a different name for the same host
# than psql does out here. Set DOCKER_PGHOST when they differ; on Docker Desktop
# a database on the host machine is host.docker.internal to the container.
DOCKER_PGHOST="${DOCKER_PGHOST:-$PGHOST}"

echo "Applying migrations to $PGUSER@$PGHOST:$PGPORT/$PGDATABASE"
# Flyway 11 ships Temurin 21, which SIGSEGVs in this container under class-data
# sharing. Same JAVA_ARGS the compose fixture uses, for the same reason.
# -defaultSchema=public for the same reason as in docker-compose.yml: one defect
# moves the database's default search_path, and Flyway follows it.
docker run --rm \
    -e JAVA_ARGS="-Xshare:off -XX:TieredStopAtLevel=1" \
    -v "$ROOT/migrations:/flyway/sql:ro" \
    flyway/flyway:11 \
    -url="jdbc:postgresql://$DOCKER_PGHOST:$PGPORT/$PGDATABASE" \
    -user="$PGUSER" \
    -password="$PGPASSWORD" \
    -connectRetries=10 \
    -baselineOnMigrate=false \
    -locations=filesystem:/flyway/sql \
    -defaultSchema=public \
    migrate || exit 1

echo
PGHOST="$PGHOST" PGPORT_HOST="$PGPORT" PGUSER="$PGUSER" \
PGDATABASE="$PGDATABASE" PGPASSWORD="$PGPASSWORD" \
VERIFY_ENV="${VERIFY_ENV:-}" \
    "$ROOT/scripts/verify-ground-truth.sh"
