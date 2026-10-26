# Voice of Customer

A guided build for a voice-of-customer pipeline that runs entirely inside Snowflake, on the reviews,
social posts and survey open-ends the organization already stores.

## The problem

Most companies collect far more customer feedback text than anyone reads. Star ratings and NPS
scores get dashboards; the words behind them get sampled, skimmed, or hand-coded by a small team a
quarter late. That costs in three places:

- **Product and pricing decisions made blind.** A hinge failing on one SKU in one market, a size
  chart that is wrong, a new fee that customers resent: all of it is written down by customers weeks
  before it shows up in returns, contacts or churn.
- **Avoidable returns and support contacts.** Many returns and contacts trace to a small number of
  fixable causes (sizing, product information, a defect, a confusing policy). They are visible in the
  feedback by topic, product and region, and invisible in aggregate scores.
- **Manual coding effort.** Analysts hand-tag open-ends against a coding frame that drifts out of
  date, and the tags cannot be trended across the change.

The feedback is already in the account. Nothing needs to be acquired.

## What this plugin builds

```
Existing feedback (reviews, social, surveys)
  -> normalize           dedup with the right scope, language, relevance gate, redaction, SKU linking
  -> topics              AI_CLASSIFY, two-level and multi-label, against a governed versioned taxonomy
  -> aspect sentiment    AI_SENTIMENT per taxonomy aspect, unknown / neutral / mixed kept distinct
  -> emerging themes     share-based weekly series, sub-theme discovery, out-of-taxonomy proposals
  -> summaries           AI_AGG / AI_SUMMARIZE_AGG by product, SKU, region and period
  -> operationalize      incremental pipeline, semantic view, Cortex Agent for CoWork
  -> evaluate + value    precision/recall, drift handling, cost per 1K, customer-input value readout
```

Every enriched row records the taxonomy version, run and experiment that produced it, and every NULL
from an AI function is logged as an error rather than read as "no topic" or "neutral".

## What it does not build

- **Ingestion.** Review APIs, social listening exports and survey platforms are assumed landed in
  tables. Use the Snowflake ingestion skills for that.
- **Customer-facing actions.** The pipeline does not reply to reviews, open tickets, or contact
  customers. It ends at tables, summaries, a semantic view and an agent.

## Getting started

Ask in plain language. The router picks up phrases like:

- "what are customers complaining about in our reviews"
- "set up voice of customer on our survey verbatims"
- "find emerging issues in product reviews by SKU and region"
- "aspect-based sentiment on our feedback"
- "why are returns up on this product"

The build runs in ten gated phases. Each phase says what it will create and what it will cost in
tokens, waits for confirmation, runs, and shows a verification query. State lives in `voc-project.yml`
in the working directory, so the build can be stopped and resumed.

**Start in the sandbox.** Phase 1 generates a synthetic corpus with a labeled answer key: thousands of
reviews, posts and survey answers composed from labeled fragments, plus hand-authored hard cases
(sarcasm, negation, mixed aspects, non-English text, over-length answers, syndicated duplicates,
spam) and two planted emerging themes that the starting taxonomy does not cover. Topic and
aspect-sentiment precision and recall, emerging-theme detection lag, and the full taxonomy-drift loop
are measurable on day one, before anyone approves access to real customer text.

This play is text-native, so there is no document test-corpus phase. Feedback that arrives as scanned
cards or PDFs is converted with `AI_PARSE_DOCUMENT` during ingestion.

## Skills

| Skill | Role |
|---|---|
| `voice-of-customer` | Entry point. Intent detection, phase gating, project state, dbt materialization, diagnosis. |
| `voc-system-of-record` | Preflight: function access, models, region and cross-region inference, feedback inventory, language and length profile, duplicates, existing taxonomy, sensitive-data posture. |
| `voc-best-practices` | Correctness rules. Always loaded. |
| `seed-voc-sandbox` | Synthetic corpus, hard cases, planted emerging themes, quarantined answer key. |
| `build-voc-taxonomy` | Versioned two-level taxonomy, aspects, examples, version map, and the drift workflow. |
| `normalize-voc-feedback` | Union, dedup, language, relevance gate, redaction, SKU linking, window measurement. |
| `classify-voc-topics` | AI_CLASSIFY topic assignment at L1 and L2, plus a return-intent flag. |
| `extract-aspect-sentiment` | AI_SENTIMENT per aspect, segmentation of long items, topic sentiment through the aspect. |
| `detect-emerging-themes` | Weekly share series, baselines, sub-theme discovery, novelty against the taxonomy, proposals. |
| `summarize-voc-themes` | Theme summaries with a citation check; incremental pipeline, semantic view, search, agent. |
| `evaluate-voc-accuracy` | Topic and aspect precision/recall, drift handling, detection lag, stability, failures, cost per 1K. |
| `voc-value-readout` | Value by lever with customer-supplied inputs only, and POC success criteria. |

## Requirements

- A role with Cortex AI function access (`SNOWFLAKE.CORTEX_USER` or equivalent). Preflight verifies
  each function with `EXPLAIN_PRIVILEGES` and reports the missing grant if not.
- A warehouse, and a database and schemas the role can create objects in, including a separate schema
  for the quarantined answer key.
- `AI_CLASSIFY`, `AI_SENTIMENT`, `AI_SUMMARIZE_AGG` / `AI_AGG`, `AI_TRANSLATE`, `AI_REDACT` and
  `AI_EMBED` available in the account's region, or cross-region inference enabled. Preflight checks,
  and surfaces the data-residency implication of cross-region processing for the customer to decide.

## A note on personal data

Feedback text contains names, handles, emails, order numbers and sometimes addresses. Every AI
function call runs inside Snowflake, so text does not leave the account boundary, though cross-region
inference, if enabled, processes it in another region. Preflight settles a redaction posture with the
customer before anything is processed; summaries and agent responses are built from redacted text
when required, author identifiers are hashed and never exposed, and verbatims are available only to
roles that can already read the source.
