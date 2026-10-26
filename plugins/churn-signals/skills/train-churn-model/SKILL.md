---
name: train-churn-model
description: "Train, evaluate and register the churn model in the Snowflake ML Model Registry. Trains XGBoost on the point-in-time feature table three ways -- usage-only baseline, text-only, and combined -- on a time split, reports AUC with bootstrap intervals, PR-AUC, Brier score and decile lift on TEST, states the AUC uplift from text features plainly, optionally contrasts a deliberately leaky sandbox model, persists every experiment to MODEL_EXPERIMENTS, and logs the combined model with an explicit predict_proba signature (P_RETAINED, P_CHURN), metrics via set_metric, and a WAREHOUSE target so it can be batch-scored in SQL. Refuses to run unless the leakage audit passed for this feature version. Phase 5 of the churn-signals build. Triggers: train churn model, Snowflake ML churn, register churn model, model registry, retrain, usage vs text model."
parent_skill: churn-signals
---

# Train and register the churn model

## Hard precondition

Read `churn-project.yml`. Proceed only if:

- `leakage.audit_passed: true`, and
- `leakage.audit_feature_version == features.feature_version`.

Otherwise stop and send the user to `build-account-features`. Do not offer to "train anyway to see".
A leaked model's numbers, once seen, anchor everyone's expectations.

## Why three models

The play's claim is that the text in tickets, surveys, emails and notes predicts churn **beyond** the
usage data the customer already has. That claim is tested, not asserted:

| Feature set | Columns | Answers |
|---|---|---|
| `usage_only` | account + usage | what a usage-based health score already gets |
| `text_only` | account + text signals | how much the text carries by itself |
| `combined` | all | the registered model |

Same rows, same split, same hyperparameters. The headline is `combined - usage_only` AUC, with both
intervals. If the uplift interval includes zero, the honest finding is that text did not add
measurable ranking power on this data -- and the reason analytics may still be worth the build. Say so.

## Model choice

XGBoost, shallow trees (`max_depth=3`), 300 rounds at 0.05 learning rate, `scale_pos_weight` for the
class imbalance. Reasons:

- Tabular, mixed-scale features with missing usage: trees handle NULLs and monotonic-ish count features
  without scaling or imputation.
- Built-in registry support for XGBoost (`predict`, `predict_proba` target methods) and Shapley-based
  explainability, so per-account drivers can be shown.
- Shallow trees on a few hundred training rows resist overfitting better than deep ones.

`scale_pos_weight` helps ranking and inflates probabilities. Phase 7 checks calibration before anyone
sums expected ARR (best-practices 23).

Alternative when the customer wants SQL-only and no Python: `SNOWFLAKE.ML.CLASSIFICATION` trains a
classifier from a table in SQL. It does not give the three-way comparison as cleanly or an explicit
signature, and this plugin does not ship it; if chosen, load the `machine-learning` skill and keep the
same spine, split and leakage audit.

## Run it

Where it runs was settled at preflight. The script is `scripts/train_churn_model.py`.

```bash
pip install snowflake-ml-python snowflake-snowpark-python xgboost scikit-learn pandas

python scripts/train_churn_model.py \
  --connection <snow connection name> \
  --database <target.database> --schema <target.schema> \
  --model-name <model.name> --version <model.version> \
  --feature-version <features.feature_version> \
  --experiment-id <experiment.experiment_id> \
  [--leaky-demo]          # sandbox only, needs ACCOUNT_FEATURES_LEAKY
  [--no-register]         # evaluate without creating a registry version
```

Gate before running: name what it creates -- `MODEL_EXPERIMENTS` (if absent), and registry model
`<name>` version `<version>` unless `--no-register`. No AI function calls; compute is the Python
process plus a warehouse for the data pull and registry logging.

For a large real feature table, do not pull it to a laptop. Run the same script logic in a Snowflake
Notebook on Container Runtime and load the `machine-learning` skill for compute pool setup.

### What the script enforces

- Reads only `SPLIT IN ('TRAIN','TEST')`; `EMBARGO` and `SCORE` rows never train.
- Refuses if `ACCOUNT_FEATURES` holds a different `feature_version` than requested.
- Refuses forbidden columns as features (`CHURNED`, `SPLIT`, ids, dates, audit columns).
- Refuses if TRAIN has fewer than 10 churners.
- Warns if combined AUC exceeds 0.97 -- best-practices 9.
- Logs every feature set's metrics to `MODEL_EXPERIMENTS` (append, keyed by experiment) so runs
  compare. The leaky demo is logged as `LEAKY_DEMO` and is never registered.

### Registry details

- **Explicit signature.** `predict_proba` is logged with an inferred signature whose output columns are
  named `P_RETAINED` and `P_CHURN`, so SQL reads `:P_CHURN` rather than a guessed
  `output_feature_N` key.
- `target_platforms=["WAREHOUSE"]` with `conda_dependencies=["xgboost","scikit-learn"]` so warehouse
  inference works via `MODEL(...)!PREDICT_PROBA`.
- `sample_input_data` is passed as background data for explainability. The script falls back to
  signature-only if the installed `snowflake-ml-python` rejects passing both, and prints that it did.
- Metrics on the version via `set_metric`: test AUC and interval, PR-AUC, Brier, top-decile lift and
  capture, uplift versus usage-only, and the feature list.
- Version names are immutable. Bump `model.version` every run; append to `model.registered_versions`.

## Gate verification

Show:

1. The script's printed table: rows and churners per split; AUC, CI95, PR-AUC, top-decile lift for
   each feature set; the uplift line; the leaky-demo AUC when run.
2. The registry entry:

```sql
SHOW MODELS LIKE '<MODEL_NAME>' IN SCHEMA <db>.<schema>;
SHOW VERSIONS IN MODEL <MODEL_NAME>;
SHOW FUNCTIONS IN MODEL <MODEL_NAME> VERSION <VERSION>;   -- confirm PREDICT_PROBA inputs and P_CHURN output
```

3. The experiment log:

```sql
SELECT experiment_id, feature_set, model_version,
       metrics:auc::FLOAT AS auc, metrics:auc_ci95 AS ci95, metrics:top_decile_lift::FLOAT AS lift
FROM MODEL_EXPERIMENTS ORDER BY run_at DESC, feature_set;
```

Present it in this order, and in these words if the numbers support them: the usage-only baseline,
the combined model, the difference with its uncertainty, and -- on the sandbox -- the leaky model as
"what this would have looked like if we had let the answer in".

Record `created_objects.models`, `model.registered_versions`, `phases.model: done`. Set
`model.default_version` only when the user confirms this version should be used for scoring.

## Explaining individual scores

Registry explainability for XGBoost computes Shapley values per row. Check availability with
`SHOW FUNCTIONS IN MODEL <name> VERSION <v>` (an `EXPLAIN` method is listed when enabled), then call it
the same way as `PREDICT_PROBA`, with named arguments. Use it to show a CSM *which features* drove a
score; use the cited evidence on the at-risk row to show *what the customer said*. They answer
different questions and both belong on the account view.

## Retraining

Retrain when the taxonomy or features change (new `feature_version`, new audit), when a new quarter of
outcomes lands, or when Phase 7 monitoring shows lift decaying. Each retrain is a new version and a new
`experiment_id`; compare against the current default before switching scoring to it.
