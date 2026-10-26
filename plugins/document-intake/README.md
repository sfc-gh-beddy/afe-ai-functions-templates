# Document Intake

A guided build for an intelligent document intake pipeline — invoices, credit notes, contracts,
insurance claim forms, and tax forms — that runs entirely inside Snowflake on files the organization
has already landed on a stage.

## The problem

Back offices re-key documents they already received electronically. An invoice arrives as a PDF; a
person reads it, types a dozen fields into an ERP screen, checks the PO, and fixes the vendor name. A
claim arrives as a faxed form; a person sorts it, finds the policy number, and keys the loss date. That
costs twice:

- **OpEx.** Keying, checking, and matching labor scales with document volume, not with value added.
- **Working capital.** Invoices approved late miss early-payment discount windows and incur late fees;
  duplicates get paid; claims and contracts wait in queues that delay the decisions downstream.

The usual automation answer — OCR plus "confidence above a threshold posts automatically" — creates a
third cost that is easy to miss: **confidently wrong values posted straight into the ledger.** This
plugin is built around preventing that.

## What this plugin builds

```
Files on a stage (PDF, scans, photos, DOCX)
  -> classify            AI_CLASSIFY on a first-page sample; byte-duplicate, size, page-limit and
                         multi-document checks; every file gets a type, a route, and a reason
  -> extract             AI_EXTRACT per document type with scores => TRUE (per-field confidence),
                         line-item tables, AI_PARSE_DOCUMENT text path for long contracts
  -> normalize           one set of UDFs for amounts (decimal comma, parentheses), dates (dd/mm vs mm/dd
                         resolved by vendor locale, never guessed), document numbers, tax IDs, names
  -> validate            per-field thresholds, required fields, arithmetic, vendor / PO / policy /
                         counterparty checks, remittance bank-change detection, duplicate detection
  -> decide              AUTO_APPROVED | EXCEPTION | REJECTED, in SQL, never by the model
  -> post or queue       INTAKE_APPROVED for downstream systems; EXCEPTIONS_QUEUE listing every
                         failing field and rule, prioritized by money and due date
```

The deliverables are two tables and a measurement. `INTAKE_APPROVED` holds documents a downstream
system can consume without a human. `EXCEPTIONS_QUEUE` holds everything else, with exactly what a
reviewer needs to fix it. The evaluation reports field accuracy, straight-through-processing (STP)
rate, the **false-STP rate** (auto-approved with a wrong posting value), and credits per 1K pages.

## What it does not build

- **Ingestion.** Email capture, SFTP, scanner and connector setup are out of scope; files are assumed
  landed on a stage with a directory table.
- **A reviewer application.** The queue schema, reviewer columns, and a `REVIEW_CORRECTIONS` feedback
  table are defined; the UI is not.
- **Writes to ERP, claims, or CLM systems.** Downstream systems read `INTAKE_APPROVED`; nothing here
  posts into them.

## Getting started

Ask in plain language. The router picks up phrases like:

- "automate our invoice intake"
- "extract fields from the claims PDFs on our stage"
- "what's our straight-through processing rate going to be"
- "build an exceptions queue for AP"
- "pull contract renewal dates out of our agreements"

The build runs in gated phases. Each phase says what it will create and what it will consume (pages and
tokens, never dollars), waits for confirmation, runs, and shows a verification query. State lives in
`intake-project.yml` in the working directory, so the build can be stopped and resumed.

**Start in the sandbox.** Phase 1 generates a few hundred invoices rendered from a truth table in
several number and date locales, plus sixteen hand-authored hard cases (payment-redirection bank
change, renumbered duplicate, broken line arithmetic, ambiguous `03.04.2026`, credit note, lapsed
policy, multi-document file, out-of-scope statement, and more), with an exact field-level answer key.
Field accuracy, STP, and false STP are measurable on day one.

**Then render the files.** `build-intake-test-corpus` produces real PDFs, clean scans, degraded scans on
a graded severity ladder, phone photos, and multi-document files — with layout, tables, form boxes and
stamps — plus the same answer-key format and the reference data validation needs. That is what tests
file-based extraction, OCR, page metering, and how accuracy falls with scan quality. It can also render
the sandbox rows, so text-path and file-path accuracy compare on identical content.

**Then key a real sample.** Synthetic accuracy proves the wiring. A customer-keyed sample of their own
documents is what the go-live decision rests on; the POC criteria require it.

## Skills

| Skill | Role |
|---|---|
| `document-intake` | Entry point. Intent detection, phase gating, state file, dbt choice, diagnosis guide. |
| `document-intake-system-of-record` | Preflight: function access, region and cross-region setting, stage readiness, page inventory, reference data and key formats, sensitive-data posture. |
| `document-intake-best-practices` | Correctness rules. Always loaded. |
| `seed-intake-sandbox` | Synthetic reference data, documents, and field- and document-level answer keys. Runnable SQL in `sql/`. |
| `build-intake-test-corpus` | Renders labeled document files (digital, scanned, degraded, photo, multi-document) and stages them with keys and reference data. Python in `scripts/`. |
| `classify-intake-documents` | Type routing with AI_CLASSIFY on a page-filtered sample; duplicates, limits, multi-document detection. |
| `extract-document-fields` | AI_EXTRACT schemas per type with per-field scores; shared normalizer UDFs in `sql/`. |
| `validate-and-queue-exceptions` | Thresholds, business rules, the decision, the approved table, the exceptions queue, reviewer feedback. |
| `evaluate-intake-accuracy` | Field exact/normalized match, STP, false STP, threshold curves, silent loss, credits per 1K pages. |
| `operationalize-intake-pipeline` | Stage stream, task graph, monitoring and STP audit sampling, semantic view, Cortex Agent for CoWork. |
| `intake-value-readout` | Value narrative from measured results and customer-supplied inputs only; POC criteria. |

## Requirements

- A role with `SNOWFLAKE.CORTEX_USER` (or equivalent) — preflight verifies with `EXPLAIN_PRIVILEGES`.
- `AI_EXTRACT` available in the account's region natively or through cross-region inference;
  preflight reports `CORTEX_ENABLED_CROSS_REGION` and treats any change to it as the customer's
  data-residency decision.
- A stage with a directory table and server- or client-side encryption.
- A SMALL or MEDIUM warehouse (larger does not speed the document functions), and a database and
  schema the role can create objects in.
- For the test corpus: Python 3 with `reportlab`, `pymupdf`, `pillow`, `numpy`, and the Snowflake CLI
  for staging.

## A note on sensitive data

Every AI function call runs inside Snowflake. Invoices carry bank details and tax IDs, W-9s carry
taxpayer IDs, and claims carry personal and sometimes health information; extraction turns images few
people query into tables many people can. Preflight reports existing masking and row access policies
and who can read the stage, and the extraction and validation designs store bank details as last-four
plus comparison only, keep TINs out of validation detail, and exclude claim narratives by default.
