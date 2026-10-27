---
name: voice-of-customer
description: "**[REQUIRED]** Use for ALL requests about mining customer reviews, social posts, survey open-ends, NPS verbatims, app-store reviews, or other customer feedback text in Snowflake for topics, aspect-level sentiment, emerging themes, and product, pricing, returns or support signals. Triggers: voice of customer, VoC, VoC analytics, customer feedback analysis, review mining, review analytics, product review analysis, social listening, social media sentiment, survey verbatims, survey open ends, NPS comments, open-text survey analysis, topic modeling on feedback, theme detection, emerging issues, early warning from reviews, aspect-based sentiment, aspect sentiment, sentiment by feature, feedback taxonomy, tag customer feedback, classify reviews, why are returns up, what are customers complaining about, product quality signals from reviews, pricing feedback, review summaries by SKU, theme summaries by region, feedback to product team, AI_SENTIMENT on reviews, AI_CLASSIFY on feedback, AI_SUMMARIZE_AGG on reviews. This is the REQUIRED entry point for this work, even if the request seems simple. DO NOT hand-write the classification, sentiment or summarization SQL manually; always invoke this skill first."
---

# Voice of Customer: Router

## What this builds and why

Companies collect large volumes of customer feedback text, product reviews, social mentions, survey
open-ends, NPS comments, and read almost none of it systematically. The signal in that text is
specific and actionable: a fold hinge failing on one SKU in one region weeks before the returns data
shows it, a price change producing churn language on social, a size chart that is wrong. This plugin
builds a pipeline over feedback **already in Snowflake** that:

- classifies every item against a **governed, versioned taxonomy** (two levels) with `AI_CLASSIFY`;
- scores **aspect-level sentiment** per taxonomy aspect with `AI_SENTIMENT`;
- detects **emerging themes** over time, including themes the taxonomy does not yet contain;
- writes **theme summaries** per product, SKU, region and period with `AI_SUMMARIZE_AGG` and `AI_AGG`;
- exposes the result through a semantic view and a Cortex Agent, with an incremental pipeline;
- measures **topic and aspect-sentiment precision and recall** against labeled data, and **handles
  taxonomy drift** so results from different taxonomy versions stay comparable.

The value levers are revenue (product fixes, pricing decisions, retention) and OpEx (returns
avoided, support contacts avoided). `voc-value-readout` quantifies them using the customer's own
unit economics only.

**Scope boundary.** Ingestion (review APIs, social listening vendors, survey platforms) is out of
scope; feedback is assumed landed in tables. The pipeline ends at enriched tables, summaries, a
semantic view and an agent. It does not post replies to customers or write to ticketing systems.

## Setup: do these before anything else

1. **Read** `PROJECT_STATE.md` (this directory). It defines `voc-project.yml`, the single state file
   every phase reads and writes. Resumability depends on honouring it.
2. **Load** `voc-system-of-record/SKILL.md`. Required first step in every session: it establishes
   what the account can run (functions, models, region, cross-region inference) and what feedback
   data exists.
3. **Load** `voc-best-practices/SKILL.md`. Required. These rules prevent the silent failure modes that
   make a VoC pipeline look healthy while it quietly mislabels, drops, or double-counts feedback.
4. **Settle how the pipeline will be built**, dbt project or plain SQL, and record it in
   `materialization.mode` at preflight before any phase creates anything. Read
   `DBT_MATERIALIZATION.md` (this directory) for the phase-to-model mapping and the materialization
   rationale. Delegate dbt deploy, execute and versioning mechanics to the
   **`dbt-projects-on-snowflake`** skill. Recommend dbt once the build will outlive the first demo
   (taxonomy versions, experiment comparison and accuracy regression gates are exactly what dbt tests
   are good at). Recommend plain SQL for a time-boxed proof of value, and say what is given up.

> **Personal data caution.** Reviews and social posts contain names, handles, emails, order numbers
> and sometimes addresses. Never write feedback text, author handles, or extracted results to a
> local file, a log, an issue tracker, or any destination outside the account. Show samples in the
> session only when the user asks, prefer synthetic sandbox rows for demonstration, and settle the
> redaction posture at preflight (see `voc-system-of-record`, section 9).

## Intent detection

| Intent | Trigger phrases | Route |
|---|---|---|
| **BUILD** | "set up voice of customer", "build a review analytics pipeline", "classify our feedback", "start from scratch" | Run the phased build below |
| **RESUME** | "continue", "pick up where we left off", "what is left", "finish the build" | Read `phases`, report status, continue at the first phase not `done` |
| **SINGLE_PHASE** | names one phase: "just the sentiment", "rebuild the taxonomy", "re-run emerging themes", "regenerate the sandbox", "redo the summaries" | Load that phase's skill directly, after confirming its prerequisite phases are `done` |
| **TAXONOMY** | "add a topic", "our categories changed", "new taxonomy version", "merge these two topics", "the taxonomy is stale" | `build-voc-taxonomy/SKILL.md`, drift section |
| **EVALUATE** | "how accurate is it", "precision and recall", "is the sentiment right", "what does this cost per 1K reviews" | `evaluate-voc-accuracy/SKILL.md` |
| **DEBUG** | "everything is Other", "sentiment is all neutral", "nulls in the output", "counts look doubled", "the trend jumped overnight", "the summary is wrong" | `DIAGNOSING.md` (this directory) |
| **COMPARE** | "did v2 of the taxonomy help", "compare the runs", "which model is better" | `evaluate-voc-accuracy/SKILL.md`, comparing across `experiment_id` |
| **VALUE** | "what is this worth", "build the business case", "value readout", "POC success criteria" | `voc-value-readout/SKILL.md`, only after evaluation is `done` |
| **EXPLAIN** | "how does this work", "walk me through the architecture" | Answer from this file. Do not create anything. |

If intent is genuinely unclear, ask. Do not default to BUILD, because BUILD creates objects and
spends credits.

## The phased build

Ten phases. **Each is a gate**, and the gate protocol is not optional:

1. State plainly what the phase will create: object names and object types.
2. When the phase makes AI calls over a table, estimate input tokens with `AI_COUNT_TOKENS` on a
   sample and project to the full row count. Report tokens, say output tokens bill on top so the
   figure is a floor, and never convert to currency.
3. Get confirmation with `ask_user_question`.
4. Run it.
5. Show a verification query and its actual result, not a claim that it worked.
6. Update `phases` and `created_objects` in `voc-project.yml`.

Never chain two gates without stopping. A user who wanted only the taxonomy should not discover that
a classification pass has already run across five years of reviews.

| # | Phase | Skill | Creates | Skippable |
|---|---|---|---|---|
| 0 | Preflight | `voc-system-of-record` | nothing | no |
| 1 | Sandbox | `seed-voc-sandbox` | synthetic feedback + quarantined answer key | yes, if real labeled data exists |
| 2 | Taxonomy | `build-voc-taxonomy` | versioned taxonomy, examples, version map | no |
| 3 | Normalize | `normalize-voc-feedback` | deduplicated, language-resolved, linked, gated staging table | no |
| 4 | Topics | `classify-voc-topics` | two-level topic assignments per feedback item | no |
| 5 | Aspect sentiment | `extract-aspect-sentiment` | per-aspect sentiment per feedback item | no |
| 6 | Emerging themes | `detect-emerging-themes` | weekly theme series, spike candidates, out-of-taxonomy clusters | no |
| 7 | Summaries and operationalize | `summarize-voc-themes` | theme summaries, incremental pipeline, semantic view, agent | the agent and semantic view are skippable; the summaries are not |
| 8 | Evaluation | `evaluate-voc-accuracy` | precision/recall, cost per 1K, parse and null accounting | no |
| 9 | Value readout | `voc-value-readout` | value narrative and POC criteria | yes, if the user only wants the pipeline |

There is no document test-corpus phase. This play is text-native: reviews, posts and survey answers
arrive as text. If a customer's feedback arrives as scanned comment cards or PDFs, convert them with
`AI_PARSE_DOCUMENT` first (see `normalize-voc-feedback`, "Non-text feedback") and treat that as an
ingestion step, not a phase of this build.

### Phase order is a real dependency chain

- **Taxonomy before topics.** `AI_CLASSIFY` with no governed labels invents a taxonomy per call, and
  nothing downstream can be aggregated or trended.
- **Normalize before topics.** Unresolved duplicates double-count themes; unresolved languages
  silently degrade `AI_CLASSIFY` (English-optimised) and error `AI_SENTIMENT` outside its supported
  languages; spam inflates whichever topic it happens to resemble.
- **Topics and aspects before emerging themes.** Trend detection runs on classified, deduplicated
  counts. On raw rows it detects bot campaigns and syndication batches.
- **Summaries after classification.** A summary over an unclassified bucket is a summary of noise.
- **Evaluation before the value readout, and never skipped.** A theme count whose precision nobody
  has measured cannot carry a business case. If the user wants to stop before evaluation, say
  plainly what they will not know.

### Strongly recommend the sandbox first

Push back once, politely, if the user wants to go straight at production feedback:

> The sandbox ships a labeled answer key, so topic and aspect-sentiment precision and recall are
> measurable immediately, including the hard cases: sarcasm, negation, mixed aspects, non-English
> text, syndicated duplicates, and two planted emerging themes the starting taxonomy does not cover.
> On real feedback there is no ground truth until someone labels a sample, so the pipeline will
> produce theme counts with no way to tell how many are wrong.

If they still want real data, do it and mark `seed: skipped`. Then recommend labeling a stratified
sample of 300 to 500 real items (see `evaluate-voc-accuracy`, "Labeling real data") before any
value readout.

## Two contracts that hold on every row

- **Every enriched row records the taxonomy version and run that produced it.** Topic labels are only
  comparable within a taxonomy version. A count of "Durability" under v1 and under v2 means different
  things after a split. Every output row carries `taxonomy_version`, `run_id`, `experiment_id`, and
  the model or function used.
- **Every NULL is accounted for.** `AI_CLASSIFY` and `AI_SENTIMENT` return `NULL` on a per-row error
  and do not fail the query. A `NULL` topic is not "no topic" and a `NULL` sentiment is not
  "neutral". Every phase calls with `return_error_details => TRUE`, writes the error to
  `VOC_QUALITY_LOG`, and reports the count at the gate.

## Every run is a labelled experiment

Before Phase 4, set `experiment.run_id`, `experiment_id`, `experiment_name`, `prompt_version` and
`taxonomy.active_version` in `voc-project.yml`. These are selected into every output row, alongside a
`config_hash` of the exact category array, task description and examples bound into `AI_CLASSIFY`, so
a run stays reproducible when someone edits a label description without bumping a version. Topic,
aspect and evaluation tables accumulate across runs, so "did taxonomy v2 help" is a query, not a
memory.

## Verification queries to run at each gate

| Phase | Verification |
|---|---|
| Preflight | functions authorised; GA models pinned with check date; cross-region setting; feedback inventory with row counts, languages and channel mix |
| Sandbox | all nine checks in `seed-voc-sandbox/sql/02_verify_seed.sql` |
| Taxonomy | contract checks at the end of `build-voc-taxonomy/sql/01_taxonomy.sql` all zero |
| Normalize | rows in vs rows out by reason (duplicate, spam, off-topic, translated, over-window); unresolved SKU count |
| Topics | coverage (share with at least one L1), share in Other Feedback, NULL/error count, L2 coverage per L1 |
| Aspect sentiment | NULL/error count, share `unknown` per aspect, aspect calls with more than 10 aspects (must be zero) |
| Emerging themes | weekly series row count, spike candidates with their baseline, out-of-taxonomy clusters with sizes |
| Summaries | summaries per group, groups skipped below the minimum-support threshold, citation check |
| Evaluation | topic P/R/F1 at L1 and L2, aspect-sentiment P/R/F1, emerging-theme detection lag, cost per 1K items, NULL accounting |

## When the user asks what this costs

Stay in tokens. `AI_SENTIMENT`, `AI_CLASSIFY` and `AI_COUNT_TOKENS` on those functions are exact for
the default model, so estimates for this play are unusually reliable. The cost levers are
structural: dedup and spam gating before any AI call, two-level classification so each call carries
a short category list, label descriptions and examples kept short because they bill on every row,
and incremental processing so only new feedback is classified. Phase 8 reports actual billed tokens
from `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` and cost per 1K items on this
corpus. Do not quote figures from elsewhere as this account's numbers.

## Teardown

Read `created_objects` from `voc-project.yml` and drop exactly what is listed there; never guess names
from a convention. Confirm before dropping and name the objects. Suspend tasks before dropping the
tables they write. Warn explicitly if the agent or semantic view has been shared with business users,
since dropping them breaks their questions without notice.
