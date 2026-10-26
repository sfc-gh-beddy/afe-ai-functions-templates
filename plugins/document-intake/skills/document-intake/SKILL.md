---
name: document-intake
description: "**[REQUIRED]** Use for ALL requests about automating intake of invoices, contracts, insurance claims, or business forms that already sit on a Snowflake stage or in a table. Triggers: document intake, intelligent document processing, IDP, invoice processing, invoice automation, accounts payable automation, AP automation, invoice capture, invoice data extraction, PO matching, three-way match, contract extraction, contract data extraction, contract metadata, claims intake, claims processing automation, FNOL documents, form extraction, form processing, extract fields from PDFs, extract data from scanned documents, OCR pipeline, straight-through processing, STP rate, exceptions queue, human-in-the-loop review, manual data entry reduction, back-office automation, document routing, document classification, mailroom automation, days payable outstanding, early payment discount capture, working capital from invoices. This is the REQUIRED entry point — even if the request seems simple. DO NOT hand-write AI_EXTRACT or AI_PARSE_DOCUMENT pipelines manually; always invoke this skill first."
---

# Document Intake — Router

## What this builds and why

Back offices re-key documents they already received electronically. An invoice arrives as a PDF, a
person reads it, types eleven fields into an ERP screen, checks the PO, and fixes the vendor name. A
claim packet arrives as a scanned fax, a person sorts it, finds the policy number, and keys the loss
date. That labor is the OpEx lever. The time it takes is the working-capital lever: invoices keyed late
miss early-payment discount windows and incur late fees; claims and contracts that sit in a queue
delay downstream decisions.

This plugin builds a pipeline over documents **already in Snowflake** that:

1. classifies each document by type so it gets the right extraction schema;
2. reads it (`AI_PARSE_DOCUMENT` when text is needed, `AI_EXTRACT` for fields, with per-field scores);
3. normalizes and validates every field against business rules and systems of record;
4. posts what is confident **and** valid straight through, and routes everything else to an
   exceptions queue that tells a reviewer exactly which field failed and why.

**Scope boundary.** Ingestion is out of scope — files are assumed landed on a stage (email capture,
SFTP, scanner, and connector setup belong to the ingestion skills). The pipeline ends at two tables:
an approved-documents table ready for a downstream system to consume, and an exceptions queue. This
plugin defines the queue schema, reviewer columns, and a correction feedback table; it does not build
a reviewer application, and it never writes into the customer's ERP, claims, or CLM system.

## Setup — do these before anything else

1. **Read** `PROJECT_STATE.md` (this directory). It defines `intake-project.yml`, the single state
   file every phase reads and writes.
2. **Load** `document-intake-system-of-record/SKILL.md`. Required first step in every session — it
   establishes what the account can run (functions, regions, cross-region setting) and what documents
   and reference data actually exist.
3. **Load** `document-intake-best-practices/SKILL.md`. Required. These rules prevent failure modes
   where the pipeline posts confidently wrong numbers while every dashboard looks green.
4. **Settle the materialization** — dbt project or plain SQL — and record it in
   `materialization.mode`. Ask once, at preflight. Read `DBT_MATERIALIZATION.md` for the phase-to-model
   mapping and delegate dbt deploy, execute, and versioning mechanics to the
   **`dbt-projects-on-snowflake`** skill.

   Recommend dbt when the build will outlive the demo: the validation rules become build-failing dbt
   tests, and the extraction schemas get version control — which matters here because a schema edit
   silently changes what every downstream consumer receives. Recommend plain SQL for a time-boxed
   proof of value or a team without dbt. Say plainly what is given up.

> **Data caution.** Invoices carry bank account numbers and tax IDs. Claims carry personal and
> sometimes health information. Contracts carry commercial terms. Never write document text or
> extracted field values into a local file, a log, an issue tracker, or any destination outside the
> account. Show sample rows only when asked, and prefer sandbox rows for demos.

## Intent detection

| Intent | Trigger phrases | Route |
|---|---|---|
| **BUILD** | "set up invoice extraction", "automate our AP intake", "build a document intake pipeline", "start from scratch" | Run the phased build below |
| **RESUME** | "continue", "pick up where we left off", "what's left" | Read `phases` in `intake-project.yml`, report, continue at the first phase not `done` |
| **SINGLE_PHASE** | "just the classifier", "re-extract the invoices", "add a validation rule", "regenerate the sandbox", "render the test PDFs" | Load that phase's skill directly after confirming prerequisites are `done` |
| **EVALUATE** | "how accurate is it", "what's our STP rate", "what does this cost per page", "field accuracy" | `evaluate-intake-accuracy/SKILL.md` |
| **TUNE** | "too many exceptions", "reviewers are overwhelmed", "raise the threshold", "it's posting bad totals" | `evaluate-intake-accuracy/SKILL.md` (threshold curve), then `validate-and-queue-exceptions` |
| **DEBUG** | "fields are null", "everything goes to exceptions", "totals are wrong", "nothing posts", "the vendor never matches" | `DIAGNOSING.md` (this directory) |
| **VALUE** | "what is this worth", "build the business case", "ROI", "POC success criteria" | `intake-value-readout/SKILL.md` |
| **OPERATIONALIZE** | "make it incremental", "schedule it", "semantic view", "agent for the AP team", "CoWork" | `operationalize-intake-pipeline/SKILL.md` |
| **EXPLAIN** | "how does this work", "walk me through the architecture" | Answer from this file. Create nothing. |

If intent is unclear, ask — do not default to BUILD, because BUILD creates objects and spends credits.

## The phased build

**Each phase is a gate**, and the gate protocol is not optional:

1. State what the phase will create — object names and types.
2. State what it will consume when it calls AI functions over a corpus: **pages** for
   `AI_PARSE_DOCUMENT` and file-based `AI_EXTRACT` (both meter by page), tokens for text calls via
   `AI_COUNT_TOKENS` (input only, so a floor). Never convert to dollars.
3. Get confirmation with `ask_user_question`.
4. Run it.
5. Show a verification query and its actual result.
6. Update `phases` and `created_objects` in `intake-project.yml`.

Never chain two gates without stopping. A user who wanted to try the classifier on 50 invoices should
not find that layout parsing already ran over 40,000 pages.

| # | Phase | Skill | Creates | Skippable |
|---|---|---|---|---|
| 0 | Preflight | `document-intake-system-of-record` | nothing | no |
| 1 | Sandbox | `seed-intake-sandbox` | reference data (vendors, POs, policies), text documents, field answer key | yes, if a labeled real sample exists |
| 1b | File corpus | `build-intake-test-corpus` | rendered PDFs, clean and degraded scans, forms, plus field answer key, on a stage | yes — but required to exercise file-based extraction and OCR |
| 2 | Classify | `classify-intake-documents` | `DOC_CLASSIFICATION` with type, route, and reason | no |
| 3 | Extract | `extract-document-fields` | `EXTRACTED_FIELDS` (one row per document x field, with score) | no |
| 4 | Validate | `validate-and-queue-exceptions` | `FIELD_VALIDATION`, `DOCUMENT_DECISION`, `INTAKE_APPROVED`, `EXCEPTIONS_QUEUE` | no |
| 5 | Evaluate | `evaluate-intake-accuracy` | accuracy, STP, false-STP, cost reports | no |
| 6 | Operationalize | `operationalize-intake-pipeline` | stream, tasks or dynamic tables, semantic view, agent | yes, for a one-off POC |
| 7 | Value readout | `intake-value-readout` | value narrative and POC criteria | no |

Phase 1b matters more here than in a text play. This pipeline's real input is **files**. A sandbox of
text rows can test classification and text-based extraction, but it cannot test file-based
`AI_EXTRACT`, page metering, or what happens to a decimal point on a 150-DPI fax. If preflight shows
the customer's corpus is files (it almost always is), run 1b.

### Phase order is a dependency chain

- Classify before extract: the extraction schema is chosen by document type. An invoice schema run on
  a contract returns plausible-looking garbage with high scores on nothing.
- Extract before validate: validation needs normalized values and per-field scores.
- Validate before anything posts: there is no path from extraction to `INTAKE_APPROVED` that does not
  pass through the decision table. Never shortcut it, even "temporarily".
- Evaluate before operationalize: scheduling a pipeline whose false-STP rate is unknown automates the
  posting of wrong amounts.
- Value readout last, from measured STP and exception rates — never from a target rate.

### Strongly recommend the sandbox and corpus first

Push back once, politely, if the user wants to skip straight to real documents:

> The sandbox ships a field-level answer key, so field accuracy, STP rate and — most importantly —
> the false-STP rate (documents that posted automatically with a wrong value) are measurable on day
> one. On real documents there is no ground truth until someone keys a labeled sample, so the pipeline
> will report a high STP rate with no way to tell how many of those posts were wrong.

If they still want real data, do it, mark `seed: skipped`, and propose a keyed sample of 100–300
real documents as the accuracy baseline (see `evaluate-intake-accuracy`).

## The decision contract

Every document ends in exactly one state, and the state is decided in SQL, not by the model:

| State | Meaning |
|---|---|
| `AUTO_APPROVED` | every required field present, every field score at or above its threshold, every blocking validation passed |
| `EXCEPTION` | anything else; one queue row per document listing every failing field and rule |
| `REJECTED` | not a supported document type (or a duplicate), with the reason |

`AI_EXTRACT` scores are **inputs** to that decision, not the decision. A high score on a total that
does not equal the sum of its line items is still an exception. A model never decides that a document
posts.

## Every run is a labelled experiment

Extraction is tuned by changing schema questions, `scale_factor`, mode, and thresholds. Before Phase 3,
set `experiment.run_id`, `experiment_id`, `experiment_name`, and `schema_version` in
`intake-project.yml`. Persist a `schema_hash` computed from the exact `responseFormat` object sent, on
every extracted row. Extraction and evaluation layers accumulate rather than replace, so
`experiment_id` supports a side-by-side comparison of two schema versions on the same documents.

## Verification queries at each gate

| Phase | Verification |
|---|---|
| Classify | type distribution with counts; documents with NULL type (must be zero — errors land as `UNCLASSIFIED`, not NULL); low-text scans routed to OCR |
| File corpus | staged file count equals manifest count; one OCR smoke test per degradation level, read for whether **amounts and dates** survived |
| Extract | documents with an extraction error; required fields NULL by type; score distribution per field |
| Validate | decision distribution; every `EXCEPTION` has at least one reason row; zero documents in `INTAKE_APPROVED` that are not `AUTO_APPROVED` |
| Evaluate | field exact and normalized accuracy, STP rate, false-STP rate, credits per 1K pages, parse/extract error count |

## When the user asks what this costs

Stay in pages, tokens, and credits. `AI_PARSE_DOCUMENT` meters per page; file-based `AI_EXTRACT`
meters per page (documented as 970 tokens per page at `scale_factor` 1.0, scaling linearly with
`scale_factor`) plus prompt and output tokens. The levers are: route text-native documents away from
OCR, use `page_filter` for classification samples, avoid parsing **and** extracting the same pages
unless the parse output is needed, and keep `scale_factor` at 1.0 unless a measured accuracy gain
justifies the multiplier. Phase 5 reports credits per 1K pages measured from
`SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` — never a quoted rate.

## Teardown

Read `created_objects` from `intake-project.yml` and drop exactly those objects — never guess names.
Confirm first and name each object. Warn explicitly if `EXCEPTIONS_QUEUE` contains rows with reviewer
activity, or if a downstream system has been reading `INTAKE_APPROVED`, because dropping either loses
audit history of what was posted and why.
