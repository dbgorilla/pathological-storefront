#!/usr/bin/env bash
#
# Runs every detection query in ground-truth.json against a running fixture and
# reports which defects are present, absent, or disagree about their numbers.
#
# Usage:
#   ./scripts/verify-ground-truth.sh
#   PGPORT_HOST=55432 ./scripts/verify-ground-truth.sh
#   PGHOST=... PGPORT=5432 PGUSER=... PGPASSWORD=... ./scripts/verify-ground-truth.sh
#   VERIFY_ENV=rds ./scripts/verify-ground-truth.sh
#
# VERIFY_ENV names a file in scripts/env-limits/ listing defects the host cannot
# hold at all — on managed PostgreSQL, the ones whose creation needs a real
# superuser. Those report as n/a and leave the totals, so the count stays a
# count of what this environment can actually be asked for.
#
# Exit code is 0 when every applicable defect matches its recorded value, 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GT="$ROOT/ground-truth.json"

declare -A NA_REASON=()
if [ -n "${VERIFY_ENV:-}" ]; then
    LIMITS="$ROOT/scripts/env-limits/${VERIFY_ENV}.tsv"
    if [ ! -f "$LIMITS" ]; then
        echo "No such environment: $VERIFY_ENV (expected $LIMITS)" >&2
        exit 2
    fi
    while IFS=$'\t' read -r lid lreason; do
        case "$lid" in ''|\#*) continue ;; esac
        NA_REASON["$lid"]="$lreason"
    done < "$LIMITS"
fi

PGHOST="${PGHOST:-localhost}"
# PGPORT is the standard libpq name and the one deploy.sh documents, so it wins.
# PGPORT_HOST stays because the compose fixture publishes on a non-default port.
PGPORT="${PGPORT:-${PGPORT_HOST:-55432}}"
PGUSER="${PGUSER:-crossriver}"
PGDATABASE="${PGDATABASE:-crossriver}"
export PGPASSWORD="${PGPASSWORD:-crossriver}"

if command -v psql >/dev/null 2>&1; then
    run_sql() { psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -tAX -c "$1" 2>&1; }
else
    # No local psql. Use the one inside the running container.
    run_sql() { docker compose -f "$ROOT/docker-compose.yml" exec -T db \
        psql -U "$PGUSER" -d "$PGDATABASE" -tAX -c "$1" 2>&1; }
fi

# Both defect lists are read by python3 through a process substitution. Without
# python3 the substitution yields nothing, every loop body is skipped, and the
# final test passes on a fixture that was never checked. Refuse instead.
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to read $GT. Nothing was checked." >&2
    exit 2
fi

probe="$(run_sql 'SELECT 1')"
if [ "$probe" != "1" ]; then
    echo "Cannot reach the fixture database." >&2
    echo "  $probe" >&2
    echo >&2
    echo "Start it first:  docker compose up -d db" >&2
    exit 2
fi

pass=0
fail=0
skip=0
na=0

while IFS=$'\t' read -r id sql want; do
    if [ -n "${NA_REASON[$id]:-}" ]; then
        printf '  n/a   %s\n          %s\n' "$id" "${NA_REASON[$id]}"
        na=$((na + 1))
        continue
    fi

    if [ "$want" = "null" ]; then
        printf '  SKIP  %s (no scalar assertion)\n' "$id"
        skip=$((skip + 1))
        continue
    fi

    got="$(run_sql "$sql" | tr -d '\r' | head -1 | sed 's/[[:space:]]*$//')"

    if [ "$got" = "$want" ]; then
        printf '  ok    %s\n' "$id"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s\n          expected: %s\n          got:      %s\n' "$id" "$want" "$got"
        fail=$((fail + 1))
    fi
done < <(python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
for d in doc["defects"]:
    det = d.get("detect") or {}
    sql = " ".join((det.get("sql") or "").split())
    exp = det.get("expect", None)
    exp = "null" if exp is None else str(exp)
    print("\t".join([d["id"], sql, exp]))
' "$GT")

total=$((pass + fail + skip))

# A run that read no defects is a run that proved nothing, so it must not pass.
if [ "$total" -eq 0 ]; then
    echo "No defects were read from $GT. Nothing was checked." >&2
    exit 2
fi

echo
if [ "$na" -gt 0 ]; then
    echo "$pass of $total applicable defects present and matching. $fail mismatched, $skip not scalar-checkable, $na not applicable on ${VERIFY_ENV}."
else
    echo "$pass of $total defects present and matching. $fail mismatched, $skip not scalar-checkable."
fi

# The clean list names objects that are correct on purpose. Check they are
# actually there, so a scorer counting false positives is counting against
# something that exists.
clean_fail=0
while IFS=$'\t' read -r name sql want; do
    got="$(run_sql "$sql" | tr -d '\r' | head -1 | sed 's/[[:space:]]*$//')"
    if [ "$got" = "$want" ]; then
        printf '  ok    clean:%s\n' "$name"
    else
        printf '  FAIL  clean:%s\n          expected: %s\n          got:      %s\n' "$name" "$want" "$got"
        clean_fail=$((clean_fail + 1))
    fi
done < <(python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
for s in (doc.get("clean") or {}).get("schemas", []):
    v = s.get("verify") or {}
    if v.get("expect") is None:
        continue
    print("\t".join([s["name"], " ".join(v["sql"].split()), str(v["expect"])]))
' "$GT")

[ "$fail" -eq 0 ] && [ "$clean_fail" -eq 0 ]
