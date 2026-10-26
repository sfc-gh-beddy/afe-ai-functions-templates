---
name: build-account-features
description: "Build point-in-time account features for the churn model from extracted text signals, monthly usage and ARR, and run the label-leakage audit that gates training. One spine of (account, as_of_date) rows -- TRAIN/TEST from observed renewals at renewal_date minus the horizon, split by time with an embargo, and SCORE rows for open renewals as of today -- with every feature computed strictly before as_of_date and audit columns carried on each row. The audit checks text and usage after the cutoff, labels known at prediction time, split overlap, outcome-derived columns, and single-feature separation via tie-aware AUC. Includes a sandbox-only deliberately leaky feature table for contrast. Phase 4 of the churn-signals build. Triggers: churn features, point in time features, leakage check, label leakage, feature table for churn model."
parent_skill: churn-signals
---

# Build point-in-time account features

This phase decides whether the model is honest. Every rule in best-practices 1-10 is enforced here.

## The shape

```
FEATURE_SPINE   (account_id, as_of_date, renewal_date, churned, split)
                  TRAIN / EMBARGO / TEST   observed renewals, as_of = renewal - horizon
                  SCORE                    open renewals within the horizon, as_of = score date
      |
      +-- FEAT_TEXT    INTERACTION_SIGNALS where created_at in [as_of - lookback, as_of)
      +-- FEAT_USAGE   usage months complete before as_of
      +-- accounts     explicit allowlist: ARR, segment, tenure
      v
ACCOUNT_FEATURES (+ max_text_ts_used, max_usage_month_used audit columns)
```

Training and scoring use the same SQL; only the spine rows differ. Do not write a second scoring
feature query.

## Before running

Confirm in `churn-project.yml`:

- `prediction.horizon_days` -- how far ahead of renewal the CSM needs to know. Ask the owner what lead
  time a save play needs (an executive sponsor meeting, a product escalation, a commercial concession)
  and how much notice the contract requires. A horizon shorter than the notice period means many
  churners have already told you by `as_of_date`.
- `prediction.lookback_days` -- text window. Default 180.
- `prediction.test_fraction` -- default 0.30 of renewals by time.
- `features.feature_version` -- bump on any feature change.
- The extraction `run_id` the features are built from.

Substitute into `sql/01_build_features.sql`. Column placeholders come from `sources.*`
(`{{OUTCOME_COL}}` / `{{CHURN_VALUE}}` from `sources.outcomes`). The churn definition (full non-renewal
versus downgrade) must match what preflight recorded. The audit and scoring SQL also read
`renewal_date`, `notice_date` and `recorded_at` from the outcome table; on real data alias them in a
staging view if the names differ.

## Feature catalogue

| Group | Feature | Built from |
|---|---|---|
| Account | `arr`, `seg_*`, `tenure_days` | accounts table; tenure measured at `as_of_date` |
| Usage | `util_last3`, `util_prior3`, `util_trend` | active users / seats, months 1-3 and 4-6 before the cutoff month |
| Usage | `logins_ratio`, `usage_months_available` | logins last 3 vs prior 3; coverage, so missing usage is visible |
| Text volume | `n_interactions`, `n_risk_interactions` | all, and reason-flagged, in the lookback window |
| Text reasons | `n_reason_<code>` (8) | per-reason counts |
| Text intent | `n_intent_high`, `n_intent_medium`, `max_intent_score` | AI_COMPLETE `churn_intent` |
| Text state | `n_unresolved_risk`, `days_since_last_risk` | flagged and not `concern_resolved`; recency |
| Sentiment | `share_negative`, `n_neg_support`, `n_neg_price` | AI_SENTIMENT overall and aspects |
| Competition | `competitor_mentioned` | AI_COMPLETE `competitor_named` |

Text features are **zero-filled**: an account with no interactions has zero risk mentions, which is
information. Usage features are left NULL when there is no usage, and `usage_months_available` says
so; XGBoost handles missing values natively, and imputing zero would make "no data" look like "no
usage".

**ARR caveat.** The account table usually holds current ARR. If an account downgraded at renewal, the
current value already reflects the outcome. If billing history exists, use ARR as of `as_of_date`;
otherwise record `arr_history_available: false` and mention it in the readout.

## Run it

1. Gate: name the tables (`FEATURE_SPINE`, `FEAT_TEXT`, `FEAT_USAGE`, `ACCOUNT_FEATURES`). No AI calls.
2. Run `sql/01_build_features.sql`. Show the per-split summary it ends with.
3. Run `sql/02_leakage_audit.sql`. Add every column in `sources.accounts.outcome_derived_cols` to the
   forbidden-column pattern first.
4. **Only if every check returns zero and no single feature is flagged**, set
   `leakage.audit_passed: true`, `leakage.audit_feature_version`, `leakage.audit_run_on`.
5. Sandbox only, optional: run `sql/03_leaky_features_demo.sql` to build `ACCOUNT_FEATURES_LEAKY` for the
   Phase 5 contrast. Never against customer data.

## Reading the audit

| Check | Non-zero means | Fix |
|---|---|---|
| `text_after_cutoff` | a join used `<=` or the wrong timestamp | strict `<` on the said-at column |
| `usage_month_not_complete_before_cutoff` | partial or post-cutoff month used | the `DATEADD(month, 1, month) <= as_of` filter |
| `outcome_known_at_prediction_time` | notice or recording precedes the prediction | longer horizon; or exclude and state it |
| `row_in_train_and_test` | split logic broken | rebuild the spine |
| `train_label_after_first_test_prediction` | embargo missing | rebuild the spine |
| forbidden column listed | an outcome-derived field is in the table | remove from the allowlist |
| single-feature AUC flagged | a feature nearly separates labels alone | treat as a leak; trace its source |

On the sandbox, the honest table should pass. If `outcome_known_at_prediction_time` fires, notice
dates (15-45 days before renewal in the generator) are inside the horizon -- check `HORIZON_DAYS`
was substituted consistently in seed and features.

A flagged single feature is not automatically a leak -- a genuinely strong signal exists in some
businesses -- but it is presumed one until its lineage is traced to data that existed before the
cutoff. Say what was traced.

## Gate verification

```sql
SELECT split, COUNT(*) AS rows, SUM(churned) AS churners, ROUND(AVG(churned), 4) AS churn_rate,
       MIN(as_of_date) AS min_as_of, MAX(as_of_date) AS max_as_of
FROM ACCOUNT_FEATURES GROUP BY 1 ORDER BY 1;

-- Text coverage: how much of the population can text help at all?
SELECT split,
       ROUND(AVG(IFF(n_interactions > 0, 1, 0)), 4)        AS share_with_text,
       ROUND(AVG(IFF(n_risk_interactions > 0, 1, 0)), 4)   AS share_with_risk_text
FROM ACCOUNT_FEATURES GROUP BY 1 ORDER BY 1;
```

Report the TRAIN and TEST churner counts. Under about 30 churners in TEST, say that AUC intervals will
be wide. Record tables in `created_objects`, `phases.features: done`.
