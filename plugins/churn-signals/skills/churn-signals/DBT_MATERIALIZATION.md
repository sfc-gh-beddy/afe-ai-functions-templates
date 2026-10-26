# Materializing the pipeline as a dbt project

The pipeline can be plain SQL (the files under each skill's `sql/`) or a **dbt project deployed into
Snowflake**. dbt is the better default once the build outlives the first demo: version control,
lineage, reproducible experiment runs, and -- most important here -- **tests that fail the build when
the leakage rules are broken**.

**Delegate the dbt mechanics.** This file covers what the models are and why they are materialized
the way they are. For `snow dbt deploy`, `EXECUTE DBT PROJECT`, project versioning, scheduling and CI,
load the **`dbt-projects-on-snowflake`** skill. Model training and registry logging stay in Python
(`train-churn-model`); dbt owns everything up to `ACCOUNT_FEATURES` and everything after scoring.

## Phase-to-model mapping

```
staging/       stg_interactions          view     union of ticket/survey/email/note sources
               stg_accounts              view
               stg_renewal_outcomes      view
               stg_usage_monthly         view
               reason_taxonomy           seed     the agreed taxonomy, versioned in git

extraction/    sig_sentiment_raw         incremental   AI_SENTIMENT
               sig_classify_raw          incremental   AI_CLASSIFY
               sig_classified            incremental   label -> code parse
               sig_evidence_raw          incremental   AI_COMPLETE (flagged rows only)
               interaction_signals       incremental

features/      feature_spine             table
               feat_text                 table
               feat_usage                table
               account_features          table

-- training + registry: Python, outside dbt --

scoring/       churn_scores              incremental   MODEL(...)!PREDICT_PROBA
               account_evidence          table
               at_risk_accounts          incremental
               churn_reasons_closed      view
               churned_arr_by_reason     view

evaluation/    eval_reason_metrics       incremental
               eval_model_metrics        incremental
```

## Materialization choices

| Layer | Materialization | Reason |
|---|---|---|
| `staging` | `view` | Renaming and type coercion only. |
| `extraction` | `incremental`, `unique_key = ['run_id','interaction_id']` | These call AI functions. A view would **re-bill inference every time anything selects from it**. Incremental also lets each experiment's raw responses accumulate for comparison. |
| `features` | `table` | Deterministic SQL over extraction output; rebuilt per feature version. Cheap, and a table is what the training script and the leakage tests read. |
| `scoring` | `incremental`, `unique_key = ['score_run_id','account_id']` | Score runs accumulate so a CSM can see how an account's probability moved week to week. |
| `evaluation` | `incremental` keyed on `experiment_id` | So experiments compare side by side rather than replacing each other. |

### The incremental filter on extraction is the cost control

```sql
{{ config(materialized='incremental', unique_key=['run_id','interaction_id'],
          incremental_strategy='merge', on_schema_change='append_new_columns') }}

SELECT '{{ var("run_id") }}' AS run_id,
       '{{ var("experiment_id") }}' AS experiment_id,
       interaction_id,
       AI_CLASSIFY(...) AS response,
       CURRENT_TIMESTAMP() AS scored_at
FROM {{ ref('stg_interactions') }} s
{% if is_incremental() %}
  -- Only rows this run has not classified. Without this, every dbt run
  -- re-classifies the whole history.
  WHERE NOT EXISTS (SELECT 1 FROM {{ this }} t
                    WHERE t.run_id = '{{ var("run_id") }}' AND t.interaction_id = s.interaction_id)
{% endif %}
```

## Project configuration

```yaml
# dbt_project.yml
name: churn_signals
version: 1.0.0
profile: churn_signals

vars:
  run_id: "manual"
  score_run_id: "manual"
  experiment_id: "exp_001"
  experiment_name: "baseline"
  prompt_version: "v1"
  feature_version: "f1"
  evidence_model: "claude-haiku-4-5"     # verify GA + region at preflight
  horizon_days: 90
  lookback_days: 180
  test_fraction: 0.30
  model_name: "CHURN_MODEL"
  model_version: "V1"
  min_reason_micro_f1: 0.0
  max_distractor_flag_rate: 1.0

models:
  churn_signals:
    staging:    { +materialized: view }
    extraction: { +materialized: incremental }
    features:   { +materialized: table }
    scoring:    { +materialized: incremental }
    evaluation: { +materialized: incremental }
```

Every run-identifying var is **selected into the output rows**, not just used in filters.

## Tests as quality gates

The leakage rules map directly onto singular tests. These are the reason to choose dbt.

```sql
-- tests/assert_no_text_after_cutoff.sql
SELECT account_id, as_of_date, max_text_ts_used
FROM {{ ref('account_features') }}
WHERE max_text_ts_used >= as_of_date::TIMESTAMP_NTZ
```

```sql
-- tests/assert_usage_months_complete_before_cutoff.sql
SELECT account_id, as_of_date, max_usage_month_used
FROM {{ ref('account_features') }}
WHERE DATEADD(month, 1, max_usage_month_used) > as_of_date
```

```sql
-- tests/assert_label_not_known_at_prediction.sql
SELECT f.account_id, f.as_of_date
FROM {{ ref('account_features') }} f
JOIN {{ ref('stg_renewal_outcomes') }} o
  ON o.account_id = f.account_id AND o.renewal_date = f.renewal_date
WHERE f.split IN ('TRAIN','TEST')
  AND (o.recorded_at <= f.as_of_date::TIMESTAMP_NTZ
       OR (o.notice_date IS NOT NULL AND o.notice_date <= f.as_of_date))
```

```sql
-- tests/assert_no_outcome_columns_in_features.sql
SELECT column_name
FROM {{ target.database }}.information_schema.columns
WHERE table_schema = UPPER('{{ target.schema }}')
  AND table_name = 'ACCOUNT_FEATURES'
  AND REGEXP_LIKE(column_name, '.*(STATUS|CANCEL|CHURN_DATE|CHURN_REASON|NOTICE|TERMINAT|OUTCOME).*', 'i')
```

```sql
-- tests/assert_evidence_is_grounded_and_precutoff.sql
SELECT t.account_id, f.value:interaction_id::STRING AS cited
FROM {{ ref('at_risk_accounts') }} t, LATERAL FLATTEN(input => t.evidence) f
LEFT JOIN {{ ref('interaction_signals') }} i
  ON i.interaction_id = f.value:interaction_id::STRING
WHERE i.interaction_id IS NULL
   OR i.created_at >= t.as_of_date::TIMESTAMP_NTZ
   OR NOT i.evidence_grounded
```

```sql
-- tests/assert_reason_accuracy_not_regressed.sql   (sandbox / labeled sample)
SELECT experiment_id, micro_f1, distractor_flag_rate
FROM {{ ref('eval_reason_metrics') }}
WHERE experiment_id = '{{ var("experiment_id") }}'
  AND (micro_f1 < {{ var('min_reason_micro_f1') }}
       OR distractor_flag_rate > {{ var('max_distractor_flag_rate') }})
```

Column tests on `at_risk_accounts`: `p_churn` not_null; `risk_band` accepted_values
`['HIGH','WATCH','LOW']`; `risk_basis` accepted_values `['TEXT_AND_USAGE','USAGE_ONLY']`.

Start the regression vars permissive (0.0 / 1.0) on the first run, then tighten to just past the
achieved figures so future regressions fail the build.

## Platform gotchas

1. **Doubled schema names.** dbt concatenates a `+schema:` with the target schema. Override
   `generate_schema_name`:
   ```sql
   {% macro generate_schema_name(custom_schema_name, node) -%}
       {{ custom_schema_name | trim if custom_schema_name else target.schema }}
   {%- endmacro %}
   ```
2. **No `authenticator: externalbrowser`** in a profile used by dbt on Snowflake.
3. **Use the error-returning forms in models over tables.** `AI_CLASSIFY(..., TRUE)` and
   `AI_SENTIMENT(..., TRUE)` return `{value, error}` objects so one bad row neither aborts the model nor
   hides as a NULL that looks like "no signal". For `AI_COMPLETE`, use `TRY_COMPLETE` semantics where a
   hard error would abort the batch.
4. **Never commit `profiles.yml`; never default the role to `ACCOUNTADMIN`.**
5. **`ARGS` on `EXECUTE DBT PROJECT` is a dbt CLI string**, e.g.
   `ARGS = 'run --select extraction --vars {"run_id": "r042"}'`. Verify supported flags through the
   `dbt-projects-on-snowflake` skill.
6. **`MODEL(...)!PREDICT_PROBA` inside a dbt model** works like any SQL, but the model version must
   exist before `dbt run`. Pin `model_version` as a var; never call `MODEL(name)` without a version in
   a model -- the default version can change under you.

## Choosing plain SQL instead

Plain SQL is right for a time-boxed proof of value or a team without a dbt practice. Record
`materialization.mode: sql`. What is given up: version control on transformations, lineage, and the
build-failing leakage tests above -- which then have to be run by hand from `02_leakage_audit.sql`
before every training run. Say that plainly.
