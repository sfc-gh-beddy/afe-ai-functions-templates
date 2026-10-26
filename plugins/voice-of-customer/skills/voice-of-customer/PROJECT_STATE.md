# Project state contract: `voc-project.yml`

Every skill in this plugin reads and writes one file: `voc-project.yml` in the working directory.
This is what makes the build resumable and stops any phase from re-asking a question an earlier phase
already answered.

## Rules

1. **Read it first.** Before asking the user anything, read `voc-project.yml`. If a value is already
   there, use it. Do not re-prompt.
2. **Write after every phase.** Update `phases` and `created_objects` immediately when a phase
   finishes, not in a batch at the end. A build interrupted mid-way must be resumable.
3. **Never guess a value into it.** If something is unknown, leave the key absent rather than writing
   a plausible default. An absent key means "ask"; a present key means "settled".
4. **Object names are recorded, not reconstructed.** Later phases read object names from
   `created_objects` rather than rebuilding them from a naming convention, because the user may have
   overridden a name at the gate.
5. **`customer_label` is a display string only.** Never use it to derive an object name, a schema, a
   prompt, or any branching logic.
6. **`materialization.mode` is settled once, at preflight, and then obeyed.** Every later skill emits
   dbt models or plain SQL according to it. Do not mix the two in one build.
7. **`taxonomy.active_version` changes only through `build-voc-taxonomy`.** No other phase edits the
   taxonomy or its version. A classification run always records the version it used.
8. **Bump `experiment.experiment_id` before any run whose results you want to keep separately**, and
   `prompt_version` on any change to a task description, label description, example, or prompt.
   Re-running with an unchanged `experiment_id` merges over the previous results, which is correct for
   a retry and wrong for a comparison.
9. **`value_inputs` hold customer-supplied numbers only**, each with its source. Never fill one from a
   benchmark, an industry figure, or the sandbox.

## Schema

```yaml
# Display label only. Never used for logic or naming.
customer_label: "Consumer Electronics Retailer"

# Where the pipeline is built.
target:
  database: VOC
  schema: PIPELINE
  taxonomy_schema: TAXONOMY
  eval_schema: VOC_EVAL            # quarantined: answer keys and labeled samples only
  warehouse: VOC_WH

# Feedback sources, discovered and confirmed at preflight. One entry per
# source table; normalize-voc-feedback unions them into one staging shape.
sources:
  - name: reviews
    table: RAW.PRODUCT_REVIEWS
    channel: REVIEW                # REVIEW | SURVEY | SOCIAL | SUPPORT | APP_STORE | OTHER
    id_col: REVIEW_ID
    text_col: REVIEW_TEXT
    created_col: SUBMITTED_AT
    sku_col: SKU                   # null when the source carries no SKU
    region_col: MARKET
    language_col: null             # null when the source does not report language
    author_col: REVIEWER_ID        # used for dedup scope only; never surfaced
    rating_col: STAR_RATING        # context only; never used as sentiment truth
    source_system_col: SITE

# Product and region dimensions used for entity linking and grouping.
dimensions:
  product_table: RAW.PRODUCTS
  sku_col: SKU
  product_name_col: PRODUCT_NAME
  product_line_col: PRODUCT_LINE
  region_table: null

# Optional operational outcomes to join themes against (returns, contacts).
# Only used to show correlation; value comes from value_inputs.
outcomes:
  table: null                      # e.g. weekly units sold / returned / contacts by SKU and region
  grain: null                      # e.g. [sku, region_code, week_start]

# Taxonomy. active_version is the version classification runs against.
taxonomy:
  active_version: v1
  versions: [v1]
  source: sandbox                  # sandbox | customer_existing | bootstrapped
  l1_count: null
  max_l2_per_l1: null
  other_rate_threshold: 0.08       # share in Other Feedback that triggers a drift review
  last_drift_review: null

# Normalization decisions.
normalize:
  target_language: en
  translate_non_english: true
  redact_pii: true                 # settled at preflight from the sensitive-data posture
  redact_categories: null          # null = AI_REDACT defaults
  dedup_scope: author_text         # author_text | text_only (never text_only without a reason)
  relevance_gate: ai_classify      # ai_classify | ai_filter | none
  sentiment_token_window: 2048     # AI_SENTIMENT context window; do not raise

# Models, where a model is chosen. AI_CLASSIFY, AI_SENTIMENT, AI_SUMMARIZE_AGG
# and AI_AGG use Snowflake-managed models and take no model argument.
# ILLUSTRATIVE ONLY: preflight must confirm GA and region availability.
models:
  embed: snowflake-arctic-embed-l-v2.0
  embed_dims: 1024
  label_proposal: claude-sonnet-4-5    # AI_COMPLETE, emerging-theme naming only
  verified_on: null

# Emerging-theme detection.
emerging:
  grain: [topic_l1, topic_l2, sku, region_code]
  baseline_weeks: 6
  min_weekly_mentions: 5
  z_threshold: 3.0
  novelty_similarity_max: 0.55     # below this vs every taxonomy node = out-of-taxonomy
  min_cluster_size: 8

# Summaries.
summaries:
  grain: [sku, region_code, topic_l1, period]
  period: WEEK
  min_items_per_summary: 10

# Accuracy gates.
thresholds:
  min_topic_f1_l1: 0.0             # raise to just under achieved after the first run
  min_aspect_f1: 0.0
  max_null_rate: 0.01

materialization:
  mode: dbt                        # dbt | sql
  project_name: voice_of_customer
  project_object: null
  source_dir: null

# Run identity. Selected into every output row.
experiment:
  run_id: null
  experiment_id: exp_001
  experiment_name: "baseline taxonomy v1"
  prompt_version: v1
  # config_hash is computed at run time from the exact AI_CLASSIFY categories,
  # task description and examples bound into the call, and persisted.

# Customer-supplied value inputs. Each value carries its source. Never filled
# from benchmarks or the sandbox.
value_inputs: {}
  # returns_per_month: {value: null, source: null}
  # cost_per_return: {value: null, source: null}

phases:
  preflight: not_started
  seed: not_started
  taxonomy: not_started
  normalize: not_started
  topics: not_started
  aspects: not_started
  emerging: not_started
  summarize: not_started
  eval: not_started
  readout: not_started

created_objects:
  tables: []
  views: []
  dynamic_tables: []
  streams: []
  tasks: []
  semantic_views: []
  agents: []
  dbt_projects: []
```

## Reading and writing it

The file is plain YAML and small. Read it with the `read` tool and edit it with `edit`. Do not shell
out to a YAML parser, and do not rewrite the whole file when changing one key: a targeted edit
preserves the user's comments and manual overrides.

If the file does not exist, the router creates it from the schema above with every `phases` value
set to `not_started` and every unknown value absent. The thresholds and emerging-theme parameters
shown are starting points the user is told about at the relevant gate, not hidden defaults.

## Resume behaviour

On entry the router reads `phases` and reports where the build stands before doing anything else. A
phase marked `done` is not re-run unless the user explicitly asks. A phase marked `failed` carries a
`failed_reason` sibling key that the router surfaces.

If `taxonomy.active_version` has changed since the last `topics: done`, the router says so: every
phase from topics onward is stale for the new version, and the user decides whether to re-run them or
keep the old version's results as a separate experiment.
