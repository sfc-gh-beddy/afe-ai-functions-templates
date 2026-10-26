---
name: build-intake-test-corpus
description: "Render a labeled synthetic corpus of real document FILES for document-intake testing: invoices with line-item tables, credit notes, insurance claim forms with field boxes, multi-page contracts whose key terms are not on page one, W-9 style tax forms, and out-of-scope look-alikes (account statements, newsletters). Each is rendered as a digital PDF, a clean 300-DPI image-only scan, a degraded scan on a graded severity ladder (blur, noise, skew, JPEG, fax thresholding), a phone photo, or a multi-document PDF, with optional PAID/RECEIVED stamps. Emits a field-level answer key, a document-level key, and the vendor/PO/policy reference data validation needs, then stages and loads them. Can also render the seed-intake-sandbox rows so text-path and file-path accuracy compare on identical content. Use when the pipeline must be tested on files, OCR, page metering, or accuracy versus scan quality."
parent_skill: document-intake
---

# Build a labeled document-file test corpus

This play's real input is files. A sandbox of text rows tests classification logic and text-input
extraction; it cannot test what matters most in production — file-input `AI_EXTRACT`, page metering,
and whether a decimal point survives a 150-DPI fax. This skill produces real files with an exact field
answer key so those things are measured rather than assumed.

## When you need it

- Always, before quoting any accuracy or cost figure for a corpus that contains scans or photos (most
  AP mailrooms and claims intakes do).
- To compare text-path and file-path extraction on identical content (`--from-sandbox` mode).
- To find the scan-quality level at which field accuracy falls off, so the business knows which intake
  channels can go straight through and which cannot.

Skip only if preflight proved the production corpus is digital-born end to end — and even then, render
a small sample to measure page-metered cost.

## Two modes

| Mode | Content | Key | Use for |
|---|---|---|---|
| `--generate N` | Fresh documents with real layout: tables, boxed form fields, stamps, multi-page contracts | generated with the document, exact | file-path accuracy, accuracy vs scan severity, cost per page |
| `--from-sandbox DIR` | The `SYN_DOCUMENTS` text from `seed-intake-sandbox`, rendered as plain flowed text | the sandbox keys, unchanged | text-path vs file-path comparison on identical content, the 16 hard cases as files |

Both write keys with identical column names and canonical forms, so `evaluate-intake-accuracy` reads
either without change.

## The render mix

| Kind | Default share | What it forces |
|---|---|---|
| `DIGITAL_PDF` | 35% | text layer present; baseline accuracy |
| `CLEAN_SCAN` | 20% | image-only PDF at 300 DPI with slight skew; OCR with clean signal |
| `DEGRADED_SCAN` | 30% | severity ladder 0.2 / 0.4 / 0.6 / 0.8 / 1.0 — lower DPI, blur, noise, contrast loss, JPEG artefacts, fax-style thresholding at 0.8+ |
| `PHOTO` | 10% | single JPEG of page 1 with perspective tilt and uneven light (bills as one page) |
| `MULTI_DOC` | 5% | invoice plus packing slip in one PDF; expected `EXCEPTION` / `MULTI_DOCUMENT` |

Weighted toward scans on purpose. The question for intake is not whether OCR returns text — modern OCR
nearly always does — but **at what severity amounts, dates, and identifiers start to change**, and
whether the per-field score drops when they do. The ladder makes that a plot instead of an anecdote.

The key adapts to the render. A `PHOTO` of a multi-page document captures page one only, so fields that
print later are re-labelled `NOT_PRESENT` for that file and the expected decision becomes `EXCEPTION`
/ `REQUIRED_FIELD_MISSING`. That is the correct pipeline behaviour, and counting those fields as misses
would understate accuracy.

## What the generated corpus contains

| Type | Share | Built-in traps |
|---|---|---|
| `invoice` | 55% | two number locales, three date locales, four invoice-number styles, PO printed without leading zeros, 1 to 18 line items (long tables span pages), remittance last-4 |
| `credit_note` | 7% | parenthesized negative total, reference to the original invoice |
| `insurance_claim_form` | 14% | boxed form layout, `N/A` police report on non-theft losses (`NOT_PRESENT`), loss dates inside and outside policy coverage |
| `contract` | 8% | 3 to 5 pages; fees and liability cap printed **after** several pages of boilerplate, term and renewal in words and digits |
| `w9_tax_form` | 8% | boxed form; TIN that validation must compare to the vendor master and storage must mask |
| `other_document` | 8% | account statements that contain amounts and dates but must **not** be posted, newsletters, offers |

## Run it

```bash
python -m venv .venv && . .venv/bin/activate
pip install reportlab pymupdf pillow numpy

# Render a SAMPLE first. 100 documents is roughly 120-150 pages.
python scripts/render_intake_corpus.py --generate 100 --outdir ./rendered --seed 7

# Or render the sandbox rows (export the three SYN_ tables to CSV first).
python scripts/render_intake_corpus.py --from-sandbox ./sandbox_export --outdir ./rendered_sbx
```

Output in `--outdir`:

```
files/                    the documents
manifest.csv              document_id, file_name, document_type, render_kind,
                          degradation_severity, stamp, rotation_deg, page_count, channel, corpus_source
field_answer_key.csv      document_id, document_type, field_name, expected_value, expected_status, posts
doc_answer_key.csv        document_id, expected_type, expected_decision, expected_reason, case_role, note
vendor_reference.csv      vendor master for the generated vendors (with locales)
po_reference.csv          POs referenced by generated invoices, with leading zeros, amount = invoice total
policy_reference.csv      policy register for generated claims
counterparty_reference.csv  contract counterparty register (generated vendors)
```

The script writes only synthetic content to the local disk. **Never** point it at real documents; it
would copy their text into local files, which the router's data caution forbids.

## Stage, load, and verify

Run these through the gate one at a time. The document stage must have a directory table and
server-side encryption:

```sql
CREATE STAGE IF NOT EXISTS {{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS
    DIRECTORY  = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');

CREATE STAGE IF NOT EXISTS {{DB}}.{{EVAL_SCHEMA}}.SYN_CORPUS_KEYS
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');      -- keys go to the EVAL schema's stage
```

Upload with the Snowflake CLI, documents and keys to **different** stages so the pipeline role never
sees the keys:

```bash
snow stage copy ./rendered/files/ @{{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS/ --recursive
snow stage copy ./rendered/manifest.csv          @{{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS/_meta/
snow stage copy ./rendered/vendor_reference.csv  @{{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS/_meta/
snow stage copy ./rendered/po_reference.csv      @{{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS/_meta/
snow stage copy ./rendered/policy_reference.csv  @{{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS/_meta/
snow stage copy ./rendered/counterparty_reference.csv @{{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS/_meta/
snow stage copy ./rendered/field_answer_key.csv  @{{DB}}.{{EVAL_SCHEMA}}.SYN_CORPUS_KEYS/
snow stage copy ./rendered/doc_answer_key.csv    @{{DB}}.{{EVAL_SCHEMA}}.SYN_CORPUS_KEYS/
```

Exclude `_meta/` from the pipeline's file patterns (`documents.file_patterns`) or the pipeline will
try to classify its own CSVs. Then refresh and load:

```sql
ALTER STAGE {{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS REFRESH;

CREATE FILE FORMAT IF NOT EXISTS {{DB}}.{{SCHEMA}}.SYN_CSV
    TYPE = CSV PARSE_HEADER = TRUE FIELD_OPTIONALLY_ENCLOSED_BY = '"' EMPTY_FIELD_AS_NULL = TRUE;

CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.SYN_CORPUS_MANIFEST (
    document_id VARCHAR, file_name VARCHAR, document_type VARCHAR, render_kind VARCHAR,
    degradation_severity FLOAT, stamp VARCHAR, rotation_deg FLOAT, page_count INT,
    channel VARCHAR, corpus_source VARCHAR);
COPY INTO {{DB}}.{{SCHEMA}}.SYN_CORPUS_MANIFEST
  FROM @{{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS/_meta/manifest.csv
  FILE_FORMAT = (FORMAT_NAME = '{{DB}}.{{SCHEMA}}.SYN_CSV') MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE;
```

Load `vendor_reference.csv`, `po_reference.csv`, `policy_reference.csv` and
`counterparty_reference.csv` the same way, **appending**
into the sandbox reference tables when both corpora are in use (vendor IDs match the sandbox's, and the
generated PO numbers and policies do not collide with it). Load the two keys into
`{{EVAL_SCHEMA}}.SYN_FIELD_ANSWER_KEY` and `SYN_DOC_ANSWER_KEY` — the same tables the sandbox
populates — with `corpus_source` distinguishing them:

```sql
ALTER TABLE {{DB}}.{{EVAL_SCHEMA}}.SYN_FIELD_ANSWER_KEY ADD COLUMN IF NOT EXISTS corpus_source VARCHAR;
ALTER TABLE {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY   ADD COLUMN IF NOT EXISTS corpus_source VARCHAR;

COPY INTO {{DB}}.{{EVAL_SCHEMA}}.SYN_FIELD_ANSWER_KEY
       (document_id, document_type, field_name, expected_value, expected_status, posts, corpus_source)
  FROM (SELECT $1, $2, $3, NULLIF($4, ''), $5, TRY_TO_BOOLEAN($6), 'SYNTHETIC_RENDERED'
        FROM @{{DB}}.{{EVAL_SCHEMA}}.SYN_CORPUS_KEYS/field_answer_key.csv)
  FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"');
```

`NULLIF($4, '')` matters: the script writes `NOT_PRESENT` values as empty strings, and an empty string
must land as NULL or every `NOT_PRESENT` field scores as a mismatch.

### Verification

```sql
-- 1. Manifest and stage agree. A mismatch means silent upload failures.
SELECT
    (SELECT COUNT(*) FROM {{DB}}.{{SCHEMA}}.SYN_CORPUS_MANIFEST)                            AS manifest_rows,
    (SELECT COUNT(*) FROM DIRECTORY(@{{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS)
      WHERE relative_path NOT LIKE '_meta/%')                                               AS staged_files,
    (SELECT COUNT(*) FROM {{DB}}.{{SCHEMA}}.SYN_CORPUS_MANIFEST m
      LEFT JOIN DIRECTORY(@{{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS) d ON d.relative_path = m.file_name
      WHERE d.relative_path IS NULL)                                                        AS manifest_without_file;
-- manifest_rows = staged_files; manifest_without_file = 0.

-- 2. Every rendered document has a doc key and at least one field key (except
--    other_document, which has no fields by design).
SELECT m.document_type,
       COUNT(*)                                   AS docs,
       COUNT_IF(dk.document_id IS NULL)           AS missing_doc_key,
       COUNT_IF(fk.n IS NULL AND m.document_type <> 'other_document') AS missing_field_key
FROM {{DB}}.{{SCHEMA}}.SYN_CORPUS_MANIFEST m
LEFT JOIN {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY dk USING (document_id)
LEFT JOIN (SELECT document_id, COUNT(*) n FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_FIELD_ANSWER_KEY GROUP BY 1) fk USING (document_id)
GROUP BY 1 ORDER BY 1;

-- 3. Render mix and severity coverage.
SELECT render_kind, degradation_severity, COUNT(*) AS docs, SUM(page_count) AS pages
FROM {{DB}}.{{SCHEMA}}.SYN_CORPUS_MANIFEST
GROUP BY 1, 2 ORDER BY 1, 2;
```

### OCR smoke test — read it for numbers, not for prose

One document per severity level, first page only (bills one page each):

```sql
SELECT m.render_kind, m.degradation_severity, m.document_type,
       LEFT(PARSE_JSON(TO_VARCHAR(AI_PARSE_DOCUMENT(
               TO_FILE('@{{DB}}.{{SCHEMA}}.SYN_CORPUS_DOCS', m.file_name),
               {'mode': 'OCR', 'page_filter': [{'start': 0, 'end': 1}]}
           ))):pages[0]:content::STRING, 600) AS ocr_sample
FROM {{DB}}.{{SCHEMA}}.SYN_CORPUS_MANIFEST m
WHERE m.document_type = 'invoice' AND m.render_kind IN ('CLEAN_SCAN', 'DEGRADED_SCAN')
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.degradation_severity ORDER BY m.document_id) = 1
ORDER BY m.degradation_severity;
```

Compare each sample's total, dates, and invoice number against the field key by eye. The failure that
matters is not missing text; it is **plausible wrong text** — `1,463.70` read as `1,46370`, `03.04`
read as `08.04`, `A10002` read as `410002`. Those produce confident wrong values, and the per-field
score is the only thing that may catch them. Phase 5 measures whether it does.

## Cost warning before rendering at scale

Every rendered page is a billed page in Phases 2 and 3. Before scaling past the sample:

- Count pages, not documents. Contracts render at 3 to 5 pages; long invoices at 2.
- File-based `AI_EXTRACT` meters ~970 tokens per page at `scale_factor` 1.0 (documented); each image
  file counts as one page.
- Classification with `page_filter` on page one bills one page per document; full parsing bills all
  pages.

State the page count at the gate. Report pages and tokens, never dollars.

## What this corpus does not reproduce

Be direct about the limits:

- **Handwriting.** Hand-filled claim forms and handwritten invoice annotations are absent, and they are
  the hardest real case for both extraction and scoring.
- **Real vendor layouts.** Logos, two-column headers, totals in a right-aligned box, remittance stubs
  with tear lines, carbon-copy forms. Synthetic layouts are cleaner and more uniform.
- **Real scanner fleets.** Rendered degradation approximates fax and photocopy; it does not reproduce
  a specific multifunction printer's compression, double-feeds, or pages scanned upside down.
- **Language variety.** Generated text is English with a German/French locale for numbers and dates;
  real multilingual invoices are not represented.

So: synthetic file accuracy is a **ceiling and a wiring test**, not a production forecast. The POC's
accuracy claim comes from a keyed sample of the customer's own documents.

Record the composition in `intake-project.yml` (`corpus.rendered_docs`, `corpus.render_mix`,
`corpus.corpus_source`) and the stages and tables in `created_objects`, then set
`phases.corpus: done`.
