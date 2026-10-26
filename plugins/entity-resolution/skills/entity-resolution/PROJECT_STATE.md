# Project state contract — `er-project.yml`

Every skill in this plugin reads and writes one file: `er-project.yml` in the working directory. It is
what makes the build resumable and stops any phase from re-asking a question an earlier phase answered.

## Rules

1. **Read it first.** Before asking the user anything, read `er-project.yml`. If a value is there, use
   it. Do not re-prompt.
2. **Write after every phase**, immediately, not batched at the end.
3. **Never guess a value into it.** Unknown means absent. An absent key means "ask"; a present key means
   "settled".
4. **Object names are recorded, not reconstructed.** Later phases read names from `created_objects`.
5. **`customer_label` is a display string only.** Never use it for naming or logic.
6. **`materialization.mode` is settled once, at preflight**, and every later skill obeys it.
7. **Thresholds are versioned with the experiment.** Changing `thresholds.*` without bumping
   `experiment.experiment_id` makes two runs with different banding indistinguishable in the scored-pair
   history. Bump it.
8. **`embed.model` and `embed.template_version` are a pair.** Changing either invalidates every stored
   vector for comparison purposes; the score phase must re-embed (it detects this via
   `embed_text_hash` and the model column, but the state file must say what is intended).
9. **`record_uid` construction is fixed at preflight** and never changed mid-build, because the answer
   key, the crosswalk and the golden id registry all key on it.

## Schema

```yaml
# Display label only. Never used for logic or naming.
customer_label: "Mid-market distributor"

target:
  database: ER_POC
  schema: PIPELINE
  eval_schema: ER_EVAL          # answer key and evaluation outputs; never read by the pipeline
  warehouse: ER_WH

# Which entity types are resolved. Each type is resolved independently.
scope:
  entity_types: [CUSTOMER, VENDOR, PRODUCT]
  # true only if the user wants the same organization linked across its customer
  # and vendor records (party-level view). Default false.
  cross_type_party: false

# record_uid = source_system || ':' || source_record_id. Fixed at preflight.
record_uid_format: "SOURCE_SYSTEM:SOURCE_RECORD_ID"

# One entry per source table. Column maps are discovered and confirmed at
# preflight so no later skill guesses column names. Unmapped attributes are null.
sources:
  - system: CRM
    entity_type: CUSTOMER
    table: RAW.CRM_ACCOUNTS
    key_col: ACCOUNT_ID
    trust_rank: 2                # survivorship tie-break; lower = more trusted
    filter: "ACCOUNT_STATUS <> 'MERGED'"   # optional; records the source already retired
    columns:
      name: ACCOUNT_NAME
      address_line: BILLING_STREET
      city: BILLING_CITY
      region: BILLING_STATE
      postal: BILLING_POSTAL_CODE
      country: BILLING_COUNTRY
      phone: PHONE
      website: WEBSITE
      updated_at: LAST_MODIFIED_AT
  # ... one block per source

# Columns that must never appear in embedding text or a prompt, even if mapped.
# Preflight populates this from what it finds (bank, IBAN, routing, card,
# government id, date of birth). Tax ids are used in SQL comparisons only.
excluded_from_ai:
  - BANK_ACCOUNT_LAST4

# Blocking configuration. See standardize-and-block-records.
blocking:
  rules: [NAME_PREFIX_POSTAL, NAME_SOUNDEX_CITY, TAX_ID, PHONE, EMAIL_DOMAIN, SEMANTIC_KNN,
          PRODUCT_BRAND_TYPE, PRODUCT_MPN, PRODUCT_GTIN]
  max_block_size: 200            # blocks above this are capped and logged, never silently dropped
  semantic_knn_k: 10

# Embedding configuration. ILLUSTRATIVE — preflight confirms availability.
embed:
  model: snowflake-arctic-embed-l-v2.0
  dimensions: 1024               # must match the model; 768 for the -m variants
  template_version: t1           # bump on any change to the serialization template
  max_input_tokens: 512          # per the model's documented context; verified at preflight

# Adjudication configuration. ILLUSTRATIVE — preflight confirms GA and region.
adjudicate:
  engine: ai_complete            # ai_complete | snowflake_decision (only if preflight verified access and syntax)
  model: claude-sonnet-4-5
  verified_on: null
  max_pairs_per_run: 5000        # hard cap; the gate shows the real count before running
  position_swap_sample: 200      # pairs re-asked in swapped order to measure position bias

# Banding thresholds on the composite score. Start from these, then calibrate in
# evaluate-match-accuracy and write the calibrated values back with a new experiment_id.
thresholds:
  auto_match: 0.92
  auto_reject: 0.55
  model_accept_confidence: 0.70  # model MATCH below this goes to steward review, not auto-accept
  max_cluster_size: 25           # clusters above this are split-checked, never auto-published
  min_cluster_cohesion: 0.60     # minimum pairwise composite inside a cluster
  # Set to 0.0 first run, then raise to just under the achieved figure.
  min_acceptable_pairwise_precision: 0.0
  min_acceptable_bcubed_f1: 0.0

survivorship:
  # Per-attribute rule order. See build-golden-records.
  default: [MOST_TRUSTED_SOURCE, MOST_RECENT, MOST_COMPLETE]
  overrides:
    tax_id: [MOST_FREQUENT_NON_NULL, MOST_TRUSTED_SOURCE]
    phone:  [MOST_RECENT, MOST_TRUSTED_SOURCE]

materialization:
  mode: dbt                      # dbt | sql
  project_name: entity_resolution
  project_object: null
  source_dir: null

experiment:
  run_id: null                   # unique per invocation; idempotency key
  experiment_id: exp_001
  experiment_name: "baseline"
  prompt_version: v1
  embed_template_version: t1     # mirrors embed.template_version for the run record

phases:
  preflight: not_started
  seed: not_started
  standardize_block: not_started
  score: not_started
  adjudicate: not_started
  golden: not_started
  eval: not_started
  publish: not_started
  readout: not_started

created_objects:
  tables: []
  views: []
  semantic_views: []
  agents: []
  tasks: []
  streams: []
  dynamic_tables: []
  dbt_projects: []
```

## Canonical object names

Defaults, used unless the user overrides at a gate (and then recorded in `created_objects`):

| Object | Schema | Written by |
|---|---|---|
| `ER_TOKEN_MAP` | pipeline | standardize |
| `ER_RECORDS` | pipeline | standardize |
| `ER_BLOCK_KEYS`, `ER_BLOCK_STATS` | pipeline | standardize |
| `ER_CANDIDATE_PAIRS` | pipeline | standardize |
| `ER_RECORD_EMBEDDINGS` | pipeline | score |
| `ER_SCORED_PAIRS` | pipeline | score (accumulates by `run_id`) |
| `ER_MATCH_DECISIONS_RAW`, `ER_MATCH_DECISIONS` | pipeline | adjudicate (accumulate) |
| `ER_ACCEPTED_EDGES` | pipeline | golden (accumulates) |
| `ER_CLUSTERS` | pipeline | golden (accumulates) |
| `ER_GOLDEN_ID_REGISTRY` | pipeline | golden (persistent across runs) |
| `ER_GOLDEN_RECORDS`, `ER_CROSSWALK` | pipeline | golden (accumulate) |
| `ER_PIPELINE_QUALITY_LOG` | pipeline | every phase |
| `SYNTH_*` source tables | pipeline (sandbox) | seed |
| `SYNTH_TRUE_ENTITIES`, `SYNTH_ER_ANSWER_KEY` | eval | seed |
| `ER_EVAL_*` | eval | evaluate |

## Reading and writing it

Plain YAML. Read with `read`, edit with `edit`. Targeted edits, never whole-file rewrites, so user
comments and overrides survive. If the file does not exist, the router creates it from the schema
above with every phase `not_started` and every unknown value absent.

## Resume behaviour

On entry the router reads `phases` and reports where the build stands before doing anything else. A
`done` phase is not re-run unless asked. A `failed` phase carries a `failed_reason` sibling key that the
router surfaces.
