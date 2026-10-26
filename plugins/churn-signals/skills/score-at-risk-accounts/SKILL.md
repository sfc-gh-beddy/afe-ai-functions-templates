---
name: score-at-risk-accounts
description: "Batch-score open renewals with the registered churn model in SQL (MODEL(name, version)!PREDICT_PROBA with named arguments), and land AT_RISK_ACCOUNTS: churn probability, risk band, ARR and probability-weighted ARR at stake, top reasons, cited grounded evidence from before the prediction cutoff, a USAGE_ONLY basis flag for silent risk, and AI_SUMMARIZE_AGG narratives for the top accounts. Also builds CHURN_REASONS_CLOSED and CHURNED_ARR_BY_REASON over closed churn (including exit surveys, attributed once per account), the incremental pipeline (stream, inbox, idempotent extraction procedure, suspended tasks), and a semantic view for Cortex Analyst and a CoWork Cortex Agent. Phase 6 of the churn-signals build. Triggers: score accounts, at risk list, save list, churn scoring, batch inference churn, churned ARR by reason, schedule churn pipeline, churn agent."
parent_skill: churn-signals
---

# Score and rank at-risk accounts

## Preconditions

- `phases.model: done` and a version chosen for scoring (`model.default_version`, confirmed).
- `ACCOUNT_FEATURES` built at the same `feature_version` the version was trained on, with SCORE rows
  for open renewals. To refresh SCORE rows without touching TRAIN/TEST, re-run
  `build-account-features/sql/01_build_features.sql` with a new `{{SCORE_AS_OF}}`; the TRAIN/TEST rows
  it rebuilds are identical because they depend only on history.
- Thresholds: on the first scoring run `thresholds.high_risk` and `thresholds.watch` are unset. Score
  first with placeholders (for example 0.5 / 0.3) marked provisional, then set them in Phase 7 from the
  TEST lift table and re-band. Do not present provisional bands as final.

## Step 1: batch score

`sql/01_score_and_rank.sql`, section 1.

- Starts with `SHOW FUNCTIONS IN MODEL <name> VERSION <v>`. Confirm the input names match
  `ACCOUNT_FEATURES` column names and the output carries `P_CHURN`. If the registry inferred different
  output names (the script fell back, or the model was logged elsewhere), fix the `:P_CHURN` path
  before running -- reading a missing key returns NULL for every row, silently.
- Calls `MODEL(<name>, <version>)!PREDICT_PROBA(...)` with **every feature passed by name**, cast to
  FLOAT to match the logged signature, and an explicit version.
- Scores `SCORE` rows (the deliverable) and `TEST` rows (so Phase 7 computes AUC from the deployed
  artifact).
- Accumulates in `CHURN_SCORES` keyed by `score_run_id`. Set `experiment.score_run_id` first.

Warehouse inference is used because it needs no compute pool and the scoring set is small (open
renewals in one horizon window). For very large populations, or to run asynchronously, the registry's
`run_batch` job API on a compute pool is the alternative; load the `machine-learning` skill for it.

## Step 2: evidence and reasons, from the model's own window

Evidence shown next to a score must be evidence the model could have seen: interactions before
`as_of_date`, flagged, **grounded**, and not resolved. `ACCOUNT_EVIDENCE` orders items by intent then
recency; `ACCOUNT_REASONS` ranks reasons by mentions.

If preflight decided evidence must be redacted for the at-risk audience, apply it here before the
array is built:

```sql
-- Inside ACCOUNT_EVIDENCE, replace i.evidence_quote with:
AI_REDACT(i.evidence_quote)
```

Verify `AI_REDACT`'s signature and categories with `cortex search docs "AI_REDACT"` before adding it,
and count the calls in the gate estimate -- it runs once per evidence item.

## Step 3: the deliverable

`AT_RISK_ACCOUNTS` columns:

| Column | Meaning |
|---|---|
| `p_churn` | registered model probability; never NULL |
| `risk_band` | HIGH / WATCH / LOW from `thresholds` |
| `arr`, `arr_at_risk_expected` | ARR and `arr * p_churn`; the latter valid only if calibration was checked |
| `top_reasons` | up to three reason codes by mention count before the cutoff |
| `evidence` | array of `{interaction_id, created_at, channel, reasons, intent, quote}` |
| `risk_basis` | `TEXT_AND_USAGE` or `USAGE_ONLY` -- the latter is real risk with nothing said |
| `narrative` | `AI_SUMMARIZE_AGG` over the cited quotes, top `narrative_top_n` by expected ARR at risk |
| `review_status`, `reviewed_by`, `reviewed_at` | defaulted for a later CSM workflow; nothing here writes them |

The narrative is built only from quotes already on the row, so it cannot introduce claims the
evidence does not support. Gate its cost: one `AI_SUMMARIZE_AGG` group per account, bounded by
`narrative_top_n`.

If `AT_RISK_ACCOUNTS` needs restricting (preflight posture decision), apply the row access or masking
policy immediately after creating it, before inserting rows.

## Step 4: closed-churn reasons

`CHURN_REASONS_CLOSED` covers churned renewals with text from a year before to 30 days after renewal,
including the post-cutoff notices and exit surveys -- deliberately (best-practices 4). `is_post_cutoff`
marks which mentions the model could not have used. `CHURNED_ARR_BY_REASON` attributes each churned
account's ARR to its most-mentioned reason once (best-practices 26).

Put the text-derived reason next to the CRM cancel picklist for the same accounts: the share of
"Other" the text resolves is often the first thing a CS leader asks about.

```sql
WITH mentions AS (
    SELECT account_id, reason_code, COUNT(*) AS n, MAX(created_at) AS last_at
    FROM CHURN_REASONS_CLOSED GROUP BY 1, 2
),
text_primary AS (
    SELECT account_id, reason_code AS text_reason
    FROM mentions
    QUALIFY ROW_NUMBER() OVER (PARTITION BY account_id ORDER BY n DESC, last_at DESC) = 1
)
SELECT COALESCE(a.{{CRM_CANCEL_REASON_COL}}, '(blank)') AS crm_reason, t.text_reason, COUNT(*) AS accounts
FROM text_primary t
JOIN {{ACCOUNT_TABLE}} a USING (account_id)
GROUP BY 1, 2 ORDER BY 3 DESC;
```

The CRM reason column is outcome-derived: fine here, in analytics about churn that already happened;
forbidden as a model feature.

## Step 5: operationalize (definitions only)

`sql/02_operationalize.sql` creates:

- `INTERACTIONS_STREAM` (append-only) on the interactions source. For multiple source tables, one
  stream each, drained into the same inbox.
- `INTERACTIONS_INBOX` -- the stream is drained here by `INSERT`, which advances the offset; rows wait
  until extracted, so a failed AI call delays them rather than losing them.
- `REFRESH_INTERACTION_SIGNALS(MAX_BATCH)` -- the same prompts, categories literal and grounding check
  as the evaluated batch path, writing under the stable `experiment.prod_run_id`. Idempotent on
  `interaction_id`.
- `REFRESH_SIGNALS_TASK`, **created suspended**. `MAX_BATCH` caps each run's AI spend.
- `CHURN_SIGNALS_SV` semantic view over `AT_RISK_ACCOUNTS` and `CHURN_REASONS_CLOSED`.

The re-score task wraps feature rebuild (SCORE spine) and scoring in a procedure; keep it suspended
too. Load the `snowflake-tasks` skill for task graphs, failure notification and schedules.

**Edited interactions.** The stream is append-only by design. A ticket edited after extraction keeps
its first extraction. If the customer's ticketing sync rewrites rows (update-in-place of a growing
thread), switch to a standard stream and decide explicitly whether to re-extract on update -- it
re-bills those rows.

**Resuming tasks** is a separate, confirmed step after Phase 7:

```sql
ALTER TASK REFRESH_SIGNALS_TASK RESUME;
```

State the expected volume per run and the measured credits per 1K interactions from Phase 7 when
asking.

### The CoWork agent

Delegate agent creation to the **`agent-studio`** skill; give it:

- the semantic view `CHURN_SIGNALS_SV` as the Cortex Analyst tool;
- instructions: always filter to the latest `score_run_id`; cite `interaction_id` and quote when
  explaining an account; say "usage-only risk, no customer statements on file" for `USAGE_ONLY` rows;
  never sum `arr_lost` across reason rows; describe `arr_at_risk_expected` as probability-weighted and
  conditional on calibration;
- optionally a Cortex Search service over `INTERACTION_SIGNALS` evidence quotes for "what did customers
  say about X" questions.

Sample questions to verify it with: "Which HIGH accounts renew next quarter and why?", "How much ARR
churned last year by reason?", "What did <account> say about pricing before renewal?", "Which at-risk
accounts mention a competitor?".

## Gate verification

Section 6 of `01_score_and_rank.sql`:

- band distribution with ARR and expected ARR at risk; `null_scores` must be 0;
- `usage_only_rows` reported, not hidden;
- `bad_citations` must be 0 (every cited interaction exists and predates `as_of_date`).

Plus, for the semantic view:

```sql
SHOW SEMANTIC VIEWS LIKE 'CHURN_SIGNALS_SV';
DESCRIBE SEMANTIC VIEW CHURN_SIGNALS_SV;
```

Record every object in `created_objects` (tables, views, semantic view, stream, procedure, tasks),
`phases.score: done`.
