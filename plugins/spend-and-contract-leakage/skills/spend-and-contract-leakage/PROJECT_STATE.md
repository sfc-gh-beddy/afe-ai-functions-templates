# Project state contract — `spend-leakage-project.yml`

Every skill in this plugin reads and writes one file: `spend-leakage-project.yml` in the working
directory. It is what makes the build resumable and stops any phase from re-asking a question an
earlier phase already answered.

## Rules

1. **Read it first.** Before asking the user anything, read `spend-leakage-project.yml`. If a value is
   already there, use it. Do not re-prompt.
2. **Write after every phase.** Update `phases` and `created_objects` immediately when a phase
   finishes, not in a batch at the end. A build interrupted mid-way must be resumable.
3. **Never guess a value into it.** If something is unknown, leave the key absent rather than writing
   a plausible default. An absent key means "ask"; a present key means "settled". This matters most
   for the column mappings: a guessed `vendor_id_col` produces a pipeline that runs and reconciles
   invoices against the wrong supplier's contract.
4. **Object names are recorded, not reconstructed.** Later phases read object names from
   `created_objects` rather than rebuilding them from a naming convention, because the user may have
   overridden a name at the gate.
5. **`customer_label` is a display string only.** Never use it to derive an object name, schema, or
   any branching logic.
6. **`materialization.mode` is settled once, at preflight, and then obeyed.** Every later skill emits
   dbt models or plain `CREATE OR REPLACE TABLE` according to it. Do not mix the two in one build.
7. **`reconcile.as_of_date` is always explicit.** Renewal findings and trailing-12-month exposure
   depend on it. Sandbox runs pin `2026-09-30`. Customer runs pin the run date at the start of the
   run and write it here, so a rerun next week of the same `run_id` reproduces the same findings.
   No SQL in this plugin calls `CURRENT_DATE()` for business logic.
8. **Bump `experiment.experiment_id` before any run whose results you want to keep separately, and
   `prompt_version` on any change to prompts, `AI_EXTRACT` questions, tolerances or match
   thresholds.** Re-running with an unchanged `experiment_id` merges over the previous results, which
   is correct for a retry and wrong for a comparison.
9. **The answer-key location is recorded but never handed to a pipeline phase.** `eval.key_schema`
   is read only by `evaluate-leakage-accuracy`.

## Schema

```yaml
# Display label only. Never used for logic or naming.
customer_label: "Example Manufacturer"

# Where the pipeline is built.
target:
  database: SPEND_LEAKAGE
  schema: PIPELINE
  warehouse: LEAKAGE_WH            # small or medium; AI function throughput is not warehouse-bound
  query_tag_prefix: spend_leakage  # every AI-function statement sets QUERY_TAG = <prefix>:<phase>:<run_id>

# Contract sources. Either or both of files and text may be present.
contracts:
  source_table: CLM.CONTRACT_DOCUMENTS
  id_col: DOCUMENT_ID
  vendor_id_col: CLM_VENDOR_ID      # nullable in most CLM exports; linking falls back to extracted names
  title_col: CLM_TITLE
  text_col: DOCUMENT_TEXT           # null when contracts are file-only
  file_col: FILE_PATH               # stage-relative path; null when text-only
  stage: "@CLM.CONTRACT_FILES"      # required when file_col is set; must use SNOWFLAKE_SSE encryption
  uploaded_at_col: UPLOADED_AT
  page_count_col: PAGE_COUNT        # optional; enables page budgeting before parse

# Spend sources and their column mappings.
spend:
  vendors_table: ERP.VENDORS
  vendor_id_col: VENDOR_ID
  vendor_name_col: VENDOR_NAME
  po_table: ERP.PURCHASE_ORDERS
  po_id_col: PO_ID
  po_contract_ref_col: CONTRACT_REFERENCE   # free text; parsed, never trusted as a key
  invoice_lines_table: AP.INVOICE_LINES
  invoice_line_id_col: INVOICE_LINE_ID
  invoice_vendor_id_col: VENDOR_ID
  invoice_vendor_name_col: VENDOR_NAME_ON_INVOICE
  invoice_po_col: PO_ID
  invoice_date_col: INVOICE_DATE
  service_start_col: SERVICE_PERIOD_START   # the date that selects the effective rate
  service_end_col: SERVICE_PERIOD_END
  sku_col: SKU                              # nullable; description matching is the fallback
  description_col: LINE_DESCRIPTION
  quantity_col: QUANTITY
  uom_col: UNIT_OF_MEASURE
  unit_price_col: UNIT_PRICE
  currency_col: CURRENCY
  amount_col: LINE_AMOUNT
  gl_col: GL_ACCOUNT
  capex_flag_col: CAPEX_FLAG                # or a GL-range rule recorded below
  capex_gl_rule: null                       # e.g. "gl_account LIKE '15%'" if no flag column exists
  # Credit memos and reversals, if AP stores them separately. Without them,
  # a refunded overcharge is reported as still outstanding.
  credit_memo_table: null

# Models. ILLUSTRATIVE ONLY. Preflight confirms each is lifecycle_status = 'GA'
# and callable in this account's region (natively or via CORTEX_ENABLED_CROSS_REGION)
# with SHOW CORTEX BASE MODELS before pinning. AI_EXTRACT, AI_PARSE_DOCUMENT and
# AI_CLASSIFY do not take a model name; only the AI_COMPLETE stages are pinned.
models:
  clause_interpret: claude-sonnet-4-6   # schema-constrained clause interpretation
  verified_on: null                     # date of the SHOW CORTEX BASE MODELS check
  cross_region: null                    # value of CORTEX_ENABLED_CROSS_REGION observed at preflight

# Parsing.
parse:
  mode: LAYOUT                 # LAYOUT keeps rate-card tables as Markdown; OCR loses table structure
  page_split: true             # required for page-level evidence citation
  min_chars_per_page: 200      # below this a page is treated as a parse failure, not an empty page
  near_duplicate_similarity: 0.97

# Extraction.
extract:
  commercial_classes: [MASTER_AGREEMENT, AMENDMENT, ORDER_FORM_OR_SOW]
  quote_min_chars: 12          # shorter quotes cannot be verified meaningfully

# Reconciliation parameters. Every one is a business decision, not a constant.
reconcile:
  as_of_date: null             # REQUIRED. 2026-09-30 for the sandbox.
  price_tolerance_abs: 0.05    # per unit, in invoice currency
  price_tolerance_rel_pct: 0.5 # per unit, percent of contracted price; the smaller of the two applies
  renewal_horizon_days: 90     # notice deadlines inside this window raise UPCOMING
  exposure_window_months: 12   # trailing spend used as renewal exposure
  sku_similarity_min: 0.80     # description-to-rate-line match threshold
  sku_similarity_margin: 0.03  # best must beat second best by this much, or the line is AMBIGUOUS
  vendor_name_jw_min: 92       # JAROWINKLER_SIMILARITY threshold for name-based vendor linking
  escalator_compounding: ALLOWED_PRICE   # ALLOWED_PRICE | BILLED_PRICE, see best practices rule 15

# Evaluation.
eval:
  key_schema: null             # e.g. SPEND_LEAKAGE.EVAL; read only by evaluate-leakage-accuracy
  min_finding_precision: 0.0   # set after the first run, then raise to just below achieved
  min_finding_recall: 0.0
  max_dollar_abs_error_pct: 0.0

# Value readout. Customer-supplied inputs only; absent until the customer gives
# them. Each value carries its source, e.g. {low: 40, expected: 60, high: 75,
# source: "procurement lead, 2026-10-20"}. See leakage-value-readout.
value:
  recovery_rate_pct: null                 # low / expected / high
  audit_window_months_default: null       # only where contracts state none
  savings_rate_on_managed_spend_pct: null # low / expected / high
  renegotiation_savings_pct: null
  share_of_renewals_acted_on_pct: null
  capex_spend_in_scope: null
  analyst_hours_per_contract_abstraction: null
  loaded_cost_per_hour: null
  contracts_per_year: null
  credit_price: null                      # per AI credit; otherwise report credits only
  fx_rates: null                          # with rate date; only if a single-currency view is asked for

# How the pipeline is built.
materialization:
  mode: sql                    # dbt | sql
  project_name: spend_leakage
  project_object: null
  source_dir: null

# Run identity. Every one of these is SELECTed into terms and findings rows.
experiment:
  run_id: null                 # unique per invocation; the idempotency key
  experiment_id: exp_001
  experiment_name: "baseline"
  prompt_version: v1
  # prompt_hash is computed at run time from the assembled prompt, the AI_EXTRACT
  # response format and the reconcile parameters, and persisted on every row.

# Phase status: not_started | done | skipped | failed (with failed_reason)
phases:
  preflight: not_started
  seed: not_started
  corpus: not_started
  parse: not_started
  extract: not_started
  reconcile: not_started
  eval: not_started
  operationalize: not_started
  readout: not_started

# Fully qualified names of everything the build created.
created_objects:
  tables: []
  views: []
  stages: []
  streams: []
  tasks: []
  dynamic_tables: []
  semantic_views: []
  agents: []
  dbt_projects: []
```

## Reading and writing it

The file is plain YAML and small. Read it with the `read` tool and edit it with `edit`. Do not shell
out to a YAML parser, and do not rewrite the whole file when changing one key — a targeted edit
preserves the user's comments and any manual overrides.

If the file does not exist, the router creates it from the schema above with every `phases` value
set to `not_started`, every customer-specific value absent, and the illustrative defaults in
`reconcile` kept but flagged to the user as defaults to confirm.

## Substituting into SQL

The SQL files under each skill's `sql/` directory use `{{DB}}`, `{{SCHEMA}}`, `{{EVAL_SCHEMA}}`,
`{{AS_OF_DATE}}`, `{{RUN_ID}}`, `{{EXPERIMENT_ID}}`, `{{PROMPT_VERSION}}`, `{{MODEL}}` and the
reconcile parameters as `{{PRICE_TOL_ABS}}` and so on. Substitute every placeholder from this file
before running. A file with an unsubstituted `{{...}}` fails to compile, which is the intended
behaviour; never paper over it with a literal guess.

## Resume behaviour

On entry the router reads `phases` and reports where the build stands before doing anything else. A
phase marked `done` is not re-run unless the user explicitly asks. A phase marked `failed` carries a
`failed_reason` sibling key that the router surfaces. If `reconcile.as_of_date` is absent on resume
of a customer run, ask; do not silently take today's date, because that changes renewal findings
relative to the run being resumed.
