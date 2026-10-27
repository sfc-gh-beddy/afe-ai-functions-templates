# Project state contract — `callcenter-project.yml`

Every skill in this plugin reads and writes one file: `callcenter-project.yml` in the working
directory. It makes the build resumable and stops any phase from re-asking a settled question.

## Rules

1. **Read it first.** Before asking the user anything, read the file. If a value is present, use it.
2. **Write after every phase.** Update `phases` and `created_objects` the moment a phase finishes.
3. **Never guess a value into it.** Unknown means absent. An absent key means "ask"; a present key
   means "settled".
4. **Object names are recorded, not reconstructed.** Later phases read names from `created_objects`.
5. **`customer_label` is a display string only.** Never used for naming or logic.
6. **`materialization.mode` is settled once at preflight**, then obeyed. Do not mix dbt and SQL.
7. **`redaction` is settled before Phase 2 and never silently changed.** `enabled: true` is the
   default. Setting it to `false` requires all three opt-out keys (`opt_out_by`, `opt_out_date`,
   `opt_out_reason`). A phase that finds `enabled: false` without those keys stops and asks.
8. **`taxonomy_version` and `rubric_version` are bumped on any change to the label set or rubric**,
   just like `prompt_version`. Scores from different rubric versions are not comparable.
9. **Bump `experiment.experiment_id` before any run you want to keep separately.** Re-running with an
   unchanged id merges over the previous run, which is right for a retry and wrong for a comparison.

## Schema

```yaml
# Display label only. Never used for logic or naming.
customer_label: "Subscription services contact center"

target:
  database: CCI
  schema: PIPELINE
  eval_schema: CCI_EVAL            # answer key and evaluation only; pipeline never reads it
  warehouse: CCI_WH

# What the corpus is. Settled at preflight.
calls:
  input_mode: mixed                # audio | transcript | mixed
  metadata_table: RAW.CALL_DETAIL_RECORDS
  id_col: CALL_ID
  leg_col: null                    # set when transfers produce multiple legs per call
  customer_id_col: CUSTOMER_ID
  agent_id_col: AGENT_ID
  queue_col: QUEUE_NAME
  start_col: CALL_START_TS
  handle_seconds_col: HANDLE_SECONDS   # system-of-record AHT; never derived from audio duration
  hold_seconds_col: HOLD_SECONDS
  transfer_flag_col: WAS_TRANSFERRED
  disposition_col: DISPOSITION_CODE    # agent-selected; compared against, never trusted as truth
  language_col: null
  # Audio side (null when input_mode = transcript)
  audio_stage: RAW.CALL_AUDIO_STAGE
  audio_path_col: RECORDING_PATH       # stage-relative path on the metadata table
  audio_channel_layout: unknown        # mono | stereo_split | unknown — see best-practices rule A4
  # Transcript side (null when input_mode = audio)
  transcript_table: RAW.CALL_TRANSCRIPTS
  transcript_grain: segment            # segment | full_text
  transcript_text_col: UTTERANCE_TEXT
  transcript_seq_col: SEQ
  transcript_speaker_col: SPEAKER_ROLE # vendor channel label, if any
  transcript_vendor_redacted: unknown  # true | false | unknown; never assumed true

# Redaction. Default ON. An opt-out is explicit and attributed.
redaction:
  enabled: true
  categories: null                 # null = all supported categories
  chunk_target_tokens: 700         # input tokens per AI_REDACT call; see best-practices rule R2
  context_max_chars: 60            # turns this short are re-redacted with the previous turn as context (Phase 2 step 4c-ctx)
  keep_raw_segments: false         # if true, raw table must have a deliberate grant decision
  # Present only when enabled is false:
  # opt_out_by: "name / role"
  # opt_out_date: 2026-10-26
  # opt_out_reason: "CCaaS vendor redacts upstream; verified on 200-call sample"

# Business definitions. Settled with the customer, not defaulted silently.
definitions:
  repeat_window_days: 7            # same customer, any reason, within N days
  min_role_confidence: 0.7         # Phase 2 eligibility: model-assigned speaker roles below this are not role-eligible
  repeat_same_reason_only: false
  escalation_sources: [transfer_flag, supervisor_request]
  min_call_seconds: 20             # shorter calls are abandons; excluded and counted

taxonomy:
  source: generic                  # generic | customer
  taxonomy_version: tax_v1
  max_other_share: 0.15            # gate threshold for the catch-all label

qa:
  rubric_source: generic           # generic | customer
  rubric_version: rub_v1
  human_qa_table: null             # existing human QA scores for calibration, if any

# Models. ILLUSTRATIVE ONLY. Preflight confirms GA and in-region via SHOW CORTEX BASE MODELS.
models:
  qa_judge: claude-sonnet-4-5
  signal_reasoner: claude-haiku-4-5    # only used where AI_EXTRACT cannot express the contract
  verified_on: null

materialization:
  mode: sql                        # dbt | sql
  project_name: call_center_intelligence
  project_object: null
  source_dir: null

experiment:
  run_id: null
  experiment_id: exp_001
  experiment_name: "baseline"
  prompt_version: v1

thresholds:
  min_reason_macro_f1: 0.0         # raise to just under achieved after first eval
  max_redaction_leak_rate: 0.0     # gate on planted PII; any leak is reported
  min_qa_within_one_agreement: 0.0

# Customer-supplied value inputs. Absent until the customer provides them.
value_inputs: {}

# not_started | done | skipped | failed  (failed carries failed_reason)
phases:
  preflight: not_started
  seed: not_started
  corpus: not_started
  transcribe_redact: not_started
  reasons: not_started
  qa: not_started
  signals: not_started
  eval: not_started
  operationalize: not_started
  readout: not_started

created_objects:
  tables: []
  views: []
  dynamic_tables: []
  streams: []
  tasks: []
  stages: []
  semantic_views: []
  agents: []
  dbt_projects: []
```

## Reading and writing it

Plain YAML. Read with `read`, change with targeted `edit` calls so user comments and overrides survive.
Do not shell out to a YAML parser and do not rewrite the whole file to change one key.

If the file does not exist, the router creates it from the schema above with every phase
`not_started`, `redaction.enabled: true`, and every unknown value absent.

## Resume behaviour

On entry the router reads `phases` and reports status first. A `done` phase is not re-run unless
asked. A `failed` phase surfaces its `failed_reason`. If `redaction.enabled` is `false`, the router
says so in its first status line every session.
