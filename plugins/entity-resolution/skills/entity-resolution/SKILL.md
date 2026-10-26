---
name: entity-resolution
description: "**[REQUIRED]** Use for ALL requests about matching, deduplicating, or merging customer, vendor, supplier, or product records across systems in Snowflake. Triggers: entity resolution, record linkage, record matching, fuzzy matching, deduplicate customers, duplicate vendors, duplicate suppliers, vendor master cleanup, supplier dedup, customer dedup, product dedup, product master matching, item master cleanup, golden record, survivorship, master data management, MDM matching, single customer view, customer 360 identity, match and merge, householding, account hierarchy matching, duplicate payments risk, vendor consolidation, spend fragmentation, cross-sell single view, link CRM and ERP records, match records across systems, AI_EMBED matching, AI_SIMILARITY matching, LLM match adjudication, snowflake-decision matching. This is the REQUIRED entry point for this work — even if the request seems simple. DO NOT hand-write the matching SQL or prompts; always invoke this skill first."
---

# Entity Resolution — Router

## What this builds and why

Organizations with more than one system of record carry the same customer, vendor, or product many
times over under drifting names and non-shared keys. That costs OpEx (duplicate vendor spend,
duplicate payments exposure, steward cleanup time) and revenue (no single customer view, so cross-sell
runs on fragments). This plugin builds a pipeline over records **already in Snowflake** that produces
golden records and a source-to-golden crosswalk, where every merge carries a decision source, a score,
and — for model-adjudicated pairs — structured reasons.

**Scope boundary.** Ingestion is out of scope. Write-back to source systems is out of scope: the
pipeline ends at the golden table and crosswalk, which are designed to feed a steward or merge process
rather than replace it.

## Setup — do these before anything else

1. **Read** `PROJECT_STATE.md` (this directory). It defines `er-project.yml`, the single state file
   every phase reads and writes.
2. **Load** `entity-resolution-system-of-record/SKILL.md`. Required first step in every session.
3. **Load** `entity-resolution-best-practices/SKILL.md`. Required. Entity resolution fails silently in
   more ways than most pipelines — blocking that drops true pairs, transitive chaining that merges
   unrelated companies, thresholds tuned on the pairs that survived blocking — and every one of them
   produces a confident-looking golden table.
4. **Settle the materialization mode** — dbt project or plain SQL — and record it in
   `materialization.mode`. Read `DBT_MATERIALIZATION.md` (this directory) and delegate dbt mechanics
   to the **`dbt-projects-on-snowflake`** skill. Recommend dbt when the build will outlive the first
   demo, because dbt tests become build-failing gates on cannot-link violations and cluster-size
   blowups. Recommend plain SQL for a time-boxed proof of value, and say what is given up.
5. **Settle the entity scope** — `CUSTOMER`, `VENDOR`, `PRODUCT`, or a combination — and record it in
   `scope.entity_types`. Each entity type is resolved independently; a customer record is never
   compared with a vendor record unless the user explicitly asks for a party-level resolution (the
   same organization as both customer and supplier), which is recorded as `scope.cross_type_party`.

> **PII caution.** Master records carry contact names, emails, phone numbers, and on vendor records
> bank and remittance details. Never write record contents to a local file, log, or ticket. Never
> include bank, payment, or government-id fields in a model prompt or embedding text — they are not
> needed to decide identity and only widen exposure. Tax identifiers are used for deterministic
> matching in SQL only. Prefer synthetic sandbox rows for demonstration.

## Intent detection

| Intent | Trigger phrases | Route |
|---|---|---|
| **BUILD** | "find duplicate vendors", "build a golden customer record", "dedupe our product master", "start from scratch" | Run the phased build below |
| **RESUME** | "continue", "pick up where we left off", "what's left" | Read `phases`, report status, continue at the first phase not `done` |
| **SINGLE_PHASE** | names one phase: "just the blocking", "re-score the pairs", "re-run adjudication", "rebuild golden records", "regenerate the sandbox" | Load that phase's skill directly, after confirming prerequisites are `done` |
| **EVALUATE** | "how accurate is the matching", "precision and recall", "what does it cost per thousand records", "are we over-merging" | `evaluate-match-accuracy/SKILL.md` |
| **CALIBRATE** | "tune the thresholds", "too many go to review", "where should the cutoff be" | `evaluate-match-accuracy/SKILL.md`, threshold sweep section, then `score-candidate-pairs` to re-band |
| **DEBUG** | "two different companies got merged", "obvious duplicates were missed", "one giant cluster", "the model says everything matches", "nulls in the decisions" | `DIAGNOSING.md` (this directory) |
| **COMPARE** | "did the new prompt help", "compare the two runs", "A/B the embedding models" | `evaluate-match-accuracy/SKILL.md`, comparing across `experiment_id` |
| **VALUE** | "what is this worth", "build the business case", "ROI", "POC criteria" | `entity-resolution-value-readout/SKILL.md` |
| **PUBLISH** | "make it incremental", "schedule it", "semantic view", "agent", "CoWork" | `publish-entity-resolution/SKILL.md` after evaluation is `done` |
| **EXPLAIN** | "how does this work", "walk me through the architecture" | Answer from this file. Create nothing. |

If intent is genuinely unclear, ask — do not default to BUILD, because BUILD creates objects.

## The phased build

**Each phase is a gate**, and the gate protocol is not optional:

1. State what the phase will create — object names and types.
2. When the phase makes AI calls over a table, estimate input tokens with `AI_COUNT_TOKENS`
   (`'ai_embed'` for embeddings, `'ai_complete'` for adjudication), report tokens and call counts,
   and say output tokens bill on top for adjudication. Never convert tokens to dollars.
3. Get confirmation with `ask_user_question`.
4. Run it.
5. Show a verification query and its actual result.
6. Update `phases` and `created_objects` in `er-project.yml`.

Never chain two gates without stopping.

| # | Phase | Skill | Creates | AI cost | Skippable |
|---|---|---|---|---|---|
| 0 | Preflight | `entity-resolution-system-of-record` | nothing | none | no |
| 1 | Sandbox | `seed-entity-resolution-sandbox` | synthetic source tables + quarantined answer key | none | yes, if a labeled set exists another way |
| 2 | Standardize and block | `standardize-and-block-records` | canonical records, blocking keys, candidate pairs | none | no |
| 3 | Score | `score-candidate-pairs` | embeddings, pair features, banded pairs | AI_EMBED, once per record | no |
| 4 | Adjudicate | `adjudicate-match-pairs` | model decisions with reasons on the review band | AI_COMPLETE, review band only | yes, if the review band is empty or routed to stewards |
| 5 | Golden records | `build-golden-records` | clusters, golden records, crosswalk | none | no |
| 6 | Evaluate | `evaluate-match-accuracy` | blocking, pairwise, cluster, cost and failure reports | none | no |
| 7 | Publish | `publish-entity-resolution` | incremental pipeline, semantic view, agent | per new record | yes |
| 8 | Readout | `entity-resolution-value-readout` | value model and POC criteria document | none | yes |

### Phase order is a real dependency chain

- **Standardize before blocking**, or blocking keys are built on raw strings and `ACME, INC.` and
  `Acme Inc` land in different blocks — the pair is lost before any AI runs, and nothing downstream
  can recover it.
- **Blocking before embeddings are compared**, or similarity is computed over all N-squared pairs.
  Embeddings are computed once per record regardless; blocking controls how many pairs are compared and
  — far more importantly — how many reach the model.
- **Scoring before adjudication**, so the model only sees the ambiguous middle band. Sending every
  candidate pair to `AI_COMPLETE` is the single largest avoidable cost in this play.
- **Evaluation before publish, and never skipped.** An entity resolution pipeline nobody has measured
  merges records at an unknown false-merge rate, and a false merge is worse than a missed duplicate: it
  pays the wrong vendor, mails the wrong customer, and is expensive to unwind once downstream systems
  consume the crosswalk.

### Strongly recommend the sandbox first

Push back once, politely, if the user wants to go straight to real master data:

> The sandbox ships a labeled answer key, so pairwise and cluster precision and recall — and blocking
> recall, which is the number most implementations never measure — are available immediately. On real
> data there is no ground truth until stewards label a sample, so thresholds would be set by eye. It
> also lets the build be demonstrated before access to customer PII is approved.

If they still want real data, do it, mark `seed: skipped`, and recommend that
`evaluate-match-accuracy` build a steward-labeled sample before any threshold is trusted.

## Decisions and golden records are in-pipeline guarantees

Three things are per-row output contract, not reporting concerns:

- **Every accepted match carries a `decision_source`** (`RULE`, `SCORE`, `MODEL`, `STEWARD`), a
  `match_score`, and the experiment identity that produced it.
- **Every model-adjudicated pair carries structured reasons** naming attributes and their effect.
  A model decision with no reasons is rejected to the quality log rather than accepted.
- **Every golden attribute carries provenance**: the source record it survived from and the
  survivorship rule that selected it.

Separately, `evaluate-match-accuracy` measures the pipeline against ground truth. Per-pair confidence
says how sure the scorer or model is about one pair; the harness says how often the pipeline is
right. Do not conflate them.

## Every run is a labelled experiment

Thresholds, embedding text templates, embedding models, and adjudication prompts are all tuned by
iteration. Before Phase 3, set `experiment.run_id`, `experiment_id`, `experiment_name`,
`prompt_version`, and `embed_template_version` in `er-project.yml`. These are selected into every
scored pair, decision, and evaluation row, alongside a `prompt_hash` and an `embed_text_hash` computed
at run time. Scored pairs, decisions, and evaluation results accumulate rather than replace, so runs can
be compared on the metrics.

## Verification queries to run at each gate

| Phase | Verification |
|---|---|
| Standardize | row count per source equals canonical row count per source; count of canonical rows with empty `name_norm` (investigate any) |
| Block | candidate pairs per entity type; reduction ratio; largest block sizes and any capped blocks; count of self-pairs and reversed duplicates (must be zero) |
| Score | count of records with no embedding (must be zero); band distribution; count of `AUTO_MATCH` pairs with a cannot-link conflict (must be zero) |
| Adjudicate | calls made; parse failures; decisions with zero reasons (must be zero); decision distribution |
| Golden | cluster size distribution; largest cluster and its member names; clusters containing a cannot-link pair (must be zero); every source record appears in the crosswalk exactly once |
| Evaluate | blocking pair completeness, pairwise P/R/F1, B-cubed cluster P/R/F1, by difficulty tier; cost per 1K records in tokens |

## When the user asks what this costs

Stay in tokens and call counts. Two cost centers exist: `AI_EMBED`, which runs once per record (and
once per changed record thereafter), and `AI_COMPLETE`, which runs once per review-band pair. Blocking
and banding are the levers on the second. Phase 6 reports tokens per 1,000 source records and the
share of pairs that reached the model on this data, rather than asserting a figure. Do not quote
savings percentages from elsewhere.

## Teardown

Read `created_objects` from `er-project.yml` and drop exactly what is listed. Confirm first and name
the objects. Warn explicitly if the crosswalk has been consumed — check `ACCESS_HISTORY` or ask —
because downstream systems may already key on golden ids.
