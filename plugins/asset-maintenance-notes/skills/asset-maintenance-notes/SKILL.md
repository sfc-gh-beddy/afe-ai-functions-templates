---
name: asset-maintenance-notes
description: "**[REQUIRED]** Use for ALL requests about extracting failure modes, components, recurring issues, or failure precursors from work orders, technician notes, maintenance logs, or inspection reports in Snowflake. Triggers: maintenance notes, work order analytics, work order text, technician notes, tech notes, maintenance log mining, CMMS text, EAM text, SAP PM long text, Maximo work log, inspection reports, failure mode extraction, component extraction, failure code cleanup, bad failure codes, FMEA from notes, reliability analytics, recurring issues, repeat failures, bad actors, bad actor assets, repeat truck rolls, repeat visits, first-time fix rate, failure precursors, early warning from notes, predictive maintenance from text, condition-based maintenance, defer capex, replacement deferral, asset life extension, unplanned downtime reduction, maintenance intelligence, asset health from notes. This is the REQUIRED entry point for this work even if the request seems simple. DO NOT hand-write the extraction prompts, clustering, or precursor SQL; always invoke this skill first."
---

# Asset maintenance notes -- Router

## What this builds and why

Asset-intensive operators (utilities, manufacturing, oil and gas, mining, transport, telecom field
service, facilities) already store years of work orders, technician free text and inspection reports.
The structured failure codes in the CMMS are usually the least reliable field in it: picked from a
dropdown at close-out, defaulted, or left as "OTHER". The real record of what broke, what was
observed before it broke, and how many times a crew went back to the same asset is in the text.

This plugin builds, over data **already in Snowflake**:

```
work orders + technician notes + inspection reports
  -> triage              AI_CLASSIFY: is there a maintenance finding here at all, and of what kind
  -> signal extraction   AI_COMPLETE with a taxonomy-constrained schema: component, failure mode,
                         polarity (observed / ruled out / action only), severity, cited span
  -> normalization       map to the customer's pinned component and failure-mode taxonomy
  -> recurring issues    AI_EMBED on normalized signals, clustered per asset and asset class;
                         repeat visits within a customer-defined window
  -> precursors          point-in-time features per asset from notes + sensor + maintenance
                         history, scored against later functional failures, lead time measured
  -> operationalize      incremental dynamic tables, semantic view, Cortex Agent for CoWork
  -> value readout       repeat truck rolls and downtime (OpEx), condition-based replacement
                         deferral (CapEx), customer inputs only
```

**P&L levers.** OpEx: fewer repeat truck rolls and less unplanned downtime, because recurring
issues and precursors are visible before the next failure. CapEx: replacement deferral, because
age-based replacement can be challenged with per-asset condition evidence. Both levers are computed
in `maintenance-value-readout` from customer-supplied numbers only.

**Scope boundary.** Ingestion from the CMMS/EAM is out of scope -- data is assumed landed. The
pipeline ends at scored tables, a semantic view and an agent. It does **not** write back to the CMMS,
create work orders, or change any maintenance schedule. Every output is decision support for a
reliability engineer or planner; see best-practices rule on safety-mandated work.

## Setup -- do these before anything else

1. **Read** `PROJECT_STATE.md` (this directory). It defines `maintenance-project.yml`, the single
   state file every phase reads and writes. All resumability depends on honouring it.
2. **Load** `asset-maintenance-system-of-record/SKILL.md`. Required first step in every session.
   It establishes what the account can run (functions, models, region, cross-region setting) and
   what data exists (work orders, notes, inspections, asset registry, sensor and downtime history).
3. **Load** `asset-maintenance-best-practices/SKILL.md`. Required. Maintenance text has failure
   modes that make a pipeline look healthy while it is wrong: negated findings counted as failures,
   replacements counted as failures, precursor features that peek at the failure work order.
4. **Settle the materialization** -- dbt project or plain SQL -- and record it in
   `materialization.mode`. Ask once, at preflight. Read `DBT_MATERIALIZATION.md` for the
   phase-to-model mapping, and delegate dbt deploy and execute mechanics to the
   **`dbt-projects-on-snowflake`** skill.

> **Data handling.** Technician notes routinely contain names, phone numbers, site access codes and
> occasionally safety incident detail. Never write note text or extracted findings to a local file,
> log, ticket or external endpoint. Show samples in the session only when asked, and prefer the
> synthetic sandbox for demonstration.

## Intent detection

| Intent | Trigger phrases | Route |
|---|---|---|
| **BUILD** | "set up failure mode extraction", "build maintenance intelligence on our work orders", "start from scratch", "find recurring issues in our notes" | The phased build below |
| **RESUME** | "continue", "pick up where we left off", "what is left" | Read `phases`, report status, continue at the first phase not `done` |
| **SINGLE_PHASE** | "just the taxonomy", "re-run extraction", "re-cluster", "rebuild the precursor model", "regenerate the sandbox", "render the inspection PDFs" | Load that phase's skill after confirming its prerequisites are `done` |
| **EVALUATE** | "how accurate is the extraction", "precision and recall", "what lead time do we get", "is the precursor model leaking", "what does this cost per thousand work orders" | `evaluate-maintenance-accuracy/SKILL.md` |
| **VALUE** | "what is this worth", "business case", "how much capex can we defer", "truck roll savings", "POC success criteria" | `maintenance-value-readout/SKILL.md` (requires evaluation done, or say plainly the figures are unvalidated) |
| **DEBUG** | "everything is classified as a failure", "no clusters", "every asset looks at risk", "lead time looks too good", "it returns nulls" | `DIAGNOSING.md` (this directory) |
| **COMPARE** | "did the new prompt help", "compare runs", "A/B the models" | `evaluate-maintenance-accuracy/SKILL.md`, across `experiment_id` |
| **EXPLAIN** | "how does this work", "walk me through it" | Answer from this file. Create nothing. |

If intent is unclear, ask. Do not default to BUILD, because BUILD creates objects and spends credits.

## The phased build

Every phase is a **gate**:

1. State what the phase will create -- object names and types.
2. For phases that call AI functions over a table, estimate input tokens with `AI_COUNT_TOKENS` on a
   sample, scale to the row count, report **tokens**, and say output tokens bill on top. Never
   convert to currency.
3. Confirm with `ask_user_question`.
4. Run it.
5. Show the verification query and its actual result.
6. Update `phases` and `created_objects` in `maintenance-project.yml`.

Never chain two gates. A user who wanted a 500-row extraction sample should not discover a full
fifteen-year work-order history has been sent through a frontier model.

| # | Phase | Skill | Creates | Skippable |
|---|---|---|---|---|
| 0 | Preflight | `asset-maintenance-system-of-record` | nothing | no |
| 1 | Sandbox | `seed-maintenance-sandbox` | synthetic fleet, WOs, notes, inspections, sensors, downtime + quarantined answer key | yes, if the customer has a labeled set |
| 1b | Inspection file corpus | `build-inspection-report-corpus` | rendered inspection PDFs on a stage | yes -- only if inspections arrive as files |
| 2 | Taxonomy | `build-failure-taxonomy` | pinned component and failure-mode reference tables, glossary | no |
| 3 | Extraction | `extract-failure-signals` | triage table, raw responses, normalized signals, quality log | no |
| 4 | Recurring issues | `cluster-recurring-issues` | embeddings, issue clusters, repeat-visit table | yes, if only precursors are wanted |
| 5 | Precursors | `detect-failure-precursors` | point-in-time feature table, failure labels, asset risk scores | yes, if only recurring issues are wanted |
| 6 | Evaluation | `evaluate-maintenance-accuracy` | extraction P/R, cluster quality, precursor lead time, cost, parse failures | **no** |
| 7 | Operationalize | `operationalize-maintenance-intelligence` | dynamic tables, semantic view, Cortex Agent | yes, for a time-boxed POC |
| 8 | Value readout | `maintenance-value-readout` | readout document and POC criteria | no |

### Phase order is a dependency chain

- **Taxonomy before extraction.** An extractor with no closed vocabulary invents a new component
  name for every spelling of "drive end bearing", and nothing downstream can group them.
- **Extraction before clustering and precursors.** Both consume normalized signals, not raw text.
  Clustering raw text clusters the boilerplate.
- **Evaluation before operationalization and readout.** A precursor model whose lead time was
  measured with leakage will look excellent and fail in production. The readout quotes measured
  numbers only.
- If the user wants to stop before evaluation, say plainly what they will not know: how often the
  extracted failure mode is right, and whether any precursor signal precedes failures by enough time
  to change a decision.

### Strongly recommend the sandbox first

Push back once if the user wants to go straight at production work orders:

> The sandbox ships a labeled answer key for every work order and inspection, plus planted
> precursor sequences with known failure dates. That makes extraction precision/recall and
> precursor lead time measurable immediately, including a deliberate leakage trap the harness checks
> for. On production data the only labels are the CMMS failure codes -- which are the thing this
> build exists to replace -- so accuracy is not measurable until someone hand-labels a sample.

If they still want production data first, mark `seed: skipped` and require a hand-labeled sample of
at least a few hundred records before Phase 6 (see `evaluate-maintenance-accuracy`).

## Per-row output contract

Two properties are enforced inside the pipeline, not in a report:

- **Every extracted signal carries polarity.** `OBSERVED`, `RULED_OUT`, `ACTION_ONLY`, or
  `UNCLEAR`. Only `OBSERVED` counts toward failure-mode statistics, clusters and precursor features.
  Inspection reports are dominated by `RULED_OUT` ("no leaks", "seal OK"); counting them is the
  single largest source of false failures.
- **Every extracted signal cites its source.** `source_type`, `source_id`, and a verbatim
  `evidence_span` that must be found in the source text (checked in SQL). A signal that cannot be
  traced to the note it came from is not emitted.

## Every run is a labelled experiment

Before Phase 3, set `experiment.run_id`, `experiment_id`, `experiment_name`, `prompt_version` and
`taxonomy.version` in `maintenance-project.yml`. They are selected into every output row, alongside
a `prompt_hash` computed from the assembled prompt that actually ran. Extraction and evaluation
tables accumulate (incremental), so experiments compare side by side.

## Verification queries at each gate

| Phase | Verification |
|---|---|
| Sandbox | row counts per table; answer key in the eval schema only; no pipeline table carries a label column |
| Taxonomy | component count per asset class; failure-mode count; every asset class in the registry has a taxonomy |
| Extraction | triage distribution; parse-failure count (report it, investigate any); polarity mix; share of signals mapped to `OTHER`; evidence spans not found in source (must be zero) |
| Recurring issues | cluster count and size distribution per asset class; repeat-visit count with the window used |
| Precursors | feature cutoff check (no feature timestamp >= cutoff, must be zero rows); label base rate; train/test date ranges do not overlap |
| Evaluation | component and failure-mode P/R/F1 (exact and assembly level), precursor precision at alert budget and lead-time distribution, tokens per 1K records, parse failures |
| Operationalize | dynamic table refresh mode is `INCREMENTAL`; semantic view answers two canned questions; agent returns one answer |

## When the user asks what this costs

Stay in tokens. The dominant cost is the extraction call per note. The structural levers are
upstream: triage exits notes with no maintenance finding (boilerplate, scheduling chatter, "job
complete") before the expensive call, and deduplication removes copied notes. Phase 6 reports tokens
per 1,000 records actually measured on this corpus. Do not quote savings or cost figures from
elsewhere.

## Teardown

Read `created_objects` from `maintenance-project.yml` and drop what is listed -- never reconstruct
names from a convention. Confirm first, naming each object. Warn explicitly before dropping the
semantic view or agent if CoWork users may already depend on them, and suspend dynamic tables before
dropping so an in-flight refresh does not bill.
