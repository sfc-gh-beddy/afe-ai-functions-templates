---
name: publish-entity-resolution
description: "Phase 7 of the entity-resolution build. Promotes an evaluated run through a recorded published-run pointer, exposes golden records, crosswalk, relationships and duplicate summaries through stable CURRENT views, creates a semantic view for Cortex Analyst and CoWork with identifiers and bank fields kept out, schedules incremental runs as a task graph that executes the staged phase SQL as Jinja templates via EXECUTE IMMEDIATE FROM with a per-run id from the task graph, reuses prior adjudication responses for identical prompts so unchanged pairs are never re-billed, and creates a Cortex Agent over the semantic view. Use when operationalizing entity resolution, scheduling matching, building a single customer view or duplicate vendor dashboard for business users, or exposing golden records to CoWork."
parent_skill: entity-resolution
---

# Publish

Only after `phases.eval: done`. A pipeline published before it is measured merges records at an
unknown false-merge rate into views that other people will build on.

`sql/01_publish.sql` is the template. It has five sections; each is its own gate.

## 1. Promote a run

`ER_PUBLISHED_RUN` records which run is current, who promoted it, when, and a snapshot of its
evaluation summary. Promotion is deliberate and recorded. Scheduled runs never promote themselves.

Before promoting, show the user the run's pairwise and B-cubed metrics from `ER_EVAL_SUMMARY`, its
held-cluster count, and its largest cluster — and confirm.

## 2. Current views

| View | Contents |
|---|---|
| `ER_GOLDEN_CURRENT` | golden records of the published run, **publishable clusters only** |
| `ER_CROSSWALK_CURRENT` | every source record of the published run, with cluster status and review status |
| `ER_RELATIONSHIPS_CURRENT` | parent/subsidiary, sibling-location and product-variant links |
| `ER_DUPLICATE_SUMMARY_CURRENT` | per golden id: source records, source systems, duplicates collapsed, weakest membership confidence |

Downstream consumers read these, never the run-stamped tables, so promotion is a single pointer change
and rollback is promoting the previous run.

Access is a decision, not an inheritance (rule 36). The golden view concentrates attributes from every
source; the crosswalk maps every source key to it. Ask who should read each, and apply masking or row
access policies before granting. Use the `data-governance` skill for policy design.

## 3. Semantic view

`ER_ENTITY_RESOLUTION_SV` over the current views: golden records, duplicate summary, crosswalk, with
relationships on `golden_id`, dimensions for entity type, name, location, brand, source system and
review status, and metrics for golden-record count, source-record count, duplicate records,
multi-system entities, and average cluster confidence.

Deliberately absent: tax ids, phone numbers, email addresses, bank fields. The analytical surface does
not need them to answer "how many duplicate vendors per ERP" or "which customers exist in both CRM and
billing". If a use case needs them, add them with an explicit access decision and a masking policy.

The syntax follows the `CREATE SEMANTIC VIEW` reference. Validate the view after creation with a few
questions and their generated SQL; for verified queries, synonyms and optimization, use the
`agent-studio` skill rather than hand-editing.

## 4. Incremental scheduling

### How the scheduled pipeline reuses the same SQL

The phase templates use `{{PLACEHOLDER}}` variables, which is Jinja syntax. `EXECUTE IMMEDIATE FROM
@stage/file.sql USING (KEY => value, ...)` renders a staged file as a Jinja2 template before executing
it, and accepts bind variables in `USING` — so the files that ran interactively run unchanged on a
schedule. Before staging:

1. Render once the values that do not change per run — schema names, models, thresholds, block cap —
   and leave `RUN_ID`, `EXPERIMENT_ID` and `PRIOR_RUN_ID` as template variables.
2. Use real data's staging SQL (from preflight), not the sandbox section, in the standardize file.
3. Keep each rendered file under the documented 100,000-byte rendered-template limit.
4. `PUT` the files to the stage from a client, or use the `snowflake-workspace` / stage tooling.

`ER_RUN_PHASE(phase_file, run_id, experiment_id)` looks up the current published run as
`PRIOR_RUN_ID` (for golden-id inheritance) and executes the file. It is a caller's-rights procedure
because the phase files set `QUERY_TAG`, and session changes are not available to owner's-rights
procedures.

### The task graph

`ER_ROOT` (scheduled) → `ER_SCORE` → `ER_ADJUDICATE` → `ER_GOLDEN`. Each passes
`SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID')` as the run id, so every scheduled run is
distinct and a retry of a failed task reuses the same run id — the phase files are idempotent on run id,
so a retry neither double-bills nor double-inserts (rule 38). Use the `snowflake-tasks` skill for
monitoring, failure notifications, and `SUSPEND_TASK_AFTER_NUM_FAILURES`.

Tasks are created suspended. Confirm the schedule and `adjudicate.max_pairs_per_run` before resuming —
the cap is the upper bound on model calls per scheduled run. Resume children before the root.

### What is incremental, and what is not

| Phase | Incremental behaviour |
|---|---|
| Standardize and block | Rebuilt in full each run. No AI cost; bounded by the block cap. New records are compared against **all** records, not only each other (rule 38). |
| Score | `AI_EMBED` only for records whose text hash, model or template changed. Pair scoring in full (vector and string functions only). |
| Adjudicate | Responses are reused for byte-identical prompts on the same model (section 3a of the adjudicate SQL). Since the prompt contains every input the model sees, an unchanged pair costs nothing on later runs. Only new or changed pairs are called. |
| Golden | Rebuilt in full; ids inherited from the published run by overlap. |

This makes steady-state cost proportional to change volume: embeddings for changed records, and model
calls for pairs that involve a changed record and land in the review band.

### Promotion check, not auto-promotion

A scheduled run writes its results but does not change `ER_PUBLISHED_RUN`. Add a check (an alert or a
final task) that compares the run's held-cluster count, maximum cluster size, model failure count, and
minted-versus-inherited golden ids against the published run, and notifies rather than promotes when
any regresses. On real data there is no answer key in the scheduled path, so these structural signals
are the regression gate; periodically re-label a steward sample to recheck precision.

## 5. Cortex Agent

`ER_ENTITY_RESOLUTION_AGENT` with one `cortex_analyst_text_to_sql` tool over the semantic view, sample
questions, and instructions to answer from the view only, report golden ids and cluster confidence
rather than deciding identity itself, and never reveal identifiers. The specification shape follows
the `CREATE AGENT` reference; creation does not validate the tool configuration, so test it with the
sample questions before sharing it. Pin `{{AGENT_MODEL}}` to an orchestration model preflight
confirmed. Use the `agent-studio` skill for evaluation and iteration.

The agent is what makes the single customer view usable by account teams in CoWork ("which of our
customers also buy from the other business unit", "show every system this vendor exists in").

## Gate verification

- `SELECT * FROM ER_PUBLISHED_RUN ORDER BY published_at DESC LIMIT 3;`
- row counts of each current view, and that `ER_CROSSWALK_CURRENT` equals the in-scope record count
- three questions to the semantic view and the SQL it generated
- `SHOW TASKS LIKE 'ER_%';` with their state
- one agent conversation using a sample question

Write `phases.publish: done` and record views, semantic view, stage, procedure, tasks and agent in
`created_objects`.
