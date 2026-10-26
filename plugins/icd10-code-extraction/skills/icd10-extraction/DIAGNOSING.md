# Diagnosing a pipeline that is not producing what you expect

Work these in order. Most reported failures are one of the first three, and all three look identical
from the output table: an empty or thin result set.

## 1. Silent JSON failures — check this first

**Symptom:** far fewer suspects than expected, or a patient you know has evidence produces nothing.

This is the most common cause and the hardest to see, because a model response that fails to parse
becomes `NULL`, and a `NULL` is indistinguishable from "this patient has no findings". If the
pipeline was built without a `response_format` schema, assume this is happening until proven
otherwise.

```sql
-- Raw responses that produced no parseable suspect.
SELECT COUNT(*) AS total,
       COUNT_IF(suspect_payload IS NULL) AS unparseable,
       ROUND(100.0 * COUNT_IF(suspect_payload IS NULL) / NULLIF(COUNT(*), 0), 1) AS pct_lost
FROM <suspect_raw_table>;
```

Anything above zero is lost recall, not an absence of disease. Fixes, in order of preference:

1. Add a `response_format` JSON schema with `required` on every field the pipeline depends on.
   The model is then constrained token by token and cannot emit unparseable output.
2. Set `temperature` to `0`.
3. On a complex reasoning task, add "Respond in JSON" to the prompt text as well and use a
   stronger model — schema adherence degrades on weaker models as task complexity rises.
4. Use `TRY_COMPLETE` if a hard model error is aborting the whole statement.

## 2. Nothing was routed to an extraction tier

**Symptom:** extraction produces almost no rows.

```sql
SELECT assigned_tier, COUNT(*) AS docs
FROM <routing_decision_table>
GROUP BY 1 ORDER BY 2 DESC;
```

Look for:

- **Everything in the skip tier.** The boilerplate patterns are too aggressive, or they were
  inherited rather than tuned to this organization's own forms. A pattern matching a phrase that
  appears in a standard note header will skip the entire corpus.
- **Nothing in the skip tier.** Suspicious in the other direction — a real corpus contains consent
  forms and duplicates. Routing may be defaulting everything to the expensive tier, which is a cost
  problem rather than a recall problem.
- **Unassigned documents.** Should be zero. A `CASE` with no `ELSE` produces `NULL` tiers that then
  vanish from every downstream join.

## 3. Already-coded suppression is removing everything

**Symptom:** the pipeline runs cleanly but finds almost nothing on a population you expect gaps in.

The suppression join exists so output is *gaps* rather than a restatement of what is already coded.
If the claims history join is wrong — mismatched code format, `HCC85` versus `85`, or a join on
patient identifiers of different types — it can suppress every candidate.

```sql
-- How many candidates does suppression remove?
SELECT COUNT(*) AS suppressed
FROM <patient_condition_candidates> c
JOIN <claims_history> h
  ON h.patient_id = c.patient_id AND h.hcc_mapped = c.hcc_code;
```

Compare that against the unsuppressed candidate count. If suppression removes nearly everything,
inspect the actual values on both sides of the join before assuming the population has no gaps.

## 4. Codes are wrong or insufficiently specific

**Symptom:** suspects appear but a coder rejects them for specificity — unspecified codes where a
specific one is documented.

This is a grounding problem, not a model problem. Check that the coder prompt is actually receiving
coding guidance:

- In `cortex_search` mode, run the retrieval directly for the condition in question and confirm the
  returned chunks contain the specificity rules. Empty or irrelevant retrieval means the coder is
  guessing specificity from training data.
- In `guideline_tables` mode, confirm the condition has rows in **both** the clinical-criteria and
  coder-specificity tables. The fan-out inner-joins them, so a condition present in only one table
  silently disappears entirely — which shows up as missing conditions, not wrong ones.

```sql
-- Conditions configured as targets but missing from either guideline table.
SELECT t.hcc_code,
       cc.hcc_code IS NOT NULL AS has_clinical_criteria,
       cs.hcc_code IS NOT NULL AS has_coder_rules
FROM <target_conditions> t
LEFT JOIN <clinical_criteria_table> cc ON cc.hcc_code = t.hcc_code
LEFT JOIN <coder_rules_table>     cs ON cs.hcc_code = t.hcc_code
WHERE cc.hcc_code IS NULL OR cs.hcc_code IS NULL;
```

## 5. Too many false positives

**Symptom:** coders are dismissing a high share of suspects.

Do not reach for the prompt first. Check the confidence banding, because the fix is usually a
threshold rather than a rewrite:

```sql
SELECT confidence_score, COUNT(*) AS suspects
FROM <suspect_output_table>
GROUP BY 1 ORDER BY 1;
```

If dismissals concentrate below a score, raise `thresholds.high_confidence` in
`icd10-project.yml` and re-band. If dismissals are spread evenly across all scores, the scoring
step is not discriminating and the judge rubric needs attention — that is a genuine prompt problem.

Also confirm the pipeline is distinguishing a confident suspect from a candidate that merely
warrants evaluation. Collapsing those two into one output is a common source of apparent
false positives: findings that were correctly flagged as needing review get read as asserted
diagnoses.

## 6. Evidence does not trace back to a document

**Symptom:** a reviewer cannot tell where a finding came from.

```sql
-- Evidence items with no resolvable source document.
SELECT COUNT(*) AS untraceable
FROM <suspect_output_table> s,
     LATERAL FLATTEN(input => s.evidence) f
WHERE f.value:document_id IS NULL
   OR f.value:document_id::STRING NOT IN (SELECT document_id FROM <documents_table>);
```

Must be zero. A non-zero count means either the extraction step dropped provenance before the coder
saw it, or the coder is generating document references rather than carrying through the ones it was
given. Both are correctness bugs, not cosmetic ones — an untraceable suspect cannot survive audit.

## 7. Cost is higher than expected

Check the tier mix and the compression ratio, in that order:

```sql
-- Did the cheap exits actually fire?
SELECT assigned_tier,
       COUNT(*) AS docs,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
       COUNT_IF(exited_before_ocr) AS pre_ocr_exits
FROM <routing_decision_table>
GROUP BY 1;

-- Did compression actually reduce input to the expensive stage?
SELECT ROUND(AVG(raw_tokens), 0)        AS avg_raw,
       ROUND(AVG(compressed_tokens), 0) AS avg_compressed,
       ROUND(100.0 * (1 - AVG(compressed_tokens) / NULLIF(AVG(raw_tokens), 0)), 1) AS pct_reduction
FROM <compression_metrics_table>;
```

If pre-OCR exits are near zero, the metadata signals the routing depends on are not populated in
this corpus — check whether the document type and source system columns actually carry values
rather than being mostly `NULL`. That is a data problem to raise with the customer, not something to
work around by routing everything to the expensive tier.
