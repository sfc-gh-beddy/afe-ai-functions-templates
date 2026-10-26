# Project state contract — `triage-project.yml`

Every skill in this plugin reads and writes one file: `triage-project.yml` in the working directory.
This is what makes the build resumable and stops any phase from re-asking a question an earlier
phase already answered.

## Rules

1. **Read it first.** Before asking the user anything, read `triage-project.yml`. If a value is
   already there, use it. Do not re-prompt.
2. **Write after every phase.** Update `phases` and `created_objects` immediately when a phase
   finishes, not in a batch at the end. A build interrupted mid-way must be resumable.
3. **Never guess a value into it.** If something is unknown, leave the key absent rather than
   writing a plausible default. An absent key means "ask"; a present key means "settled".
4. **Object names are recorded, not reconstructed.** Later phases read object names from
   `created_objects` rather than rebuilding them from a naming convention, because the user may have
   overridden a name at the gate.
5. **`customer_label` is a display string only.** Never use it to derive an object name, schema, or
   any branching logic.
6. **`materialization.mode` is settled once, at preflight, and then obeyed.** Every later skill emits
   dbt models or plain SQL according to it. Do not mix the two in one build.
7. **Bump `experiment.experiment_id` before any run whose results you want to keep separately, and
   `prompt_version` on any prompt change.** Re-running with an unchanged `experiment_id` merges over
   the previous results, which is correct for a retry and wrong for a comparison.
8. **Bump `taxonomy.version` on any change to a label set** — adding, removing, renaming or merging a
   category or queue, or rewording a description. A taxonomy change is not a prompt change; it moves
   the label space, and the harness will not compare per-queue metrics across taxonomy versions
   without flagging it.
9. **Value inputs are customer-supplied or absent.** `value_inputs` holds numbers the customer gave,
   each with a `source` note. Never write an estimate, an industry benchmark, or a number from
   another engagement into it.

## Schema

```yaml
# Display label only. Never used for logic or naming.
customer_label: "Regional IT Service Desk"

# Where the pipeline is built.
target:
  database: TICKET_TRIAGE
  schema: PIPELINE
  eval_schema: EVAL              # answer key and labeled holdout live here, quarantined
  warehouse: TRIAGE_WH

# Cross-region inference. Read at preflight, never set by this plugin.
# If the preferred model is not in-region and this is DISABLED, preflight
# says so and an account administrator decides.
cortex:
  cross_region: null             # value of CORTEX_ENABLED_CROSS_REGION as observed
  region: null                   # CURRENT_REGION() as observed

# The customer's ticket table and its column mapping. Discovered and
# confirmed at preflight so no later skill has to guess column names.
tickets:
  source_table: RAW.TICKETS
  id_col: TICKET_ID
  created_at_col: CREATED_AT
  resolved_at_col: RESOLVED_AT
  subject_col: SHORT_DESCRIPTION
  body_col: DESCRIPTION
  comments_table: null           # optional work-notes / reply thread table
  comments_ticket_id_col: null
  comments_text_col: null
  comments_at_col: null          # comment timestamp
  comments_author_type_col: null # REQUESTER vs AGENT; needed for the pre-assignment cut
  first_assigned_at_col: null    # when the ticket first reached a queue
  channel_col: CONTACT_TYPE      # email | portal | phone | chat ...
  requester_col: CALLER_ID
  # Historical labels. Used to DERIVE the taxonomy and as a NOISY baseline
  # only -- never as the classifier's input. See best-practices rule 2.
  hist_category_col: CATEGORY
  hist_priority_col: PRIORITY
  hist_queue_col: ASSIGNMENT_GROUP
  first_queue_source: null       # audit/history table that gives the FIRST assignment group
  reassignment_count_col: REASSIGNMENT_COUNT
  resolution_notes_col: CLOSE_NOTES
  parent_col: PARENT_INCIDENT    # existing parent/child links, if any
  language_col: null

# Knowledge sources for grounding.
knowledge:
  kb_source_table: RAW.KB_ARTICLES
  kb_id_col: ARTICLE_ID
  kb_title_col: TITLE
  kb_body_col: BODY
  kb_status_col: WORKFLOW_STATE  # only published articles are indexed
  include_resolved_tickets: true # resolution notes of closed tickets as a second source
  search_service: null           # FQN once created
  batch_score_col: null          # score column name observed from a CORTEX_SEARCH_BATCH probe
  self_retrieval_guard: null     # temporal_split | self_exclusion_filter (evaluation only)
  chunk_tokens: 400

# Label sets. Populated by define-triage-taxonomy, stored in tables listed in
# created_objects. The version is selected into every output row.
taxonomy:
  version: tx_v1
  category_dimension: category   # what the customer calls it
  queue_dimension: assignment_group
  priority_scheme: [P1, P2, P3, P4]
  priority_rule: null            # the customer's impact x urgency matrix, if one exists
  multi_label_categories: false

# One model per stage. ILLUSTRATIVE ONLY -- preflight must confirm each is
# lifecycle_status = 'GA' and available in-region (or via cross-region)
# using SHOW CORTEX BASE MODELS before pinning.
models:
  classify_fallback: null        # AI_COMPLETE model for low-confidence residue
  extract: null                  # AI_COMPLETE model if AI_EXTRACT is insufficient
  suggest: null                  # AI_COMPLETE model for cited resolution drafting
  embed: snowflake-arctic-embed-l-v2.0
  verified_on: null              # date the SHOW CORTEX BASE MODELS check was run

# Thresholds. Start permissive, tune in phase 7 on measured precision.
thresholds:
  classify_confidence_floor: null   # below this, route to AI_COMPLETE fallback
  duplicate_similarity: null        # cosine; tuned on planted clusters
  known_issue_similarity: null
  deflection_min_retrieval_score: null
  # Set to 0.0 on the first run, then raise to just under the achieved figure
  # so a future regression fails the build rather than passing quietly.
  min_acceptable_macro_f1_queue: 0.0
  min_acceptable_deflection_precision: 0.0

# How the pipeline is built. See DBT_MATERIALIZATION.md.
materialization:
  mode: dbt                      # dbt | sql
  project_name: ticket_triage
  project_object: null
  source_dir: null

# Operationalization choices, settled in phase 8.
operations:
  mode: null                     # stream_task | dynamic_table
  schedule: null                 # e.g. '15 MINUTE' or a CRON expression
  semantic_view: null
  agent: null

# Run identity. Every one of these must be SELECTed into output rows.
experiment:
  run_id: null
  experiment_id: exp_001
  experiment_name: "baseline"
  prompt_version: v1
  # prompt_hash is computed at run time from the assembled prompt and label set.

# Customer-supplied unit economics for the readout. Every value needs a source.
# Absent means "ask"; never estimate.
value_inputs:
  monthly_ticket_volume: null
  loaded_cost_per_agent_hour: null
  dispatcher_minutes_per_ticket: null
  minutes_per_reassignment: null
  cost_per_contact_avoided: null
  mttr_hours_by_priority: null
  # example of the required shape:
  # monthly_ticket_volume: {value: 42000, source: "ITSM report shared 2026-10-20"}

# Phase status: not_started | done | skipped | failed
phases:
  preflight: not_started
  seed: not_started
  taxonomy: not_started
  knowledge: not_started
  classify: not_started
  link: not_started
  suggest: not_started
  eval: not_started
  operationalize: not_started
  readout: not_started

# Fully qualified names of everything the build created.
created_objects:
  tables: []
  views: []
  dynamic_tables: []
  streams: []
  tasks: []
  search_services: []
  semantic_views: []
  agents: []
  dbt_projects: []
```

## Reading and writing it

The file is plain YAML and small. Read it with the `read` tool and edit it with `edit`. Do not shell
out to a YAML parser, and do not rewrite the whole file when changing one key — a targeted edit
preserves the user's comments and any manual overrides they made.

If the file does not exist, the router creates it from the schema above with every `phases` value
set to `not_started` and every unknown value absent. The illustrative values in the schema above are
**not** defaults: write a key only when it has been confirmed.

## Resume behaviour

On entry the router reads `phases` and reports where the build stands before doing anything else. A
phase marked `done` is not re-run unless the user explicitly asks. A phase marked `failed` carries a
`failed_reason` sibling key that the router surfaces so the user is not left guessing why the build
stopped.

If `taxonomy.version` has changed since `phases.classify` was marked `done`, the router says so: the
classification output was produced against a different label set and should be re-run before
evaluation.
