---
name: evaluate-icd10-accuracy
description: "Measure whether the ICD-10 suspecting pipeline is actually right, and what it cost. Computes micro and macro precision/recall/F1 with spread, hierarchical code matching (exact vs category-only vs missed), and recall and precision at both HCC level and ICD-10-specificity level against the labeled answer key, joining from ground truth so total extraction failure counts as false negatives rather than vanishing. Scores over-calling on distractor cases and correct handling of borderline cases, verifies suppression, reports AI_COMPLETE parse failures and fabricated citations so silent recall loss is visible, compares experiments by experiment_id and prompt_hash, instruments real per-stage token usage from account usage history, measures what the routing and compression cost levers actually saved on this corpus, and tunes confidence thresholds. Phase 6 of the icd10-extraction build."
parent_skill: icd10-extraction
---

# Evaluate accuracy and cost

A suspecting pipeline nobody has measured is a pipeline that generates coder workload of unknown value.
This phase answers four questions with numbers: how much does it find, how much of what it finds is
right, how much did it silently lose, and what did it cost.

Do not skip this. If the user wants to stop before it, say plainly what they will not know.

## The distinction that matters most

**Per-row confidence** is what the model thinks about one code. **Pipeline accuracy** is how often the
pipeline is actually right. They are unrelated measurements, and a pipeline can produce uniformly high
confidence while being frequently wrong. Confidence is produced in Phase 5; accuracy is produced here,
against ground truth.

## Normalise both sides with one shared expression

Before any matching, get this right, because it is the single most common way an accuracy harness
reports a broken number with total confidence.

Ground truth is frequently authored as a delimited string (`"E11.9, I10"`) while the pipeline emits an
ARRAY. If the two sides are normalised differently — even trivially differently — matching fails
silently and every metric downstream is wrong in the pessimistic direction.

The specific trap: `UPPER(TRIM(gt_codes))` trims *the ends of the whole string*, not each element. Split
`"E11.9, I10"` on `,` afterwards and the second element is `" I10"` with a leading space. Set
intersection is exact, so **every code after the first silently fails to match** and recall looks
roughly halved on multi-code patients.

Normalise per element, on both sides, using the same expression:

```sql
CREATE OR REPLACE VIEW EVAL_NORMALIZED AS
WITH gt AS (
    SELECT
        patient_id,
        case_role,
        expected_hcc,
        expected_classification,
        -- Split FIRST, then normalise each element. Never trim the whole string.
        ARRAY_AGG(DISTINCT UPPER(TRIM(f.value::STRING))) AS gt_codes
    FROM <answer_key>,
         LATERAL FLATTEN(input => SPLIT(expected_icd10, ',')) f
    WHERE TRIM(f.value::STRING) <> ''
    GROUP BY 1, 2, 3, 4
),
pred AS (
    SELECT
        patient_id,
        hcc_code,
        classification,
        judge_score,
        confidence_band,
        run_id,
        -- Same expression, same order of operations.
        ARRAY_AGG(DISTINCT UPPER(TRIM(f.value::STRING))) AS pred_codes
    FROM (
        SELECT patient_id, hcc_code, classification, judge_score, confidence_band, run_id,
               ARRAY_APPEND(COALESCE(additional_icd10_codes, ARRAY_CONSTRUCT()), icd10_code) AS all_codes
        FROM ICD10_SUSPECTS
        WHERE run_id = :run_id
    ),
    LATERAL FLATTEN(input => all_codes) f
    WHERE TRIM(f.value::STRING) <> ''
    GROUP BY 1, 2, 3, 4, 5, 6
)
-- FULL OUTER, not LEFT. See below -- this is the correctness-critical part.
SELECT
    COALESCE(gt.patient_id, pred.patient_id) AS patient_id,
    gt.case_role,
    gt.expected_hcc,
    gt.expected_classification,
    pred.hcc_code,
    pred.classification,
    pred.judge_score,
    pred.confidence_band,
    COALESCE(gt.gt_codes,   ARRAY_CONSTRUCT()) AS gt_codes,
    COALESCE(pred.pred_codes, ARRAY_CONSTRUCT()) AS pred_codes
FROM gt
FULL OUTER JOIN pred
  ON  pred.patient_id = gt.patient_id
  AND pred.hcc_code   = gt.expected_hcc;
```

Verify the normalisation before trusting any metric:

```sql
-- Round-trip check. Both sides must agree on a delimited-string ground truth.
SELECT patient_id, gt_codes, pred_codes,
       ARRAY_INTERSECTION(gt_codes, pred_codes) AS matched
FROM EVAL_NORMALIZED
WHERE ARRAY_SIZE(gt_codes) > 1
LIMIT 10;
-- A multi-code row matching only its FIRST code is the whitespace bug above,
-- not a model failure. Check here before changing a prompt.
```

## Join from ground truth, or total failure is invisible

Build evaluation **from ground truth outward**. If the harness builds from emitted suspects and
`LEFT JOIN`s ground truth, then a patient the pipeline returned nothing for — or whose response failed
to parse — is absent from evaluation entirely and contributes **zero false negatives**. Complete
extraction failure then reports as perfect recall on the rows that survived.

This compounds with any upstream `WHERE ... IS NOT NULL` filter, which removes exactly the failures the
harness most needs to count.

The `FULL OUTER JOIN` above is what fixes it: unmatched ground-truth rows are false negatives, unmatched
predictions are false positives, and neither can disappear.

## Hierarchical matching — three outcomes, not two

ICD-10 is hierarchical, so exact string comparison scores `E11.9` against `E11.65` as a full miss
**plus** a full false positive. Clinically that is a specificity difference, and operationally it is a
coder-rework signal rather than a wrong answer. Reporting it as both a miss and a false positive
double-penalises the pipeline and hides the real failure mode.

Score three distinct outcomes and report all three:

```sql
-- Category arrays are computed in their own CTEs. Do NOT try to do this with a
-- windowed ARRAY_AGG over two LATERAL FLATTENs in one SELECT: the two flattens
-- cross-join, the window then aggregates over the product, and the counts come
-- out inflated without erroring.
CREATE OR REPLACE VIEW EVAL_CODE_MATCHES AS
WITH gt_cat AS (
    SELECT n.patient_id, n.expected_hcc,
           ARRAY_UNION_AGG(ARRAY_CONSTRUCT(SPLIT_PART(g.value::STRING, '.', 1))) AS gt_cats
    FROM EVAL_NORMALIZED n, LATERAL FLATTEN(input => n.gt_codes) g
    GROUP BY 1, 2
),
pred_cat AS (
    SELECT n.patient_id, n.expected_hcc,
           ARRAY_UNION_AGG(ARRAY_CONSTRUCT(SPLIT_PART(p.value::STRING, '.', 1))) AS pred_cats
    FROM EVAL_NORMALIZED n, LATERAL FLATTEN(input => n.pred_codes) p
    GROUP BY 1, 2
)
SELECT
    n.patient_id, n.case_role, n.expected_hcc, n.expected_classification,
    n.classification, n.judge_score, n.confidence_band,
    n.gt_codes, n.pred_codes,
    -- 1. Exact match: right code, right specificity. A coder accepts this.
    ARRAY_INTERSECTION(n.gt_codes, n.pred_codes) AS exact_matches,
    -- 2. Category match: right condition family, wrong specificity. Rework,
    --    not a miss. Compared on the part before the decimal.
    ARRAY_INTERSECTION(COALESCE(gt_cat.gt_cats,     ARRAY_CONSTRUCT()),
                       COALESCE(pred_cat.pred_cats, ARRAY_CONSTRUCT())) AS category_matches,
    ARRAY_SIZE(n.gt_codes)   AS gt_count,
    ARRAY_SIZE(n.pred_codes) AS pred_count
FROM EVAL_NORMALIZED n
-- EQUAL_NULL, not =. The FULL OUTER JOIN upstream leaves expected_hcc NULL on
-- false-positive rows, and a plain equality join drops exactly those rows --
-- silently restoring the false-positive blindness the outer join just fixed.
LEFT JOIN gt_cat   ON gt_cat.patient_id   = n.patient_id
                  AND EQUAL_NULL(gt_cat.expected_hcc, n.expected_hcc)
LEFT JOIN pred_cat ON pred_cat.patient_id = n.patient_id
                  AND EQUAL_NULL(pred_cat.expected_hcc, n.expected_hcc);
```

```sql
-- The three outcomes, per patient-condition. This is the table to show.
SELECT
    patient_id,
    expected_hcc,
    ARRAY_SIZE(exact_matches)                                     AS exact,
    ARRAY_SIZE(category_matches) - ARRAY_SIZE(exact_matches)      AS category_only,
    gt_count - ARRAY_SIZE(category_matches)                       AS missed_entirely,
    pred_count - ARRAY_SIZE(category_matches)                     AS spurious
FROM EVAL_CODE_MATCHES
ORDER BY missed_entirely DESC, spurious DESC;
```

A `category_only` row is the most actionable output this harness produces: the pipeline found the right
condition and got the specificity wrong, which is almost always a knowledge-store coverage gap for that
condition rather than a prompt problem. Fix it in Phase 3.

## Micro and macro averages — report both, always

They answer different questions and they diverge exactly when it matters:

- **Micro** pools every code across every patient into one confusion matrix. A handful of patients
  carrying many codes dominate it. This is "how many of all the codes did we get right".
- **Macro** computes per-patient P/R/F1 and then averages the patients. Every patient counts equally.
  This is "how well does this work for a typical patient".

A pipeline that is excellent on complex multi-code charts and poor on simple ones shows strong micro and
weak macro. Reporting only micro hides that, and the simple charts are the majority of a real panel.

```sql
-- Per-patient-condition P/R/F1. Counts EXACT matches as true positives, and
-- treats a category-only match as a false positive AND a false negative --
-- deliberately strict, because a coder must rework it. Report the
-- category_only count alongside so the strictness is visible, not hidden.
CREATE OR REPLACE VIEW EVAL_METRICS_PER_PATIENT AS
SELECT
    patient_id,
    expected_hcc,
    case_role,
    ARRAY_SIZE(exact_matches)                       AS tp,
    pred_count - ARRAY_SIZE(exact_matches)          AS fp,
    gt_count   - ARRAY_SIZE(exact_matches)          AS fn,
    DIV0(ARRAY_SIZE(exact_matches), pred_count)     AS precision_p,
    DIV0(ARRAY_SIZE(exact_matches), gt_count)       AS recall_p,
    DIV0(2 * ARRAY_SIZE(exact_matches), pred_count + gt_count) AS f1_p
FROM EVAL_CODE_MATCHES;
```

```sql
-- Micro (pooled) and macro (per-patient then averaged), side by side, plus the
-- spread. STDDEV and MIN/MAX are what tell you whether a headline average is
-- describing consistent behaviour or averaging over a bimodal result.
WITH micro AS (
    SELECT SUM(tp) AS tp, SUM(fp) AS fp, SUM(fn) AS fn
    FROM EVAL_METRICS_PER_PATIENT
)
SELECT
    'micro' AS averaging,
    ROUND(DIV0(tp, tp + fp), 3)         AS precision_score,
    ROUND(DIV0(tp, tp + fn), 3)         AS recall_score,
    ROUND(DIV0(2 * tp, 2 * tp + fp + fn), 3) AS f1,
    NULL AS f1_stddev, NULL AS f1_min, NULL AS f1_max
FROM micro
UNION ALL
SELECT
    'macro',
    ROUND(AVG(precision_p), 3),
    ROUND(AVG(recall_p), 3),
    ROUND(AVG(f1_p), 3),
    ROUND(STDDEV(f1_p), 3),
    ROUND(MIN(f1_p), 3),
    ROUND(MAX(f1_p), 3)
FROM EVAL_METRICS_PER_PATIENT;
```

A macro F1 with a stddev approaching its mean is not a pipeline with that F1 — it is a pipeline that
works on some charts and not others. Say that instead of quoting the mean.

## Comparing experiments

The whole point of stamping `experiment_id` on every row is this query. It only works if the suspecting
and evaluation layers are **incremental** rather than tables — a table materialization drops and
recreates, so only one experiment exists at rest and this returns a single row while appearing to work.

```sql
-- The experiment columns are carried THROUGH from EVAL_NORMALIZED, not joined
-- back from ICD10_SUSPECTS. Re-joining on patient_id fans out across every
-- experiment and every condition for that patient, and inflates every count
-- without erroring -- a comparison table that looks right and is not.
CREATE OR REPLACE VIEW EVAL_EXPERIMENT_SUMMARY AS
SELECT
    experiment_id, experiment_name, prompt_version, prompt_hash,
    COUNT(DISTINCT run_id)                                      AS runs,
    COUNT(*)                                                    AS scored_rows,
    ROUND(DIV0(SUM(tp), SUM(tp) + SUM(fp)), 3)                  AS micro_precision,
    ROUND(DIV0(SUM(tp), SUM(tp) + SUM(fn)), 3)                  AS micro_recall,
    ROUND(DIV0(2 * SUM(tp), 2 * SUM(tp) + SUM(fp) + SUM(fn)), 3) AS micro_f1,
    ROUND(AVG(f1_p), 3)                                         AS macro_f1,
    ROUND(STDDEV(f1_p), 3)                                      AS macro_f1_stddev
FROM EVAL_METRICS_PER_PATIENT
GROUP BY 1, 2, 3, 4
ORDER BY micro_f1 DESC;
```

For this to work, `run_id`, `experiment_id`, `experiment_name`, `prompt_version` and `prompt_hash` must
be selected into `EVAL_NORMALIZED` from the prediction side and carried down through
`EVAL_CODE_MATCHES` and `EVAL_METRICS_PER_PATIENT`. Take them from the prediction side rather than
ground truth — a ground-truth-only row is a false negative and has no experiment of its own, so
`COALESCE` it to the run being evaluated.

Two cautions when presenting a comparison. On a labeled set of roughly eleven patients, a difference of
a few points is noise — do not report a winner without saying what one miss is worth. And if
`prompt_hash` differs while `prompt_version` does not, the prompt changed without being versioned;
trust the hash.

## Recall and precision at two levels of strictness

Measuring HCC match alone overstates accuracy. A pipeline that returns the right condition with the
wrong code specificity will be rejected by a coder — that is a miss in practice, and it must be counted
as one.

```sql
CREATE OR REPLACE VIEW EVAL_MATCHES AS
SELECT
    ak.patient_id,
    ak.case_role,
    ak.expected_hcc,
    ak.expected_icd10,
    ak.expected_classification,
    s.hcc_code        AS got_hcc,
    s.icd10_code      AS got_icd10,
    s.classification  AS got_classification,
    s.coder_confidence,
    s.judge_score,
    s.confidence_band,
    -- Level 1: did we find the right condition?
    (s.hcc_code IS NOT NULL)                          AS hcc_matched,
    -- Level 2: did we also get the code specificity right? This is the number
    -- that predicts whether a coder accepts it.
    -- MUST check additional_icd10_codes too. The coder legitimately reports one
    -- primary code plus separately reportable manifestations, and the expected
    -- code is frequently the secondary one -- scoring on the primary alone
    -- understates specificity accuracy.
    (s.icd10_code = ak.expected_icd10
     OR ARRAY_CONTAINS(ak.expected_icd10::VARIANT, s.additional_icd10_codes))
                                                      AS icd10_matched,
    -- Level 3: did we get the assertion strength right? Calling an EVAL a
    -- SUSPECT is a false positive in practice, even with the right condition.
    (s.classification = ak.expected_classification)   AS classification_matched
FROM <answer_key> ak
LEFT JOIN ICD10_SUSPECTS s
       ON s.patient_id = ak.patient_id
      AND s.hcc_code   = ak.expected_hcc
      AND s.run_id     = :run_id;
```

```sql
-- Condition-level recall and assertion strength, over every case that should
-- produce some output.
SELECT
    COUNT(*)                                              AS labeled_positives,
    COUNT_IF(hcc_matched)                                 AS found_condition,
    COUNT_IF(classification_matched)                      AS right_assertion_strength,
    ROUND(100.0 * COUNT_IF(hcc_matched) / NULLIF(COUNT(*), 0), 1) AS recall_hcc_pct
FROM EVAL_MATCHES
WHERE case_role IN ('PLANTED', 'BORDERLINE');
```

```sql
-- Specificity recall, scored ONLY where a code is actually expected to be
-- asserted. Including EVAL cases in this denominator is wrong: an EVAL means
-- the evidence does not support asserting a diagnosis, so there is no correct
-- code to find, and counting it as a specificity miss understates accuracy.
SELECT
    COUNT(*)                                                AS codeable_cases,
    COUNT_IF(icd10_matched)                                 AS found_with_right_code,
    ROUND(100.0 * COUNT_IF(icd10_matched) / NULLIF(COUNT(*), 0), 1) AS recall_icd10_pct
FROM EVAL_MATCHES
WHERE expected_classification = 'SUSPECT'
  AND expected_icd10 IS NOT NULL;
```

Report **both** recall figures, and state the denominators. A gap between condition-level and
specificity-level recall is not necessarily a model failure — it is usually a knowledge-store finding,
and the fix is in Phase 3 rather than the prompt.

```sql
-- Precision. Every suspect the pipeline emitted, judged against ground truth.
WITH emitted AS (
    SELECT s.patient_id, s.hcc_code, s.icd10_code, s.additional_icd10_codes,
           s.classification, s.confidence_band,
           ak.case_role, ak.expected_hcc, ak.expected_icd10, ak.expected_classification
    FROM ICD10_SUSPECTS s
    LEFT JOIN <answer_key> ak
           ON ak.patient_id = s.patient_id AND ak.expected_hcc = s.hcc_code
    WHERE s.run_id = :run_id
)
SELECT
    COUNT(*)                                                   AS suspects_emitted,
    COUNT_IF(expected_hcc IS NOT NULL)                         AS true_positives_hcc,
    COUNT_IF(icd10_code = expected_icd10
             OR ARRAY_CONTAINS(expected_icd10::VARIANT, additional_icd10_codes))
                                                               AS true_positives_icd10,
    COUNT_IF(expected_hcc IS NULL)                             AS false_positives,
    ROUND(100.0 * COUNT_IF(expected_hcc IS NOT NULL) / NULLIF(COUNT(*), 0), 1)
                                                               AS precision_hcc_pct,
    ROUND(100.0 * COUNT_IF(icd10_code = expected_icd10
                           OR ARRAY_CONTAINS(expected_icd10::VARIANT, additional_icd10_codes))
          / NULLIF(COUNT(*), 0), 1)                            AS precision_icd10_pct
FROM emitted;
```

## Over-calling, on the cases designed to catch it

Distractor cases have findings that superficially suggest a condition and a documented alternative
explanation. A pipeline that flags them is over-calling, and this is where reviewer trust is lost.

```sql
SELECT
    ak.patient_id,
    ak.case_role,
    ak.evidence_summary,
    s.hcc_code      AS wrongly_flagged_hcc,
    s.icd10_code,
    s.classification,
    s.coder_confidence,
    s.judge_score
FROM <answer_key> ak
LEFT JOIN ICD10_SUSPECTS s
       ON s.patient_id = ak.patient_id AND s.run_id = :run_id
WHERE ak.case_role = 'DISTRACTOR'
ORDER BY ak.patient_id;
```

Every distractor should show `NULL` on the right. Anything flagged means the reject criteria in the
knowledge store are not doing their job, or the compression step dropped the documented exclusion
before the coder ever saw it. Check which before changing anything: a coder prompt cannot reject an
exclusion it was never shown.

```sql
-- Borderline cases must land as EVAL, not SUSPECT. Collapsing the two
-- manufactures false positives out of genuine uncertainty.
SELECT ak.patient_id, ak.expected_classification, s.classification AS got, s.judge_score
FROM <answer_key> ak
LEFT JOIN ICD10_SUSPECTS s
       ON s.patient_id = ak.patient_id AND s.hcc_code = ak.expected_hcc AND s.run_id = :run_id
WHERE ak.case_role = 'BORDERLINE';
```

```sql
-- Suppression control: a condition already coded must NOT be re-surfaced.
SELECT ak.patient_id, ak.expected_hcc, s.suspect_id IS NOT NULL AS wrongly_resurfaced
FROM <answer_key> ak
LEFT JOIN ICD10_SUSPECTS s
       ON s.patient_id = ak.patient_id AND s.hcc_code = ak.expected_hcc AND s.run_id = :run_id
WHERE ak.case_role = 'SUPPRESSED';
-- wrongly_resurfaced must be FALSE. TRUE means the claims join is broken, and
-- a share of the output is restatement rather than gap.
```

## Silent loss — the numbers nothing else surfaces

These do not appear in recall or precision, because a lost finding looks exactly like an absent one.

```sql
-- 1. Parse failures and refusals. Any non-zero value here is lost recall that
--    recall itself cannot see.
SELECT issue, detail
FROM PIPELINE_QUALITY_LOG
WHERE run_id = :run_id AND stage = 'suspecting';
```

```sql
-- 2. Fan-out completeness. Every candidate must have produced a response.
SELECT
    (SELECT COUNT(*) FROM SUSPECT_CANDIDATES)                          AS candidates,
    (SELECT COUNT(*) FROM SUSPECT_RAW)                                 AS responses,
    (SELECT COUNT(*) FROM SUSPECT_RAW
      WHERE response:structured_output IS NULL)                        AS null_responses;
-- candidates must equal responses. null_responses must be zero.
```

```sql
-- 3. Documents that entered the pipeline and vanished before extraction.
SELECT r.assigned_tier, COUNT(*) AS lost_after_routing
FROM ROUTING_DECISIONS r
LEFT JOIN (SELECT DISTINCT document_id FROM EXTRACTED_DOCUMENTS) e USING (document_id)
WHERE r.assigned_tier <> 'T4' AND e.document_id IS NULL
GROUP BY 1;
```

```sql
-- 4. Patients with documents who produced no summary, and so could produce
--    no suspects for reasons unrelated to their charts.
SELECT COUNT(*) AS patients_lost_at_compression
FROM (SELECT DISTINCT patient_id FROM EXTRACTED_DOCUMENTS) e
LEFT JOIN PATIENT_SUMMARY ps USING (patient_id)
WHERE ps.patient_id IS NULL;
```

```sql
-- 5. Fabricated citations rejected at the provenance gate.
SELECT COUNT(*) AS rejected_for_bad_provenance
FROM PIPELINE_QUALITY_LOG
WHERE run_id = :run_id AND issue IN ('FABRICATED_CITATION', 'NO_EVIDENCE');
```

Report all five even when zero. "We checked and it was zero" is a materially different statement from
not having checked, and only one of them supports an accuracy claim.

## Cost, measured — in tokens

```sql
-- Per-stage token usage recorded by the pipeline itself.
SELECT 'compression' AS stage,
       COUNT(*)                            AS calls,
       SUM(compress_prompt_tokens)         AS prompt_tokens,
       SUM(compress_completion_tokens)     AS completion_tokens,
       SUM(compress_total_tokens)          AS total_tokens
FROM PATIENT_SUMMARY WHERE strategy = 'SINGLE_PASS'
UNION ALL
SELECT 'coder', COUNT(*), NULL, NULL, SUM(coder_tokens) FROM ICD10_SUSPECTS WHERE run_id = :run_id
UNION ALL
SELECT 'judge', COUNT(*), NULL, NULL, SUM(judge_tokens) FROM ICD10_SUSPECTS WHERE run_id = :run_id;
```

```sql
-- Billed totals, which are the system of record. Reconcile against the above.
-- Set the run's tag first: ALTER SESSION SET QUERY_TAG = 'icd10:<run_id>';
-- Rows are hourly windows per query, so collapse METRICS to one token count per row
-- before summing, or credits double-count.
WITH per_row AS (
    SELECT u.query_id, u.start_time, u.function_name, u.model_name,
           ANY_VALUE(u.credits) AS credits,
           SUM(IFF(m.value:key:unit::STRING = 'tokens', m.value:value::NUMBER, 0)) AS tokens
    FROM snowflake.account_usage.cortex_ai_functions_usage_history u,
         LATERAL FLATTEN(input => u.metrics, outer => TRUE) m
    WHERE u.query_tag = :run_query_tag
    GROUP BY 1, 2, 3, 4
)
SELECT function_name, model_name, SUM(tokens) AS tokens, SUM(credits) AS credits
FROM per_row GROUP BY 1, 2 ORDER BY credits DESC;
```

Reporting rules, and they are not negotiable:

- **Report tokens and credits. Never convert to dollars**, even if asked directly. Do not look up
  pricing.
- Expect billed input tokens on the coder and judge stages to **exceed** any `AI_COUNT_TOKENS`
  estimate. Structured output on Claude models generates extra request content that is billed but not
  counted by the estimator. This is verified behaviour, not a discrepancy to investigate.
- `account_usage` views have latency. If the numbers look low immediately after a run, that is the
  view catching up, not a cost saving.

## What the cost levers actually saved on this corpus

The two levers were promised in Phase 2 and Phase 4. Here they are measured rather than asserted.

```sql
-- Lever 1: routing. How many documents avoided the expensive path?
SELECT assigned_tier,
       COUNT(*) AS docs,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_corpus,
       COUNT_IF(exited_before_ocr) AS avoided_ocr_entirely
FROM ROUTING_DECISIONS
GROUP BY 1 ORDER BY 1;
```

```sql
-- Lever 2: compression. Positive means a saving; NEGATIVE means compression
-- made the input bigger, which happens on short charts.
SELECT strategy,
       COUNT(*) AS patients,
       ROUND(AVG(raw_tokens), 0)                 AS avg_raw,
       ROUND(AVG(compress_completion_tokens), 0) AS avg_compressed,
       ROUND(100.0 * (1 - AVG(compress_completion_tokens)
                          / NULLIF(AVG(raw_tokens), 0)), 1) AS pct_reduction
FROM PATIENT_SUMMARY GROUP BY 1;
```

Be honest about what these show on **this** corpus:

- If the skip tier is small, routing saved little here. Say so.
- If `pct_reduction` is negative or most charts are `PASSTHROUGH`, compression is not a saving on this
  corpus and the compression floor should be raised. Report that rather than quoting a saving figure
  from elsewhere.
- Never present a savings percentage sourced from another engagement as if it were this account's
  number.

## Threshold tuning

Bands are configuration, not model behaviour, and they are the cheapest lever available.

```sql
-- Precision by judge score. Find where accuracy falls off, then set the band.
SELECT s.judge_score,
       COUNT(*) AS suspects,
       COUNT_IF(ak.expected_hcc IS NOT NULL)   AS true_positives,
       ROUND(100.0 * COUNT_IF(ak.expected_hcc IS NOT NULL) / NULLIF(COUNT(*), 0), 1)
                                               AS precision_pct
FROM ICD10_SUSPECTS s
LEFT JOIN <answer_key> ak
       ON ak.patient_id = s.patient_id AND ak.expected_hcc = s.hcc_code
WHERE s.run_id = :run_id
GROUP BY 1 ORDER BY 1 DESC;
```

```sql
-- The tradeoff, made explicit. Raising the threshold buys precision and costs
-- recall; the right point is a business decision about reviewer capacity, not
-- a technical one. Present the curve and let the user choose.
WITH thresholds AS (SELECT VALUE::INT AS t FROM TABLE(FLATTEN(input => [4,5,6,7,8,9])))
SELECT th.t AS min_judge_score,
       COUNT_IF(s.judge_score >= th.t)                                    AS suspects_surfaced,
       COUNT_IF(s.judge_score >= th.t AND ak.expected_hcc IS NOT NULL)    AS true_positives,
       ROUND(100.0 * COUNT_IF(s.judge_score >= th.t AND ak.expected_hcc IS NOT NULL)
             / NULLIF(COUNT_IF(s.judge_score >= th.t), 0), 1)             AS precision_pct
FROM thresholds th
CROSS JOIN ICD10_SUSPECTS s
LEFT JOIN <answer_key> ak
       ON ak.patient_id = s.patient_id AND ak.expected_hcc = s.hcc_code
WHERE s.run_id = :run_id
GROUP BY th.t ORDER BY th.t;
```

Write the chosen values back to `thresholds` in `icd10-project.yml`.

Also check whether the judge is discriminating at all:

```sql
SELECT ROUND(AVG(judge_score), 2)    AS avg_score,
       ROUND(STDDEV(judge_score), 2) AS score_spread,
       COUNT(DISTINCT judge_score)   AS distinct_scores
FROM ICD10_SUSPECTS WHERE run_id = :run_id;
```

A narrow spread means the judge is scoring everything the same, so banding is meaningless and the
rubric needs work. That is a genuine prompt problem, unlike most apparent ones.

## Per-condition breakdown

Aggregate figures hide the condition that is not working.

```sql
SELECT ak.expected_hcc,
       COUNT(*)                                 AS labeled_cases,
       COUNT_IF(em.hcc_matched)                 AS found,
       COUNT_IF(em.icd10_matched)               AS found_right_code,
       ROUND(AVG(em.judge_score), 1)            AS avg_judge_score
FROM EVAL_MATCHES em
JOIN <answer_key> ak USING (patient_id)
WHERE ak.case_role IN ('PLANTED','BORDERLINE')
GROUP BY 1 ORDER BY found ASC;
```

A condition with zero found is usually a configuration problem rather than a model problem, and the
order to check is: is it in the target list, does it have knowledge-store coverage, did suppression
remove it, did its candidates survive the joins. Check in that order before touching a prompt.

## What to present at the gate

A short written summary, in this order:

1. **Micro and macro** precision, recall and F1, with the macro stddev and min/max. Never one without
   the other.
2. **The three code-match outcomes**: exact, category-only (right condition, wrong specificity), missed
   entirely — plus spurious codes.
3. **Recall** at HCC and ICD-10-specificity level, with the gap between them explained.
4. **Precision** at both levels.
5. **Over-calling**: distractors flagged, borderline cases misclassified as asserted, suppression
   control result.
6. **Silent loss**: all five checks, with zeros stated explicitly.
7. **Cost**: tokens and credits per stage, plus what routing and compression measurably saved on this
   corpus — including if the answer is "not much".
8. **Threshold recommendation**, with the precision-recall curve behind it.
9. **Per-condition table**, worst first.
10. **Experiment comparison**, if more than one experiment exists.

Then set `phases.eval: done`.

## When the judge disagrees with the answer key, check the answer key

A specific and valuable behaviour: if the judge scores a suspect low while the answer key says it is
correct, **read the judge's notes before assuming the pipeline is wrong.** Hand-authored ground truth
contains coding errors, and the judge is reasoning against retrieved guidance rather than against your
assumptions.

This is not hypothetical. On the reference sandbox the judge scored a COPD suspect 4 out of 10 and
recommended REVISE, noting that `J44.1` denotes COPD *with acute exacerbation* and requires a current
exacerbation at the encounter, whereas the chart documented only a history of two prednisone courses in
the prior year. The judge was right: the correct code was `J44.9`.

Note carefully which way this cut. The coder had assigned `J44.1` and the answer key *also* said
`J44.1` — the key contained the same error, so it was **masking** the coder's mistake and scoring it as
a hit. Correcting the key made measured specificity recall **worse**, not better. That is the normal
direction: a key written by the same reasoning that wrote the prompts tends to agree with the pipeline's
errors. Expect corrections to lower the numbers, and be suspicious of a key that never disagrees.

The judge is not infallible either. In the same run it scored a wrong-laterality code 10 out of 10 and
APPROVE — `I70.212` (left leg) where bilateral ABI findings supported `I70.213` (bilateral). So the
judge caught one specificity error and missed another. Use it as a filter, not as ground truth, and do
not let a high judge score substitute for measuring against a reviewed key.

So when a labeled case scores low:

1. Read `judge_notes` in full.
2. Check the coding guidance the coder actually received for that condition.
3. Decide whether the key or the pipeline is wrong, and record the decision.

Never silently adjust the pipeline to agree with an unexamined key. And treat this as an argument for
clinician review of the answer key before publishing accuracy figures from it.

## Interpreting the numbers honestly

- **On the synthetic sandbox, expect high recall.** The planted cases are constructed to be findable.
  Sandbox recall demonstrates the pipeline is wired correctly; it does **not** predict performance on
  real charts, which are messier, contradictory, and full of findings recorded once in a fax. Say this
  explicitly rather than letting a strong sandbox number be read as a production forecast.
- **Precision on the sandbox is more transferable than recall**, because the distractor cases model the
  failure modes that actually occur.
- **A small labeled set gives wide confidence intervals.** With around eleven labeled patients, one
  miss moves recall by roughly nine points. Report counts alongside percentages so the sample size is
  visible, and resist reading movement between runs as improvement.
- **On real data with no answer key, recall is unmeasurable.** Precision can be estimated from coder
  accept and reject decisions once review exists, but the pipeline's misses stay invisible. State this
  rather than presenting precision alone as accuracy.
- **Treat any published accuracy figure for this use case — including one from another engagement — as
  unverified until you know how it was measured.** The two most common measurement bugs, asymmetric
  normalisation and a `LEFT JOIN` from predictions, both bias the number and pull in opposite
  directions. A figure produced with either is not comparable to one produced here. Do not quote
  someone else's precision or recall into a customer conversation without checking the join direction
  and the normalisation.

## Rerunning after a change

Change one thing at a time and keep the run history. Attribution is impossible otherwise, and a
combined change that improves one metric while degrading another is common:

```sql
SELECT run_id, experiment_id, experiment_name, prompt_version, prompt_hash,
       MIN(generated_at) AS run_at, COUNT(*) AS suspects,
       ROUND(AVG(judge_score), 2) AS avg_judge_score
FROM ICD10_SUSPECTS GROUP BY 1,2,3,4,5 ORDER BY run_at DESC;
```

Never tune against the answer key until the numbers look good — that is fitting to eleven patients, and
it will not survive contact with a real corpus. Use the sandbox to verify correctness and catch
regressions, not to optimise.
