#!/usr/bin/env python3
"""Score a database-analysis tool's JSON output against ground-truth.json.

The point of a written-down answer key is that nobody has to read the tool's
output and the key side by side and decide whether they agree. This does the
matching: every defect in the key is found or missed, and everything the tool
said that the key does not cover is reported separately.

A claim matches a defect when the kind is the same and the objects overlap. A
claim that names a column must name the same column; a claim that names only a
table matches any defect on that table, because a tool reporting
`ops.event_log` for a defect recorded against `ops.event_log.entity_id` has
found the same thing. Without that asymmetry a claim about some unrelated
column of the right table scores as a hit.

Object names are read from whichever fields a claim happens to carry, because
the shape of a tool's JSON is its own business and will change. The kind
vocabulary and the object names are the contract, and both are published in
ground-truth.json.

A score that counts only misses rewards a tool for reporting everything, so
claims landing on the `clean` objects are counted as false positives.

Usage:
    ./scripts/score.py report.json
    your-tool --json | ./scripts/score.py -
    ./scripts/score.py report.json --json

Needs Python 3.9 or newer and nothing else.

Exit 0 = every defect found and no false positives. 1 = something missed or a
false positive. 2 = could not run.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

GROUND_TRUTH = pathlib.Path(__file__).resolve().parent.parent / "ground-truth.json"

# Fields a claim might name its objects in. Extra names here are harmless; a
# missing one shows up as a claim that matches nothing, not as a silent pass.
OBJECT_FIELDS = (
    "objects",
    "object",
    "table",
    "tables",
    "column",
    "columns",
    "relation",
    "target",
    "from",
    "to",
    "left",
    "right",
    "name",
    "qualified_name",
    "qualifiedName",
)


def normalise(name: str) -> str:
    """Strip quoting and case. Depth is kept: a column stays a column."""
    return ".".join(p.strip('"') for p in str(name).split(".") if p).lower()


def table_of(name: str) -> str:
    """Reduce schema.table.column to schema.table."""
    return ".".join(normalise(name).split(".")[:2])


def schema_of(name: str) -> str:
    return normalise(name).split(".")[0]


def is_table_level(name: str) -> bool:
    return len(name.split(".")) <= 2


def overlaps(defect_objects, claimed) -> bool:
    if defect_objects & claimed:
        return True
    tables = {table_of(o) for o in defect_objects}
    return bool(tables & {c for c in claimed if is_table_level(c)})


def claim_objects(claim: dict) -> set:
    found = set()
    for field in OBJECT_FIELDS:
        value = claim.get(field)
        if isinstance(value, str):
            found.add(normalise(value))
        elif isinstance(value, list):
            found.update(normalise(v) for v in value if isinstance(v, str))
        elif isinstance(value, dict):
            found.update(claim_objects(value))
    schema, table = claim.get("schema"), claim.get("table")
    if isinstance(schema, str) and isinstance(table, str):
        found.add(normalise(f"{schema}.{table}"))
        column = claim.get("column")
        if isinstance(column, str):
            found.add(normalise(f"{schema}.{table}.{column}"))
    return {f for f in found if f}


def harvest_claims(blob) -> list:
    """Every dict anywhere in the report that carries a `kind`.

    Tools nest their output differently and rename the list it lives under, so
    the whole document is walked rather than any one path into it.
    """
    out = []
    if isinstance(blob, dict):
        if isinstance(blob.get("kind"), str):
            out.append(blob)
        for value in blob.values():
            out.extend(harvest_claims(value))
    elif isinstance(blob, list):
        for item in blob:
            out.extend(harvest_claims(item))
    return out


def score(defects: list, claims: list, clean_schemas: set) -> dict:
    wanted = [
        (d["kind"].lower(), {normalise(o) for o in d["objects"]})
        for d in defects
    ]
    claimed = [(c["kind"].lower(), claim_objects(c)) for c in claims]

    # Two defects can sit on the same table under the same kind, so a claim is
    # assigned to the defect it fits best rather than to whichever comes first
    # in the file. Without this a defect recorded against one view swallows the
    # claim belonging to a defect recorded against three, and the second is
    # reported missed when the tool did in fact find it.
    pairs = []
    for di, (want_kind, want_objects) in enumerate(wanted):
        for ci, (claim_kind, objects) in enumerate(claimed):
            if claim_kind != want_kind or not overlaps(want_objects, objects):
                continue
            exact = len(want_objects & objects)
            pairs.append(((exact, -len(want_objects ^ objects)), di, ci))
    pairs.sort(key=lambda p: (p[0][0], p[0][1]), reverse=True)

    hits = {}
    taken = set()
    for _, di, ci in pairs:
        if di in hits or ci in taken:
            continue
        hits[di] = [ci]
        taken.add(ci)

    # A tool that says the same thing three times has still found it once. Spare
    # claims are attached only after every defect has had its chance at one.
    for _, di, ci in pairs:
        if di in hits and ci not in taken:
            hits[di].append(ci)
            taken.add(ci)

    unmatched = [i for i in range(len(claims)) if i not in taken]

    found, missed = [], []
    for di, defect in enumerate(defects):
        if di in hits:
            found.append(
                {"id": defect["id"], "kind": defect["kind"], "claims": len(hits[di])}
            )
        else:
            missed.append(
                {
                    "id": defect["id"],
                    "kind": defect["kind"],
                    "objects": sorted(wanted[di][1]),
                    # A tool that reported the right kind on the wrong object is
                    # a different failure from one that never looked.
                    "claims_of_this_kind_elsewhere": sum(
                        1 for i in unmatched if claimed[i][0] == wanted[di][0]
                    ),
                }
            )

    false_positives, uncatalogued = [], []
    for i in unmatched:
        objects = sorted(claim_objects(claims[i]))
        entry = {"kind": claims[i]["kind"], "objects": objects}
        if objects and all(schema_of(o) in clean_schemas for o in objects):
            false_positives.append(entry)
        else:
            uncatalogued.append(entry)

    return {
        "found": found,
        "missed": missed,
        "false_positives": false_positives,
        "uncatalogued_claims": uncatalogued,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Score a tool's JSON output against ground-truth.json.",
        epilog="Exit 0 when every defect was found and nothing was claimed against "
               "the objects that are correct on purpose.",
    )
    parser.add_argument("report", help="the tool's JSON output, or - for stdin")
    parser.add_argument("--json", action="store_true", help="machine-readable result")
    args = parser.parse_args()

    if not GROUND_TRUTH.exists():
        print(f"no ground truth at {GROUND_TRUTH}", file=sys.stderr)
        return 2

    text = sys.stdin.read() if args.report == "-" else pathlib.Path(args.report).read_text()
    try:
        blob = json.loads(text)
    except json.JSONDecodeError as exc:
        print(f"report is not JSON: {exc}", file=sys.stderr)
        return 2

    key = json.loads(GROUND_TRUTH.read_text())
    defects = key["defects"]
    vocabulary = set((key.get("kinds") or {}).get("values", {}))
    clean_schemas = {s["name"].lower() for s in (key.get("clean") or {}).get("schemas", [])}

    claims = harvest_claims(blob)
    if not claims:
        print("no claims found in the report. Each finding needs a `kind` field naming "
              "one of the kinds in ground-truth.json.", file=sys.stderr)
        return 2

    result = score(defects, claims, clean_schemas)
    result["total_defects"] = len(defects)
    result["total_claims"] = len(claims)
    result["unknown_kinds"] = sorted(
        {c["kind"] for c in claims if c["kind"].lower() not in vocabulary}
    )

    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"{len(result['found'])}/{len(defects)} defects found from "
              f"{len(claims)} claims, {len(result['false_positives'])} false positives\n")
        for f in result["found"]:
            print(f"found  {f['id']}")
        for m in result["missed"]:
            extra = m["claims_of_this_kind_elsewhere"]
            note = f"  ({extra} {m['kind']} claims on other objects)" if extra else ""
            print(f"MISSED {m['id']}  {' '.join(m['objects'])}{note}")
        for fp in result["false_positives"]:
            print(f"FALSE  {fp['kind']}  {' '.join(fp['objects'])}")
        for u in result["uncatalogued_claims"]:
            print(f"extra  {u['kind']}  {' '.join(u['objects'])}")
        if result["unknown_kinds"]:
            print("\nkinds not in the published vocabulary, which can never match:")
            for k in result["unknown_kinds"]:
                print(f"  {k}")

    return 1 if result["missed"] or result["false_positives"] else 0


if __name__ == "__main__":
    sys.exit(main())
