---
name: extract-churn-signals
description: "Extract churn signals from every customer interaction (tickets, survey verbatims, emails, call notes) with Cortex AI functions: agree the churn-reason taxonomy with the business owner, render it into AI_CLASSIFY multi-label categories with descriptions and few-shot distractor examples, run AI_SENTIMENT with retention aspects, then AI_COMPLETE with a JSON schema only on flagged rows to produce a verbatim grounded evidence quote, churn intent, resolved flag and named competitor. Stages land separately with return_error_details, a quality log, prompt hashes and query tags. Phases 2 and 3 of the churn-signals build. Triggers: classify tickets for churn, churn reason taxonomy, extract churn reasons, tag survey verbatims, competitor mentions, churn intent."
parent_skill: churn-signals
---

# Extract churn signals

Output: `INTERACTION_SIGNALS`, one row per interaction per `run_id`, with reason codes, aspect
sentiment, churn intent, resolved flag, competitor, and a grounded evidence quote. Everything
downstream -- features, the at-risk list, the reason analysis -- reads this table.

## Step 1 (Phase 2): agree the taxonomy before extracting anything

The taxonomy **is** the prompt. Changing it after a full extraction means re-billing every row, so
settle it first, with the person who will act on the output (VP Customer Success, retention lead).

Start from `SYN_REASON_TAXONOMY` (sandbox) or copy it as a draft:

| Code | Label (AI_CLASSIFY category) |
|---|---|
| `PRICE_VALUE` | price or value concerns |
| `PRODUCT_GAP` | missing product capability |
| `RELIABILITY` | reliability or performance problems |
| `SUPPORT` | poor support experience |
| `ADOPTION` | low adoption or onboarding difficulty |
| `COMPETITOR` | evaluating a competitor |
| `BUSINESS_CHANGE` | budget cuts or business change |
| `CHAMPION_LOSS` | loss of internal champion |
| `NONE` | no retention risk |

Questions to ask the owner -- each answer changes the taxonomy:

1. Which reasons would trigger a *different* save play? Reasons that lead to the same action can be
   merged; one that leads to a distinct action (exec sponsor outreach for champion loss, product
   escalation for a gap) earns its own label.
2. What do your exit surveys or CRM cancel picklist already use? Align codes where sensible so
   closed-churn analysis can be compared with history -- while noting how often the picklist says
   "Other".
3. Is there a reason specific to this business -- a mandated migration, a regulatory change, a
   seasonal business -- that the generic list misses?

Rules (best-practices 13-14): plain English lowercase labels, mutually exclusive, twenty or fewer,
exactly one `NONE`, a description per label that says what separates it from its neighbours.

Create the pipeline copy and run the guardrails:

```sql
CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.REASON_TAXONOMY AS
SELECT * FROM {{TAXONOMY_SOURCE}};
```

Then run the first two statements of `sql/00_size_and_render.sql`: the rendered categories literal
with its hash, and the guardrail check. Record `extraction.categories_hash`, mark `phases.taxonomy:
done`, and show the owner the final table.

## Step 2: size it

Run the token estimate in `sql/00_size_and_render.sql` on a sample (`extraction.sample_size`, default
500). Report:

- average and max input tokens per stage, and how many rows exceed AI_SENTIMENT's 2,048-token window;
- that these are **floors** -- AI_CLASSIFY and AI_SENTIMENT add their own prompt tokens, label
  descriptions and examples count as input on every call, and output tokens bill on top;
- that the evidence stage's total depends on the flag rate, which is unknown until a sample run.

Then run Step 3 on the sample only (uncomment `{{SAMPLE_LIMIT}}` as `LIMIT <n>` or stage a sampled
`STG_INTERACTIONS`) and use the observed flag rate to project the full run. Present the projection and
let the user choose: full run, larger sample, or narrower scope (one channel, last N months).

## Step 3 (Phase 3): run the extraction

Before running: set `experiment.run_id` (unique), `experiment_id`, `prompt_version` in
`churn-project.yml`. Substitute into `sql/01_extract_signals.sql`:

| Placeholder | From |
|---|---|
| `{{SOURCE_TABLE}}` and column placeholders | `sources.interactions` |
| `{{EVIDENCE_MODEL}}` | `models.evidence` (verified GA at preflight) |
| `{{CATEGORIES_LITERAL}}` | the rendered literal from Step 1 |
| `{{TASK_DESCRIPTION}}` | `extraction.task_description` -- 50 words or fewer |
| `{{RUN_ID}}`, `{{EXPERIMENT_ID}}`, `{{PROMPT_VERSION}}` | `experiment` |

### Multiple source tables

Tickets, surveys, emails and call notes usually live in different tables. Build `STG_INTERACTIONS` as
a `UNION ALL` of per-source selects, each mapping its own id, account key, text, said-at timestamp, and
a constant or column for channel. Prefix ids with the source (`'TKT-' || id`) so ids cannot collide.
Apply the customer-voice filter per source (best-practices 11): exclude agent replies, strip quoted
reply chains and signatures, drop survey rows where the verbatim is empty.

### What each stage does and why it is shaped that way

**A. AI_SENTIMENT** with aspects `price`, `product features`, `reliability`, `support`, `ease of
use`, `competitors`, `renewal` (seven of the ten allowed, each under 30 characters). Every row.
Returns an `overall` entry plus one per aspect, each `positive | negative | neutral | mixed | unknown`.
`unknown` means not mentioned -- it is not neutral, and the feature step counts only `negative` and
`mixed`. Rows over the 2,048-token window error rather than truncate; window them by tokens and keep
the worst sentiment per aspect across windows.

**B. AI_CLASSIFY** with `output_mode: 'multi'`, the categories literal (label + description objects),
a task description, and three few-shot examples that are deliberately the hard cases: a past
competitor evaluation, a resolved bug, and a genuine two-reason message. `return_error_details =>
TRUE` so failures are countable. The input is prefixed with the channel ("Channel: SURVEY. Text: ...")
because the same words mean different things in a CSM's call note and in a customer's email.

**B2. Parse** labels back to codes through `REASON_TAXONOMY` with one normalization (`LOWER(TRIM())`).
If `no retention risk` comes back alongside a real reason, the real reason wins and `none_conflict` is
set. Labels that map to no code are counted in `unmapped_label_count` and must total zero.

**C. AI_COMPLETE**, only on rows B flagged. A JSON schema with `required` on every field:

| Field | Use |
|---|---|
| `evidence_quote` | one sentence copied verbatim -- the CSM-facing evidence |
| `churn_intent` | `none | low | medium | high`, defined in the prompt; becomes a model feature |
| `concern_resolved` | true only if the text says it was fixed and the customer is satisfied |
| `competitor_named` | competitor product named in the text, or empty |

`temperature: 0`, "Respond in JSON" in the prompt, `show_details => TRUE` for per-call token usage.

**C2. Ground** the quote: `CONTAINS(LOWER(body), LOWER(quote))` after whitespace normalization.
Ungrounded quotes are nulled and flagged `evidence_grounded = FALSE`. A flagged row whose evidence call
produced nothing is `evidence_failed`.

### Why AI_COMPLETE and not AI_EXTRACT for evidence

AI_EXTRACT is the simpler call for pulling a fact out of text, and is a reasonable choice for a
competitor-name-only field. It does not fit the evidence step here: its JSON-schema response format
supports only string scalars (no enum for intent, no boolean for resolved), and the grounding check
needs a single verbatim sentence chosen against the detected risk categories, which the prompt
supplies. Keep AI_EXTRACT in mind for document sources (contracts, PDFs of QBR decks) where it reads
files directly.

## Gate verification

Show these results:

```sql
-- Staging accounting (printed by the script after STG_INTERACTIONS)
-- source_rows, too_short_or_null, staged_rows

SELECT stage, total_rows, failed_rows, detail
FROM PIPELINE_QUALITY_LOG WHERE run_id = '{{RUN_ID}}' ORDER BY stage;

-- Flag rate and reason mix
SELECT r.value::STRING AS reason_code, COUNT(*) AS interactions
FROM INTERACTION_SIGNALS s, LATERAL FLATTEN(input => s.reason_codes) r
WHERE s.run_id = '{{RUN_ID}}'
GROUP BY 1 ORDER BY 2 DESC;

SELECT channel,
       COUNT(*) AS rows,
       ROUND(AVG(IFF(ARRAY_SIZE(reason_codes) > 0, 1, 0)), 4) AS flag_rate,
       COUNT_IF(churn_intent = 'high') AS high_intent
FROM INTERACTION_SIGNALS WHERE run_id = '{{RUN_ID}}'
GROUP BY 1 ORDER BY 1;

-- Read five flagged rows with their quotes, in the session only
SELECT interaction_id, channel, reason_codes, churn_intent, concern_resolved, evidence_quote
FROM INTERACTION_SIGNALS
WHERE run_id = '{{RUN_ID}}' AND ARRAY_SIZE(reason_codes) > 0
ORDER BY RANDOM() LIMIT 5;
```

Must-be-zero: `unmapped_labels`. Should be near zero and investigated if not: classify failures,
evidence failures, ungrounded quotes. Report the none-conflict rate.

Then record the raw and output tables in `created_objects.tables` and `phases.extract: done`.

## Iterating

Every prompt or taxonomy change: bump `prompt_version` and `experiment_id`, new `run_id`, re-render
the categories literal, re-run on the **same** sample, and compare in `evaluate-churn-accuracy` before
spending on a full re-extraction. The raw tables accumulate by `run_id`; old runs stay comparable.

Common levers, in the order to try them:

1. A label description that does not separate two neighbours (check the confusion query).
2. A missing few-shot example for a distractor pattern that the false-flag rate shows leaking through.
3. Customer-voice filtering in staging (agent text, signatures).
4. A stronger evidence model -- only if the grounding rate is the problem.
