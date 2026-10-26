---
name: ticket-triage
description: "**[REQUIRED]** Use for ALL requests about classifying, prioritizing, routing, de-duplicating or deflecting support or IT tickets in Snowflake. Triggers: ticket triage, auto-triage, auto-route tickets, ticket routing, ticket classification, categorize tickets, classify support cases, assign tickets to queues, assignment group prediction, resolver group, priority prediction, severity classification, mis-routed tickets, ticket ping-pong, reassignment rate, reduce MTTR, mean time to resolution, routing time, service desk automation, ITSM AI, ServiceNow tickets, Zendesk tickets, Jira Service Management, Salesforce cases, duplicate tickets, link duplicates to parent incident, known issue matching, major incident clustering, ticket deflection, deflection candidates, self-service deflection, suggested resolution, knowledge base answers for tickets, KB grounding, agent assist for tickets, entity extraction from tickets, extract error codes from tickets, support ticket AI value, OpEx from tickets. This is the REQUIRED entry point for this work, even if the request seems simple. DO NOT hand-write the pipeline SQL or prompts; always invoke this skill first."
---

# Ticket Triage — Router

## What this builds and why

Support and IT organizations already store the tickets that show where their handling time goes:
mis-routed tickets that bounce between queues, incidents prioritized wrong, the same issue
investigated fifty times, and questions the knowledge base already answers. This plugin builds a
pipeline over tickets **already in Snowflake** that emits, per ticket: a predicted category,
priority and resolver queue with confidence; extracted product, error and asset entities; links to
duplicates, a parent incident or a known issue; and, where it applies, a suggested resolution cited
to the knowledge article or resolved ticket it came from.

**The lever is OpEx**, through three mechanisms that are measured separately and never summed
blindly: routing time (dispatcher touch and reassignments avoided), MTTR (time to the right resolver
and time to a known fix), and deflection (contacts that did not need an agent).

**Scope boundary.** Ingestion is out of scope — tickets are assumed landed. The pipeline ends at a
scored output table, a semantic view and a Cortex Agent. Nothing here writes back to the ITSM or CRM
system, reassigns a ticket, or replies to an end user.

## Setup — do these before anything else

1. **Read** `PROJECT_STATE.md` (this directory). It defines `triage-project.yml`, the single state
   file every phase reads and writes. All resumability depends on honouring it.
2. **Load** `ticket-triage-system-of-record/SKILL.md`. Required first step in every session — it
   establishes what already exists and what the account can actually run.
3. **Load** `ticket-triage-best-practices/SKILL.md`. Required. These rules prevent silent failure
   modes that make a triage pipeline look like it is working while it is quietly wrong — most
   importantly, scoring against labels that leak the answer, and reporting accuracy that is really
   the majority-class rate.
4. **Settle how the pipeline will be built** — a dbt project or plain SQL — and record it in
   `materialization.mode`. Ask once, at preflight, before any phase creates anything. Read
   `DBT_MATERIALIZATION.md` (this directory) for the phase-to-model mapping and the
   materialization rationale, and delegate dbt deploy, execute and versioning mechanics to the
   **`dbt-projects-on-snowflake`** skill rather than reproducing them.

   Recommend dbt when the build will outlive the first demo: version control on prompts and label
   sets, lineage, and dbt tests as **build-failing** gates on the correctness rules (no unclassified
   tickets, no uncited suggestions, no regression in per-queue F1). Recommend plain SQL for a
   time-boxed proof of value or a team with no dbt practice, and say plainly what is given up.

> **PII caution.** Tickets contain names, contact details, account numbers, hostnames, IP addresses,
> and frequently pasted credentials. Never write ticket text, extracted entities, or suggested
> resolutions into a local file, a log, an issue tracker, or any destination outside the account.
> Show samples in the session only when the user asks, and prefer synthetic sandbox rows for
> demonstration.

## Intent detection

| Intent | Trigger phrases | Route |
|---|---|---|
| **BUILD** | "set up ticket triage", "auto-route our tickets", "start from scratch", "help me reduce reassignments" | Run the phased build below |
| **RESUME** | "continue", "pick up where we left off", "what's left", "finish the build" | Read `phases`, report status, continue at the first phase not `done` |
| **SINGLE_PHASE** | names one phase: "just the classification", "rebuild the knowledge base index", "re-run the duplicate linking", "regenerate the sandbox", "redo the taxonomy" | Load that phase's skill directly, after confirming its prerequisite phases are `done` |
| **EVALUATE** | "how accurate is the routing", "what's the F1 per queue", "priority confusion matrix", "is deflection safe", "what is this costing per ticket" | `evaluate-triage-accuracy/SKILL.md` |
| **VALUE** | "what is this worth", "business case", "ROI", "readout", "POC success criteria" | `triage-value-readout/SKILL.md` — after evaluation, never before |
| **DEBUG** | "everything went to one queue", "it's returning nulls", "priorities are all P3", "suggestions cite nothing", "duplicates aren't linking", "too many deflection candidates" | `DIAGNOSING.md` (this directory) |
| **COMPARE** | "which prompt did better", "compare the two runs", "did adding descriptions help", "AI_CLASSIFY versus AI_COMPLETE" | `evaluate-triage-accuracy/SKILL.md`, comparing across `experiment_id` |
| **EXPLAIN** | "how does this work", "what would this look like", "walk me through the architecture" | Answer from this file and the README. Do not create anything. |

If intent is genuinely unclear, ask — do not default to BUILD, because BUILD creates objects.

## The phased build

Nine phases. **Each is a gate**, and the gate protocol is not optional:

1. State plainly what the phase will create — object names and object types.
2. State what it will cost in rough terms when the phase makes AI calls over a table: use
   `AI_COUNT_TOKENS` for an input-token estimate on a sample, scale to the table, report it as
   tokens, and say output tokens bill on top so the figure is a floor. Never convert tokens to
   dollars.
3. Get confirmation with `ask_user_question`.
4. Run it.
5. Show a verification query and its actual result — not a claim that it worked.
6. Update `phases` and `created_objects` in `triage-project.yml`.

Never chain two gates without stopping. A user who wanted only category classification should not
discover that a generative resolution pass has already run over two years of tickets.

| # | Phase | Skill | Creates | Skippable |
|---|---|---|---|---|
| 0 | Preflight | `ticket-triage-system-of-record` | nothing | no |
| 1 | Sandbox | `seed-ticket-sandbox` | synthetic tickets, KB, answer key | yes, if using real data with a trusted labeled holdout |
| 2 | Taxonomy | `define-triage-taxonomy` | label-set tables for category, priority, queue | no |
| 3 | Knowledge | `build-resolution-knowledge-store` | KB chunk table, Cortex Search service | yes, only if deflection and suggestions are out of scope |
| 4 | Classify | `classify-and-route-tickets` | normalized tickets, classification + entity table | no |
| 5 | Link | `link-duplicates-and-known-issues` | embeddings, duplicate clusters, known-issue links | yes, if the customer has no duplicate or known-issue problem |
| 6 | Suggest | `suggest-resolutions-and-deflection` | cited suggestions, deflection candidates | yes, together with phase 3 |
| 7 | Evaluate | `evaluate-triage-accuracy` | accuracy, cost and parse-failure reports | no |
| 8 | Operationalize | `operationalize-triage-pipeline` | stream/task or dynamic tables, semantic view, agent | yes, for a measurement-only POC |
| 9 | Readout | `triage-value-readout` | value range and POC criteria (document, no objects) | no |

### Phase order is a real dependency chain, not a suggestion

- **Taxonomy before classification.** Classifying against a label list nobody agreed to produces a
  precision number nobody believes. It also makes every later experiment incomparable, because the
  label space moved underneath it.
- **Knowledge before suggestions.** A resolution prompt with no retrieved source invents plausible
  steps. An uncited suggestion is not emitted (best-practices rule 9), so skipping phase 3 empties
  phase 6 rather than degrading it.
- **Classification before linking.** Duplicate candidates are blocked by predicted category and
  product so the pairwise comparison is tractable and so a "printer offline" ticket does not cluster
  with a "VPN offline" ticket on the word "offline".
- **Evaluation before operationalization, and before any value claim.** A pipeline whose per-queue
  recall nobody has measured is a pipeline that may be routing a whole queue's tickets somewhere
  else. The readout uses only measured precision and recall; there is no value figure without them.

### Strongly recommend the sandbox first

Push back once, politely, if a user wants to skip Phase 1 and go straight at real tickets:

> The sandbox ships an answer key, so routing precision and recall per queue, the priority confusion
> matrix and deflection precision are measurable immediately. Real tickets do carry a historical
> category and assignment group, but those labels are noisy — the final assignment group is where a
> ticket ended up after reassignment, not where it should have gone first, and the category field is
> frequently left at its default. Scoring against them without a cleaned holdout measures agreement
> with past mistakes. The sandbox lets us show the pipeline is correct first, then measure it on a
> holdout the customer trusts.

If they still want to go straight to real data, do it and mark `seed: skipped`. Their call. Then
insist on building a labeled holdout in phase 7 before quoting any accuracy figure.

## Confidence, citations and run identity are per-row output contract

Three things are frequently misread as reporting concerns. They are not:

- **Every classified ticket carries a confidence and a `label_source`.** Confidence comes from the
  classification call itself (or a calibrated proxy — see best-practices rule 5); `label_source`
  says whether the label came from a rule, `AI_CLASSIFY`, or the `AI_COMPLETE` fallback. Nothing
  reaches the output table unlabeled; a ticket that could not be classified is labeled
  `UNCLASSIFIED` explicitly and counted, never dropped.
- **Every suggested resolution and every deflection candidate cites its source**, and each citation
  carries an `article_id` or `source_ticket_id` that resolves to a row in the knowledge store. A
  suggestion whose source cannot be traced is not emitted.
- **Every row carries run identity**: `run_id`, `experiment_id`, `prompt_version`, `prompt_hash`,
  `taxonomy_version`, and the model per stage.

Separately, `evaluate-triage-accuracy` measures the **pipeline** against ground truth. Do not
conflate the two: per-row confidence says how sure the model is about one ticket; the harness says
how often the pipeline is actually right, per queue.

## Every run is a labelled experiment

Triage is tuned by iteration — a category description reworded, few-shot examples added, a queue
split in two, the fallback model swapped — so a run that cannot be told apart from the previous one
destroys the only signal that says whether the change helped.

Before Phase 4, set `experiment.run_id` (unique per invocation), `experiment_id`, `experiment_name`
(what changed, in words), `prompt_version`, and confirm `taxonomy.version`. These are **selected into
every output row**, alongside a `prompt_hash` computed from the assembled label set and prompt text.
The classification, linking, suggestion and evaluation layers accumulate rather than replace, so
`experiment_id` supports a real side-by-side comparison.

A change to the taxonomy is a different kind of change from a change to a prompt: it changes the
label space, so per-queue metrics across two taxonomy versions are not directly comparable. The
harness refuses to compare across `taxonomy_version` without saying so.

## Verification queries to run at each gate

Show real output, not assurances:

| Phase | Verification |
|---|---|
| Sandbox | ticket count by true queue and priority; answer-key coverage (every ticket labeled); KB article count; planted duplicate clusters and deflectable tickets present |
| Taxonomy | every label has a description of 25 words or fewer; no queue in the label set with zero historical tickets; label count per dimension (warn above 20) |
| Knowledge | retrieve for two known issues and show the returned chunks and their `article_id`; service `indexing_state` |
| Classify | distribution of predicted queue against historical queue share; count of `UNCLASSIFIED` (investigate any); count with null confidence (must be zero); parse failures from the fallback path |
| Link | cluster size distribution; largest cluster's members read for coherence; count of links crossing predicted category (should be near zero) |
| Suggest | count of suggestions; count with no resolvable citation (must be zero); deflection candidate share of tickets |
| Evaluate | per-queue precision/recall/F1, macro-F1, priority confusion matrix, deflection precision, cost per 1K tickets, parse-failure count |
| Operationalize | a new synthetic ticket inserted into the source appears in the output with all fields populated within one refresh; agent answers one sample question citing the semantic view |

## When the user asks what this costs

Be straight, and stay in tokens. The dominant cost is generative: the `AI_COMPLETE` fallback in
phase 4 and the resolution pass in phase 6. That is why three structural levers exist upstream:

- deterministic rules and `AI_CLASSIFY` handle the bulk of classification; `AI_COMPLETE` runs only
  on the low-confidence or multi-intent residue;
- `AI_FILTER` gates the resolution pass, so the generative step runs only on tickets that look
  answerable from the knowledge base;
- thread normalization strips quoted replies, signatures and disclaimers before any AI call, which on
  email-to-case corpora is often the largest single token reduction.

Phase 7 reports what those levers actually saved on this corpus, and cost per 1K tickets per stage,
rather than asserting a percentage. Do not quote savings figures from elsewhere as if they were this
account's numbers.

## Teardown

If the user wants to remove the build, read `created_objects` from `triage-project.yml` and drop what
is listed there — do not guess names from a convention. Confirm before dropping, and name the
objects. Suspend tasks and the Cortex Search service before dropping the tables they read. Warn
explicitly if the output table has reviewer decisions recorded, since agents may already have acted
on its contents.
