---
name: classify-intake-documents
description: "Phase 2 of the document-intake build: decide what every file on the stage is before any extraction schema runs. Enumerates files from the directory table, skips byte-identical duplicates by MD5, samples the first page(s) with AI_PARSE_DOCUMENT page_filter (or uses an existing text layer), classifies with AI_CLASSIFY using plain-English labels with descriptions and an explicit other_document label, detects multi-document files with per-page classification, maps AI errors to an UNCLASSIFIED exception route instead of NULL, enforces page and size limits, and writes DOC_CLASSIFICATION with type, route, and reason for every file. Use for document routing, document type classification, mailroom sorting, or 'which extraction schema should this use'."
parent_skill: document-intake
---

# Classify and route documents

Every file gets exactly one row in `DOC_CLASSIFICATION`, with a type, a route, and a reason. Nothing is
extracted here. This phase decides which extraction schema each document gets — and getting it wrong is
expensive, because an invoice schema run on a contract returns confident nonsense.

## The order of operations: cheapest signal first

```
1. Directory metadata      no AI call      extension, size, path prefix, MD5
2. Byte duplicates         no AI call      MD5 already seen -> REJECT
3. Limits                  no AI call      > 100 MB, unsupported extension -> EXCEPTION
4. First-page text         page_filter     one billed page per file (or free, if a text layer exists)
5. AI_CLASSIFY             tokens          plain-English labels with descriptions
6. Multi-document check    page_filter     only for files with more than a few pages
7. Route assignment        no AI call      type -> EXTRACT | EXCEPTION | REJECT
```

## Step 1 — enumerate files

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.INBOUND_FILES (
    document_id     VARCHAR,          -- stable: derived from path + md5, see below
    relative_path   VARCHAR,
    file_ext        VARCHAR,
    size_bytes      NUMBER,
    md5             VARCHAR,
    last_modified   TIMESTAMP_TZ,
    discovered_at   TIMESTAMP_LTZ,
    run_id          VARCHAR
);

MERGE INTO {{DB}}.{{SCHEMA}}.INBOUND_FILES t
USING (
    SELECT
        -- Content-addressed id: a re-upload of the same bytes under the same path
        -- is the same document; a changed file is a new one.
        SHA2(relative_path || '::' || md5)                                 AS document_id,
        relative_path,
        LOWER(REGEXP_SUBSTR(relative_path, '\\.([A-Za-z0-9]+)$', 1, 1, 'e')) AS file_ext,
        size                                                                AS size_bytes,
        md5,
        last_modified
    FROM DIRECTORY(@{{STAGE_FQN}})
    WHERE NOT STARTSWITH(relative_path, '_meta/')
      AND REGEXP_LIKE(LOWER(relative_path), '.*\\.(pdf|png|jpe?g|tiff?|docx?|html?|txt)$')
) s
ON t.document_id = s.document_id
WHEN NOT MATCHED THEN INSERT
    (document_id, relative_path, file_ext, size_bytes, md5, last_modified, discovered_at, run_id)
VALUES
    (s.document_id, s.relative_path, s.file_ext, s.size_bytes, s.md5, s.last_modified,
     CURRENT_TIMESTAMP(), :run_id);
```

Refresh the directory first (`ALTER STAGE ... REFRESH`) for internal stages, or confirm auto-refresh is
working for external stages. A stale directory is the single most common reason "new files are not
being picked up".

Files the regex excludes are not forgotten — list them at the gate:

```sql
SELECT LOWER(REGEXP_SUBSTR(relative_path, '\\.([A-Za-z0-9]+)$', 1, 1, 'e')) AS ext, COUNT(*) AS files
FROM DIRECTORY(@{{STAGE_FQN}})
WHERE NOT REGEXP_LIKE(LOWER(relative_path), '.*\\.(pdf|png|jpe?g|tiff?|docx?|html?|txt)$')
GROUP BY 1 ORDER BY files DESC;
```

Note that `AI_PARSE_DOCUMENT` does not accept `.doc` (it lists DOCX), and `AI_CLASSIFY` document input
does not accept images. The supported-format lists differ per function; route accordingly.

### Table mode (the sandbox, or documents with an existing text layer)

When `documents.mode = table`, there is no directory to enumerate. Build the same candidate shape from
the table, with the content hash taken over the text:

```sql
CREATE OR REPLACE TEMPORARY TABLE CLASSIFY_CANDIDATES AS
SELECT d.document_id,
       d.file_name                                   AS relative_path,
       LOWER(REGEXP_SUBSTR(d.file_name, '\\.([A-Za-z0-9]+)$', 1, 1, 'e')) AS file_ext,
       LENGTH(d.document_text)                       AS size_bytes,
       MD5(d.document_text)                          AS md5,
       d.received_at                                 AS last_modified,
       ROW_NUMBER() OVER (PARTITION BY MD5(d.document_text) ORDER BY d.received_at, d.document_id) AS md5_rank
FROM {{DB}}.{{SCHEMA}}.SYN_DOCUMENTS d
WHERE NOT EXISTS (SELECT 1 FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION c WHERE c.document_id = d.document_id);

INSERT INTO {{DB}}.{{SCHEMA}}.DOC_PAGE_SAMPLE
SELECT d.document_id, :run_id, d.page_count,
       -- First page only: split on form feed if present (the sandbox uses \f
       -- between documents in multi-document files), else the leading text.
       SPLIT_PART(d.document_text, '\f', 1), NULL, CURRENT_TIMESTAMP()
FROM {{DB}}.{{SCHEMA}}.SYN_DOCUMENTS d
JOIN CLASSIFY_CANDIDATES c USING (document_id)
WHERE c.md5_rank = 1;
```

Skip step 4's parse in table mode (there is nothing to parse) and run step 6 over the `\f`-separated
parts instead of `page_filter` pages. Everything else is identical, which is the point: the sandbox
exercises the same routing and the same `DOC_CLASSIFICATION` contract as files do.

## Step 2 — byte duplicates

```sql
CREATE OR REPLACE TEMPORARY TABLE CLASSIFY_CANDIDATES AS
SELECT f.*,
       ROW_NUMBER() OVER (PARTITION BY f.md5 ORDER BY f.last_modified, f.relative_path) AS md5_rank
FROM {{DB}}.{{SCHEMA}}.INBOUND_FILES f
WHERE NOT EXISTS (
    SELECT 1 FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION c WHERE c.document_id = f.document_id
);
```

`md5_rank > 1` is a byte-identical resend: route `REJECT` with reason `DUP_FILE_HASH`. Also check
against files classified in earlier runs (same `md5`, different `document_id` because the path
changed). Keep the row; a deleted duplicate cannot be explained later.

Byte identity is only the cheap half of duplicate detection. A rescanned paper invoice has different
bytes. The business-level duplicate check (vendor + normalized invoice number) runs in Phase 4.

## Step 3 — limits

Route to `EXCEPTION` with a specific reason, before spending a page:

| Condition | Reason |
|---|---|
| `size_bytes > 100 * 1024 * 1024` | `FILE_TOO_LARGE` (both document functions cap at 100 MB) |
| extension unsupported by the functions the route needs | `UNSUPPORTED_FORMAT` |
| page count > 125 / `scale_factor` (known after step 4) | `EXCEEDS_EXTRACT_PAGE_LIMIT` — needs page selection or text-path extraction |

## Step 4 — first-page text for the classifier

Two sources, cheapest first:

1. **An existing text layer** — if the customer's table already carries OCR text from an upstream
   system (`documents.text_col`), use its first 3,000 characters. Free.
2. **`AI_PARSE_DOCUMENT` with `page_filter`** on page 0 only. One billed page per file (image files
   always count as one page). `page_split` alone does **not** limit pages billed.

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.DOC_PAGE_SAMPLE (
    document_id   VARCHAR,
    run_id        VARCHAR,
    page_count    INT,
    sample_text   VARCHAR,
    parse_error   VARCHAR,
    sampled_at    TIMESTAMP_LTZ
);

INSERT INTO {{DB}}.{{SCHEMA}}.DOC_PAGE_SAMPLE
SELECT
    c.document_id,
    :run_id,
    COALESCE(r:value:metadata:pageCount, r:metadata:pageCount)::INT AS page_count,
    r:value:pages[0]:content::STRING                                AS sample_text,
    r:error::STRING                                                 AS parse_error,
    CURRENT_TIMESTAMP()
FROM (
    SELECT c.*,
           AI_PARSE_DOCUMENT(
               TO_FILE('@{{STAGE_FQN}}', c.relative_path),
               {'mode': 'OCR', 'page_filter': [{'start': 0, 'end': 1}]},
               TRUE                                   -- return_error_details: errors are data, not NULLs
           ) AS r
    FROM CLASSIFY_CANDIDATES c
    WHERE c.md5_rank = 1
      AND c.size_bytes <= 100 * 1024 * 1024
      AND c.file_ext IN ('pdf', 'png', 'jpg', 'jpeg', 'tif', 'tiff', 'docx', 'html', 'htm', 'txt')
) c;
```

`OCR` mode is enough for classification; `LAYOUT` costs the same per page but returns Markdown that is
noisier for a classifier and is only worth it when the parse output feeds extraction.

**The blank-first-page problem.** Fax cover sheets, scanner separator sheets, and email-to-PDF banners
put nothing useful on page one. Count them:

```sql
SELECT COUNT(*) AS near_empty_first_page
FROM {{DB}}.{{SCHEMA}}.DOC_PAGE_SAMPLE
WHERE run_id = :run_id AND parse_error IS NULL AND LENGTH(TRIM(sample_text)) < 40;
```

For those, sample page 1 (`{'start': 1, 'end': 2}`) — one more billed page each — rather than
classifying on emptiness. If the corpus systematically has cover sheets, sample pages 0 and 1 for every
multi-page file and say why.

## Step 5 — classify

Labels are plain English, mutually exclusive, and described in 25 words or fewer each (the documented
limit). Always include the out-of-scope label. Descriptions are billed as input tokens on every row, so
keep them tight.

```sql
SET classify_labels = '[
  {"label": "invoice",              "description": "A supplier bill requesting payment, with an invoice number, amounts due and usually line items"},
  {"label": "credit_note",          "description": "A supplier document reducing an amount owed, usually referencing an earlier invoice, often with a negative total"},
  {"label": "purchase_order",       "description": "A buyer document ordering goods or services from a supplier, with a PO number"},
  {"label": "contract",             "description": "A legal agreement between parties with terms, obligations, signatures, effective date and governing law"},
  {"label": "insurance_claim_form", "description": "A form reporting a loss or damage against an insurance policy, with a policy number and date of loss"},
  {"label": "w9_tax_form",          "description": "A taxpayer identification form giving a legal name, tax classification and tax identification number"},
  {"label": "other_document",       "description": "Anything else: account statements, remittance advice, packing slips, newsletters, letters, marketing"}
]';
```

Two subtle choices are encoded there. **Account statements and remittance advice are `other_document`**
even though they carry amounts and dates — they are the most common thing an invoice pipeline wrongly
posts. And **packing slips are `other_document`**, so a packing-slip page inside an invoice file shows
up as a type change in step 6.

Remove labels for types not in `document_types.in_scope`, but keep `other_document`. Estimate tokens
before running:

```sql
SELECT SUM(AI_COUNT_TOKENS('ai_classify', LEFT(sample_text, 3000), PARSE_JSON($classify_labels))) AS est_input_tokens,
       COUNT(*) AS docs
FROM {{DB}}.{{SCHEMA}}.DOC_PAGE_SAMPLE
WHERE run_id = :run_id AND parse_error IS NULL;
```

`AI_COUNT_TOKENS` for `ai_classify` is documented as exact for the default model, and it includes the
labels. It does not include output. Present as a floor.

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION (
    document_id        VARCHAR,
    relative_path      VARCHAR,
    run_id             VARCHAR,
    page_count         INT,
    document_type      VARCHAR,       -- never NULL: errors become 'UNCLASSIFIED'
    page_types         ARRAY,         -- per-page labels when step 6 ran
    is_multi_document  BOOLEAN,
    route              VARCHAR,       -- EXTRACT | EXCEPTION | REJECT
    route_reason       VARCHAR,
    classify_error     VARCHAR,
    path_hint          VARCHAR,       -- folder-derived hint, for agreement checks only
    received_at        TIMESTAMP_TZ,  -- file last_modified, or the table's received_at column
    classified_at      TIMESTAMP_LTZ
);

CREATE OR REPLACE TEMPORARY TABLE CLASSIFY_RESULTS AS
SELECT
    s.document_id,
    s.page_count,
    s.parse_error,
    IFF(s.parse_error IS NULL AND LENGTH(TRIM(s.sample_text)) >= 40,
        AI_CLASSIFY(
            LEFT(s.sample_text, 3000),
            PARSE_JSON($classify_labels),
            {'task_description': 'Classify the type of business document received by a back office for processing'},
            TRUE                                         -- return_error_details
        ),
        NULL) AS r
FROM {{DB}}.{{SCHEMA}}.DOC_PAGE_SAMPLE s
WHERE s.run_id = :run_id;
```

`LEFT(sample_text, 3000)` here is a **classification sample of page one**, which is deliberate — type
is evident from the top of the first page, and classification cost scales with input. Do not reuse
this truncated text for extraction.

`AI_CLASSIFY` returns labels only; there is no confidence score to threshold (best-practices rule 10).

### Optional: file input

If `ai.classify_input = file`, pass `TO_FILE(...)` directly as the input instead of parsed text. This is
documented as **Preview**, single-label only, no few-shot examples, English only, 100 pages / 22 MB,
no image file types, and listed under cross-region availability only. It saves the parse page but
should not be the production default until it is GA in the account's region. Say so if the user asks
for it.

## Step 6 — multi-document detection

Only for files with more than a few pages and a type of `invoice` or `credit_note` (contracts are
legitimately long). Classify a small sample of later pages:

```sql
-- Pages 1..3 of multi-page invoice-like files. Bills up to 3 pages per such file.
CREATE OR REPLACE TEMPORARY TABLE MULTI_DOC_PAGES AS
SELECT c.document_id, p.value:index::INT AS page_index,
       AI_CLASSIFY(LEFT(p.value:content::STRING, 2000), PARSE_JSON($classify_labels)):labels[0]::STRING AS page_type
FROM CLASSIFY_RESULTS c
JOIN {{DB}}.{{SCHEMA}}.INBOUND_FILES f USING (document_id),
LATERAL FLATTEN(input => PARSE_JSON(TO_VARCHAR(AI_PARSE_DOCUMENT(
        TO_FILE('@{{STAGE_FQN}}', f.relative_path),
        {'mode': 'OCR', 'page_filter': [{'start': 1, 'end': 4}]}
     ))):pages) p
WHERE c.page_count BETWEEN 2 AND 40
  AND c.r:value:labels[0]::STRING IN ('invoice', 'credit_note')
  AND LENGTH(TRIM(p.value:content::STRING)) >= 40;
```

A page classified as a different in-scope type, or as `other_document` because it is a packing slip,
makes the file `MULTI_DOCUMENT`. A long invoice whose later pages are line-item continuations will
classify as `invoice` and is fine. Note that the cost is bounded by the `page_filter` range — never run
per-page classification across every page of every file.

## Step 7 — route assignment

```sql
MERGE INTO {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION t
USING (
    SELECT
        f.document_id, f.relative_path, :run_id AS run_id, r.page_count,
        -- NEVER NULL. Errors and empty samples are a type of their own.
        CASE
            WHEN f.md5_rank > 1                         THEN 'DUPLICATE_FILE'
            WHEN r.document_id IS NULL                  THEN 'NOT_SAMPLED'
            WHEN r.parse_error IS NOT NULL              THEN 'UNCLASSIFIED'
            WHEN r.r IS NULL                            THEN 'UNCLASSIFIED'    -- empty first page
            WHEN r.r:error IS NOT NULL                  THEN 'UNCLASSIFIED'
            ELSE COALESCE(r.r:value:labels[0]::STRING, 'UNCLASSIFIED')
        END AS document_type,
        md.page_types,
        COALESCE(md.is_multi, FALSE) AS is_multi_document,
        CASE
            WHEN f.md5_rank > 1                                           THEN 'REJECT'
            WHEN f.size_bytes > 100 * 1024 * 1024                         THEN 'EXCEPTION'
            WHEN r.document_id IS NULL OR r.parse_error IS NOT NULL
              OR r.r IS NULL OR r.r:error IS NOT NULL                     THEN 'EXCEPTION'
            WHEN r.r:value:labels[0]::STRING = 'other_document'           THEN 'REJECT'
            WHEN COALESCE(md.is_multi, FALSE)                             THEN 'EXCEPTION'
            WHEN r.page_count > FLOOR(125 / :scale_factor)                THEN 'EXCEPTION'
            WHEN ARRAY_CONTAINS(r.r:value:labels[0], PARSE_JSON(:in_scope_types)) THEN 'EXTRACT'
            ELSE 'EXCEPTION'      -- a known label not in scope for this POC
        END AS route,
        CASE
            WHEN f.md5_rank > 1                                           THEN 'DUP_FILE_HASH'
            WHEN f.size_bytes > 100 * 1024 * 1024                         THEN 'FILE_TOO_LARGE'
            WHEN r.document_id IS NULL                                    THEN 'UNSUPPORTED_FORMAT'
            WHEN r.parse_error IS NOT NULL                                THEN 'PARSE_ERROR'
            WHEN r.r IS NULL                                              THEN 'EMPTY_FIRST_PAGE'
            WHEN r.r:error IS NOT NULL                                    THEN 'CLASSIFY_ERROR'
            WHEN r.r:value:labels[0]::STRING = 'other_document'           THEN 'OUT_OF_SCOPE'
            WHEN COALESCE(md.is_multi, FALSE)                             THEN 'MULTI_DOCUMENT'
            WHEN r.page_count > FLOOR(125 / :scale_factor)                THEN 'EXCEEDS_EXTRACT_PAGE_LIMIT'
            WHEN ARRAY_CONTAINS(r.r:value:labels[0], PARSE_JSON(:in_scope_types)) THEN 'CLASSIFIED'
            ELSE 'TYPE_NOT_IN_SCOPE'
        END AS route_reason,
        COALESCE(r.parse_error, r.r:error::STRING) AS classify_error,
        CASE
            WHEN f.relative_path ILIKE ANY ('%invoice%', '%/ap/%')       THEN 'invoice'
            WHEN f.relative_path ILIKE ANY ('%contract%', '%agreement%') THEN 'contract'
            WHEN f.relative_path ILIKE ANY ('%claim%')                   THEN 'insurance_claim_form'
        END AS path_hint,
        f.last_modified AS received_at
    FROM CLASSIFY_CANDIDATES f
    LEFT JOIN CLASSIFY_RESULTS r USING (document_id)
    LEFT JOIN (
        SELECT d.document_id,
               ARRAY_AGG(page_type) WITHIN GROUP (ORDER BY page_index) AS page_types,
               BOOLOR_AGG(page_type <> c.r:value:labels[0]::STRING)   AS is_multi
        FROM MULTI_DOC_PAGES d JOIN CLASSIFY_RESULTS c USING (document_id)
        GROUP BY d.document_id
    ) md USING (document_id)
) s
ON t.document_id = s.document_id
WHEN NOT MATCHED THEN INSERT
    (document_id, relative_path, run_id, page_count, document_type, page_types, is_multi_document,
     route, route_reason, classify_error, path_hint, received_at, classified_at)
VALUES
    (s.document_id, s.relative_path, s.run_id, s.page_count, s.document_type, s.page_types,
     s.is_multi_document, s.route, s.route_reason, s.classify_error, s.path_hint, s.received_at,
     CURRENT_TIMESTAMP());
```

`:in_scope_types` is the JSON array from `document_types.in_scope`; `:scale_factor` is
`ai.extract_scale_factor`. Note the `ELSE 'EXCEPTION'` on the route — a `CASE` without an `ELSE` yields
NULL routes, and NULL routes vanish from every downstream join.

Every `EXCEPTION` and `REJECT` here also writes a row to `EXCEPTIONS_QUEUE` (schema in
`validate-and-queue-exceptions`) with `stage = 'CLASSIFY'`, so a reviewer sees unclassifiable files
alongside extraction exceptions rather than in a separate place nobody checks.

## Verification at the gate

```sql
-- 1. Distribution. This is the shape of the whole downstream workload.
SELECT document_type, route, route_reason, COUNT(*) AS docs,
       SUM(page_count) AS pages,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION
WHERE run_id = :run_id
GROUP BY 1, 2, 3 ORDER BY docs DESC;

-- 2. Nothing NULL, nothing lost. All three counts must match, and nulls must be zero.
SELECT
    (SELECT COUNT(*) FROM CLASSIFY_CANDIDATES)                                     AS candidates,
    (SELECT COUNT(*) FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION WHERE run_id = :run_id) AS classified,
    (SELECT COUNT(*) FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION
      WHERE run_id = :run_id AND (document_type IS NULL OR route IS NULL))         AS null_type_or_route;

-- 3. Agreement with the free signal. Disagreement is not proof of error,
--    but a cluster of it points at a label problem or a mis-filed folder.
SELECT path_hint, document_type, COUNT(*) AS docs
FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION
WHERE run_id = :run_id AND path_hint IS NOT NULL AND path_hint <> document_type
GROUP BY 1, 2 ORDER BY docs DESC;
```

On the sandbox or rendered corpus, also measure type accuracy directly against the document key (the
query is in `evaluate-intake-accuracy`). Type accuracy below the target is fixed here — labels,
descriptions, which page is sampled — never by loosening extraction.

Then sample 10 `REJECT` rows and read the files' first page. Out-of-scope rejection is the one decision
in this phase that drops a document from the workflow entirely; checking it is cheap insurance.

Record `phases.classify: done` and the created objects.

## What this phase does not do

It does not extract fields and it does not post anything. `DOC_PAGE_SAMPLE` holds first-page text for
routing only; Phase 3 extracts from the file (or full parse) and must not reuse the sample, which would
drop totals, remittance details, and every contract clause after page one.
