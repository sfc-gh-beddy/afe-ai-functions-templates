# Project state contract — `icd10-project.yml`

Every skill in this plugin reads and writes one file: `icd10-project.yml` in the working directory.
This is what makes the build resumable and stops any phase from re-asking a question an earlier
phase already answered.

## Rules

1. **Read it first.** Before asking the user anything, read `icd10-project.yml`. If a value is
   already there, use it. Do not re-prompt.
2. **Write after every phase.** Update `phases` and `created_objects` immediately when a phase
   finishes, not in a batch at the end. A build interrupted mid-way must be resumable.
3. **Never guess a value into it.** If something is unknown, leave the key absent rather than
   writing a plausible default. An absent key means "ask"; a present key means "settled".
4. **Object names are recorded, not reconstructed.** Later phases must read object names from
   `created_objects` rather than rebuilding them from a naming convention, because the user may have
   overridden a name at the gate.
5. **`customer_label` is a display string only.** Never use it to derive an object name, schema, or
   any branching logic.
6. **`materialization.mode` is settled once, at preflight, and then obeyed.** Every later skill emits
   dbt models or plain `CREATE OR REPLACE TABLE` according to it. Do not mix the two in one build.
7. **Bump `experiment.experiment_id` before any run whose results you want to keep separately, and
   `prompt_version` on any prompt change.** Re-running with an unchanged `experiment_id` merges over
   the previous results, which is correct for a retry and wrong for a comparison.

## Schema

```yaml
# Display label only. Never used for logic or naming.
customer_label: "Regional MA Provider"

# Where the pipeline is built.
target:
  database: ICD10_SUSPECTING
  schema: PIPELINE
  warehouse: ICD10_WH

# Risk model configuration. model_year must be pinned — RAF factors and HCC
# numbering change between CMS model years, so an unpinned build silently
# produces wrong revenue figures after a model year rolls.
cms:
  model_year: v28
  target_hccs: [HCC85, HCC111, HCC18, HCC96, HCC82]

# The customer's existing document table and its column mapping. Discovered
# and confirmed at preflight so no later skill has to guess column names.
documents:
  source_table: RAW.CLINICAL_DOCUMENTS
  id_col: DOCUMENT_ID
  patient_id_col: PATIENT_ID
  text_col: DOCUMENT_TEXT          # null if documents are file-only
  file_col: null                   # stage-relative path, null if text-only
  stage: null                      # required when file_col is set
  type_col: DOCUMENT_TYPE
  source_system_col: SOURCE_SYSTEM
  date_col: DOCUMENT_DATE
  page_count_col: null             # enables the cheapest routing exit when present

# How coding guidance reaches the coder prompt.
knowledge:
  mode: cortex_search              # cortex_search | guideline_tables
  search_service: null
  guideline_stage: null

# One model per stage. These are ILLUSTRATIVE ONLY — preflight must confirm
# each is lifecycle_status = 'GA' and available in this account's region via
# SHOW CORTEX BASE MODELS before pinning. Never copy these values forward
# without checking: models move to LEGACY and EOL on published dates, and
# several models in older reference material are already LEGACY.
models:
  classify: llama3.1-8b
  compress: claude-haiku-4-5
  extract: claude-sonnet-4-6
  judge: claude-sonnet-4-5
  verified_on: null              # date the SHOW CORTEX BASE MODELS check was run

# Confidence banding applied to the inline judge score.
thresholds:
  high_confidence: 8
  review_candidate: 6
  # Set to 0.0 on the first run, then raise to just under the achieved figure
  # so a future regression fails the build rather than passing quietly.
  min_acceptable_f1: 0.0

# How the pipeline is built. dbt is the better default once past first demo:
# version control, a real DAG, lineage, and dbt tests as build-failing quality
# gates. See DBT_MATERIALIZATION.md, and delegate deploy/execute mechanics to
# the dbt-projects-on-snowflake skill.
materialization:
  mode: dbt                        # dbt | sql
  project_name: icd10_suspecting
  project_object: null             # DB.SCHEMA.NAME once deployed
  source_dir: null                 # local path to the dbt project

# Run identity. Every one of these must be SELECTed into the output rows, not
# just used for filtering — a result that cannot say which prompt and model
# produced it is not reproducible.
experiment:
  run_id: null                     # unique per invocation; the idempotency key
  experiment_id: exp_001
  experiment_name: "baseline"
  prompt_version: v1               # bump on any prompt change
  # prompt_hash is computed at run time and persisted, so a run is still
  # reproducible when someone forgets to bump prompt_version.

# Phase status: not_started | done | skipped | failed
phases:
  preflight: not_started
  seed: not_started
  route: not_started
  knowledge: not_started
  extract: not_started
  suspect: not_started
  eval: not_started

# Fully qualified names of everything the build created, so teardown and
# later phases never have to guess.
created_objects:
  tables: []
  views: []
  search_services: []
  stages: []
  dbt_projects: []
```

## Reading and writing it

The file is plain YAML and small. Read it with the `read` tool and edit it with `edit`. Do not
shell out to a YAML parser, and do not rewrite the whole file when changing one key — a targeted
edit preserves the user's comments and any manual overrides they made.

If the file does not exist, the router creates it from the schema above with every `phases` value
set to `not_started` and every unknown value absent.

## Resume behaviour

On entry the router reads `phases` and reports where the build stands before doing anything else.
A phase marked `done` is not re-run unless the user explicitly asks. A phase marked `failed`
carries a `failed_reason` sibling key that the router surfaces so the user is not left guessing why
the build stopped.
