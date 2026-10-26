# ICD-10 Code Extraction

A guided build for an ICD-10 / HCC suspecting pipeline that runs entirely inside Snowflake, on
clinical documents the organization already stores.

## The problem

Healthcare payers and providers sit on large volumes of unstructured clinical documents — visit
notes, referrals, echo and imaging reports, labs, scanned faxes. The diagnoses those documents
support are frequently never coded. That gap costs twice:

- **Unrecovered risk-adjustment revenue.** An uncoded HCC is unfunded care. The clinical evidence
  that would have justified the code was captured, filed, and never read again.
- **Undetected disease progression.** A patient with a documented declining eGFR, a falling
  ejection fraction, or a new non-healing ulcer who is never flagged is a patient who does not get
  the follow-up that record already justifies.

Both gaps close with documents that are already in the account. Nothing needs to be acquired.

## What this plugin builds

```
Existing clinical documents
  -> cost-tiered routing        cheap metadata and partial-OCR exits before expensive paths
  -> tiered extraction          full OCR, direct text, or targeted field pull per tier
  -> chart compression          cheap model reduces tokens before the expensive reasoning step
  -> coder agent                one focused pass per target condition, grounded in coding guidance
  -> scored suspect output      ICD-10 + confidence + the specific evidence behind it
```

The deliverable is an output table. Every row is a suspected code with a confidence score and the
cited clinical findings — including which source document each finding came from — so a coder or
clinician can accept or dismiss it without re-reading the chart.

## What it does not build

- **Ingestion.** Documents are assumed to be landed in Snowflake already. Use the Snowflake
  ingestion skills for external stages, queue notifications, and streams.
- **A review application.** The pipeline ends at the output table. Reviewer and status columns are
  defined and defaulted so a review workflow can be layered on later without a migration, but
  nothing here writes them.

## Getting started

Ask for it in plain language. The router picks up phrases like:

- "help me find uncoded diagnoses in our clinical notes"
- "set up ICD-10 extraction on our documents"
- "build an HCC suspecting pipeline"
- "we have RAF gaps, what can we do with the charts we already have"

The build runs in six gated phases. Each phase says what it will create, waits for confirmation,
runs, and shows a verification query. State lives in `icd10-project.yml` in the working directory,
so the build can be stopped and resumed.

**Start in the sandbox.** Phase 1 generates a synthetic clinical corpus with a labeled answer key.
That means the accuracy harness produces real recall and precision numbers on day one, and the
pipeline can be demonstrated and tuned before a PHI access review completes.

**If the corpus is materially scanned**, also run `build-document-test-corpus`. Note text in a table
cannot exercise the OCR or form tiers — it renders text into real PDFs, graded-degradation scans and
structured forms on a stage, so routing is tested rather than simulated. It also covers importing an
open external corpus for background realism, with an honest assessment of what such corpora do and do
not provide — notably, they carry no coding labels and so cannot measure recall on their own.

## Skills

| Skill | Role |
|---|---|
| `icd10-extraction` | Entry point. Intent detection and phase gating. |
| `icd10-extraction-system-of-record` | Preflight: model availability, document inventory, PHI posture. |
| `icd10-extraction-best-practices` | Correctness rules. Always loaded. |
| `seed-icd10-sandbox` | Synthetic corpus with planted signals and a labeled answer key. |
| `build-document-test-corpus` | Renders note text into real files on a stage so the OCR and form tiers actually run. Optional. |
| `classify-and-route-documents` | Cost-tier routing engine. |
| `build-coding-knowledge-store` | Cortex Search over coding guidance, or curated guideline tables. |
| `extract-clinical-evidence` | Per-tier extraction and chart compression. |
| `suspect-icd10-codes` | The coder agent and the scored output table. |
| `evaluate-icd10-accuracy` | Recall, precision, specificity, cost, and parse-failure reporting. |

## Requirements

- A role with Cortex AI function access (`SNOWFLAKE.CORTEX_USER` or equivalent) — preflight verifies
  this and reports the exact missing grant if not.
- A warehouse, and a database and schema the role can create objects in.
- Model availability in the account's region for the four pipeline stages — also verified at
  preflight, since availability varies by region.

## A note on PHI

Every AI function call runs inside Snowflake; document text does not leave the account boundary.
Preflight reports existing masking and row access policies on the source documents and on the
output table, because a suspect record contains clinical detail and inherits the sensitivity of the
chart it came from.
