# Project state contract — `intake-project.yml`

Every skill in this plugin reads and writes one file: `intake-project.yml` in the working directory.
It is what makes the build resumable and stops any phase from re-asking a settled question.

## Rules

1. **Read it first.** Before asking the user anything, read `intake-project.yml`. A present value is
   settled; use it.
2. **Write after every phase**, immediately, not batched at the end.
3. **Never guess a value into it.** Unknown means the key is absent. An absent key means "ask".
4. **Object names are recorded, not reconstructed.** Later phases read names from `created_objects`.
5. **`customer_label` is display only.** Never derive names or logic from it.
6. **`materialization.mode` is settled once at preflight** and obeyed by every later phase.
7. **Thresholds are per field, not global.** A single global confidence threshold is a design bug (see
   best-practices rule 6). The `thresholds` block is keyed by document type and field.
8. **Bump `experiment.experiment_id` before a run you want to compare, and `schema_version` on any
   change to an extraction `responseFormat`.** `schema_hash` is computed at run time; when it disagrees
   with `schema_version`, trust the hash.
9. **Value inputs come from the customer, with a named source.** Every entry under `value_inputs`
   carries `source` (who said it, or which system it came from) and `as_of`. An input without a source
   is not used in the readout.

## Schema

```yaml
customer_label: "Example Co AP pilot"       # display only

target:
  database: DOC_INTAKE
  schema: PIPELINE
  eval_schema: PIPELINE_EVAL                # answer key quarantine
  warehouse: DOC_INTAKE_WH                  # SMALL or MEDIUM; larger does not speed AI_EXTRACT

# Where documents live. Discovered and confirmed at preflight.
documents:
  mode: stage                               # stage | table
  stage: RAW.DOCS.INBOUND_DOCS              # must have DIRECTORY enabled and SSE or client-side encryption
  path_prefix: null                         # e.g. 'ap/2026/' to scope a pilot
  file_patterns: ['.*\.pdf', '.*\.(png|jpe?g|tiff?)']
  source_table: null                        # when mode = table: id, file path, optional text
  id_col: null
  path_col: null
  text_col: null                            # pre-extracted text, if the customer already has it
  received_at_col: null
  channel_col: null                         # email / sftp / scan / portal; useful routing signal

# Document types in scope. Each one has an extraction schema in extract-document-fields.
# Keep labels plain English (AI_CLASSIFY guidance): no codes or abbreviations.
document_types:
  in_scope: [invoice, credit_note, purchase_order, contract, insurance_claim_form, w9_tax_form]
  out_of_scope_label: other_document        # always present so nothing is forced into a wrong type

# Reference data used by validation. Absent means that rule family is skipped and said so.
reference:
  vendor_master: null                       # e.g. ERP.AP.VENDORS  (vendor_id, name, tax_id, remit bank last4, status)
  purchase_orders: null                     # e.g. ERP.AP.PO_LINES (po_number, vendor_id, amount, open_amount, currency)
  goods_receipts: null                      # enables three-way match
  policies: null                            # claims: policy_number, effective/expiry, status
  contracts_register: null                  # contracts: counterparty master
  posted_invoices: null                     # duplicate detection against history

# Inference. Preflight confirms availability per function and records the check.
ai:
  cross_region: null                        # value of CORTEX_ENABLED_CROSS_REGION at preflight
  classify_input: text                      # text | file  (file input to AI_CLASSIFY is Preview)
  parse_mode: OCR                           # OCR | LAYOUT; LAYOUT only where tables/structure are extracted from parse output
  extract_input: file                       # file | text
  extract_scale_factor: 1.0                 # 1.0-4.0; raises page tokens linearly, lowers max pages
  complete_model: null                      # only if a fallback AI_COMPLETE step is used; must be GA in region
  verified_on: null

# Per document type, per field. Starting values are PLACEHOLDERS to be replaced by the
# threshold curve in evaluate-intake-accuracy. 'required' fields block auto-approval when null.
thresholds:
  invoice:
    invoice_number:   {min_score: 0.90, required: true}
    invoice_date:     {min_score: 0.90, required: true}
    vendor_name:      {min_score: 0.85, required: true}
    vendor_tax_id:    {min_score: 0.90, required: false}
    po_number:        {min_score: 0.90, required: false}
    currency:         {min_score: 0.80, required: true}
    subtotal_amount:  {min_score: 0.90, required: false}
    tax_amount:       {min_score: 0.90, required: false}
    total_amount:     {min_score: 0.95, required: true}
    due_date:         {min_score: 0.85, required: false}
    payment_terms:    {min_score: 0.80, required: false}
  # contract / insurance_claim_form / credit_note / ... added by extract-document-fields

# Tolerances used by validation rules. Customer policy, not defaults to assume.
tolerances:
  amount_abs: 0.01                          # rounding tolerance on arithmetic checks
  po_match_pct: null                        # e.g. 0.02 = 2% price variance allowed; absent = exact
  max_invoice_age_days: null
  future_date_days: 0

materialization:
  mode: sql                                 # dbt | sql
  project_name: document_intake
  project_object: null
  source_dir: null

experiment:
  run_id: null
  experiment_id: exp_001
  experiment_name: "baseline schemas"
  schema_version: v1

# Sandbox / corpus composition, so evaluation can compare against a known mix.
corpus:
  sandbox_docs: null
  rendered_docs: null
  render_mix: null                          # DIGITAL_PDF / CLEAN_SCAN / DEGRADED_SCAN / FORM / OTHER counts
  corpus_source: null

# Customer-supplied value inputs. Every entry needs source and as_of. No defaults.
value_inputs: {}
#  docs_per_month:          {value: , source: "", as_of: ""}
#  minutes_per_doc_manual:  {value: , source: "", as_of: ""}
#  minutes_per_exception:   {value: , source: "", as_of: ""}
#  loaded_cost_per_hour:    {value: , source: "", as_of: ""}
#  ...

phases:
  preflight: not_started
  seed: not_started
  corpus: not_started
  classify: not_started
  extract: not_started
  validate: not_started
  eval: not_started
  operationalize: not_started
  readout: not_started

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

Plain YAML. Read with the `read` tool and change single keys with `edit`; do not rewrite the file or
shell out to a parser, so user comments and manual overrides survive.

If the file does not exist, the router creates it from the schema above with every `phases` value
`not_started` and every unknown value absent (the `thresholds` block is written with a comment that the
values are placeholders until Phase 5 replaces them).

## Resume behaviour

On entry the router reports `phases`. A `done` phase is not re-run unless asked. A `failed` phase
carries a `failed_reason` sibling key that the router surfaces before anything else.
