#!/usr/bin/env python3
"""Render GROUND-TRUTH.md from ground-truth.json.

The JSON is the source of truth. This script exists so the readable document
and the machine-readable one cannot drift apart: edit the JSON, rerun this.

    ./scripts/render-ground-truth.py
"""

import collections
import json
import pathlib
import textwrap

ROOT = pathlib.Path(__file__).resolve().parent.parent
DATA = json.loads((ROOT / "ground-truth.json").read_text())
PREAMBLE = (ROOT / "scripts" / "ground-truth-preamble.md").read_text().rstrip()

CLASS_ORDER = ["structure", "behaviour", "operations", "data", "procedure"]

CLASS_HEADING = {
    "structure": "Structure",
    "behaviour": "Behaviour",
    "operations": "Operations",
    "data": "Data",
    "procedure": "Stored procedures",
}

CLASS_BLURB = {
    "structure": (
        "Defects you can see by reading the schema, if you read the right catalogue. "
        "Several of these are invisible to information_schema and to pg_dump."
    ),
    "behaviour": (
        "Defects that only appear when something runs. The schema looks correct and "
        "the database does the wrong thing."
    ),
    "operations": (
        "Defects in how the database is configured and maintained rather than in what "
        "it stores. Nothing here is a constraint violation and all of it costs money."
    ),
    "data": (
        "Defects in the rows themselves. The schema permits all of it, which is why it "
        "is there."
    ),
    "procedure": (
        "Eighteen stored procedures, each wrong in a way worth naming. Two of them are "
        "security problems, one does not terminate, and one has never executed a line "
        "of the code it was written to add."
    ),
}


def wrap(text: str, width: int = 78) -> str:
    out = []
    for para in text.split("\n\n"):
        out.append("\n".join(textwrap.wrap(para.strip(), width=width)))
    return "\n\n".join(out)


def check_cross_references(defects) -> None:
    """The README promises that every defect id is greppable in the migrations
    and that every migration a defect names exists. Both are easy to break by
    editing the JSON alone, so they are checked here rather than trusted."""
    migrations = ROOT / "migrations"
    names = {p.name for p in migrations.iterdir()}
    sql = "\n".join(p.read_text() for p in sorted(migrations.glob("*.sql")))

    vocabulary = set((DATA.get("kinds") or {}).get("values", {}))

    problems = []
    for d in defects:
        if d.get("kind") not in vocabulary:
            problems.append(f"{d['id']}: kind {d.get('kind')!r} is not in kinds.values")
        if f"DEFECT {d['id']}" not in sql:
            problems.append(f"{d['id']}: no '-- DEFECT {d['id']}' marker in migrations/")
        for key in ("introduced_in", "changed_in"):
            ref = d.get(key)
            if ref and ref not in names:
                problems.append(f"{d['id']}: {key} names migrations/{ref}, which does not exist")

    for s in (DATA.get("clean") or {}).get("schemas", []):
        for ref in s["introduced_in"]:
            if ref not in names:
                problems.append(f"clean:{s['name']}: names migrations/{ref}, which does not exist")

    if problems:
        raise SystemExit("ground-truth.json is inconsistent with migrations/:\n  "
                         + "\n  ".join(problems))


def main() -> None:
    lines = [PREAMBLE, ""]

    defects = DATA["defects"]
    check_cross_references(defects)
    by_class = {c: [d for d in defects if d.get("class") == c] for c in CLASS_ORDER}

    lines += [
        "## What is in here",
        "",
        f"{len(defects)} defects, in five groups.",
        "",
        "| Group | Count | What it means |",
        "| --- | --- | --- |",
    ]
    short = {
        "structure": "Visible in the schema, if you read the right catalogue",
        "behaviour": "Only appears when something runs",
        "operations": "Configuration and maintenance, not correctness",
        "data": "The rows themselves",
        "procedure": "The stored procedures",
    }
    for c in CLASS_ORDER:
        lines.append(f"| {CLASS_HEADING[c]} | {len(by_class[c])} | {short[c]} |")
    lines.append("")

    pg18 = [d for d in defects if d.get("severity") == "pg18-specific"]
    lines += [
        f"{len(pg18)} of them are specific to PostgreSQL 18 and cannot be reproduced on "
        "any earlier version:",
        "",
    ]
    for d in pg18:
        lines.append(f"- `{d['id']}` — {d['title']}")
    lines.append("")

    invisible = [d for d in defects if d.get("invisible_to")]
    lines += [
        f"{len(invisible)} do not appear in information_schema, in pg_dump, or in both. A "
        "tool that reads only those sources cannot find them, however carefully it looks.",
        "",
    ]

    kinds = DATA.get("kinds")
    if kinds:
        counts = collections.Counter(d["kind"] for d in defects)
        lines += ["## The kind vocabulary", "", wrap(kinds["description"]), ""]
        lines += ["| Kind | Count | What a claim of this kind says |", "| --- | --- | --- |"]
        for name, meaning in kinds["values"].items():
            lines.append(f"| `{name}` | {counts[name]} | {meaning} |")
        lines.append("")

    clean = DATA.get("clean")
    if clean:
        lines += ["## Correct on purpose", "", wrap(clean["description"]), ""]
        for s in clean.get("schemas", []):
            intro = ", ".join(f"`migrations/{m}`" for m in s["introduced_in"])
            lines += [f"### `{s['name']}` (schema)", "", wrap(s["why"]), ""]
            lines += [f"Introduced in {intro}.", ""]
            v = s.get("verify") or {}
            if v.get("expect") is not None:
                lines += ["```sql", v["sql"].strip(), f"-- {v['expect']}", "```", ""]

    lines += ["---", ""]

    for c in CLASS_ORDER:
        group = by_class[c]
        if not group:
            continue
        lines += [f"## {CLASS_HEADING[c]}", "", wrap(CLASS_BLURB[c]), ""]

        for d in group:
            lines += [f"### `{d['id']}`", "", f"**{d['title']}**", ""]

            intro = d["introduced_in"]
            if d.get("changed_in"):
                lines.append(
                    f"Introduced in `migrations/{intro}`, "
                    f"changed in `migrations/{d['changed_in']}`."
                )
            else:
                lines.append(f"Introduced in `migrations/{intro}`.")
            lines.append("")

            lines.append(f"Kind: `{d['kind']}`")
            lines.append("")

            lines.append("Objects: " + ", ".join(f"`{o}`" for o in d["objects"]))
            lines.append("")

            lines += [wrap(d["why"]), ""]

            if d.get("invisible_to"):
                lines += [
                    "Invisible to: " + ", ".join(f"`{s}`" for s in d["invisible_to"]),
                    "",
                ]

            det = d.get("detect") or {}
            if det.get("expect") is not None:
                lines += [
                    "```sql",
                    det["sql"].strip(),
                    f"-- {det['expect']}",
                    "```",
                    "",
                ]
            elif det.get("assert"):
                lines += [f"Assertion: {det['assert']}", ""]

    lines += [
        "---",
        "",
        "## Index",
        "",
        "| Id | Kind | Group | Introduced |",
        "| --- | --- | --- | --- |",
    ]
    for d in sorted(defects, key=lambda x: x["id"]):
        intro = d["introduced_in"].split("__")[0]
        lines.append(f"| `{d['id']}` | `{d['kind']}` | {d.get('class', '')} | `{intro}` |")
    lines.append("")

    out = ROOT / "GROUND-TRUTH.md"
    out.write_text("\n".join(lines))
    print(f"wrote {out} ({len(defects)} defects)")


if __name__ == "__main__":
    main()
