---
name: build-document-test-corpus
description: "Turn clinical note TEXT into actual document artifacts on a Snowflake stage so the routing tiers and OCR paths are genuinely exercised, not simulated. Renders notes to digital-born PDFs, degraded scans (skew, noise, JPEG artefacts) that force real AI_PARSE_DOCUMENT OCR, and structured forms for the AI_EXTRACT tier. Also covers importing an external open synthetic corpus for background realism and combining it with labeled planted cases so the corpus has both realism and ground truth. Use when the sandbox needs real files rather than text rows, or when evaluating routing and OCR quality. Optional companion to seed-icd10-sandbox."
parent_skill: icd10-extraction
---

# Build a document test corpus

A corpus of note **text** in a table cannot test this pipeline properly. Routing decides tiers partly
from OCR quality, T1 runs full OCR, and T3 runs field extraction against files — none of which happen
if every row already has clean text in a column. A text-only sandbox silently routes everything to T2
and reports a tier mix that will not resemble production.

This skill produces real files on a stage: digital-born PDFs, deliberately degraded scans, and
structured forms.

## When you need this

- The sandbox from `seed-icd10-sandbox` has `file_path` values that do not resolve to anything, so T1
  and T3 are untestable.
- The customer's real corpus is mostly scanned and routing needs tuning before it touches PHI.
- Someone needs to see the OCR path work in a demo.

Skip it if the customer's corpus is genuinely text-native end to end. Check the preflight
text-native/scanned split first — if it says 95 percent text-native, this is effort for a path that
barely runs.

## The two gaps, and they are separate

| Gap | Fixed by |
|---|---|
| Notes are not realistic enough — no typos, no personas, no longitudinal depth | Import an external corpus (see `EXTERNAL_CORPORA.md`) |
| Notes are text rows, not files | Render to documents (this skill) |

An external corpus fixes realism and does **not** fix the file gap: published synthetic clinical note
datasets ship as CSV text. Rendering is still required.

## The hybrid design — realism from one source, labels from another

This is the important design decision, and getting it backwards wastes the effort.

- A **generated sandbox** has ground truth and weak realism. Its notes are hand-authored, so the
  planted evidence is findable and the answer key is exact — but the background is uniform and the
  document mix is thin.
- An **external open corpus** has strong realism and **no ICD-10 or HCC labels at all**. It is a
  corpus, not a benchmark. It cannot tell you whether the pipeline found what it should have.

Combine them rather than choosing:

```
labeled planted cases  (from seed-icd10-sandbox)   -> the signal, and the answer key
external corpus notes  (imported, unlabeled)       -> realistic background volume and distractor noise
rendered documents     (this skill)                -> the file artifacts that exercise every tier
```

The external corpus patients enter the answer key as `case_role = 'UNLABELED'` with
`expected_classification = NULL`. The harness then reports recall over labeled cases only, and treats
suspects raised on unlabeled patients as **unscored** rather than as false positives — because nobody
verified those charts. Failing to do this is the trap: unlabeled background will generate suspects, and
counting them as false positives will make a working pipeline look badly over-calling.

```sql
-- Extend the answer key so unlabeled background is explicitly unscored.
ALTER TABLE <answer_key> ADD COLUMN IF NOT EXISTS corpus_source VARCHAR(50);

-- Harness rule: three buckets, never two.
SELECT
    COUNT_IF(ak.case_role IN ('PLANTED','BORDERLINE'))  AS scoreable_positives,
    COUNT_IF(ak.case_role = 'DISTRACTOR')               AS scoreable_negatives,
    COUNT_IF(ak.case_role = 'UNLABELED')                AS unscored_background
FROM <answer_key> ak;
```

## Rendering notes to documents

`scripts/render_corpus.py` in this directory does the work. Read it before running — it is
parameterized and it decides the document mix, which is the thing worth tuning.

### The mix is the point

Render to a **deliberate distribution** that exercises every tier, rather than one format:

| Rendered as | Share | Exercises | How |
|---|---|---|---|
| Digital-born PDF, selectable text | ~45% | T2 direct text | Straight text-to-PDF |
| Clean scan | ~20% | T1 OCR, clean signal | Rasterize at 300 DPI, no degradation |
| Degraded scan | ~20% | T1 OCR, poor signal | Rasterize at 150 DPI + skew + noise + JPEG artefacts |
| Structured form | ~10% | T3 `AI_EXTRACT` | Render with labelled field boxes |
| Administrative | ~5% | T4 skip | Consent, privacy, billing content |

The degraded tier matters most and is the one people skip. It is the only way to know whether the
`clean_char_ratio` routing threshold is set sensibly for this corpus, and whether OCR preserves the
decimal point in an ejection fraction — which is the difference between a correct code and a wrong one.

### Degradation should be graded, not binary

Render a **spread** of degradation severity, not just good and bad. Two reasons: a routing threshold on a
continuous signal cannot be placed from a bimodal corpus, and — more importantly — grading is how you
find out whether a candidate signal carries information at all.

```
severity 0.0  clean 300 DPI
severity 0.3  150 DPI, slight skew
severity 0.6  150 DPI, skew, gaussian noise, mild blur
severity 0.9  100 DPI, heavy skew, noise, JPEG artefacts, contrast loss
```

Record the severity used for each file. That gives ground truth for the OCR quality signal itself.

> **Measured result, worth knowing before you build on it.** Running exactly this experiment on a real
> corpus — rendering clinical notes across the full severity ladder plus an extreme 1.0 tier, then
> OCR-ing with `AI_PARSE_DOCUMENT` — produced these character-cleanliness ratios:
>
> | severity | docs | avg clean-char ratio | avg chars/page | OCR failures |
> |---|---|---|---|---|
> | 0.0 (clean scan) | 11 | 0.974 | 897 | 0 |
> | 0.3 | 4 | 0.975 | 899 | 0 |
> | 0.6 | 2 | 0.972 | 773 | 0 |
> | 0.9 | 4 | 0.962 | 1159 | 0 |
> | 1.0 (extreme) | 4 | 0.968 | 1148 | 0 |
>
> **Flat.** OCR read every document successfully at every severity, including 100 DPI with heavy skew,
> noise and JPEG artefacts. `AI_PARSE_DOCUMENT` degrades **discretely, not gradually** — it reads the
> page or it returns almost nothing.
>
> The consequence is that OCR-quality scoring is **not a valid tier decider**, and the routing skill has
> been corrected accordingly: the reliable signal is near-empty output, and content classification plus
> metadata carry the real decision. If you want a quality-based rule anyway, run the correlation query
> below on the customer's own documents and prove it varies first.
>
> Caveat in the other direction: rendered degradation is gentler than the worst real-world input.
> Handwriting, stamps, stapled inserts and generational photocopies are not reproduced here, and may
> genuinely defeat OCR where synthetic noise does not.

### Upload to the stage

The stage must have server-side encryption or `AI_PARSE_DOCUMENT` will refuse the files:

```sql
CREATE OR REPLACE STAGE CORPUS_DOCUMENTS
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
```

```bash
snow stage copy ./rendered/ @CORPUS_DOCUMENTS/ --recursive
```

Then rebuild the document table so `file_path` resolves and the text column is `NULL` for anything
rendered as a scan — otherwise routing sees clean text and never OCRs anything:

```sql
CREATE OR REPLACE TABLE CORPUS_DOCUMENTS_TABLE AS
SELECT
    m.document_id,
    m.patient_id,
    m.document_date,
    m.document_type,
    m.source_system,
    m.file_format,
    m.page_count,
    m.file_path,
    -- CRITICAL: NULL for rendered scans and forms. Leaving the source text in
    -- place means routing takes the T2 fast path and the OCR tiers never run,
    -- so the whole exercise measures nothing.
    CASE WHEN m.render_kind = 'DIGITAL_PDF' THEN m.source_text ELSE NULL END AS document_text,
    m.render_kind,
    m.degradation_severity,
    m.corpus_source
FROM CORPUS_RENDER_MANIFEST m;
```

Verify the files actually landed and are readable, before trusting any routing result:

```sql
SELECT COUNT(*) AS staged_files FROM DIRECTORY(@CORPUS_DOCUMENTS);

-- Do the manifest and the stage agree? A mismatch means silent upload failures.
SELECT
    (SELECT COUNT(*) FROM CORPUS_RENDER_MANIFEST WHERE render_kind <> 'DIGITAL_PDF') AS expected,
    (SELECT COUNT(*) FROM DIRECTORY(@CORPUS_DOCUMENTS))                               AS on_stage;
```

```sql
-- Smoke-test OCR on one file per degradation level. Read the output.
-- TO_VARCHAR before PARSE_JSON: the function is documented as returning a JSON
-- string but returns an OBJECT on some accounts, where PARSE_JSON is a compile
-- error. TO_VARCHAR handles both.
SELECT m.render_kind, m.degradation_severity,
       LEFT(PARSE_JSON(TO_VARCHAR(AI_PARSE_DOCUMENT(
           TO_FILE('@CORPUS_DOCUMENTS', m.file_path),
           {'mode': 'LAYOUT', 'page_filter': [{'start': 0, 'end': 1}]}
       ))):pages[0]:content::STRING, 400) AS ocr_sample
FROM CORPUS_RENDER_MANIFEST m
WHERE m.render_kind IN ('CLEAN_SCAN','DEGRADED_SCAN')
QUALIFY ROW_NUMBER() OVER (PARTITION BY m.degradation_severity ORDER BY m.document_id) = 1;
```

Read those samples properly. The question is not "did OCR return text" but "did it preserve the
numbers". A scan that returns fluent prose while mangling `0.52` into `052` will produce confidently
wrong codes, and nothing downstream will flag it.

## Validate that the corpus actually exercises the tiers

The whole point. Run routing, then check:

```sql
-- Does routing distribute across tiers, and does it track the render kind?
SELECT d.render_kind, d.degradation_severity, r.assigned_tier, COUNT(*) AS docs
FROM ROUTING_DECISIONS r
JOIN CORPUS_DOCUMENTS_TABLE d USING (document_id)
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
```

What good looks like:

- `DIGITAL_PDF` lands predominantly in T2.
- `CLEAN_SCAN` lands in T1 or T2 — either is defensible.
- `DEGRADED_SCAN` at high severity lands in T1 **on content grounds**, via the classifier reading the
  OCR'd sample — not on an OCR-quality score, which does not discriminate.
- `FORM` lands in T3.
- `ADMINISTRATIVE` lands in T4.

```sql
-- Does any candidate OCR quality signal correlate with known degradation?
-- Expected result, based on measurement: avg_clean_ratio is FLAT and
-- ocr_failures is zero. If so, the ratio carries no information and must not
-- be used as a tier decider -- which is what the routing skill now assumes.
SELECT d.degradation_severity,
       COUNT(*)                            AS docs,
       ROUND(AVG(g.clean_char_ratio), 3)    AS avg_clean_ratio,
       ROUND(AVG(g.chars_per_page), 0)      AS avg_chars_per_page,
       COUNT_IF(g.ocr_effectively_empty)    AS ocr_failures
FROM ROUTING_OCR_SIGNAL g
JOIN CORPUS_DOCUMENTS_TABLE d USING (document_id)
GROUP BY 1 ORDER BY 1;
```

If the ratio is flat, that is the expected and correct result — report it and move on. Content
classification is doing the routing work, and this query is how you confirm you have not built a
threshold on noise.

## Cost warning before you render everything

`AI_PARSE_DOCUMENT` bills **per page**, and rendering turns a cheap text corpus into a billable OCR
workload. Before rendering at full scale:

- Estimate pages, not documents. A 1,600-note corpus rendered at two pages per note is 3,200 pages, and
  every T1 document is OCR'd in full.
- Render a **sample first** — 50 to 100 documents spanning the mix — validate the tier distribution and
  the OCR quality correlation, and only then scale up.
- Remember that `page_filter` limits the routing sample but T1 extraction deliberately parses whole
  documents.

State the page estimate at the gate and let the user decide. Report pages and tokens, never dollars.

## Licensing and provenance, if importing an external corpus

Record where the corpus came from and under what terms, in the manifest and in
`icd10-project.yml`. Rules:

- Check the licence permits your use, including derivative works if you are rendering it.
- Carry the required attribution and citation. Put it in the plugin output, not just in someone's head.
- Do not stage third-party licensed **coding guidance** without confirming the customer is licensed for
  it — that is a separate question from the note corpus and it is easy to conflate.
- Never mix a synthetic corpus into a table alongside real patient data without an unmistakable source
  marker on every row. Synthetic rows that become indistinguishable from real ones are a governance
  problem that gets worse with time.

```sql
ALTER TABLE CORPUS_DOCUMENTS_TABLE
  ADD COLUMN IF NOT EXISTS corpus_source VARCHAR(100);  -- e.g. 'SYNTHETIC_GENERATED', 'EXTERNAL_<name>'
```

## What this does not fix

Be straight with the user about the limits:

- **Rendered text is not a real scan.** Rasterizing clean text and adding noise approximates a fax or a
  photocopy; it does not reproduce handwriting, stamps, stapled inserts, forms filled in by hand, or
  the particular failure modes of the customer's own scanning estate. Routing tuned on rendered
  degradation will need re-tuning on real documents.
- **Handwriting is absent.** `AI_PARSE_DOCUMENT` does recognise handwriting, but nothing here generates
  any, so the hardest T1 case is untested.
- **An external corpus brings its own domain.** A corpus of inpatient hospital notes is a different
  documentation genre from the ambulatory visit notes where risk-adjustment coding gaps actually live,
  and its coding taxonomy may not be the customer's at all. It is useful as realistic background and
  for routing and OCR work; it is not a substitute for the customer's own document mix.

Record what was built in `created_objects`, and note the corpus composition in `icd10-project.yml` so
Phase 6 can report tier mix against a known-good expectation.
