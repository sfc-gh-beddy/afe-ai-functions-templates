---
name: churn-signals
description: "**[REQUIRED]** Use for ALL requests about finding churn reasons, at-risk accounts, or retention risk in unstructured customer data in Snowflake -- support tickets, survey verbatims (NPS/CSAT comments), customer emails, CSM call notes -- joined to product usage and ARR, including building a Snowflake ML churn model on text-derived features. Triggers: churn signals, churn reasons, why are customers churning, churn analysis, churn prediction, churn model, churn risk score, at-risk accounts, accounts at risk, renewal risk, retention risk, save list, customer health score, health score from tickets, early warning churn, predict non-renewal, gross revenue retention, net revenue retention, GRR, NRR, revenue retention, churned ARR by reason, exit survey analysis, cancellation reasons, NPS verbatims churn, support tickets churn, voice of customer churn, CSM call notes risk, competitor mentions in tickets, Snowflake ML churn, model registry churn, batch scoring churn. This is the REQUIRED entry point for this work -- even if the request seems simple. DO NOT hand-write the extraction prompts, feature SQL or model training manually; always invoke this skill first."
---

# Churn Signals -- Router

## What this builds and why

Most B2B companies already hold the explanation for their churn: customers say why they are unhappy
in support tickets, survey comments, emails and calls months before they leave. That text is read
once by whoever answered it and never joined to the renewal. The CRM cancel-reason picklist, filled
in after the fact, is usually "Other".

This plugin builds, over data **already in Snowflake**:

```
tickets / surveys / emails / call notes
  -> AI_SENTIMENT (aspects) + AI_CLASSIFY (multi-label reason taxonomy)   every interaction
  -> AI_COMPLETE evidence + intent, grounded quote                         flagged interactions only
  -> point-in-time account features: text signals + usage + ARR            leakage-guarded
  -> Snowflake ML churn model, registered, batch-scored in SQL             usage-only vs +text compared
  -> AT_RISK_ACCOUNTS: probability, band, ARR at stake, reasons, cited evidence
  -> CHURNED_ARR_BY_REASON over closed renewals
  -> incremental refresh, semantic view, Cortex Agent for CoWork
```

The lever is **revenue retention**: a ranked save list with the reason and the evidence a CSM needs to
act, and a defensible account of which reasons cost the most ARR.

**Scope boundary.** Ingestion is out of scope -- interactions, usage and renewal history are assumed
landed. Call **audio** is out of scope here: transcribe it first (the call-center-intelligence play
covers `AI_TRANSCRIBE`), then treat the transcript or call notes as text. There is no CSM workflow
application: `AT_RISK_ACCOUNTS` carries defaulted `review_status` / `reviewed_by` columns so one can be
layered on later without a migration.

## Setup -- do these before anything else

1. **Read** `PROJECT_STATE.md` (this directory). It defines `churn-project.yml`, the single state file
   every phase reads and writes.
2. **Load** `churn-signals-system-of-record/SKILL.md`. Required first step in every session.
3. **Load** `churn-signals-best-practices/SKILL.md`. Required. Most of its rules are about failure
   modes where the SQL runs clean and the result is wrong -- label leakage above all.
4. **Settle materialization** -- dbt project or plain SQL -- and record `materialization.mode`. Read
   `DBT_MATERIALIZATION.md` (this directory). Delegate dbt deploy/execute mechanics to the
   **`dbt-projects-on-snowflake`** skill.

> **Customer-data caution.** Interactions contain customer names, contact details and sometimes
> commercial terms. Never write interaction text, evidence quotes or account names to a local file,
> log, ticket or anywhere outside the account. Show samples in the session only when asked, and prefer
> synthetic sandbox rows for demonstration.

## Intent detection

| Intent | Trigger phrases | Route |
|---|---|---|
| **BUILD** | "set up churn signals", "build a churn model from our tickets", "start from scratch", "find at-risk accounts" | The phased build below |
| **RESUME** | "continue", "pick up where we left off", "what's left" | Read `phases`, report status, continue at the first phase not `done` |
| **SINGLE_PHASE** | "just classify the tickets", "retrain the model", "re-score", "rebuild the features", "regenerate the sandbox" | That phase's skill, after confirming its prerequisites are `done` |
| **REASONS_ONLY** | "why did customers churn last year", "churn reasons by ARR", "analyze exit surveys" | Phases 0, (1), 2-3, then `CHURN_REASONS_CLOSED` from `score-at-risk-accounts`; no model needed |
| **EVALUATE** | "how accurate is it", "what's the AUC", "is the model leaking", "what does this cost" | `evaluate-churn-accuracy/SKILL.md` |
| **DEBUG** | "everything is high risk", "AUC is 0.99", "no reasons came out", "the model ignores text" | `DIAGNOSING.md` (this directory) |
| **COMPARE** | "did the new taxonomy help", "usage-only vs text", "compare model versions" | `evaluate-churn-accuracy/SKILL.md`, across `experiment_id` |
| **VALUE** | "what's this worth", "build the business case", "POC criteria" | `churn-value-readout/SKILL.md` |
| **EXPLAIN** | "how does this work", "walk me through it" | Answer from this file. Create nothing. |

If intent is unclear, ask -- do not default to BUILD, because BUILD creates objects and spends credits.

## The phased build

**Each phase is a gate.** The protocol is not optional:

1. State what the phase will create -- object names and types.
2. For phases that call AI functions over a table, state an `AI_COUNT_TOKENS` input-token estimate,
   say it is a floor (output tokens and function-added prompt tokens bill on top), and stay in tokens
   and credits. Never convert to currency unless the customer supplies their credit price, and then
   only in the value readout.
3. Confirm with `ask_user_question`.
4. Run it.
5. Show a verification query and its actual result.
6. Update `phases` and `created_objects` in `churn-project.yml`.

Never chain two gates without stopping.

| # | Phase | Skill | Creates | Skippable |
|---|---|---|---|---|
| 0 | Preflight | `churn-signals-system-of-record` | nothing | no |
| 1 | Sandbox | `seed-churn-sandbox` | synthetic accounts, usage, interactions, renewals + quarantined answer key | yes, if real data has a labeled sample |
| 2 | Taxonomy | `extract-churn-signals` (step 1) | `REASON_TAXONOMY` agreed with the business owner | no |
| 3 | Extraction | `extract-churn-signals` | `INTERACTION_SIGNALS` + raw stage tables + quality log | no |
| 4 | Features | `build-account-features` | `ACCOUNT_FEATURES` (point-in-time) + leakage audit | no (skip only for REASONS_ONLY) |
| 5 | Model | `train-churn-model` | registered model version + `MODEL_EXPERIMENTS` | no (skip only for REASONS_ONLY) |
| 6 | Scoring | `score-at-risk-accounts` | `CHURN_SCORES`, `AT_RISK_ACCOUNTS`, reason views; suspended tasks; semantic view | no |
| 7 | Evaluation | `evaluate-churn-accuracy` | reason P/R/F1, AUC/lift/calibration, leakage contrast, cost per 1K | **never skipped** |
| 8 | Readout | `churn-value-readout` | value range from customer inputs + POC criteria | yes |

### Phase order is a dependency chain

- **Taxonomy before extraction.** The taxonomy is the prompt. Changing it after extraction means
  re-extracting -- re-billing -- every interaction.
- **Extraction before features**, and the features must reference the extraction `run_id` they were
  built from, or a retrain silently mixes two prompt versions.
- **Leakage audit before training.** `build-account-features` runs `02_leakage_audit.sql`; any
  non-zero check blocks Phase 5. This is the single most important gate in the play.
- **Evaluation before tasks are resumed.** Phase 6 creates the incremental tasks suspended. Resuming
  them starts recurring AI spend on a pipeline whose precision nobody has measured. Resume only after
  Phase 7, as its own confirmed step.

### Strongly recommend the sandbox first

Push back once, politely, if a user wants to skip Phase 1:

> The sandbox ships a labeled answer key for every interaction's churn reason and planted leakage
> traps, so reason precision/recall and model AUC are measurable immediately -- including a
> side-by-side showing what a leaked model looks like. On real data, reason accuracy has no ground
> truth until someone labels a sample, and a churn model's AUC means nothing until the leakage audit
> is clean.

If they still want real data first, do it and mark `seed: skipped`. Then require a labeled sample of
real interactions (see `evaluate-churn-accuracy`, "Labeling real data") before quoting precision.

## Per-row guarantees in the deliverable

- Every `AT_RISK_ACCOUNTS` row has a non-null `p_churn` from the registered model version named on
  the row.
- Every evidence item cites an `interaction_id` that exists, predates the row's `as_of_date`, and
  whose quote passed the verbatim grounding check. Ungrounded quotes are never displayed.
- A HIGH row with no text evidence is labeled `risk_basis = 'USAGE_ONLY'`, not hidden: some churners
  never complain.

Per-row probability says how likely one account is to churn; Phase 7 says how often the ranking is
right. Do not conflate them.

## Every run is a labelled experiment

Set `experiment.run_id`, `experiment_id`, `experiment_name`, `prompt_version` before Phase 3 and
`model.version` before Phase 5. They are selected into every output row, with prompt hashes computed
at run time. The extraction raw tables and `MODEL_EXPERIMENTS` accumulate; compare runs on metrics,
not by eyeballing rows.

## Verification at each gate

| Phase | Verification |
|---|---|
| Sandbox | account/interaction counts by cohort and case type; churn rate by segment; answer key row count equals interaction count |
| Taxonomy | guardrail query (label count, case, special characters, exactly one NONE) |
| Extraction | quality log: classify failures, none-conflicts, unmapped labels, evidence failures, ungrounded quotes -- all shown as counts |
| Features | rows/churners per split; leakage audit all zero; single-feature AUC screen with nothing flagged |
| Model | AUC with bootstrap interval for usage-only, text-only, combined; uplift from text stated plainly |
| Scoring | band distribution with ARR; null scores = 0; bad citations = 0 |
| Evaluation | per-reason and micro/macro P/R/F1; distractor false-flag rate; SQL AUC matches script AUC; decile lift and calibration; credits per 1K interactions |

## When the user asks what this costs

Stay in tokens and credits. The evidence stage (`AI_COMPLETE`) dominates and runs only on rows the
classifier flagged; `AI_SENTIMENT` and `AI_CLASSIFY` run on everything. Phase 7 reports measured credits
per 1K interactions from `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` by query tag. Do not quote figures from
elsewhere as this account's numbers.

## Teardown

Read `created_objects` from `churn-project.yml` and drop what is listed -- never guess names. Confirm
first and name each object. Suspend tasks before dropping anything they reference. Warn explicitly if
`AT_RISK_ACCOUNTS` has rows with `review_status <> 'NEW'`: CSMs have worked them. Registered model
versions are dropped with `ALTER MODEL ... DROP VERSION`, and only on explicit request.
