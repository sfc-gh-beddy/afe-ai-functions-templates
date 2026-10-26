---
name: seed-maintenance-sandbox
description: "Generate a deterministic synthetic maintenance corpus with a labeled answer key so failure-mode and component extraction, recurring-issue clustering, and failure-precursor lead time can be built, demonstrated and measured before touching production CMMS data. Creates an asset registry across three asset classes, a reference component and failure-mode taxonomy, work orders with noisy CMMS failure codes, technician notes (corrective, PM action-only, no-fault-found, boilerplate, admin), inspection reports dominated by negated findings, daily vibration and temperature history with gaps, planned and unplanned downtime, planted failure chains with text precursors and sensor drift, false-alarm controls, recurring-issue sequences, and deliberate leakage traps (hindsight edits and as-found notes written after the failure). Answer key quarantined in a separate schema. Phase 1 of the asset-maintenance-notes build."
parent_skill: asset-maintenance-notes
---

# Seed the sandbox

Generate a synthetic maintenance corpus with **ground truth**. This is what makes extraction
precision and recall, cluster quality and precursor lead time measurable on day one, and it lets the
build be demonstrated before anyone grants access to production work orders.

The corpus is built from templates whose labels are known, so every note and inspection has a
correct answer -- including the correct answer "no signals" for boilerplate and admin text. Planted
failure chains have a known failure timestamp and a known first precursor, so lead time is
measurable. Leakage traps are planted on purpose, so the harness can prove the precursor pipeline
does not read them.

## Why not just use the CMMS failure codes as labels

Because they are the problem. Preflight usually finds that a large share of corrective work orders
carry `OTHER`, a default, or a code chosen for speed at close-out. Measuring extraction against them
rewards a model for reproducing a bad label. The sandbox generates a deliberately noisy
`failure_code` column for exactly this reason: the harness reports agreement with it separately from
accuracy against the real key, and the two numbers should disagree.

On production data, a few hundred hand-labeled notes from a maintenance lead are required before
any accuracy claim (see `evaluate-maintenance-accuracy`, section "Production labeling").

## Configure before generating

Ask for these, default sensibly, and write them into `maintenance-project.yml`.

| Parameter | Default | Notes |
|---|---|---|
| `ASSETS_PER_CLASS` | 80 | Three classes (centrifugal pump, gearbox, air compressor) = 240 assets. Ten percent of assets get each special scenario, so at 80 per class there are 24 planted failures, 24 false-alarm controls, 24 recurring-issue assets |
| `HISTORY_DAYS` | 600 | Must exceed the latest event offset (499 days) plus the 50-day precursor lead |
| `ANCHOR_DATE` | a fixed past date, e.g. `2026-06-30` | A fixed anchor keeps the corpus identical across regenerations. Never use `CURRENT_DATE`: stored evaluation results would silently stop matching a regenerated corpus |
| `WOS_PER_ASSET` | 6 | Background work orders per asset: roughly 40% PM, 45% corrective, 15% no-fault-found |
| `INSPECTIONS_PER_ASSET` | 5 | Background inspection reports per asset, all negative findings |

At the defaults the corpus is roughly 1,560 work orders, 2,350 notes, 1,270 inspection reports,
144,000 daily sensor rows and a few hundred downtime events. Extraction over the full sandbox is a
modest token spend; still estimate it at the Phase 3 gate.

**Asset classes must match the taxonomy.** The sandbox ships its own taxonomy in
`SYNTH_TAXONOMY_COMPONENT` and `SYNTH_TAXONOMY_FAILURE_MODE`. Phase 2 (`build-failure-taxonomy`) loads
those as `taxonomy.source: sandbox`. Do not mix the sandbox with a customer taxonomy -- planted labels
use sandbox codes.

## What gets created

Pipeline schema (`{{SCHEMA}}`) -- what the pipeline is allowed to read:

| Object | Purpose |
|---|---|
| `SYNTH_ASSETS` | Registry: class, tag, site, functional location, install date, criticality. `replacement_unit_capex` is deliberately NULL |
| `SYNTH_TAXONOMY_COMPONENT` | Component codes per class with assembly grouping and synonyms |
| `SYNTH_TAXONOMY_FAILURE_MODE` | Failure-mode codes (observed effect) with definitions |
| `SYNTH_WORK_ORDERS` | WO header: type, priority, created/closed/last-modified, noisy `failure_code` |
| `SYNTH_WO_NOTES` | Technician notes with their **own** timestamps |
| `SYNTH_INSPECTION_REPORTS` | Inspection text; mostly negated findings |
| `SYNTH_SENSOR_DAILY` | Daily vibration (mm/s) and bearing/discharge temperature (C), UTC dates, ~3% NULL |
| `SYNTH_DOWNTIME_EVENTS` | Planned (PM) and unplanned (failure) downtime -- the precursor label source |

Eval schema (`{{EVAL_SCHEMA}}`) -- **never** read by the pipeline:

| Object | Purpose |
|---|---|
| `SYNTH_NOTE_TEMPLATES`, `SYNTH_TEMPLATE_LABELS`, `SYNTH_TEMPLATE_CATALOGUE` | Generator inputs with labels |
| `SYNTH_ASSET_SCENARIO` | Which assets are planted, controls, recurring, background |
| `SYNTH_GEN_WORK_ORDERS`, `SYNTH_GEN_TEXT` | Generator staging carrying template ids |
| `ANSWER_KEY_SOURCES` | Every generated source, labeled or not (needed to count false positives) |
| `ANSWER_KEY_SIGNALS` | Per source: component, assembly, failure mode, polarity |
| `ANSWER_KEY_PRECURSORS` | Planted failures with failure time, first text precursor, first sensor drift; controls with anomaly date |
| `ANSWER_KEY_RECURRING` | Recurring-issue groups and their work orders |
| `ANSWER_KEY_LEAKAGE_CANARY` | Records that must never reach a precursor feature for their event |

`sql/01_seed_sandbox.sql` is the template. Substitute every `{{...}}` placeholder, then run it as a
script. `sql/02_verify_seed.sql` holds the gate checks. Do not run either unmodified.

## The answer key is quarantined

- Templates, labels and scenario flags exist only in the eval schema. The pipeline-visible tables are
  created from the staging tables with the label columns projected away; check 6 in the verify
  script asserts no pipeline column name suggests a label.
- No pipeline query reads the eval schema. Only `evaluate-maintenance-accuracy` does.
- Never put the eval schema in a semantic view, an agent tool, a Cortex Search service, or a prompt.
  A `SELECT *` over a database, or a semantic view built by "add all tables", is enough to leak it.
- Grant the eval schema to the harness role only, if roles are separated.

## What the corpus contains, and what each part tests

| Text kind | Example | Correct extraction | Tests |
|---|---|---|---|
| Corrective (`FAILURE`) | "Found mech seal leaking approx 1 L/min at gland" | `MECH_SEAL / EXTERNAL_LEAK / OBSERVED` | basic recall |
| Multi-finding | "Coupling insert disintegrated... NDE brg sounding noisy" | two signals | array schema, multi-label recall |
| Negated in a corrective note | "Checked alignment - within tolerance" | `COUPLING / NONE / RULED_OUT` | polarity inside an otherwise positive note |
| PM action (`ACTION`) | "replaced mech seal per 24 month interval. Old seal in good condition." | `MECH_SEAL / NONE / ACTION_ONLY` | replacement is not failure |
| Inspection (`NEGATIVE`) | "Seal - no leaks. DE brg temp 59C normal" | `RULED_OUT` rows | the dominant false-positive source |
| Checklist format | "Casing leaks: N" | `CASING / NONE / RULED_OUT` | Y/N checklist negation |
| Shorthand | "o/c P-1003 - motor wont start, VFD fault OC", "u/s pending o/h" | correct codes | glossary use |
| No-fault-found (`NFF`) | "Attended, nff, unit running normally" | no signals | empty array is a valid answer |
| Boilerplate, admin | "LOTO removed and permit closed", "gate locked" | no signals | triage exits, and precision on empties |
| Precursor | "slight weep at seal faces... monitor" | `OBSERVED`, low severity | early, mild mentions |
| Hedged precursor | "Operator thinks DE brg may be running warm, not confirmed" | `UNCLEAR` | hedging is not observation |
| False-alarm control | "vib spike after restart, settled to normal... No action" / "No fault found on cooler" | `OBSERVED` transient, or `RULED_OUT` | precursor precision |
| Hindsight edit (trap) | "in hindsight the weep noted on this route was the start of the seal failure" | extract normally; **exclude from precursor features** | note-level cutoff |
| As-found (trap) | "As found after trip: seal faces destroyed... weep had been reported" | extract normally; **exclude** | failure WO exclusion |

### Planted failure chain (one per planted asset)

| Offset from failure | Record | Content |
|---|---|---|
| -50 days | inspection report | precursor template rank 1 (e.g. seal weep) |
| -45 to -1 days | daily sensors | vibration rises by up to ~5 mm/s, temperature by up to ~22 C |
| -30 days | route WO note | precursor template rank 2 (e.g. bearing temp up, vib trending) |
| -12 days | inspection report | precursor template rank 3 (hedged mention) |
| 0 | downtime event | unplanned, ~48 hours |
| +3 hours | emergency WO note | the failure description |
| +3 days | emergency WO note | as-found (leakage trap) |
| +5 days | route WO (created at -30) gets a new note and `last_modified_at` | hindsight (leakage trap) |

Background work orders are kept out of the 60 days before each planted failure so the label is clean.

### False-alarm controls

One benign anomaly inspection and a one-day sensor spike, with no failure afterwards. A precursor
model that alerts on these is reacting to any anomaly rather than to sustained degradation.

### Recurring issues

Three corrective work orders using the same failure template on the same asset, each opened 12 days
after the previous closed. A correct clusterer groups all three, and a repeat-visit rule with a
window of at least 12 days counts two repeats.

## Run it

1. Substitute placeholders; show the user the substituted header.
2. Run `01_seed_sandbox.sql` as a script (statement by statement through `sql_execute`, or
   `snow sql -f` with the substituted file).
3. Run every check in `02_verify_seed.sql` and show results:
   - check 1: row counts, roughly as estimated above;
   - checks 2, 3, 4, 6, 7, 8: **zero rows** -- anything else is a generator bug;
   - check 9: one row per planted asset (the trap is reachable through a pre-failure WO);
   - check 10: last-10-day vibration well above baseline for planted assets;
   - check 11: a few percent NULL, zero exact zeros;
   - check 12: events spread across the history;
   - check 13: `OTHER` dominates the CMMS codes.
4. Record objects in `created_objects` (both schemas) and set `phases.seed: done`.

## What the sandbox does not test

Be explicit with the user:

- **Real language variety.** Templates are cleaner and less varied than production text: no
  misspellings beyond shorthand, no multilingual notes, no rambling multi-day logs. Extraction
  accuracy on the sandbox is an upper bound, not a forecast.
- **Real failure physics.** Drift is linear and every planted failure has precursors. In production,
  many failures have no text precursor at all. The sandbox proves the pipeline **can** measure lead
  time without leakage; only production data says how much lead time exists.
- **Taxonomy fit.** The sandbox taxonomy fits the sandbox perfectly. A customer taxonomy will have
  gaps, which shows up as `OTHER` share.

For variety, add customer-authored paraphrases of real (de-identified) notes as new templates with
labels from a maintenance lead -- in the eval schema, never the pipeline schema.
