# Diagnosing a churn-signals build that is not producing what you expect

Work these in order. The first two are the most common and the most dangerous, because both make
the output look *better* than it is.

## 1. AUC is suspiciously high -- assume leakage first

**Symptom:** combined-model AUC above roughly 0.95, a top-decile lift that captures nearly every
churner, or one feature dominating importance.

Real churn models on real data are rarely that good. A near-perfect model is almost always reading
the answer. Do not celebrate it; audit it.

```sql
-- Re-run the audit. Every row must be zero.
-- build-account-features/sql/02_leakage_audit.sql
```

Then check, in order:

- **A post-outcome column in the features.** `CRM_STATUS`, `CANCEL_REASON`, `CHURN_RISK_FLAG`,
  `CLOSED_LOST_DATE`, a CSM health field updated after notice. Grep the feature table's columns and
  check every account-table column used against `sources.accounts.outcome_derived_cols`.
- **Text after the cutoff.** The non-renewal notice, offboarding ticket and exit survey are
  explicitly about churn. If `created_at` is a *load* timestamp rather than when the customer wrote it,
  a backfilled export can land months of old tickets "before" the cutoff -- or real pre-cutoff ones
  after it. Check `MAX(created_at)` against `MAX(loaded_at)` on the source.
- **Usage after the cutoff.** A "last 3 months" window anchored on the renewal date, or including
  the partial current month, reads the post-churn zero as signal.
- **Label known at prediction time.** If notice is often given more than `horizon_days` before
  renewal, those rows were "predicted" after the customer already said they were leaving.
  `outcome_known_at_prediction_time` catches this; the fix is a longer horizon or excluding
  notice-before-cutoff rows from evaluation, not ignoring the check.
- **Random instead of time split, or no embargo.** Accounts renew on cycles; a random split lets the
  model see the future.

On the sandbox, `03_leaky_features_demo.sql` plus `--leaky-demo` shows exactly this failure on known
data. If the honest model's numbers look like the leaky demo's, something leaked.

## 2. Everything is flagged -- or the distractors are

**Symptom:** a large share of routine tickets carry a reason; CSMs say the queue is noise.

```sql
SELECT stage, total_rows, failed_rows, detail
FROM PIPELINE_QUALITY_LOG WHERE run_id = '<run_id>' ORDER BY logged_at;

SELECT ARRAY_SIZE(reason_codes) > 0 AS flagged, overall_sentiment, COUNT(*)
FROM INTERACTION_SIGNALS WHERE run_id = '<run_id>' GROUP BY 1, 2 ORDER BY 3 DESC;
```

Causes, most likely first:

- **No `'no retention risk'` category.** In `output_mode: 'multi'`, a classifier with no sanctioned
  "nothing here" label assigns *something* to every row. Confirm the NONE label is in the rendered
  categories literal.
- **Negative sentiment read as churn risk.** An angry bug report that was fixed the same day is not
  a retention risk. Check `concern_resolved` and the distractor false-flag rate in Phase 7.
- **Label descriptions missing or overlapping.** "price or value concerns" versus "budget cuts or
  business change" is the most common confusion; the descriptions must say what distinguishes them.
  Check the reason confusion query in `evaluate-churn-accuracy`.
- **Boilerplate.** Email signatures, legal footers and survey question text that mention "cancel"
  or "competitor". Strip them in `STG_INTERACTIONS`, tuned to this customer's templates.

## 3. Nothing is flagged, or far less than expected

```sql
SELECT COUNT(*) AS rows,
       COUNT_IF(classify_failed) AS classify_failed,
       COUNT_IF(ARRAY_SIZE(reason_codes) = 0 AND NOT classify_failed) AS no_reason
FROM INTERACTION_SIGNALS WHERE run_id = '<run_id>';

SELECT detail:unmapped_labels FROM PIPELINE_QUALITY_LOG
WHERE run_id = '<run_id>' AND stage = 'classify';
```

- **Unmapped labels.** The taxonomy table was edited after the categories literal was rendered, so
  returned labels no longer join to a code and vanish. `unmapped_labels` must be zero. Re-render.
- **Case mismatch.** AI_CLASSIFY categories are case sensitive; the join normalizes with
  `LOWER(TRIM())`, but a hand-edited literal with different wording does not match at all.
- **Classify failures read as "no risk".** With `return_error_details => TRUE` a failure is visible
  in `response:error`. Without it, a NULL is indistinguishable from a clean row. Check which form
  the run used.
- **Inputs over the AI_SENTIMENT window.** AI_SENTIMENT is documented as optimized for 2,048 tokens
  and **errors** above it. Long email threads and call transcripts hit this. Window them (see
  best-practices) rather than dropping them.
- **Staging dropped the text.** Compare `source_rows`, `too_short_or_null`, `staged_rows` from the
  staging gate. A text column that is mostly HTML or a VARIANT payload needs extraction first.

## 4. The model ignores the text features

**Symptom:** combined AUC is no better than usage-only.

That can be a true finding -- report it, do not tune it away. Before concluding, check:

```sql
SELECT split,
       AVG(n_risk_interactions) AS avg_risk_mentions,
       COUNT_IF(n_interactions = 0) / COUNT(*) AS share_no_text
FROM ACCOUNT_FEATURES GROUP BY 1;
```

- **Coverage.** If most accounts have no interactions in the lookback window, text cannot help most
  rows. Widen `lookback_days`, or add channels (call notes and survey verbatims usually cover
  accounts that never file tickets).
- **Account join.** Interactions keyed by contact email or ticket org ID that does not map cleanly to
  the CRM account. Check the share of interactions that join to an account at all.
- **Silent churners.** In the sandbox, the `SILENT` cohort is designed to be text-invisible; the
  cohort capture query shows text helping `VOCAL` churners and not `SILENT` ones. On real data the
  proportion is unknown and is itself a finding.

## 5. Reasons look wrong to the business owner

Do not reach for the prompt first.

- **Taxonomy fit.** If the owner keeps saying "that's really about X", X is missing from the taxonomy
  or merged into another label. Fix the taxonomy, bump `prompt_version`, re-extract a sample, and
  compare experiments.
- **Reason-confusion matrix.** Systematic confusion between two labels is a description problem.
- **Evidence quote.** Read the cited quote. If the quote supports the reason, the label is right and
  the owner's mental model differs -- which is worth discussing, not overriding.

## 6. Evidence quotes missing or ungrounded

```sql
SELECT COUNT_IF(ARRAY_SIZE(reason_codes) > 0) AS flagged,
       COUNT_IF(evidence_failed)               AS evidence_failed,
       COUNT_IF(evidence_grounded = FALSE)     AS ungrounded,
       COUNT_IF(evidence_grounded)             AS grounded
FROM INTERACTION_SIGNALS WHERE run_id = '<run_id>';
```

- **Ungrounded quotes** mean the model paraphrased. Keep the verbatim instruction, use `temperature: 0`,
  and if the rate is material, use a stronger GA model for the evidence stage. Never relax the
  grounding check to make the number look better.
- **Whitespace mismatches.** The grounding check normalizes whitespace on both sides; HTML entities or
  smart quotes in the source do not normalize. Clean them in staging.

## 7. Scores look plausible but SQL AUC disagrees with the training script

The deployed artifact is not the one that was evaluated, or features are fed in the wrong order.

- `SHOW FUNCTIONS IN MODEL <name> VERSION <v>` -- confirm the input names and that the scoring SQL
  passes every feature **by name**.
- Confirm `CHURN_SCORES.model_version` is the version the script registered.
- Confirm `ACCOUNT_FEATURES.feature_version` was the same for training and scoring.

## 8. Cost is higher than expected

```sql
SELECT stage, total_rows FROM PIPELINE_QUALITY_LOG WHERE run_id = '<run_id>';
```

- **Evidence stage running on too many rows.** It is gated on the classifier; a high flag rate (see
  #2) multiplies its cost. Fix precision first.
- **Re-extraction.** A view or `table` materialization over an AI call re-bills on every read; a
  rebuilt `STG_INTERACTIONS` with new ids defeats the incremental key. Check that the raw tables hold
  one row per `(run_id, interaction_id)`.
- **Narratives.** `AI_SUMMARIZE_AGG` runs per account; keep `narrative_top_n` bounded.
