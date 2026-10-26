---
name: build-contract-test-corpus
description: "Optional Phase 1b of the spend-and-contract-leakage build. Renders the synthetic sandbox contracts into real files — digital PDFs with drawn rate tables, clean scans and graded-degradation scans, each with the rate schedule on its own page and an image-only signature page — uploads them to an SSE-encrypted internal stage with a directory table, and points the sandbox document table at them, so AI_PARSE_DOCUMENT, page attribution, table survival, near-duplicate detection of a rescanned contract and low-text page handling are tested against the same answer key. Also explains what public contract corpora can and cannot provide. Triggers: render the contracts, test on PDFs, scanned contracts, build the test corpus, OCR test, do we handle scans, parse real files."
parent_skill: spend-and-contract-leakage
---

# Build the contract test corpus

The sandbox stores contracts as text rows. That exercises extraction and reconciliation, and it
skips the step where real contract programs break: parsing. Rate cards are tables, tables span pages,
schedules sit at the back of 40-page agreements, signature pages are images, and the same contract
arrives twice — once from the CLM and once as a rescan from someone's desk. None of that is visible in
a text column.

This skill renders the same ten contracts into files with those properties. The answer key is
unchanged, so the difference between a text experiment and a file experiment in Phase 5 is exactly
what parsing costs in accuracy, pages and credits on this corpus.

Prerequisites: `phases.seed: done`. Skip this phase only if preflight showed the customer's
contracts are text-native in the CLM; say so in the project file (`phases.corpus: skipped`, with the
reason).

## What it produces

| Document | Render | Tests |
|---|---|---|
| `SYN-DOC-C001` Northwind MSA | digital PDF | Markdown-table rate card survives `LAYOUT`; schedule on its own page |
| `SYN-DOC-C001-A1` Amendment 1 | clean scan | amendment read from an image-only PDF |
| `SYN-DOC-C001-DUP` rescan | degraded scan, 0.6 | **exact-hash dedup no longer fires**; near-duplicate path (similarity plus agreement number) must |
| `SYN-DOC-C002` Contoso supply | digital PDF | two tables (item list, tier schedule) kept distinct; tier caption kept |
| `SYN-DOC-C003` Fabrikam order form | clean scan | prose pricing from OCR text |
| `SYN-DOC-C004` Litware equipment | clean scan | CapEx price table from a scan |
| `SYN-DOC-C006` Tailspin staffing | degraded scan, 0.6 | term end date and bill rate legible under noise |
| `SYN-DOC-C007` Wide World telecom | degraded scan, 0.3 | escalator sentence from a light scan |
| `SYN-DOC-C008` Proseware SOW | digital PDF | EUR table, counterparty name variant |
| `SYN-DOC-N008` NDA | clean scan | classification from OCR text |

Every file ends with an image-only signature page, which must come back as a `LOW_TEXT_PAGE`, not a
parse failure and not a retry.

Severity is graded (0.3, 0.6, 0.9 are available) so the point where small-print tables stop
surviving can be found rather than assumed. Override per document with
`--assign SYN-DOC-C004=DEGRADED_SCAN:0.9`.

## Steps

### 1. Export the sandbox text

The script runs locally and needs the contract text. This is the only place in the plugin where text
leaves the account, and it is allowed **only because every row is synthetic**. The script refuses any
`document_id` not prefixed `SYN-`. Never run it on customer contracts.

```sql
-- From the sandbox schema. Use the Snowflake CLI or Snowsight to export as CSV.
SELECT document_id, file_path, document_text
FROM {{DB}}.{{SCHEMA}}.SYNTH_CONTRACT_DOCUMENTS
ORDER BY document_id;
```

Save as `synth_contract_documents.csv` with a header row.

### 2. Render

```bash
pip install reportlab pymupdf pillow numpy
python scripts/render_contracts.py --input synth_contract_documents.csv --outdir ./rendered
```

Output: one file per document at its `file_path` under `./rendered`, plus `manifest.csv` with
`render_kind`, `degradation_severity`, `page_count`, `schedule_page_index` and
`signature_page_index`. Show the user the per-document summary the script prints.

### 3. Create the stage and upload

AI functions do not read internal stages with `SNOWFLAKE_FULL` encryption, user or table stages, or
stages with double-quoted names. Create a server-side-encrypted stage with a directory table. State
the object at the gate and confirm before creating it.

```sql
CREATE STAGE IF NOT EXISTS {{DB}}.{{SCHEMA}}.CONTRACT_FILES
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  DIRECTORY = (ENABLE = TRUE);
```

Upload preserving the relative paths (from the `./rendered` directory, with the Snowflake CLI):

```bash
snow stage copy ./rendered/contracts @{{DB}}.{{SCHEMA}}.CONTRACT_FILES/contracts --recursive --no-auto-compress
```

`--no-auto-compress` matters: a gzipped PDF on the stage is not a PDF to `AI_PARSE_DOCUMENT`.

Then refresh and check the directory table matches the manifest:

```sql
ALTER STAGE {{DB}}.{{SCHEMA}}.CONTRACT_FILES REFRESH;

SELECT relative_path, size, md5
FROM DIRECTORY(@{{DB}}.{{SCHEMA}}.CONTRACT_FILES)
ORDER BY relative_path;
-- Expect 10 rows whose relative_path values equal SYNTH_CONTRACT_DOCUMENTS.file_path.
```

If the paths came back with a different prefix, fix the upload, not the document table: the answer
key and the documents share `file_path`.

### 4. Load the manifest

```sql
CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.SYNTH_CORPUS_MANIFEST (
    document_id VARCHAR, file_path VARCHAR, render_kind VARCHAR,
    degradation_severity NUMBER(3,2), page_count INT,
    schedule_page_index INT, signature_page_index INT
);
-- Load manifest.csv into it (PUT to the table stage and COPY INTO, or Snowsight load).
```

The manifest is a property of the rendered files, not an answer about the contracts, so it may live
in the sandbox schema. It is used by the corpus checks below and never by a pipeline phase.

### 5. Point staging at the files

Rerun `parse-contract-documents/sql/01_staging_views.sql` with the staging view's `content_md5`
taken from the directory table, so the parse cache keys on file content:

```sql
CREATE OR REPLACE VIEW STG_CONTRACT_DOCUMENTS AS
SELECT d.document_id, d.clm_vendor_id, d.clm_title, d.file_path, d.uploaded_at,
       m.page_count, d.document_text, f.md5 AS content_md5
FROM SYNTH_CONTRACT_DOCUMENTS d
JOIN DIRECTORY(@CONTRACT_FILES) f ON f.relative_path = d.file_path
LEFT JOIN SYNTH_CORPUS_MANIFEST m ON m.document_id = d.document_id;
```

Then run Phase 2 with `{{PARSE_SOURCE}} = FILE` and `{{STAGE}} = @{{DB}}.{{SCHEMA}}.CONTRACT_FILES`,
under a **new `experiment_id`** (for example `exp_002_files`), and continue through Phases 3 to 5.

Record the stage and manifest table in `created_objects`, and `phases.corpus: done`.

## Corpus checks after parsing

```sql
-- C1. Signature pages are low-text pages, not failures.
SELECT m.document_id, m.signature_page_index, p.char_count, p.parse_error
FROM SYNTH_CORPUS_MANIFEST m
LEFT JOIN CONTRACT_PAGES p ON p.document_id = m.document_id AND p.page_index = m.signature_page_index
ORDER BY 1;
-- Expect parse_error = 'LOW_TEXT_PAGE' on every row.

-- C2. The schedule page carries the table in Markdown.
SELECT m.document_id, m.render_kind, m.degradation_severity,
       REGEXP_COUNT(p.page_text, '\\|') AS pipe_chars
FROM SYNTH_CORPUS_MANIFEST m
JOIN CONTRACT_PAGES p ON p.document_id = m.document_id AND p.page_index = m.schedule_page_index
WHERE m.schedule_page_index >= 0
ORDER BY 3, 1;
-- Pipes present means LAYOUT returned a table. Watch where they disappear as severity rises.

-- C3. The rescan was caught as a near duplicate.
SELECT document_id, is_duplicate_of, duplicate_method
FROM CONTRACT_REGISTRY WHERE document_id = 'SYN-DOC-C001-DUP';
-- Expect SYN-DOC-C001, NEAR_DUPLICATE.

-- C4. Every extracted header term resolves to a page. A NULL page_index on
--     an EXTRACTED term means the quote spans a page break.
SELECT document_id, term_name, page_index
FROM CONTRACT_HEADER_TERMS
WHERE experiment_id = '<file experiment id>' AND status = 'EXTRACTED' AND page_index IS NULL;
-- Expect zero or few rows; each one is worth a look.
```

If C3 fails, the duplicate will double every Northwind finding in this experiment and the dollar
reconciliation in Phase 5 will show USD +16,800; that is the trap working as intended, and the fix is
the near-duplicate threshold or the agreement-number extraction on the scan, not the key.

## What to expect between text and file experiments

Expect some loss, and measure it rather than assuming it:

- quotes extracted from OCR text with a stray character fail exact verification and become
  `UNVERIFIED` (rule 2 doing its job; the fix is better parsing or a scale factor, not a fuzzier
  check);
- tier tables on degraded scans may lose a row;
- page counts, and therefore parse cost, are now real.

Report both experiments side by side with R8 in `evaluate-leakage-accuracy`.

## Public contract corpora: what they do and do not provide

Customers sometimes ask to test on "real" contracts. Public sources exist — government procurement
portals publish awarded contracts and price lists, regulatory filings include material agreements as
exhibits, and research datasets of annotated contract clauses are published for legal NLP. They are
useful for one thing here: **realism of length, layout and drafting** for parse and extraction
testing.

What they do not provide:

- **No invoices.** Leakage is a contract-to-spend comparison; a contract corpus alone cannot produce a
  single finding, so finding precision and recall cannot be measured on it.
- **No term key in this plugin's schema.** Clause-annotation datasets label clause types, not the
  normalized values (a notice period in days, a cap in percent) that reconciliation needs. Using one
  for term accuracy requires hand-abstracting a sample into `SYNTH_TERM_KEY_WIDE` shape.
- **Redactions.** Filed exhibits frequently redact exactly the pricing schedules this play reads.

Check each source's license before loading it, keep it in its own schema, and never mix its documents
into a customer's corpus. For finding-level accuracy, extend this sandbox (see "Extending the corpus"
in `seed-spend-leakage-sandbox`) rather than looking for a public substitute.
