# Project state contract -- `maintenance-project.yml`

Every skill in this plugin reads and writes one file: `maintenance-project.yml` in the working
directory. It makes the build resumable and stops any phase re-asking a question an earlier phase
already settled.

## Rules

1. **Read it first.** Before asking the user anything, read `maintenance-project.yml`. If a value is
   present, use it. Do not re-prompt.
2. **Write after every phase.** Update `phases` and `created_objects` immediately when a phase ends,
   not in a batch. An interrupted build must be resumable.
3. **Never guess a value into it.** Unknown means absent. An absent key means "ask"; a present key
   means "settled". This matters most for `value_inputs`: an invented replacement cost or downtime
   rate written here would flow straight into the readout.
4. **Object names are recorded, not reconstructed.** Later phases read names from `created_objects`.
5. **`customer_label` is a display string only.** Never use it for naming or branching.
6. **`materialization.mode` is settled once, at preflight, then obeyed.**
7. **`taxonomy.version` is pinned.** Any change to the component or failure-mode reference tables
   bumps it. Signals extracted under different taxonomy versions are not comparable and the
   evaluation harness refuses to pool them.
8. **Bump `experiment.experiment_id` before any run whose results you want kept separately, and
   `prompt_version` on any prompt change.** Re-running with the same `experiment_id` merges over the
   previous run -- correct for a retry, wrong for a comparison.
9. **`precursor.cutoff_policy` and `precursor.split` are settled before features are built.**
   Changing them after a model has been evaluated invalidates the evaluation; re-run Phase 6.

## Schema

```yaml
# Display label only. Never used for logic or naming.
customer_label: "Regional water utility"

target:
  database: MAINT_INTEL
  schema: PIPELINE
  eval_schema: PIPELINE_EVAL        # answer key and harness only; pipeline never reads it
  warehouse: MAINT_WH

# Source mapping. Discovered and confirmed at preflight so no later skill guesses column names.
sources:
  work_orders:
    table: RAW.CMMS_WORK_ORDERS
    id_col: WO_ID
    asset_id_col: ASSET_ID              # the equipment the WO was raised against
    functional_location_col: FUNC_LOC   # position in the plant; null if the CMMS has none
    type_col: WO_TYPE                   # PM / CM / INSPECTION / EMERGENCY or customer codes
    created_col: CREATED_AT
    closed_col: CLOSED_AT
    last_modified_col: LAST_MODIFIED_AT # leakage control: long text edited after the fact
    short_text_col: DESCRIPTION
    failure_code_col: FAILURE_CODE      # the structured code; compared, never used as a label
    priority_col: PRIORITY
  notes:
    table: RAW.CMMS_WO_NOTES            # null if notes live only in a WO long-text column
    id_col: NOTE_ID
    wo_id_col: WO_ID
    ts_col: NOTE_TS                     # the timestamp of THIS note, not the WO
    text_col: NOTE_TEXT
    author_role_col: AUTHOR_ROLE
  inspections:
    table: RAW.INSPECTION_REPORTS       # null if none
    id_col: REPORT_ID
    asset_id_col: ASSET_ID
    ts_col: INSPECTION_TS
    text_col: REPORT_TEXT               # null if file-only
    file_col: null                      # stage-relative path when reports are files
    stage: null
  asset_registry:
    table: RAW.ASSET_REGISTRY
    asset_id_col: ASSET_ID
    class_col: ASSET_CLASS
    site_col: SITE_CODE
    install_date_col: INSTALL_DATE
    criticality_col: CRITICALITY
    parent_col: PARENT_ASSET_ID         # null if flat
  asset_moves:
    table: null                         # equipment install/remove history per functional location
  sensors:
    table: RAW.SENSOR_DAILY             # null if no sensor history
    asset_id_col: ASSET_ID
    ts_col: READING_DATE
    grain: daily                        # daily | hourly | raw
    timezone: UTC                       # recorded, never assumed
    measures: [VIBRATION_MM_S, BEARING_TEMP_C]
  downtime:
    table: RAW.DOWNTIME_EVENTS          # functional failures; the precursor label source
    id_col: EVENT_ID
    asset_id_col: ASSET_ID
    start_col: START_TS
    end_col: END_TS
    planned_col: IS_PLANNED

# Taxonomy. Customer-owned. version bumps on any change.
taxonomy:
  source: sandbox                       # sandbox | customer_tables | iso14224_subset
  version: tax_v1
  component_table: null                 # filled by build-failure-taxonomy
  failure_mode_table: null
  glossary_table: null                  # abbreviations: brg, vib, o/h, DE, NDE

# One model per stage. ILLUSTRATIVE ONLY. Preflight confirms each is GA and available in this
# account's region (or via cross-region inference) with SHOW CORTEX BASE MODELS before pinning.
models:
  triage: llama3.1-8b                   # used only if AI_COMPLETE triage replaces AI_CLASSIFY
  extract: claude-sonnet-4-5
  cluster_label: claude-haiku-4-5
  embed: snowflake-arctic-embed-l-v2.0
  verified_on: null
cross_region:
  setting: null                         # value of CORTEX_ENABLED_CROSS_REGION observed at preflight
  residency_approved: null              # true only if the customer confirmed cross-region is allowed

extraction:
  triage_categories_version: tri_v1
  dedup_key: "asset_id || '::' || normalized_text_hash"
  max_input_tokens: 6000                # per call; longer notes are segmented, never truncated

recurring:
  repeat_window_days: null              # CUSTOMER-DEFINED; ask, do not default
  similarity_threshold: null            # set from the sandbox sweep, not a guess
  exclude_wo_types: [PM]

precursor:
  horizon_days: null                    # how far ahead a warning must arrive to be useful; ask
  min_lead_days: null                   # below this an alert cannot change a decision; ask
  cutoff_policy: note_ts                # features use note_ts < cutoff, never WO created/closed
  label_source: downtime                # downtime | emergency_wo
  split:
    method: time                        # time | time_and_asset; never random
    train_end: null
    test_start: null
  alert_budget_per_month: null          # how many alerts the planners can act on; ask

thresholds:
  min_acceptable_failure_mode_f1: 0.0   # raise to just under achieved after first run
  min_acceptable_component_f1: 0.0

materialization:
  mode: sql                             # dbt | sql
  project_name: maint_intel
  project_object: null
  source_dir: null

experiment:
  run_id: null
  experiment_id: exp_001
  experiment_name: "baseline"
  prompt_version: v1

# Customer-supplied value inputs. Absent until the customer provides them. Never defaulted.
# Ranges are {low, expected, high}. See maintenance-value-readout for how each is used.
value_inputs:
  truck_roll_cost: null
  avoidable_repeat_share: null          # from a planner-reviewed sample of repeat pairs
  repeat_prevention_rate: null
  downtime_cost_per_hour: null          # may be per asset class or criticality
  avg_unplanned_downtime_hours: null
  avg_planned_repair_hours: null
  intervention_success_rate: null
  planned_age_based_replacements_per_year: null
  replacement_unit_capex: null          # per asset class
  deferral_years: null
  deferral_acceptance_rate: null
  cost_of_capital_pct: null
  mandated_classes_or_work_types: null  # never deferred
  credit_price: null                    # only if the customer wants currency
  monthly_new_records: null
  source_notes: null                    # who supplied each figure and when

phases:
  preflight: not_started
  seed: not_started
  corpus: not_started
  taxonomy: not_started
  extract: not_started
  recurring: not_started
  precursor: not_started
  eval: not_started
  operationalize: not_started
  readout: not_started

created_objects:
  tables: []
  views: []
  dynamic_tables: []
  semantic_views: []
  agents: []
  stages: []
  dbt_projects: []
```

## Reading and writing it

Plain YAML, small. Read with `read`, edit with `edit`. Do not rewrite the whole file to change one
key -- a targeted edit keeps the user's comments and manual overrides.

If the file does not exist, the router creates it from the schema above with every `phases` value
`not_started` and every unknown value absent (or `null` where the schema shows it).

## Resume behaviour

On entry the router reads `phases` and reports status before doing anything. A `done` phase is not
re-run unless asked. A `failed` phase carries a `failed_reason` sibling key, which the router
surfaces.
