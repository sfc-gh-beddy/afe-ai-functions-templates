---
name: classify-and-route-documents
description: "Build the cost-tier routing engine for a clinical document corpus. Assigns every document to an extraction tier before expensive processing runs: metadata fast-exit with no model call, partial OCR on the first pages using AI_PARSE_DOCUMENT where OCR quality is itself the routing signal, a constrained AI_COMPLETE tier classifier, and four tiers (full OCR plus reasoning, direct text reasoning, targeted field extraction, skip). Includes patient-scoped dedup, customer-tuned boilerplate gating, and a routing decision audit table so tier mix and OCR-avoidance rate are measured rather than assumed. Phase 2 of the icd10-extraction build."
parent_skill: icd10-extraction
---

# Route documents by cost tier

Not every document deserves the same processing. A consent form and a dense handwritten referral cost
the same to run through full OCR plus a frontier model, and only one of them contains a diagnosis.
Routing is where the cost profile of the whole pipeline is decided.

This phase assigns every document a tier and records why. Nothing is extracted yet.

## The ordering principle: cheapest signal first

Each step is more expensive than the last, so exit as early as possible.

```
1. Metadata rules          no model call        free
2. Partial OCR             first pages only     cheap, and OCR quality IS the routing signal
3. Model classifier        small model          only for what rules could not settle
4. Tier assignment         no model call        free
```

A corpus where step 1 settles most documents is dramatically cheaper than one where everything falls
through to step 3. Preflight already reported whether the metadata is populated well enough for that
to happen — if it is not, say so now rather than promising savings the corpus cannot deliver.

## The four tiers

| Tier | Path | For |
|---|---|---|
| **T1** | `AI_PARSE_DOCUMENT` full OCR plus layout, then `AI_COMPLETE` | Complex clinical documents, handwritten referrals, dense outside records, poor scan quality |
| **T2** | `AI_COMPLETE` directly on existing text | Text-native documents: EHR exports, visit notes, structured lab text |
| **T3** | `AI_EXTRACT` targeted fields | Structured forms with a known, stable field set |
| **T4** | **SKIP**, archive and log | Administrative documents, consent, privacy notices, billing, duplicates, empty content |

T4 is not a rounding error. On a real corpus it is frequently a third or more of documents, and every
one it catches is a document the expensive path never sees.

## Step 1 — Metadata fast-exit

Rules over columns that already exist. No model call.

```sql
CREATE OR REPLACE TABLE ROUTING_STAGE_1 AS
SELECT
    d.<id_col>            AS document_id,
    d.<patient_id_col>    AS patient_id,
    d.<type_col>          AS document_type,
    d.<source_system_col> AS source_system,
    d.<date_col>          AS document_date,
    d.<text_col>          AS document_text,
    d.<file_col>          AS file_path,
    d.<page_count_col>    AS page_count,
    CASE
        -- Known administrative document types: skip before anything else.
        WHEN d.<type_col> IN (<customer_admin_types>)                       THEN 'T4'
        -- Empty content and no file to OCR: nothing to process.
        WHEN d.<text_col> IS NULL AND d.<file_col> IS NULL                   THEN 'T4'
        -- CRITICAL: text present and NO file. T2 is the ONLY possible tier,
        -- because every OCR tier needs a file to OCR. Length is irrelevant
        -- here. Placing this rule AFTER a length test is a real bug: a short
        -- lab report carrying a value trend -- exactly the densest clinical
        -- evidence there is -- falls through the length guard, hits the
        -- ELSE default, lands in an OCR tier with no file, and produces
        -- nothing. The finding disappears with no error anywhere.
        WHEN d.<text_col> IS NOT NULL AND d.<file_col> IS NULL               THEN 'T2'
        -- Known text-native source systems with usable text present.
        WHEN d.<source_system_col> IN (<customer_text_native_sources>)
             AND d.<text_col> IS NOT NULL
             AND LENGTH(d.<text_col>) > 200                                  THEN 'T2'
        -- Known structured form types.
        WHEN d.<type_col> IN (<customer_form_types>)                         THEN 'T3'
        -- Very long scanned documents are T1 regardless: partial OCR will
        -- not represent them, and they are where dense records live.
        WHEN d.<text_col> IS NULL AND d.<page_count_col> > 10                THEN 'T1'
        ELSE NULL   -- unsettled, falls through to later steps
    END AS tier_from_metadata,
    CASE
        WHEN d.<type_col> IN (<customer_admin_types>)          THEN 'ADMIN_TYPE'
        WHEN d.<source_system_col> IN (<customer_text_native_sources>)
             AND LENGTH(d.<text_col>) > 200                    THEN 'TEXT_NATIVE_SOURCE'
        WHEN d.<type_col> IN (<customer_form_types>)            THEN 'KNOWN_FORM'
        WHEN d.<text_col> IS NULL AND d.<file_col> IS NULL      THEN 'NO_CONTENT'
        WHEN d.<text_col> IS NULL AND d.<page_count_col> > 10   THEN 'LONG_SCAN'
        ELSE NULL
    END AS routing_reason
FROM <source_table> d;
```

`<customer_admin_types>`, `<customer_text_native_sources>` and `<customer_form_types>` must come from
the **actual distribution** preflight reported. Do not carry over a list from anywhere else.

**Show the user what each rule would skip, with counts, before committing it.** A single over-broad
type match can silently remove a meaningful share of the clinical corpus, and it will look like a
recall problem three phases later.

```sql
-- Run this at the gate. Any rule skipping an unexpected share needs a second look.
SELECT routing_reason, tier_from_metadata, COUNT(*) AS docs,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM ROUTING_STAGE_1
GROUP BY 1, 2 ORDER BY docs DESC;
```

## Step 2 — Dedup, scoped to the patient

Before spending anything on a document, check whether its content was already processed.

```sql
CREATE OR REPLACE TABLE ROUTING_STAGE_2 AS
SELECT s.*,
       -- Patient-scoped. An unscoped MD5(LEFT(text, N)) collides across
       -- patients because note templates share opening text, and the second
       -- patient's document silently disappears.
       MD5(s.patient_id || '::' || LEFT(COALESCE(s.document_text, s.file_path), 500)) AS content_hash,
       ROW_NUMBER() OVER (
           PARTITION BY s.patient_id,
                        MD5(s.patient_id || '::' || LEFT(COALESCE(s.document_text, s.file_path), 500))
           ORDER BY s.document_date DESC NULLS LAST, s.document_id
       ) AS dup_rank
FROM ROUTING_STAGE_1 s;
```

Everything with `dup_rank > 1` becomes T4 with reason `DUPLICATE`. Keep the row rather than deleting
it — a deleted duplicate cannot be explained later, and the count is a useful corpus statistic.

Prefer a content-bearing window over the leading 500 characters when the corpus has long shared
headers. If the first 500 characters are all letterhead, the hash is a hash of the letterhead.

## Step 3 — Boilerplate gate

Pattern matching for administrative content that the type column did not catch — which is common,
because scanned documents frequently carry a generic type.

```sql
CREATE OR REPLACE TABLE BOILERPLATE_PATTERNS (
    pattern_id   INT,
    pattern_text VARCHAR(500),
    doc_class    VARCHAR(50)
);
```

Derive patterns from the customer's own high-frequency documents. **Then validate each one before
committing it**, because an over-broad pattern is the single fastest way to destroy the corpus:

```sql
-- What would each pattern skip, and does it ever hit a clinical document?
SELECT bp.pattern_id, bp.doc_class, bp.pattern_text,
       COUNT(*) AS would_skip,
       COUNT_IF(s.document_type IN (<customer_clinical_types>)) AS clinical_hits
FROM BOILERPLATE_PATTERNS bp
JOIN ROUTING_STAGE_2 s ON s.document_text ILIKE '%' || bp.pattern_text || '%'
GROUP BY 1, 2, 3 ORDER BY would_skip DESC;
```

`clinical_hits > 0` means the pattern appears inside real clinical documents. Do not commit it.
A phrase that is pure noise in one organization sits in another organization's standard note header.

## Step 4 — Partial OCR to get cheap text for classification

Only for documents still unsettled and having a file. A scanned document has no text, so there is
nothing for a content classifier to read. Partial OCR fixes that cheaply: parse the first pages only,
and hand that sample to the classifier in Step 5.

**Use `page_filter`, not `page_split`.** `AI_PARSE_DOCUMENT` bills per page processed, and
`page_split: TRUE` processes *every* page — it only changes the response shape. `page_filter` is what
actually limits the pages parsed, and it implies `page_split`, so the paged response shape comes for
free. Getting this wrong silently converts the cheapest step in the pipeline into a full-corpus OCR
run at full cost, while still looking like it worked.

> **Do not use OCR "quality" as a tier decider without validating it on this corpus first.**
> A tempting design is to score how clean the OCR output looks and route poor scans to the expensive
> tier. **Measured, this does not work.** Rendering the same clinical notes at graded degradation — 300
> DPI clean through 100 DPI with heavy skew, gaussian noise, contrast loss and JPEG artefacts — and
> OCR-ing them produced a character-cleanliness ratio of 0.974, 0.975, 0.972, 0.962 and 0.968 across
> the whole severity range. Flat. `AI_PARSE_DOCUMENT` did not garble characters at any severity; it
> read every document successfully.
>
> The lesson is that modern OCR degrades **discretely, not gradually**: it either reads the page or
> returns almost nothing. So the only reliable signal from the OCR step is near-empty output, and the
> real routing decision has to come from **content** (Step 5) and **metadata** (Step 1).
>
> Genuinely bad real-world scans — handwriting, stamps, stapled inserts, generational photocopies — may
> behave differently from synthetic degradation. If you want a quality-based rule, prove it correlates
> on the customer's own documents before you route on it. The validation query is at the end of this
> file.

```sql
CREATE OR REPLACE TABLE ROUTING_PARTIAL_OCR AS
SELECT
    s.document_id,
    s.patient_id,
    -- Pages 0 and 1 only. end is exclusive, indexes start at 0.
    -- Wrap in TO_VARCHAR before PARSE_JSON: the function is documented as
    -- returning a JSON string, but returns an OBJECT on some accounts, and
    -- PARSE_JSON(OBJECT) is a compile error. TO_VARCHAR handles both.
    PARSE_JSON(TO_VARCHAR(
        AI_PARSE_DOCUMENT(
            TO_FILE('@<stage>', s.file_path),
            {'mode': 'LAYOUT', 'page_filter': [{'start': 0, 'end': 2}]}
        )
    )) AS parsed
FROM ROUTING_STAGE_2 s
WHERE s.tier_from_metadata IS NULL
  AND s.file_path IS NOT NULL
  AND s.dup_rank = 1;
```

A note on cost accounting for this step: for PDF and DOCX each page counts as a page; for image
formats each file counts as a page, so `page_filter` buys nothing on a single-image scan; and for
HTML or TXT each 3,000-character chunk counts as a page. Run OCR on a warehouse no larger than
medium — a bigger warehouse does not make it faster.

Derive the sample text and a **failure** signal — not a graded quality score:

```sql
CREATE OR REPLACE TABLE ROUTING_OCR_SIGNAL AS
WITH s AS (
    SELECT
        o.document_id,
        o.patient_id,
        ARRAY_TO_STRING(
            TRANSFORM(o.parsed:pages::ARRAY, p VARIANT -> p:content::STRING),
            '\n') AS sample_text,
        ARRAY_SIZE(o.parsed:pages::ARRAY) AS pages_sampled
    FROM ROUTING_PARTIAL_OCR o
)
SELECT
    document_id,
    patient_id,
    sample_text,
    LENGTH(sample_text)                                   AS sample_len,
    ROUND(LENGTH(sample_text) / NULLIF(pages_sampled, 0), 0) AS chars_per_page,
    -- The signal that IS reliable: OCR produced essentially nothing. That means
    -- an unreadable scan, an image-only page with no text, or a failed parse.
    -- Threshold is low deliberately -- a genuine one-line addendum is thin but
    -- not a failure, and must not be treated as one.
    (LENGTH(sample_text) < 40) AS ocr_effectively_empty,
    -- Retained for measurement only. Do NOT route on this without proving it
    -- correlates with readability on this corpus first.
    ROUND(
        (LENGTH(sample_text)
         - LENGTH(REGEXP_REPLACE(sample_text, '[A-Za-z0-9 .,:;/()%-]', '')))
        / NULLIF(LENGTH(sample_text), 0), 3) AS clean_char_ratio
FROM s;
```

Inspect the distribution before trusting anything derived from it:

```sql
SELECT ocr_effectively_empty,
       COUNT(*)                        AS docs,
       ROUND(AVG(chars_per_page), 0)    AS avg_chars_per_page,
       ROUND(MIN(clean_char_ratio), 3)  AS min_ratio,
       ROUND(MAX(clean_char_ratio), 3)  AS max_ratio
FROM ROUTING_OCR_SIGNAL
GROUP BY 1;
```

If `min_ratio` and `max_ratio` are close together across the whole corpus, the ratio carries no
information and must not be used as a tier decider — which is the expected result. Then sample a few
documents and read them: the question worth answering is not whether OCR returned text, but whether it
preserved the **numbers**. A scan that returns fluent prose while turning `0.52` into `052` will
produce confidently wrong codes and nothing downstream will flag it.

## Step 5 — Model classifier for what remains

Only documents that rules and OCR signal could not settle. Use the small model, and **constrain the
output with a schema** so the tier can never come back as unparseable prose.

```sql
CREATE OR REPLACE TABLE ROUTING_CLASSIFIED AS
SELECT
    s.document_id,
    s.patient_id,
    AI_COMPLETE(
        model => '<classify_model>',
        prompt => CONCAT(
            'You are routing a clinical document to a processing tier. Respond in JSON.\n\n',
            'TIERS:\n',
            'CLINICAL_COMPLEX  - dense clinical content, poor scan quality, handwriting, ',
            'multiple report types in one document\n',
            'CLINICAL_TEXT     - clean readable clinical content: visit note, lab report, ',
            'imaging or diagnostic report\n',
            'STRUCTURED_FORM   - a form with labelled fields and little free text\n',
            'ADMINISTRATIVE    - consent, privacy notice, billing, records release, ',
            'scheduling, or any document with no clinical findings\n\n',
            'Classify based only on document character. Do NOT attempt to diagnose. ',
            'A document containing clinical findings is never ADMINISTRATIVE, even if it ',
            'also contains administrative text.\n\n',
            'DOCUMENT TYPE: ', COALESCE(s.document_type, 'unknown'), '\n',
            'SOURCE: ', COALESCE(s.source_system, 'unknown'), '\n',
            'CONTENT SAMPLE:\n',
            LEFT(COALESCE(g.sample_text, s.document_text), 3000)
        ),
        model_parameters => {'temperature': 0, 'max_tokens': 256},
        response_format => {
            'type': 'json',
            'schema': {
                'type': 'object',
                'properties': {
                    'tier_class': {'type': 'string',
                                   'enum': ['CLINICAL_COMPLEX','CLINICAL_TEXT',
                                            'STRUCTURED_FORM','ADMINISTRATIVE']},
                    'has_clinical_findings': {'type': 'boolean'},
                    'reason': {'type': 'string'}
                },
                'required': ['tier_class', 'has_clinical_findings', 'reason']
            }
        },
        show_details => TRUE
    ) AS classification
FROM ROUTING_STAGE_2 s
LEFT JOIN ROUTING_OCR_SIGNAL g ON g.document_id = s.document_id
WHERE s.tier_from_metadata IS NULL
  AND s.dup_rank = 1;
```

The `enum` constraint is what makes this safe — the tier cannot come back as a value the `CASE`
below does not handle. `has_clinical_findings` is a deliberate second signal: it lets the tier
assignment refuse to skip anything clinical even when the classifier called it administrative, which
is the asymmetry that matters. Skipping a clinical document loses a diagnosis; over-processing an
administrative one costs a few tokens.

## Step 6 — Final tier assignment

```sql
CREATE OR REPLACE TABLE ROUTING_DECISIONS AS
SELECT
    s.document_id,
    s.patient_id,
    s.document_type,
    s.source_system,
    s.document_date,
    s.page_count,
    s.file_path,
    s.content_hash,
    COALESCE(
        s.tier_from_metadata,
        CASE
            -- Never skip anything with clinical findings, whatever the
            -- classifier called it. The asymmetry is deliberate.
            WHEN c.classification:structured_output[0]:raw_message:has_clinical_findings::BOOLEAN
                 AND c.classification:structured_output[0]:raw_message:tier_class::STRING
                     = 'ADMINISTRATIVE'                            THEN 'T2'
            WHEN c.classification:structured_output[0]:raw_message:tier_class::STRING
                 = 'ADMINISTRATIVE'                                THEN 'T4'
            WHEN c.classification:structured_output[0]:raw_message:tier_class::STRING
                 = 'STRUCTURED_FORM'                               THEN 'T3'
            WHEN c.classification:structured_output[0]:raw_message:tier_class::STRING
                 = 'CLINICAL_COMPLEX'                              THEN 'T1'
            WHEN c.classification:structured_output[0]:raw_message:tier_class::STRING
                 = 'CLINICAL_TEXT'
                 AND s.document_text IS NOT NULL                   THEN 'T2'
            WHEN c.classification:structured_output[0]:raw_message:tier_class::STRING
                 = 'CLINICAL_TEXT'                                 THEN 'T1'
            -- OCR produced essentially nothing: unreadable scan or failed
            -- parse. Full OCR with layout is the best remaining chance.
            -- NOTE: this is a FAILURE signal, not a graded quality score.
            -- Do not substitute clean_char_ratio here -- measured, it is flat
            -- across the whole degradation range and carries no information.
            WHEN g.ocr_effectively_empty                            THEN 'T1'
            -- Unclassifiable: T1 rather than skip, because the cost of
            -- losing a diagnosis exceeds the cost of OCR -- but ONLY when
            -- there is a file to OCR. Without one, T1 is a black hole.
            WHEN s.file_path IS NOT NULL                            THEN 'T1'
            ELSE 'T4'
        END
    ) AS assigned_tier,
    COALESCE(s.routing_reason,
             CASE WHEN s.dup_rank > 1 THEN 'DUPLICATE' ELSE 'MODEL_CLASSIFIED' END) AS routing_reason,
    -- Did this document avoid OCR entirely?
    (s.tier_from_metadata IS NOT NULL)          AS exited_before_ocr,
    g.chars_per_page,
    g.ocr_effectively_empty,
    g.clean_char_ratio,                          -- measurement only, not a decider
    c.classification:usage:total_tokens::INT    AS classify_tokens,
    CURRENT_TIMESTAMP()                         AS routed_at
FROM ROUTING_STAGE_2 s
LEFT JOIN ROUTING_CLASSIFIED c  ON c.document_id = s.document_id
LEFT JOIN ROUTING_OCR_SIGNAL  g ON g.document_id = s.document_id;
```

Note the `ELSE 'T1'` rather than `ELSE NULL`. A `CASE` with no `ELSE` produces `NULL` tiers that then
vanish from every downstream join — documents disappear from the pipeline with no error anywhere.

Note also that unclassifiable documents go to T1, not T4. The asymmetry is the whole point: an
over-processed administrative document costs tokens, a skipped clinical document costs a diagnosis.

## Verification at the gate

```sql
-- 1. Tier mix. This is the cost profile of the entire pipeline.
SELECT assigned_tier,
       COUNT(*) AS docs,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
       COUNT_IF(exited_before_ocr) AS avoided_ocr
FROM ROUTING_DECISIONS
GROUP BY 1 ORDER BY 1;
```

```sql
-- 2. Nothing may be unassigned, and nothing may sit in an OCR tier without a
--    file to OCR. Both must be zero. The second is the silent-loss check:
--    a document with text that lands in T1 produces nothing at all.
SELECT COUNT_IF(assigned_tier IS NULL)                              AS unassigned,
       COUNT_IF(assigned_tier IN ('T1','T3') AND file_path IS NULL) AS ocr_tier_without_file,
       COUNT_IF(assigned_tier = 'T1' AND document_text IS NOT NULL) AS text_docs_sent_to_ocr
FROM ROUTING_DECISIONS;
```

```sql
-- 3. Every input document must appear exactly once. Catches join fanout,
--    which silently multiplies downstream inference cost.
SELECT
    (SELECT COUNT(*) FROM <source_table>)      AS input_docs,
    (SELECT COUNT(*) FROM ROUTING_DECISIONS)   AS routed_docs,
    (SELECT COUNT(DISTINCT document_id) FROM ROUTING_DECISIONS) AS distinct_routed;
-- All three must match.
```

```sql
-- 4. Sanity-check the skip tier by reading a sample. Do this rather than
--    trusting the counts -- it is the cheapest possible insurance against
--    having thrown away the corpus.
SELECT document_id, document_type, routing_reason, LEFT(document_text, 300) AS preview
FROM ROUTING_DECISIONS r
JOIN ROUTING_STAGE_2 USING (document_id)
WHERE r.assigned_tier = 'T4' AND r.routing_reason <> 'DUPLICATE'
ORDER BY RANDOM() LIMIT 15;
```

```sql
-- 5. And sample what went to the expensive tier, to check it deserves it.
SELECT document_id, document_type, routing_reason, chars_per_page, ocr_effectively_empty
FROM ROUTING_DECISIONS
WHERE assigned_tier = 'T1'
ORDER BY RANDOM() LIMIT 15;
```

```sql
-- 6. ONLY if you want to route on OCR quality: prove the signal correlates with
--    readability on THIS corpus first. Requires documents whose true condition
--    is known -- see the build-document-test-corpus skill, which renders a
--    graded-degradation corpus for exactly this purpose.
--
--    Expected result, based on measurement: avg_clean_ratio is FLAT across
--    severity. If so, do not route on it.
SELECT d.degradation_severity,
       COUNT(*)                            AS docs,
       ROUND(AVG(g.clean_char_ratio), 3)    AS avg_clean_ratio,
       ROUND(AVG(g.chars_per_page), 0)      AS avg_chars_per_page,
       COUNT_IF(g.ocr_effectively_empty)    AS ocr_failures
FROM ROUTING_OCR_SIGNAL g
JOIN <rendered_corpus_table> d USING (document_id)
GROUP BY 1 ORDER BY 1;
```

## Reading the tier mix honestly

- **T4 near zero** on a real corpus means routing is not working. Real corpora contain consent forms.
- **T4 very high**, above roughly half, means a pattern or type rule is too broad. Read the samples.
- **T1 dominant** means either a genuinely scanned corpus, which is fine and is where routing earns
  most, or a classifier defaulting to T1 because the content sample is empty. Check
  `clean_char_ratio` is populated before concluding it is the former.
- **`avoided_ocr` near zero** means the metadata signals are not populated well enough for the cheap
  exits to fire. That is a data quality finding to report to the customer, not something to route
  around by sending everything to T1.

Record the tier mix in `icd10-project.yml`. Phase 6 compares against it to report what the cost
levers actually saved.

## What this phase does not do

No text is extracted and no clinical reasoning happens here. `ROUTING_PARTIAL_OCR` holds only a
first-two-pages sample used for signal, and it must not be treated as extracted content — Phase 4
does the real extraction per tier. Reusing the partial sample as if it were the full document is a
tempting shortcut that quietly truncates every scanned chart to two pages, which is exactly where
progression evidence gets lost because clinical timelines are ordered.
