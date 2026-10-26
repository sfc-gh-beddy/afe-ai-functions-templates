# Asset Maintenance Notes

A guided build that turns work orders, technician notes and inspection reports already stored in
Snowflake into maintenance intelligence: what fails, how, how often it comes back, and what was
written down before it failed.

## The problem

Asset-intensive operators -- utilities, manufacturing, oil and gas, mining, transport, facilities,
field service -- keep years of maintenance history in a CMMS or EAM. The structured failure code on
each work order is usually the weakest field in the system: chosen at close-out, defaulted, or left
as `OTHER`. The real record is in the free text. That gap costs in three places:

- **Repeat truck rolls.** The same seal on the same pump is replaced three times in two months, and
  nobody sees the pattern because each work order is coded differently, or not at all.
- **Unplanned downtime.** "Slight weep at seal faces, monitor" and "DE brg running warm" were
  written weeks before the trip. Nobody aggregated them.
- **Age-based replacement spend.** Assets are replaced on schedule regardless of condition, because
  condition evidence exists only as unread inspection text.

All three close with text the customer already owns. Nothing new needs to be collected.

## What this plugin builds

```
work orders + technician notes + inspection reports (+ files)
  -> asset-scoped dedup + AI_CLASSIFY triage        exit boilerplate and admin text before the expensive call
  -> taxonomy-constrained AI_COMPLETE extraction    component, failure mode, polarity, severity, verbatim evidence
  -> AI_EMBED recurring-issue clustering            same issue across the fleet; repeat visits per asset
  -> point-in-time precursor features               notes + inspections + sensors + maintenance history, leak-free
  -> SNOWFLAKE.ML.CLASSIFICATION risk scores        combined vs sensor-only vs text-only, at the alert budget
  -> incremental dynamic tables + semantic view + Cortex Agent for CoWork
  -> value readout                                  OpEx (truck rolls, downtime) and CapEx (deferral), customer inputs only
```

The core deliverable is `MAINT_SIGNALS`: one row per component finding, each with a polarity
(`OBSERVED`, `RULED_OUT`, `ACTION_ONLY`, `UNCLEAR`), codes from a pinned customer taxonomy, and a
verbatim evidence span verified against the source note -- so a reliability engineer can trust a
count and audit any single row.

## What it does not build

- **Ingestion** from the CMMS/EAM, historian or condition-monitoring system. Data is assumed landed.
- **Write-back.** Nothing creates work orders, edits failure codes, or changes maintenance plans.
- **Deferral of mandated work.** Regulatory, insurance and safety-case replacements are excluded
  from the CapEx lever and the agent is instructed never to recommend deferring them.

## Getting started

Ask in plain language. The router picks up phrases like:

- "find recurring failures in our work order notes"
- "our failure codes are useless, can we get them from the technician notes"
- "which assets keep getting repeat truck rolls"
- "can the inspection reports tell us what is about to fail"
- "build a case for deferring age-based replacements"

The build runs in gated phases. Each phase states what it will create and what it will cost in
tokens, waits for confirmation, runs, and shows a verification query. State lives in
`maintenance-project.yml` in the working directory, so the build can be stopped and resumed.

**Start in the sandbox.** Phase 1 generates a deterministic synthetic fleet -- pumps, gearboxes and
air compressors -- with work orders, technician notes, inspection reports, daily vibration and
temperature, downtime events, and a quarantined answer key. It plants failure chains with known
precursors, false-alarm controls, recurring issues, and deliberate leakage traps (hindsight edits
and as-found notes written after the failure). Extraction precision/recall and precursor lead time
are measurable on day one, and the harness proves the precursor pipeline did not read the traps.

**If inspections arrive as files**, also run `build-inspection-report-corpus` to render the synthetic
inspections as PDF checklists and degraded scans on a stage, so the parse path is exercised.

## Skills

| Skill | Role |
|---|---|
| `asset-maintenance-notes` | Entry point. Intent detection, phase gating, project state, dbt mapping, diagnosis. |
| `asset-maintenance-system-of-record` | Preflight: function access, models and region, cross-region setting, source mapping, timestamp/leakage verdict, registry, sensors, labels, CMMS code baseline, sensitive content. |
| `asset-maintenance-best-practices` | Correctness rules. Always loaded. |
| `seed-maintenance-sandbox` | Synthetic fleet with labeled answer key, precursor chains, controls and leakage traps (`sql/`). |
| `build-inspection-report-corpus` | Optional. Renders synthetic inspections into PDF and scan files on a stage. |
| `build-failure-taxonomy` | Pinned component / failure-mode taxonomy per asset class, shorthand glossary, gap review. |
| `extract-failure-signals` | Dedup, triage, taxonomy-constrained extraction, evidence verification, quality log (`sql/`). |
| `cluster-recurring-issues` | Embeddings, threshold sweep, connected components, cluster names, repeat visits (`sql/`). |
| `detect-failure-precursors` | Labels, point-in-time features, leakage assertion, time split, ablation models (`sql/`). |
| `evaluate-maintenance-accuracy` | Extraction P/R/F1 (hierarchical, micro/macro), polarity confusion, recurring recovery, leakage canary, lead time at alert budget, cost per 1K records (`sql/`). |
| `operationalize-maintenance-intelligence` | Incremental dynamic tables, tasks, redaction and search, semantic view, Cortex Agent. |
| `maintenance-value-readout` | Value levers from customer inputs only, consumption, POC criteria. |

## Requirements

- A role with Cortex AI function access (`SNOWFLAKE.CORTEX_USER`) -- preflight reports the exact
  missing grant if not.
- A warehouse, and a database and schema the role can create objects in. Phase 7 additionally needs
  `CREATE DYNAMIC TABLE`, `CREATE SEMANTIC VIEW`, `CREATE AGENT`, and for Phase 5
  `CREATE SNOWFLAKE.ML.CLASSIFICATION`.
- GA model availability for extraction in the account's region, or approved cross-region inference.
  Preflight checks `CORTEX_ENABLED_CROSS_REGION` and does not change it.

## A note on data handling

Every AI function call runs inside Snowflake. Technician notes often contain names, phone numbers,
site access details and occasionally incident descriptions; extracted evidence spans inherit that
sensitivity. Preflight reports existing masking and row access policies, and Phase 7 offers an
`AI_REDACT` pass before evidence reaches a broad CoWork audience. Nothing in this plugin writes note
text outside the account; the only local rendering step accepts synthetic `SYN-` records only.
