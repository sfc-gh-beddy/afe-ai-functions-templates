---
name: extract-clinical-evidence
description: "Extract text per routing tier and compress charts before the expensive reasoning step. Runs full AI_PARSE_DOCUMENT OCR for the complex tier, uses existing text directly for the text-native tier, AI_EXTRACT for structured forms, and skips the skip tier. Then compresses each patient chart into a structured clinical timeline with a cheap model, using token-aware windowing rather than blind character truncation, and preserves document-level provenance so extracted findings remain traceable. Phase 4 of the icd10-extraction build."
parent_skill: icd10-extraction
---

# Extract text and compress charts

Two jobs. Get usable text out of every document that earned processing, and then shrink each patient's
chart before it reaches the frontier model — without losing the findings that matter.

## Job 1 — Extraction per tier

Each tier gets exactly the treatment routing assigned it. Nothing crosses tiers.

### T1 — full OCR with layout, for complex and scanned documents

```sql
CREATE OR REPLACE TABLE EXTRACTED_T1 AS
SELECT
    r.document_id,
    r.patient_id,
    r.document_date,
    r.document_type,
    'T1' AS tier,
    -- No page_filter here: the whole document is wanted. page_split keeps the
    -- response paged, which is what preserves page-level provenance below.
    -- TO_VARCHAR before PARSE_JSON: the function is documented as returning a
    -- JSON string but returns an OBJECT on some accounts, and PARSE_JSON(OBJECT)
    -- is a compile error. TO_VARCHAR handles both.
    PARSE_JSON(TO_VARCHAR(
        AI_PARSE_DOCUMENT(
            TO_FILE('@<stage>', r.file_path),
            {'mode': 'LAYOUT', 'page_split': TRUE}
        )
    )) AS parsed
FROM ROUTING_DECISIONS r
WHERE r.assigned_tier = 'T1' AND r.file_path IS NOT NULL;
```

`LAYOUT` rather than `OCR` because clinical documents are full of tables — lab panels, medication
lists, vital sign grids — and a flattened lab panel loses the association between an analyte and its
value. That association is the finding.

Then flatten to page-level rows, which is what makes page-level citation possible later:

```sql
CREATE OR REPLACE TABLE EXTRACTED_T1_PAGES AS
SELECT
    e.document_id,
    e.patient_id,
    e.document_date,
    e.document_type,
    e.tier,
    f.value:index::INT      AS page_index,
    f.value:content::STRING AS page_text
FROM EXTRACTED_T1 e,
     LATERAL FLATTEN(input => e.parsed:pages) f
WHERE LENGTH(TRIM(f.value:content::STRING)) > 0;
```

### T2 — existing text, no model call

```sql
CREATE OR REPLACE TABLE EXTRACTED_T2 AS
SELECT r.document_id, r.patient_id, r.document_date, r.document_type,
       'T2' AS tier, 0 AS page_index, s.document_text AS page_text
FROM ROUTING_DECISIONS r
JOIN ROUTING_STAGE_2 s USING (document_id)
WHERE r.assigned_tier = 'T2' AND s.document_text IS NOT NULL;
```

This tier is free. On a text-native corpus it is most of the volume, which is exactly why routing
matters.

### T3 — targeted field extraction for structured forms

```sql
CREATE OR REPLACE TABLE EXTRACTED_T3 AS
SELECT
    r.document_id,
    r.patient_id,
    r.document_date,
    r.document_type,
    'T3' AS tier,
    AI_EXTRACT(
        file => TO_FILE('@<stage>', r.file_path),
        responseFormat => {
            'diagnoses_listed'  : 'All diagnoses or conditions named on this form, verbatim',
            'test_results'      : 'All test or measurement names with their values and units',
            'medications'       : 'All medications listed, with dose if present',
            'provider_findings' : 'Any clinical findings, impressions, or assessments recorded',
            'document_date'     : 'The date of service or date of the result on this form'
        }
    ) AS extracted_fields
FROM ROUTING_DECISIONS r
WHERE r.assigned_tier = 'T3' AND r.file_path IS NOT NULL;
```

Ask for **verbatim** values. A form field paraphrased by the extractor cannot be cited as evidence
later, and paraphrase is where numbers quietly drift.

### T4 — nothing

Skipped by design. Log the count so the skip is visible and auditable, but do not process.

### Union the tiers, and check nothing vanished

```sql
CREATE OR REPLACE TABLE EXTRACTED_DOCUMENTS AS
SELECT document_id, patient_id, document_date, document_type, tier, page_index, page_text
FROM EXTRACTED_T1_PAGES
UNION ALL
SELECT document_id, patient_id, document_date, document_type, tier, page_index, page_text
FROM EXTRACTED_T2
UNION ALL
SELECT document_id, patient_id, document_date, document_type, tier, 0 AS page_index,
       TO_JSON(extracted_fields) AS page_text
FROM EXTRACTED_T3;
```

```sql
-- Every non-skip document must have produced text. Anything here is a
-- silent loss: routing said process it, and nothing came out.
SELECT r.assigned_tier, COUNT(*) AS missing_extraction
FROM ROUTING_DECISIONS r
LEFT JOIN (SELECT DISTINCT document_id FROM EXTRACTED_DOCUMENTS) e USING (document_id)
WHERE r.assigned_tier <> 'T4' AND e.document_id IS NULL
GROUP BY 1;
```

Investigate rather than ignore. Common causes: a file path that does not resolve on the stage, a
document past the 2,000-page limit or the 100 MB file size limit, an unsupported format, or a stage
without server-side encryption. `AI_PARSE_DOCUMENT` returns `NULL` on failure rather than erroring,
so these losses are silent by default. Pass `return_error_details => TRUE` when diagnosing to see the
actual message.

A genuinely thin document — a one-line addendum — is not a failure. Distinguish empty from thin
before treating either as a bug.

## Job 2 — Chart compression

The frontier model in Phase 5 runs once per patient per target condition. Feeding it a raw chart at
that multiplier is where cost gets out of hand. Compression converts a chart into a dense clinical
timeline that preserves every finding and discards the scaffolding.

### Assemble the chart with provenance intact

Provenance has to survive this step or the whole audit story collapses. The compressed summary must
still say which document each finding came from, which means the document id travels **inside** the
text handed to the model:

```sql
CREATE OR REPLACE TABLE PATIENT_CHART_RAW AS
SELECT
    e.patient_id,
    COUNT(DISTINCT e.document_id) AS document_count,
    -- Each document is delimited and labelled with its id and date. This is
    -- what lets the coder cite a document_id it was actually given, rather
    -- than inventing one.
    ARRAY_TO_STRING(
        ARRAY_AGG(
            '=== DOCUMENT ' || e.document_id
            || ' | TYPE: ' || COALESCE(e.document_type, 'unknown')
            || ' | DATE: ' || COALESCE(e.document_date::STRING, 'unknown')
            || ' | PAGE: ' || e.page_index::STRING || ' ===\n'
            || e.page_text
        ) WITHIN GROUP (ORDER BY e.document_date DESC NULLS LAST, e.document_id, e.page_index),
        '\n\n') AS chart_text,
    ARRAY_AGG(DISTINCT e.document_id) AS document_ids
FROM EXTRACTED_DOCUMENTS e
GROUP BY e.patient_id;
```

### Size the chart before compressing it — and decide whether to compress at all

Measure, do not guess, and never blindly truncate. `LEFT(chart_text, 60000)` discards the tail of long
charts — and because a clinical timeline is ordered, the tail is where progression lives. A falling
ejection fraction, a rising creatinine, a worsening ABI: the evidence that a condition is real rather
than incidental is precisely the part that gets cut.

**Compression is not free, and on small charts it is a net loss.** A structured timeline is more
verbose than a short chart: in testing, a 534-token chart compressed to 1,184 tokens — more than twice
the input. That is a real cost increase, not a saving, and it is then multiplied by every target
condition in the Phase 5 fan-out. Compression pays off on long charts and actively hurts on short
ones, so the decision has to be per patient.

```sql
CREATE OR REPLACE TABLE PATIENT_CHART_SIZED AS
SELECT
    c.*,
    -- Signature is ('ai_complete', '<model>', <text>). Function name first,
    -- lowercase. A wrong function name returns NULL rather than erroring.
    AI_COUNT_TOKENS('ai_complete', '<compress_model>', c.chart_text) AS chart_tokens,
    CASE
        -- Below the break-even point, compression costs more than it saves.
        -- Pass the chart through unchanged.
        WHEN AI_COUNT_TOKENS('ai_complete', '<compress_model>', c.chart_text)
             < <compression_floor_tokens>                    THEN 'PASSTHROUGH'
        WHEN AI_COUNT_TOKENS('ai_complete', '<compress_model>', c.chart_text)
             <= <window_token_budget>                        THEN 'SINGLE_PASS'
        ELSE 'SEGMENTED'
    END AS compression_strategy
FROM PATIENT_CHART_RAW c;
```

Setting the two thresholds:

- **`<compression_floor_tokens>`** — establish it empirically rather than assuming. Compress a sample
  of maybe twenty charts spanning the size range, compare input to output tokens, and find where the
  ratio crosses 1.0. Something in the low thousands is typical, but it depends on the model and on how
  verbose the target format is. Below the floor, `PASSTHROUGH`.
- **`<window_token_budget>`** — from the compression model's context window, with headroom for the
  prompt and the response.

The three strategies:

- **`PASSTHROUGH`** — no compression call. Carry `chart_text` straight through as the summary. Provenance
  is already present, because the `=== DOCUMENT <id> ... ===` markers are in the assembled text.
- **`SINGLE_PASS`** — compress in one call.
- **`SEGMENTED`** — split by document boundary, never mid-document, compress each segment, then
  concatenate the segment summaries. Splitting on a character offset severs findings from their values
  and their dates.

Report the distribution at the gate, and be straight about it. If most charts are `PASSTHROUGH`, the
compression lever does not apply to this corpus and the cost story rests on routing alone — say so
rather than reporting a compression saving that is not there. If most are `SEGMENTED`, the compression
model's context window is the binding constraint and a longer-context model is the fix.

### Compress

```sql
CREATE OR REPLACE TABLE PATIENT_CHART_SUMMARY AS
SELECT
    c.patient_id,
    c.document_count,
    c.document_ids,
    c.chart_tokens AS raw_tokens,
    AI_COMPLETE(
        model => '<compress_model>',
        prompt => CONCAT(
            'You are a clinical data compression engine. Produce a dense clinical timeline for ',
            'this patient. Your output will be read by a clinical coding AI looking for ',
            'undocumented conditions, so every clinically significant detail must survive.\n\n',
            'PRESERVE, without exception:\n',
            '- Every diagnosis and clinical impression\n',
            '- Every test result WITH its numeric value and units\n',
            '- Every medication with dose\n',
            '- Every abnormal finding and every physical exam finding\n',
            '- Trends: when a value appears at multiple dates, keep ALL values with their dates. ',
            'A trend is frequently the evidence that a condition is real rather than incidental.\n',
            '- Findings explicitly documented as normal WHERE they rule something out. ',
            'A normal result that excludes a diagnosis is clinically significant.\n',
            '- Statements that a condition is resolved, or that a finding has an alternative ',
            'explanation. These prevent incorrect conclusions and must not be dropped.\n\n',
            'REMOVE:\n',
            '- Scheduling, consent and billing language\n',
            '- Repeated headers and letterhead\n',
            '- Routine normal findings that rule nothing out\n\n',
            'CRITICAL - PROVENANCE:\n',
            'Each source document is delimited by === DOCUMENT <id> ... === markers. ',
            'Every finding you record MUST be tagged with the document id it came from, ',
            'in the form [doc: <document_id>]. Never invent a document id. Never merge ',
            'findings from two documents under one id.\n\n',
            'FORMAT:\n',
            'TIMELINE (most recent first, each entry dated and tagged with its document id)\n',
            'ACTIVE PROBLEMS\n',
            'KEY RESULTS AND TRENDS (values with dates and document ids)\n',
            'MEDICATIONS\n',
            'EXPLICIT EXCLUSIONS (conditions ruled out, resolved, or otherwise explained)\n\n',
            '=== PATIENT CHART ===\n',
            c.chart_text
        ),
        model_parameters => {'temperature': 0, 'max_tokens': 8192},
        show_details => TRUE
    ) AS compression_response
FROM PATIENT_CHART_SIZED c
WHERE c.compression_strategy = 'SINGLE_PASS';
```

Three things in that prompt are load-bearing and easy to lose in an edit:

- **Trends must be preserved in full.** A model told to summarise will collapse three BNP values into
  "elevated BNP", which destroys exactly the evidence that distinguishes a real condition from an
  incidental abnormal result.
- **Normal findings that rule something out must survive.** "Normal ejection fraction" is the sentence
  that stops the coder flagging heart failure on a patient with venous edema. A compression step that
  drops normals as uninteresting manufactures false positives downstream.
- **Explicit exclusions must survive**, for the same reason. "Dyspnea attributable to corrected
  anemia" is the whole answer for that patient.

### Persist the compressed text and its token cost

Union the compressed and passthrough charts so Phase 5 reads one table:

```sql
CREATE OR REPLACE TABLE PATIENT_SUMMARY AS
SELECT
    patient_id,
    document_count,
    document_ids,
    raw_tokens,
    'SINGLE_PASS'                                        AS strategy,
    compression_response:choices[0]:messages::STRING     AS summary_text,
    compression_response:usage:prompt_tokens::INT        AS compress_prompt_tokens,
    compression_response:usage:completion_tokens::INT    AS compress_completion_tokens,
    compression_response:usage:total_tokens::INT         AS compress_total_tokens,
    CURRENT_TIMESTAMP()                                  AS compressed_at
FROM PATIENT_CHART_SUMMARY
UNION ALL
SELECT
    patient_id, document_count, document_ids, chart_tokens,
    'PASSTHROUGH'    AS strategy,
    chart_text       AS summary_text,
    0, 0, 0,
    CURRENT_TIMESTAMP()
FROM PATIENT_CHART_SIZED
WHERE compression_strategy = 'PASSTHROUGH';
```

Note the response path. Without `response_format`, `show_details => TRUE` returns
`choices[0].messages`. With a `response_format` schema it returns `structured_output[0].raw_message`
instead. Compression is deliberately unstructured — a clinical timeline is prose, and forcing it into
a schema costs quality for no benefit — so this stage uses the `choices` path. The coder and judge
stages use the `structured_output` path. Mixing them up yields silent `NULL`s.

## Verification at the gate

```sql
-- 1. Compression ratio, by strategy. This is the cost lever, measured rather
--    than claimed. A NEGATIVE pct_reduction means compression made the input
--    bigger -- report that honestly and raise the compression floor.
SELECT strategy,
       COUNT(*) AS patients,
       ROUND(AVG(raw_tokens), 0)                  AS avg_raw_tokens,
       ROUND(AVG(compress_completion_tokens), 0)  AS avg_summary_tokens,
       ROUND(100.0 * (1 - AVG(compress_completion_tokens)
                          / NULLIF(AVG(raw_tokens), 0)), 1) AS pct_reduction
FROM PATIENT_SUMMARY
GROUP BY 1;
```

```sql
-- 2. No empty summaries. A NULL here means a failed model call, and that
--    patient will produce no suspects for a reason unrelated to their chart.
SELECT COUNT(*) AS empty_summaries
FROM PATIENT_SUMMARY
WHERE summary_text IS NULL OR LENGTH(TRIM(summary_text)) < 100;
```

```sql
-- 3. Provenance survived compression. Summaries with no [doc: ...] tag will
--    produce untraceable suspects, which cannot be audited.
SELECT COUNT(*) AS summaries_without_provenance
FROM PATIENT_SUMMARY
WHERE summary_text NOT ILIKE '%[doc:%';
-- Must be zero.
```

```sql
-- 4. Cited ids must be real. A fabricated document id is worse than a missing
--    one, because it looks like valid provenance.
WITH cited AS (
    SELECT s.patient_id,
           f.value::STRING AS cited_doc
    FROM PATIENT_SUMMARY s,
         LATERAL FLATTEN(input =>
             REGEXP_EXTRACT_ALL(s.summary_text, '\\[doc: ([A-Za-z0-9_-]+)\\]', 1, 1, 'e', 1)) f
)
SELECT COUNT(*) AS fabricated_citations
FROM cited c
WHERE NOT ARRAY_CONTAINS(c.cited_doc::VARIANT,
        (SELECT document_ids FROM PATIENT_SUMMARY p WHERE p.patient_id = c.patient_id));
-- Must be zero. Non-zero means the compression prompt's provenance
-- instruction is not holding and needs strengthening, or the model is too weak.
```

```sql
-- 5. Spot-read two summaries against their source charts. Confirm trends kept
--    their individual values, and that any documented exclusion survived.
SELECT patient_id, summary_text FROM PATIENT_SUMMARY ORDER BY RANDOM() LIMIT 2;
```

Check 5 is the one worth actually doing rather than skimming. It is the only step that catches a
compression prompt that is quietly dropping the evidence the pipeline depends on, and every downstream
accuracy number inherits that loss.

Record the compression ratio in `icd10-project.yml` so Phase 6 can report the measured saving, then set
`phases.extract: done`.
