# Project state contract -- `churn-project.yml`

Every skill in this plugin reads and writes one file: `churn-project.yml` in the working directory.
It makes the build resumable and stops any phase from re-asking a question an earlier phase settled.

## Rules

1. **Read it first.** Before asking the user anything, read `churn-project.yml`. If a value is there,
   use it.
2. **Write after every phase.** Update `phases` and `created_objects` the moment a phase finishes.
3. **Never guess a value into it.** Unknown means absent. An absent key means "ask"; a present key
   means "settled".
4. **Object names are recorded, not reconstructed.** Later phases read names from `created_objects`.
5. **`customer_label` is a display string only.** Never used for naming or logic.
6. **`materialization.mode` is settled once, at preflight, and obeyed.** No mixing dbt and plain SQL.
7. **Bump `experiment.experiment_id` before any run you want kept separately, `prompt_version` on any
   prompt or taxonomy change, `features.feature_version` on any feature change, and `model.version`
   on every training run.** Registry versions are immutable; reusing a version name fails.
8. **`prediction.horizon_days` and `prediction.lookback_days` are fixed per model version.** A model
   trained at a 90-day horizon scored with features built at 60 days is a different, unevaluated model.
9. **`leakage.audit_passed` gates Phase 5.** It is written only by `build-account-features` after
   `02_leakage_audit.sql` returns all zeros, with the date and feature version it applies to.

## Schema

```yaml
# Display label only.
customer_label: "Example SaaS Co"

target:
  database: CHURN_SIGNALS
  schema: PIPELINE
  eval_schema: PIPELINE_EVAL        # answer key; sandbox only
  warehouse: CHURN_WH

# Source mappings, discovered and confirmed at preflight. A wrong
# account_col joins one customer's complaints to another customer's renewal --
# the worst failure available here, and it raises no error.
sources:
  interactions:
    table: RAW.SUPPORT.INTERACTIONS
    id_col: INTERACTION_ID
    account_col: ACCOUNT_ID
    text_col: BODY
    channel_col: CHANNEL             # or a constant per source table, see system-of-record
    created_col: CREATED_AT          # when the customer said it, not when it was loaded
    extra_tables: []                 # additional tables unioned in staging (surveys, emails, notes)
  accounts:
    table: RAW.CRM.ACCOUNTS
    id_col: ACCOUNT_ID
    name_col: ACCOUNT_NAME
    owner_col: CSM_NAME
    arr_col: ARR_USD
    segment_col: SEGMENT
    contract_start_col: CONTRACT_START_DATE
    renewal_col: RENEWAL_DATE
    # Columns found at preflight that are written BECAUSE of the outcome.
    # Never features. The leakage audit greps for these names too.
    outcome_derived_cols: [CRM_STATUS, CRM_CANCEL_REASON]
  outcomes:
    table: RAW.CRM.RENEWAL_OUTCOMES
    outcome_col: OUTCOME
    churn_value: CHURNED
    notice_col: NOTICE_DATE          # null if not tracked; say so
    recorded_col: RECORDED_AT
  usage:
    table: RAW.PRODUCT.USAGE_MONTHLY
    month_col: USAGE_MONTH
    active_col: ACTIVE_USERS
    seats_col: SEATS_PURCHASED
    logins_col: LOGINS
  arr_history_available: false       # if false, current ARR is used -- recorded as a known limitation

# Prediction framing. Fixed per model version.
prediction:
  horizon_days: 90                   # predict at renewal_date - horizon
  lookback_days: 180                 # text window before as_of_date
  test_fraction: 0.30                # latest renewals by time; never random
  score_as_of: null                  # date open renewals are scored as of; defaults to today at run time

# One model per AI_COMPLETE stage. ILLUSTRATIVE -- preflight confirms GA and
# in-region via SHOW CORTEX BASE MODELS and records verified_on.
models:
  evidence: claude-haiku-4-5
  summary: null                      # AI_SUMMARIZE_AGG takes no model argument; kept for symmetry
  verified_on: null

extraction:
  taxonomy_source: SYN_REASON_TAXONOMY   # or the customer-approved table
  categories_hash: null                  # SHA2 of the rendered AI_CLASSIFY categories
  task_description: "Identify retention risks in this B2B customer interaction that a customer success manager should act on."
  sample_size: 500

features:
  feature_version: f1

leakage:
  audit_passed: false
  audit_feature_version: null
  audit_run_on: null

model:
  name: CHURN_MODEL
  version: V1                        # bump every training run
  registered_versions: []
  default_version: null              # the version scoring uses

thresholds:
  high_risk: null                    # set in Phase 7 from the lift table, not guessed
  watch: null
  narrative_top_n: 50

materialization:
  mode: sql                          # dbt | sql
  project_name: churn_signals
  project_object: null

experiment:
  run_id: null                       # unique per extraction invocation
  score_run_id: null                 # unique per scoring invocation
  prod_run_id: null                  # stable id the incremental task writes under
  experiment_id: exp_001
  experiment_name: "baseline"
  prompt_version: v1

phases:
  preflight: not_started
  seed: not_started
  taxonomy: not_started
  extract: not_started
  features: not_started
  model: not_started
  score: not_started
  eval: not_started
  readout: not_started

created_objects:
  tables: []
  views: []
  semantic_views: []
  models: []
  streams: []
  tasks: []
  procedures: []
  agents: []
  dbt_projects: []
```

## Reading and writing it

Plain YAML. Read with `read`, edit with `edit` -- targeted edits preserve the user's comments. If the
file does not exist, the router creates it from the schema above with every `phases` value
`not_started` and every unknown value absent.

## Resume behaviour

On entry the router reports `phases`. `done` phases are not re-run unless asked. A `failed` phase has
a sibling `failed_reason` the router surfaces. If `leakage.audit_feature_version` differs from
`features.feature_version`, the audit is stale: treat `audit_passed` as false.
