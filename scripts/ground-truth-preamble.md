<!--
  Generated file. Do not edit by hand.
  Edit ground-truth.json and run ./scripts/render-ground-truth.py
-->

# Ground truth

This document lists every defect in the Cross River Trading Co. database, describes each defect, identifies the migration that introduced it, and gives the query that proves it is present.

This file is generated from `ground-truth.json`, which is the machine-readable
version of the same list. A tool's output can be scored against the JSON without
anyone reading this document: compare the defect ids it reports with the ids
listed there.

`./scripts/verify-ground-truth.sh` runs every detection query against a running
fixture and reports which defects are present and which numbers disagree. On a
correctly built database, it reports 699 of 699 matching and no mismatches.
Every defect has a single-value assertion, so scoring requires no human
judgement.

## How to read a defect

Each entry identifies the migration that introduced it. The migrations are in
date order, and the reasoning behind them is documented in `ROADMAP.md`, so the
history and schema can be followed together. Each defect resulted from a
particular decision that was not revisited.

Every defect is also marked in the SQL itself. Searching the migrations for its
id finds the exact statement that created it, along with a comment explaining
the reasoning at the time.

```
grep -rn "DEFECT not-null-not-valid-over-real-nulls" migrations/
```

## A note on the numbers

The counts in this document are exact and reproducible. Each seed migration
derives its values arithmetically from `generate_series`, so two builds of this
fixture produce identical databases and the same numbers every time. The load
uses no randomness.
