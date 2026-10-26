---
name: evaluate-intake-accuracy
description: "Measure whether the document-intake pipeline is right, how much it automates, how often its automation is wrong, and what it costs. Computes document-type accuracy, field-level exact and normalized match per field, type, render kind, scan severity and input mode (from the answer key outward with a FULL OUTER JOIN), six field outcomes (correct, correct-absent, not-extracted, wrong, hallucinated, document-not-extracted), straight-through-processing rate, false-STP rate (auto-approved with a wrong posting field), false-exception rate, decision and reason accuracy on hard cases, score-versus-correctness calibration and per-field threshold sweeps, silent-loss accounting, and credits per 1K pages from CORTEX_AI_FUNCTIONS_USAGE_HISTORY. Compares experiments. Use for accuracy, STP rate, false STP, confidence threshold tuning, cost per page, or 'is it good enough to go live'."
parent_skill: document-intake
---

# Evaluate accuracy, automation, and cost

Four questions, answered with numbers: how often is each field right; how much posts without a human;
**how often what posts is wrong**; and what does it cost per thousand pages. Do not skip this phase. A
pipeline with an unmeasured false-STP rate is automating an unknown error stream into the ledger.

## Ground truth sources

| Source | Where | What it can measure |
|---|---|---|
| Sandbox | `SYN_FIELD_ANSWER_KEY`, `SYN_DOC_ANSWER_KEY` (`corpus_source` NULL) | text-path accuracy; every rule via hard cases |
| Rendered corpus | same tables, `corpus_source = 'SYNTHETIC_RENDERED'` | file-path accuracy; accuracy vs scan severity; real page cost |
| Keyed real sample | a customer-keyed table in the same shape | **the only production-predictive accuracy** |
| Reviewer corrections | `REVIEW_CORRECTIONS` | accuracy on exceptions only (biased: says nothing about approved docs) |

For a real-data baseline, ask the customer to key 100–300 documents per in-scope type, stratified by
intake channel and vendor, into the field-key shape (canonical values, `PRESENT`/`NOT_PRESENT`,
`posts`). It is the cheapest credible accuracy claim available and the POC criteria should require it.

## One normalization, both sides

The key stores canonical values; the pipeline stores raw strings plus normalized values. Comparing
anything other than **the same normalizer applied to both sides** reports a wrong number (best-practices
rule 20). The key side goes through the same UDFs, by the same `FIELD_CATALOG` kind:

```sql
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_KEY_NORMALIZED AS
SELECT k.document_id, k.document_type, k.field_name, k.expected_value, k.expected_status, k.posts,
       COALESCE(k.corpus_source, 'SANDBOX') AS corpus_source,
       fc.field_kind,
       CASE fc.field_kind
           -- Canonical amounts and ISO dates need no locale; passing NULL is correct here.
           WHEN 'AMOUNT'     THEN TO_VARCHAR({{DB}}.{{SCHEMA}}.NORM_AMOUNT(k.expected_value, NULL):value::NUMBER(18,2), 'FM999999999990.00')
           WHEN 'DATE'       THEN {{DB}}.{{SCHEMA}}.NORM_DATE(k.expected_value, 'ISO'):value::STRING
           WHEN 'DOC_NUMBER' THEN {{DB}}.{{SCHEMA}}.NORM_DOC_NUMBER(k.expected_value)
           WHEN 'TAX_ID'     THEN {{DB}}.{{SCHEMA}}.NORM_TAX_ID(k.expected_value)
           WHEN 'PARTY'      THEN {{DB}}.{{SCHEMA}}.NORM_PARTY_NAME(k.expected_value)
           WHEN 'CURRENCY'   THEN {{DB}}.{{SCHEMA}}.NORM_CURRENCY(k.expected_value):value::STRING
           WHEN 'INTEGER'    THEN TO_VARCHAR(TRY_TO_NUMBER(REGEXP_SUBSTR(k.expected_value, '[0-9]+')))
           WHEN 'YESNO'      THEN UPPER(k.expected_value)
           ELSE UPPER({{DB}}.{{SCHEMA}}.NULLIF_PLACEHOLDER(k.expected_value))
       END AS expected_normalized
FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_FIELD_ANSWER_KEY k
LEFT JOIN {{DB}}.{{SCHEMA}}.FIELD_CATALOG fc
       ON fc.document_type = k.document_type AND fc.field_name = k.field_name;
```

A canonical amount like `1234.56` contains no ambiguous pattern, so `NORM_AMOUNT(..., NULL)` returns it
unchanged; `'1234'` with no decimal also normalizes cleanly. Confirm with the round-trip check before
quoting anything:

```sql
-- Every PRESENT key value must normalize to non-NULL. A failure here is a key
-- or normalizer bug, and every metric below would be wrong.
SELECT field_kind, COUNT(*) AS present_keys, COUNT_IF(expected_normalized IS NULL) AS key_normalize_failed
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_KEY_NORMALIZED
WHERE expected_status = 'PRESENT'
GROUP BY 1 ORDER BY 1;
-- key_normalize_failed must be 0 for every kind.
```

## Field matches — from the key outward

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{EVAL_SCHEMA}}.EVAL_FIELD_MATCHES (
    run_id VARCHAR, experiment_id VARCHAR, schema_hash VARCHAR,
    document_id VARCHAR, document_type VARCHAR, field_name VARCHAR, field_kind VARCHAR,
    posts BOOLEAN, corpus_source VARCHAR, input_mode VARCHAR,
    render_kind VARCHAR, degradation_severity FLOAT,
    expected_status VARCHAR, expected_value VARCHAR, expected_normalized VARCHAR,
    raw_value VARCHAR, normalized_value VARCHAR, score FLOAT, normalize_status VARCHAR,
    exact_match BOOLEAN, normalized_match BOOLEAN, outcome VARCHAR,
    evaluated_at TIMESTAMP_LTZ
);

MERGE INTO {{DB}}.{{EVAL_SCHEMA}}.EVAL_FIELD_MATCHES t
USING (
    SELECT
        :run_id AS run_id, :experiment_id AS experiment_id, r.schema_hash,
        k.document_id, k.document_type, k.field_name, k.field_kind, k.posts, k.corpus_source,
        r.input_mode, m.render_kind, m.degradation_severity,
        k.expected_status, k.expected_value, k.expected_normalized,
        f.raw_value, f.normalized_value, f.score, f.normalize_status,
        -- Exact: what a downstream system would receive with no normalization.
        EQUAL_NULL(TRIM(f.raw_value), TRIM(k.expected_value))                 AS exact_match,
        -- Normalized: did the pipeline understand the document.
        EQUAL_NULL(f.normalized_value, k.expected_normalized)                 AS normalized_match,
        CASE
            WHEN r.document_id IS NULL                                        THEN 'DOC_NOT_EXTRACTED'
            WHEN k.expected_status = 'NOT_PRESENT' AND f.raw_value IS NULL    THEN 'CORRECT_ABSENT'
            WHEN k.expected_status = 'NOT_PRESENT'                            THEN 'HALLUCINATED'
            WHEN f.raw_value IS NULL                                          THEN 'NOT_EXTRACTED'
            WHEN EQUAL_NULL(f.normalized_value, k.expected_normalized)        THEN 'CORRECT'
            ELSE 'WRONG'
        END AS outcome,
        CURRENT_TIMESTAMP() AS evaluated_at
    FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_KEY_NORMALIZED k
    -- The key drives. A document whose extraction failed or never ran is
    -- still here, as DOC_NOT_EXTRACTED, not silently absent.
    LEFT JOIN {{DB}}.{{SCHEMA}}.EXTRACT_RAW r
           ON r.document_id = k.document_id AND r.run_id = :run_id
    LEFT JOIN {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS f
           ON f.document_id = k.document_id AND f.field_name = k.field_name AND f.run_id = :run_id
    -- Present only when build-intake-test-corpus ran. Without it, create an empty
    -- table with the manifest's columns so this join still compiles.
    LEFT JOIN {{DB}}.{{SCHEMA}}.SYN_CORPUS_MANIFEST m
           ON m.document_id = k.document_id
    WHERE k.document_type IN (SELECT DISTINCT document_type FROM {{DB}}.{{SCHEMA}}.FIELD_CATALOG)
) s
ON t.run_id = s.run_id AND t.document_id = s.document_id AND t.field_name = s.field_name
WHEN NOT MATCHED THEN INSERT VALUES (
    s.run_id, s.experiment_id, s.schema_hash, s.document_id, s.document_type, s.field_name, s.field_kind,
    s.posts, s.corpus_source, s.input_mode, s.render_kind, s.degradation_severity,
    s.expected_status, s.expected_value, s.expected_normalized,
    s.raw_value, s.normalized_value, s.score, s.normalize_status,
    s.exact_match, s.normalized_match, s.outcome, s.evaluated_at);
```

Also count **extracted fields with no key row** — a field the schema asks for that the key does not
label. It should be zero; if not, the key is incomplete for that field and its accuracy is unmeasured:

```sql
SELECT f.document_type, f.field_name, COUNT(*) AS unlabeled
FROM {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS f
JOIN {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY d USING (document_id)
LEFT JOIN {{DB}}.{{EVAL_SCHEMA}}.SYN_FIELD_ANSWER_KEY k
       ON k.document_id = f.document_id AND k.field_name = f.field_name
WHERE f.run_id = :run_id AND k.document_id IS NULL
GROUP BY 1, 2 ORDER BY unlabeled DESC;
```

The hard cases label only the fields each case targets. Their unlabeled fields are expected and are
excluded from field metrics (they still count for decisions). Generated and rendered documents must
show zero.

## Field accuracy

```sql
SELECT document_type, field_name, posts,
       COUNT(*)                                                        AS keyed,
       COUNT_IF(outcome IN ('CORRECT', 'CORRECT_ABSENT'))              AS correct,
       ROUND(100.0 * COUNT_IF(normalized_match OR outcome = 'CORRECT_ABSENT') / COUNT(*), 1) AS normalized_acc_pct,
       ROUND(100.0 * COUNT_IF(exact_match)                     / COUNT(*), 1) AS exact_acc_pct,
       COUNT_IF(outcome = 'WRONG')                                     AS wrong,
       COUNT_IF(outcome = 'HALLUCINATED')                              AS hallucinated,
       COUNT_IF(outcome = 'NOT_EXTRACTED')                             AS not_extracted,
       COUNT_IF(outcome = 'DOC_NOT_EXTRACTED')                         AS doc_not_extracted
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_FIELD_MATCHES
WHERE run_id = :run_id
GROUP BY 1, 2, 3
ORDER BY normalized_acc_pct ASC;
```

How to read it:

- **Exact well below normalized** on amounts and dates is expected — `1.463,70` is not `1463.70`
  byte-for-byte. It is a downstream-integration finding (send normalized values), not an accuracy
  problem. On identifiers (`invoice_number`, `policy_number`) a gap means formatting noise — spaces,
  `#` — that the matching normalizer absorbs but the posted value would carry.
- **`WRONG` on a posting field** is the number that matters. Each one is a potential bad post unless
  validation stops it.
- **`HALLUCINATED`** — a value for a field that is not on the document — concentrates on `po_number`
  and `due_date` for non-PO invoices. Fix with "empty if not printed" in the description.
- **`NOT_EXTRACTED`** on a required field is a recall loss that validation will catch (it blocks),
  so it costs STP, not correctness.

Then split by the dimensions that predict production behaviour:

```sql
-- Accuracy vs scan quality. The curve the business needs to decide which
-- intake channels can go straight through.
SELECT COALESCE(render_kind, 'TEXT_ROW') AS render_kind, degradation_severity,
       COUNT(DISTINCT document_id) AS docs,
       ROUND(100.0 * COUNT_IF(posts AND outcome IN ('CORRECT','CORRECT_ABSENT')) / NULLIF(COUNT_IF(posts), 0), 1)
             AS posting_field_acc_pct,
       COUNT_IF(posts AND outcome IN ('WRONG', 'HALLUCINATED')) AS posting_field_errors,
       ROUND(AVG(IFF(outcome = 'WRONG', score, NULL)), 3)   AS avg_score_when_wrong,
       ROUND(AVG(IFF(outcome = 'CORRECT', score, NULL)), 3) AS avg_score_when_correct
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_FIELD_MATCHES
WHERE run_id = :run_id
GROUP BY 1, 2 ORDER BY 1, 2;

-- Text path vs file path on identical content (sandbox rendered with --from-sandbox).
SELECT input_mode, field_name,
       ROUND(100.0 * COUNT_IF(outcome IN ('CORRECT','CORRECT_ABSENT')) / COUNT(*), 1) AS acc_pct, COUNT(*) AS n
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_FIELD_MATCHES
WHERE experiment_id IN (:text_experiment, :file_experiment)
GROUP BY 1, 2 ORDER BY 2, 1;
```

`avg_score_when_wrong` close to `avg_score_when_correct` at a severity level means the score is not
separating right from wrong there — thresholds cannot protect that channel, and its documents should
route to review regardless of score.

## Document type accuracy

```sql
SELECT k.expected_type, c.document_type AS predicted_type, COUNT(*) AS docs
FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY k
LEFT JOIN {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION c USING (document_id)
GROUP BY 1, 2 ORDER BY 1, docs DESC;
```

The cells that matter: anything predicted `invoice` that is not one (it would run the invoice schema
and could post), and any invoice predicted `other_document` (it was silently rejected).

## STP, false STP, false exceptions

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{EVAL_SCHEMA}}.EVAL_DOCUMENT_STP (
    run_id VARCHAR, experiment_id VARCHAR, document_id VARCHAR, document_type VARCHAR,
    corpus_source VARCHAR, case_role VARCHAR,
    expected_decision VARCHAR, expected_reason VARCHAR,
    decision VARCHAR, blocking_failures ARRAY,
    any_posting_field_wrong BOOLEAN, wrong_posting_fields ARRAY,
    reason_matched BOOLEAN, evaluated_at TIMESTAMP_LTZ
);

INSERT INTO {{DB}}.{{EVAL_SCHEMA}}.EVAL_DOCUMENT_STP
SELECT :run_id, :experiment_id, k.document_id, k.expected_type, COALESCE(k.corpus_source, 'SANDBOX'),
       k.case_role, k.expected_decision, k.expected_reason,
       -- From the key outward: a document with no decision is a defect and shows as NULL here.
       d.decision, d.blocking_failures,
       COALESCE(fm.any_wrong, FALSE),
       fm.wrong_fields,
       k.expected_reason IS NULL OR ARRAY_CONTAINS(k.expected_reason::VARIANT, d.blocking_failures)
         OR c.route_reason = k.expected_reason,
       CURRENT_TIMESTAMP()
FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY k
LEFT JOIN {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION d ON d.document_id = k.document_id AND d.run_id = :run_id
LEFT JOIN {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION c ON c.document_id = k.document_id
LEFT JOIN (
    SELECT document_id,
           BOOLOR_AGG(posts AND outcome IN ('WRONG', 'HALLUCINATED')) AS any_wrong,
           ARRAY_AGG(IFF(posts AND outcome IN ('WRONG', 'HALLUCINATED'), field_name, NULL)) AS wrong_fields
    FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_FIELD_MATCHES WHERE run_id = :run_id GROUP BY 1
) fm ON fm.document_id = k.document_id;
```

The headline table:

```sql
SELECT document_type,
       COUNT(*)                                                           AS docs,
       COUNT_IF(decision IS NULL)                                         AS no_decision,           -- must be 0
       COUNT_IF(decision = 'AUTO_APPROVED')                               AS auto_approved,
       ROUND(100.0 * COUNT_IF(decision = 'AUTO_APPROVED')
             / NULLIF(COUNT_IF(expected_decision <> 'REJECTED'), 0), 1)   AS stp_rate_pct,
       -- Of what posted automatically, how much carried a wrong posting value.
       COUNT_IF(decision = 'AUTO_APPROVED' AND any_posting_field_wrong)   AS false_stp,
       ROUND(100.0 * COUNT_IF(decision = 'AUTO_APPROVED' AND any_posting_field_wrong)
             / NULLIF(COUNT_IF(decision = 'AUTO_APPROVED'), 0), 2)        AS false_stp_rate_pct,
       -- Auto-approved documents that SHOULD have been stopped by a rule.
       COUNT_IF(decision = 'AUTO_APPROVED' AND expected_decision = 'EXCEPTION') AS missed_exceptions,
       -- Exceptions on documents that were clean and correctly extracted: reviewer
       -- work the pipeline created unnecessarily. The cost side of a tight threshold.
       COUNT_IF(decision = 'EXCEPTION' AND expected_decision = 'AUTO_APPROVED'
                AND NOT any_posting_field_wrong)                          AS false_exceptions
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_DOCUMENT_STP
WHERE run_id = :run_id
GROUP BY ROLLUP (document_type)
ORDER BY document_type NULLS LAST;
```

Definitions to state whenever these numbers are shown:

- **STP rate** = auto-approved / documents that should be processed (excludes expected rejects).
- **False-STP rate** = auto-approved with at least one wrong or hallucinated posting field /
  auto-approved. This is the go-live gate. Its acceptable level is a **customer decision** — ask for it,
  record it in `intake-project.yml`, and never propose a number.
- **Missed exceptions** = auto-approved when a business rule should have stopped it (bank change,
  duplicate, coverage). On the sandbox each one is a named hard case; any non-zero count blocks
  operationalization.
- **False exceptions** = clean, correctly extracted documents sent to review. This is lost STP, and
  it is what thresholds trade against false STP.

### Hard-case scorecard

```sql
SELECT document_id, expected_type, expected_decision, expected_reason,
       decision, blocking_failures, reason_matched,
       IFF(decision = expected_decision AND reason_matched, 'PASS', 'FAIL') AS result
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_DOCUMENT_STP
WHERE run_id = :run_id AND case_role = 'HARD_CASE'
ORDER BY result, document_id;
```

`reason_matched = FALSE` with the right decision means the document was stopped by accident (for
example H01 caught by `LOW_SCORE` rather than `VENDOR_BANK_MATCH`). That control would not have fired
on a cleaner scan of the same fraudulent invoice. Treat it as a failure.

H04 is special: `AUTO_APPROVED` with `invoice_date = 2026-04-03` passes; `EXCEPTION` with
`NORMALIZE_FAILED` also passes (the locale was not wired, and the pipeline refused to guess);
`AUTO_APPROVED` with `2026-03-04` is the failure this case exists to catch.

## Thresholds: from the score curve, per field

Thresholds are the cheapest lever and the most misused. Set them from data:

```sql
-- Calibration: does the score separate correct from wrong, per field?
SELECT document_type, field_name,
       WIDTH_BUCKET(score, 0, 1, 10) / 10.0 - 0.1            AS score_bucket_floor,
       COUNT(*)                                               AS values_n,
       ROUND(100.0 * COUNT_IF(outcome = 'CORRECT') / COUNT(*), 1) AS correct_pct
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_FIELD_MATCHES
WHERE run_id = :run_id AND raw_value IS NOT NULL
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
```

```sql
-- Sweep: for each candidate threshold, how many values would be accepted, and
-- how many of the accepted would be wrong. The right point is where the
-- error rate among accepted meets the customer's tolerance at maximum coverage.
WITH th AS (SELECT VALUE::FLOAT AS t FROM TABLE(FLATTEN(input => [0.5,0.6,0.7,0.8,0.85,0.9,0.93,0.95,0.97,0.99])))
SELECT m.document_type, m.field_name, th.t AS min_score,
       COUNT_IF(m.score >= th.t)                                            AS accepted,
       ROUND(100.0 * COUNT_IF(m.score >= th.t) / COUNT(*), 1)               AS coverage_pct,
       COUNT_IF(m.score >= th.t AND m.outcome IN ('WRONG', 'HALLUCINATED')) AS accepted_wrong,
       ROUND(100.0 * COUNT_IF(m.score >= th.t AND m.outcome IN ('WRONG', 'HALLUCINATED'))
             / NULLIF(COUNT_IF(m.score >= th.t), 0), 2)                     AS accepted_error_pct
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_FIELD_MATCHES m
CROSS JOIN th
WHERE m.run_id = :run_id AND m.raw_value IS NOT NULL AND m.posts
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
```

Present the curve per posting field and let the business owner choose the operating point — it is a
trade between reviewer capacity and error tolerance, not a technical setting. Write the chosen values
to `FIELD_THRESHOLDS` with `threshold_source = '<experiment_id>'` and to `thresholds` in
`intake-project.yml`, then **re-run Phase 4 and this phase** to report STP and false STP at the chosen
thresholds. A threshold chosen on the same documents it is reported on is optimistic; with a keyed real
sample, choose on half and report on the other half.

Two cautions that come from the arithmetic, not from opinion:

- With few wrong values in a field (the sandbox has few by design), `accepted_error_pct` at high
  thresholds is computed from a handful of cases. Show counts beside every percentage.
- If a field has **zero** wrong values on the labeled set, its threshold cannot be chosen from this
  data at all. Say so, and leave the placeholder or set it from the real keyed sample.

## Silent loss — the numbers accuracy cannot see

Report every one, including zeros. "Checked and zero" and "not checked" are different claims.

```sql
SELECT 'documents_without_decision' AS check_name, COUNT(*) AS n
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_DOCUMENT_STP WHERE run_id = :run_id AND decision IS NULL
UNION ALL
SELECT 'extract_errors', COUNT(*) FROM {{DB}}.{{SCHEMA}}.EXTRACT_RAW
WHERE run_id = :run_id AND response:error IS NOT NULL
UNION ALL
SELECT 'values_without_score', COUNT(*) FROM {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS
WHERE run_id = :run_id AND raw_value IS NOT NULL AND score IS NULL
UNION ALL
SELECT 'classify_unclassified', COUNT(*) FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION
WHERE run_id = :run_id AND document_type = 'UNCLASSIFIED'
UNION ALL
SELECT 'normalize_ambiguous_on_posting_fields', COUNT(*) FROM {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS f
JOIN {{DB}}.{{SCHEMA}}.FIELD_THRESHOLDS t USING (document_type, field_name)
WHERE f.run_id = :run_id AND t.posts AND f.normalize_status IN ('AMBIGUOUS', 'LOCALE_CONFLICT', 'UNPARSEABLE')
UNION ALL
SELECT 'exceptions_without_reason', COUNT(*) FROM {{DB}}.{{SCHEMA}}.EXCEPTIONS_QUEUE
WHERE run_id = :run_id AND (reason_count = 0 OR primary_reason IS NULL)
UNION ALL
SELECT 'approved_without_decision', COUNT(*) FROM {{DB}}.{{SCHEMA}}.INTAKE_APPROVED a
LEFT JOIN {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION d USING (document_id, run_id)
WHERE a.run_id = :run_id AND d.decision IS DISTINCT FROM 'AUTO_APPROVED';
```

## Cost per 1K pages — measured

Two sources, reconciled: billed credits from the account usage view, and pages from the pipeline's own
tables. The usage view meters `AI_PARSE_DOCUMENT` in pages but file-based `AI_EXTRACT` in tokens (pages
are converted at ~970 tokens each), so **the page denominator must come from the pipeline**, not from
the view.

```sql
-- Billed credits for this experiment, attributed by QUERY_TAG set per phase.
-- Two-level aggregation: CREDITS is per usage row; METRICS has one element per
-- metric, so flattening before summing credits double-counts them.
WITH usage_rows AS (
    SELECT SPLIT_PART(h.query_tag, ':', 3) AS phase, h.function_name, h.model_name,
           h.query_id, h.warehouse_id, h.start_time, h.credits, h.metrics
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
    WHERE h.query_tag LIKE 'doc_intake:' || :experiment_id || ':%'
      AND h.start_time >= :run_start
),
metric_rows AS (
    SELECT u.query_id, u.function_name, u.model_name, u.warehouse_id, u.start_time,
           SUM(IFF(m.value:key:unit::STRING = 'pages',  m.value:value::NUMBER, 0)) AS metered_pages,
           SUM(IFF(m.value:key:unit::STRING = 'tokens', m.value:value::NUMBER, 0)) AS metered_tokens
    FROM usage_rows u, LATERAL FLATTEN(input => u.metrics) m
    GROUP BY 1, 2, 3, 4, 5
),
billed AS (
    SELECT u.phase, u.function_name,
           SUM(u.credits) AS credits, SUM(mr.metered_pages) AS metered_pages, SUM(mr.metered_tokens) AS metered_tokens
    FROM usage_rows u
    LEFT JOIN metric_rows mr
      ON  mr.query_id = u.query_id AND mr.function_name = u.function_name AND mr.start_time = u.start_time
      AND EQUAL_NULL(mr.model_name, u.model_name) AND EQUAL_NULL(mr.warehouse_id, u.warehouse_id)
    GROUP BY 1, 2
),
pages AS (
    SELECT
        (SELECT SUM(page_count) FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION WHERE run_id = :run_id) AS pages_received,
        (SELECT SUM(page_count) FROM {{DB}}.{{SCHEMA}}.EXTRACT_RAW         WHERE run_id = :run_id) AS pages_extracted
)
SELECT b.phase, b.function_name, b.credits, b.metered_pages, b.metered_tokens,
       p.pages_received,
       ROUND(1000 * b.credits / NULLIF(p.pages_received, 0), 4) AS credits_per_1k_pages_received
FROM billed b CROSS JOIN pages p
UNION ALL
SELECT 'ALL', 'ALL', SUM(b.credits), SUM(b.metered_pages), SUM(b.metered_tokens),
       MAX(p.pages_received),
       ROUND(1000 * SUM(b.credits) / NULLIF(MAX(p.pages_received), 0), 4)
FROM billed b CROSS JOIN pages p
ORDER BY 1, 2;
```

Report **credits per 1K pages received** as the headline (it includes classification of documents
that were later rejected, which is real cost), plus the per-phase breakdown. Also report credits per
auto-approved document — the unit the value model compares against manual handling cost.

Rules, not negotiable:

- **Credits and pages, never dollars.** Do not look up pricing or convert. The customer's credit price
  goes into `intake-value-readout` as a customer input.
- The usage view aggregates in one-hour windows, updates with a few minutes' lag, and includes only
  usage on or after its documented start date. Very recent runs look cheap; wait, then report.
- Warehouse credits are separate from AI function credits (the view excludes them). Report warehouse
  usage for the run from `WAREHOUSE_METERING_HISTORY` separately if the user wants all-in cost, and say
  which one each number is.
- Rendered-corpus cost is real page cost but on synthetic page density. Customer documents differ in
  pages per document; scale by the customer's own page counts from preflight, not by document counts.

## Comparing experiments

```sql
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_EXPERIMENT_SUMMARY AS
SELECT s.experiment_id, s.run_id,
       COUNT(*)                                                                   AS docs,
       ROUND(COUNT_IF(s.decision = 'AUTO_APPROVED') / NULLIF(COUNT_IF(s.expected_decision <> 'REJECTED'), 0), 4) AS stp_rate,
       ROUND(COUNT_IF(s.decision = 'AUTO_APPROVED' AND s.any_posting_field_wrong)
             / NULLIF(COUNT_IF(s.decision = 'AUTO_APPROVED'), 0), 4)              AS false_stp_rate,
       COUNT_IF(s.decision = 'AUTO_APPROVED' AND s.expected_decision = 'EXCEPTION') AS missed_exceptions,
       ROUND(f.posting_field_acc, 4)                                              AS posting_field_acc,
       MAX(f.schema_hash)                                                         AS schema_hash
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_DOCUMENT_STP s
JOIN (SELECT run_id, MAX(schema_hash) schema_hash,
             COUNT_IF(posts AND outcome IN ('CORRECT','CORRECT_ABSENT')) / NULLIF(COUNT_IF(posts), 0) AS posting_field_acc
      FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_FIELD_MATCHES GROUP BY 1) f USING (run_id)
GROUP BY s.experiment_id, s.run_id, f.posting_field_acc;
```

Compare on **the same documents** only. Change one thing at a time (schema description, `scale_factor`,
input mode, thresholds). When `schema_version` matches across two runs and `schema_hash` differs, the
schema changed without a version bump — trust the hash.

## Small-sample honesty

With 16 hard cases, each case is 6 percentage points of the hard-case pass rate. With a few hundred
generated documents and a low error rate, a false-STP rate is computed from a handful of events.
Report counts next to every rate, and for false STP give an interval rather than a point: with `x`
false STPs among `n` auto-approved documents, the 95 percent Wilson interval is

```sql
SELECT x, n,
       (x + 1.92) / (n + 3.84) - 1.96 * SQRT(x * (n - x) / n + 0.96) / (n + 3.84) AS lower_95,
       (x + 1.92) / (n + 3.84) + 1.96 * SQRT(x * (n - x) / n + 0.96) / (n + 3.84) AS upper_95
FROM (SELECT :false_stp::FLOAT AS x, :auto_approved::FLOAT AS n);
```

Zero false STPs on 300 auto-approved documents does not mean zero; the Wilson upper bound is about
1.3 percent. Say that.

## What to present at the gate

In this order:

1. **False-STP rate** with count and interval, **STP rate**, missed exceptions, false exceptions — per
   type and overall.
2. **Hard-case scorecard**, failures first, with reason matching.
3. **Posting-field accuracy** per field, normalized and exact, with the six outcomes.
4. **Accuracy vs scan severity** and text vs file path, with score separation per level.
5. **Threshold curves** for posting fields and the recommended operating point for the owner to choose.
6. **Silent-loss checks**, zeros stated.
7. **Credits per 1K pages** received, per phase, and per auto-approved document.
8. **Experiment comparison**, if more than one exists.

Then the honest framing: sandbox and rendered-corpus accuracy show the pipeline is wired correctly and
where it breaks; they do not forecast production accuracy. The POC's accuracy claim is the keyed real
sample. Set `phases.eval: done`.
