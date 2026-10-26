# Diagnosing an intake pipeline that is not producing what you expect

Work these in order. The first four account for most reports, and they present as one of two
symptoms: "everything goes to exceptions" or "fields are NULL".

## 1. Scores are NULL — the positional-syntax trap

**Symptom:** every document is an exception for "low confidence" even on clean digital PDFs, or —
worse — everything auto-approves.

`AI_EXTRACT` returns a `scoring` object only with named arguments and `scores => TRUE`.

```sql
SELECT
    COUNT(*)                                             AS fields,
    COUNT_IF(raw_value IS NOT NULL)                      AS with_value,
    COUNT_IF(raw_value IS NOT NULL AND score IS NULL)    AS value_without_score
FROM EXTRACTED_FIELDS
WHERE run_id = :run_id;
```

`value_without_score > 0` means the call was positional or `scores` was omitted. Fix the call; then
confirm threshold logic fails closed (`COALESCE(score, 0) >= min_score`). If everything had been
auto-approving, treat every post from that run as unvalidated and re-run the decision step.

## 2. Extraction errors that look like empty fields

**Symptom:** many NULL fields on a subset of documents.

```sql
SELECT
    COALESCE(response:error::STRING, 'OK')  AS error,
    COUNT(*)                                AS docs
FROM EXTRACT_RAW
WHERE run_id = :run_id
GROUP BY 1 ORDER BY docs DESC;
```

The documented error messages tell you the cause directly: `Maximum number of 125 pages exceeded`,
`Maximum file size ... exceeded`, `The provided file format ... isn't supported`, `Provided file cannot
be accessed`, page dimension limits. Each needs routing (split, page-select, convert, or reject with a
reason), not a retry. `Provided file cannot be accessed` is usually a privilege on the stage for the
role running the task, not the role you tested with.

## 3. Wrong schema ran on the document

**Symptom:** invoice fields populated on contracts; "totals" that are liability caps; dates that are
effective dates.

```sql
SELECT c.document_type, c.route, c.classify_error IS NOT NULL AS had_error, COUNT(*) AS docs
FROM DOC_CLASSIFICATION c
GROUP BY 1, 2, 3 ORDER BY docs DESC;
```

Then sample documents per type and check the classifier against the file. Common causes:

- no `other_document` label, so out-of-scope documents are forced into the nearest type;
- labels with abbreviations or overlapping meaning (`invoice` and `bill`, `claim` and `claim_form`);
- the classification sample was a fax cover sheet — classify on the first **non-empty** page;
- multi-document PDFs classified as their first document (best-practices rule 19).

## 4. Normalization is failing, not extraction

**Symptom:** raw values look right on inspection, but normalized values are NULL and validation fails.

```sql
SELECT field_name,
       COUNT(*)                                                  AS with_raw,
       COUNT_IF(normalized_value IS NULL)                        AS normalize_failed,
       COUNT_IF(normalize_status = 'AMBIGUOUS')                  AS ambiguous
FROM EXTRACTED_FIELDS
WHERE run_id = :run_id AND raw_value IS NOT NULL
GROUP BY 1 ORDER BY normalize_failed DESC;
```

Look at the raw values for the failing field. Typical causes: decimal commas, currency codes inside
the amount string, `dd.mm.yyyy` dates, invoice numbers with internal spaces. Fix the shared UDF —
never add a second normalizer for one field, because the harness will keep using the old one and the
two will disagree.

`AMBIGUOUS` is correct behaviour for `03/04/2026` and `1.234` without a locale. The fix is a
per-vendor locale in reference data, not a guess.

## 5. Everything is an exception because of one rule

**Symptom:** STP near zero, exceptions dominated by one reason.

```sql
SELECT rule_id, severity, COUNT(*) AS failures,
       ROUND(100.0 * COUNT(*) / NULLIF(SUM(COUNT(*)) OVER (), 0), 1) AS pct_of_failures
FROM FIELD_VALIDATION
WHERE run_id = :run_id AND passed = FALSE
GROUP BY 1, 2 ORDER BY failures DESC;
```

If one reference-data rule fails nearly everywhere (`VENDOR_MATCH`, `PO_EXISTS`, `POLICY_ACTIVE`), the
join key format is mismatched — leading zeros, prefixes, hyphens in tax IDs, legal-entity suffixes in
vendor names. Inspect both sides' **shape**:

```sql
SELECT v.normalized_value AS invoice_side, LENGTH(v.normalized_value) AS len,
       REGEXP_LIKE(v.normalized_value, '^[0-9]+$') AS digits_only
FROM EXTRACTED_FIELDS v
WHERE v.field_name = 'po_number' AND v.run_id = :run_id
LIMIT 20;
```

Compare against the preflight-recorded format on the reference side. Fix the normalizer so both sides
go through the same function.

If the rule failing everywhere is a **masked** column comparison (bank details, tax ID), the validation
role cannot see unmasked values and every comparison fails. That is a governance decision: grant an
unmasked view to the validation role, or compare hashes computed under a role that can see them.

## 6. Everything is an exception because thresholds are too high

**Symptom:** exceptions dominated by `LOW_SCORE`, spread across fields.

Thresholds in `intake-project.yml` are placeholders until Phase 5 sets them from the score/correctness
curve. Run that curve (`evaluate-intake-accuracy`). Do not lower thresholds globally to raise STP; lower
them **per field** only where the labeled set shows the lower band is still correct, and check that
false-STP does not rise.

## 7. STP looks great — check false STP before celebrating

**Symptom:** none, which is the problem.

```sql
SELECT
    COUNT_IF(d.decision = 'AUTO_APPROVED')                                    AS auto_approved,
    COUNT_IF(d.decision = 'AUTO_APPROVED' AND s.any_posting_field_wrong)      AS false_stp
FROM DOCUMENT_DECISION d
JOIN EVAL_DOCUMENT_STP s USING (document_id, run_id)
WHERE d.run_id = :run_id;
```

Requires a labeled set. If there is none, say so: a high STP rate on unlabeled documents is not
evidence of correctness. Sample 50 auto-approved documents for human verification before the rate is
presented to anyone.

## 8. Duplicates are slipping through, or legitimate invoices are rejected as duplicates

```sql
SELECT rule_id, passed, COUNT(*) FROM FIELD_VALIDATION
WHERE run_id = :run_id AND rule_id IN ('DUP_FILE_HASH', 'DUP_VENDOR_INVOICE')
GROUP BY 1, 2;
```

- Slipping through: invoice number not normalized identically on both sides (`INV-0042` vs `42`), or
  history table not included (`reference.posted_invoices` absent).
- False rejects: the business-level key is not scoped to vendor, so two vendors' invoice `1001`
  collide; or a credit note shares the number of the invoice it credits and is being compared under the
  same document type.

## 9. Line items do not reconcile

**Symptom:** `LINES_SUM_TO_SUBTOTAL` fails on documents that look correct.

- Table extraction returned columns of different lengths (a wrapped description split into two rows).
  Check `ARRAY_SIZE` per column before zipping.
- Discount, freight, or fee lines extracted as items, or missed. Ask the schema explicitly for them.
- Tax-inclusive line amounts. The rule must know whether lines are net or gross for this vendor.
- The table spans pages and the description did not localize both halves. Use the `description` to
  name the table header text the vendor actually prints.

Remember the table score is aggregate; a 0.9 table can contain one wrong cell. Arithmetic is the
check.

## 10. Cost is higher than expected

```sql
-- CREDITS is per usage row; METRICS is an array with one element per metric
-- (input and output tokens are two elements). Aggregate metrics per usage row
-- FIRST, then join back and sum. Flattening and summing CREDITS in one step
-- double-counts credits for every token-metered call. (A correlated scalar
-- subquery over FLATTEN is not supported, hence the two CTEs.)
WITH usage_rows AS (
    SELECT h.function_name, h.model_name, h.query_id, h.warehouse_id, h.start_time,
           h.credits, h.metrics
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h
    WHERE h.query_tag ILIKE 'doc_intake:%' AND h.start_time >= :run_start
),
metric_rows AS (
    SELECT u.function_name, u.model_name, u.query_id, u.warehouse_id, u.start_time,
           SUM(IFF(m.value:key:unit::STRING = 'pages',  m.value:value::NUMBER, 0)) AS pages,
           SUM(IFF(m.value:key:unit::STRING = 'tokens', m.value:value::NUMBER, 0)) AS tokens
    FROM usage_rows u, LATERAL FLATTEN(input => u.metrics) m
    GROUP BY 1, 2, 3, 4, 5
)
SELECT u.function_name,
       SUM(u.credits) AS credits, SUM(mr.pages) AS pages, SUM(mr.tokens) AS tokens
FROM usage_rows u
LEFT JOIN metric_rows mr
  ON  mr.query_id = u.query_id AND mr.function_name = u.function_name
  AND mr.start_time = u.start_time
  AND EQUAL_NULL(mr.model_name, u.model_name) AND EQUAL_NULL(mr.warehouse_id, u.warehouse_id)
GROUP BY 1 ORDER BY credits DESC;
```

Look for, in order:

1. `AI_PARSE_DOCUMENT` pages close to total pages — the classification sample is not using
   `page_filter`, or full parsing runs on documents that only need extraction.
2. Pages billed twice — documents parsed in full **and** extracted from file.
3. `scale_factor` above 1.0 applied to every type rather than the ones that measured a gain.
4. Re-extraction of unchanged files — the incremental predicate is keyed on arrival time rather than
   `(document_id, schema_hash)`.
5. Large `AI_CLASSIFY` token counts — long label descriptions and few-shot examples bill on every row.

Note the usage view aggregates in one-hour windows and lags by minutes; very recent runs look cheap.
