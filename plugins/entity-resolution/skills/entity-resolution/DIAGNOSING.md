# Diagnosing an entity resolution pipeline that is not producing what you expect

Work the symptom that matches. Most reported failures trace back to blocking, placeholders, chaining,
or silent model failures — and all of them look like a plausible golden table.

On the sandbox, start every investigation with the stage-loss table from `evaluate-match-accuracy`
section 2a. It says which phase lost the pairs, which is usually not the phase that is blamed.

---

## 1. Obvious duplicates were missed

**Find the stage that lost them.** On real data, take two records the user says are duplicates and
trace them:

```sql
-- Substitute the two record_uids.
WITH p AS (SELECT LEAST(:a, :b) AS ua, GREATEST(:a, :b) AS ub)
SELECT
    (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('rule', block_rule, 'key', block_key))
       FROM ER_BLOCK_KEYS WHERE record_uid = p.ua)                         AS keys_a,
    (SELECT ARRAY_AGG(OBJECT_CONSTRUCT('rule', block_rule, 'key', block_key))
       FROM ER_BLOCK_KEYS WHERE record_uid = p.ub)                         AS keys_b,
    (SELECT block_rules FROM ER_CANDIDATE_PAIRS
      WHERE record_uid_a = p.ua AND record_uid_b = p.ub)                   AS candidate_rules,
    (SELECT OBJECT_CONSTRUCT(*) FROM ER_SCORED_PAIRS
      WHERE record_uid_a = p.ua AND record_uid_b = p.ub
      QUALIFY ROW_NUMBER() OVER (ORDER BY scored_at DESC) = 1)             AS latest_score,
    (SELECT golden_id FROM ER_CROSSWALK_CURRENT WHERE record_uid = p.ua)   AS golden_a,
    (SELECT golden_id FROM ER_CROSSWALK_CURRENT WHERE record_uid = p.ub)   AS golden_b
FROM p;
```

Then by stage:

- **No shared block key.** Compare `keys_a` and `keys_b`. Usual causes: a normalization difference
  (one name still carries a suffix or punctuation the token map does not cover), a typo in the first
  four characters, a missing postal code, or a rebrand where no name key can match. Fixes: extend the
  token map; confirm the semantic KNN pass ran; confirm tax id and phone fill rates (rebrands and
  relocations are only catchable through identifiers).
- **Shared key, but no candidate pair.** The block was capped. Check `ER_BLOCK_STATS` for that key. A
  capped block is almost always a placeholder or a too-common token — exclude it and regenerate rather
  than raising the cap.
- **Candidate, auto-rejected.** Read the features. A cannot-link reason on a true duplicate means the
  identifier itself is wrong in one source (a typo in a tax id) or a placeholder slipped through. A low
  composite with no cannot-link means a feature is misbehaving — often an address present on one side in
  a different format, or `cos_sim` computed from stale vectors (run the parity check).
- **Review band, not merged.** Read the model's decision and reasons. `MODEL_FAILED` is a failure, not a
  judgment (section 4). A `NO_MATCH` with reasons that misread the evidence points at the prompt rules.
  `STEWARD_REVIEW` is waiting for a person.
- **Matched, but different golden ids.** The edge exists but was excluded — a swapped-order probe
  disagreed — or the cluster was rebuilt from a different run than the one being viewed. Check which run
  `ER_CROSSWALK_CURRENT` points at.

## 2. Two different companies (or products) were merged

**Read the edge that joined them.** In a multi-record cluster the bad link is usually one edge, often the
weakest:

```sql
SELECT e.decision_source, e.edge_confidence, e.composite_score, e.detail,
       ra.name_raw AS name_a, ra.city_norm AS city_a, rb.name_raw AS name_b, rb.city_norm AS city_b
FROM ER_ACCEPTED_EDGES e
JOIN ER_RECORDS ra ON ra.record_uid = e.record_uid_a
JOIN ER_RECORDS rb ON rb.record_uid = e.record_uid_b
JOIN ER_CROSSWALK x ON x.record_uid = e.record_uid_a AND x.run_id = e.run_id
WHERE x.golden_id = :golden_id AND e.run_id = :run_id
ORDER BY e.edge_confidence;
```

By source:

- **`RULE`**: almost always the tax-id rule. Two separately managed vendors share a tax id (a parent's
  id entered on subsidiaries, or one legal entity with several vendor setups the business wants to keep
  apart). Demote the rule to a feature for this customer; see `score-candidate-pairs`.
- **`SCORE`**: `auto_match` too low, or a sibling pair slipped the substitution guard because the
  distinguishing token was normalized away. Check whether `HOLDINGS`, `GROUP` or a regional word was put
  in the stopword list — stopwords drop out of `name_core`, which the guard reads. Re-run the threshold
  sweep.
- **`MODEL`**: read the reasons. Merges of parents and subsidiaries mean the model is collapsing
  "related" into "same"; confirm the prompt's identity rules are present (check the stored prompt for the
  pair, not the template) and that `relationship` is being required to be `SAME_ENTITY` for acceptance.
  Product variants merged means size was not shown or was not parsed (`size_oz` NULL on one side).

**Chaining.** If no single edge looks wrong, the records were joined through intermediaries. The
`LOW_COHESION` hold exists for exactly this; check the cluster's `min_pair_composite`. Lower
`max_cluster_size` or raise `min_cluster_cohesion` and recluster.

## 3. One giant cluster

Almost never a matching problem. In order:

1. **A placeholder acting as evidence**: a shared dummy tax id or switchboard phone produced `RULE`
   edges. Look at the most common tax id and phone in the cluster. Add it to the placeholder exclusions
   and rerun from Phase 2.
2. **A free-mail or parent domain** used as a blocking key and then as `domain_eq` evidence. Check
   `ER_FREE_EMAIL_DOMAINS`.
3. **Chaining** through near-duplicate names in one city (section 2).

The size-cap hold should have caught it before publish. If it did not, check that
`thresholds.max_cluster_size` was actually substituted into the template.

## 4. Model decisions are NULL, or everything is MODEL_FAILED

```sql
SELECT outcome, COUNT(*) AS n, ANY_VALUE(LEFT(error_message, 300)) AS sample_error
FROM ER_MATCH_DECISIONS WHERE run_id = :run_id GROUP BY 1;

SELECT COUNT(*) AS accessor_mismatch
FROM ER_MATCH_DECISIONS
WHERE run_id = :run_id AND error_message IS NULL AND decision IS NULL;
```

- **Errors present**: read them. Model not available in region (preflight: cross-region setting),
  schema validation failure (an unsupported keyword such as `minItems` or `minimum` crept into the
  schema), or a prompt too long for the model.
- **No errors, no decisions**: the accessor does not match this account's response shape. Look at one
  raw response (`SELECT response FROM ER_MATCH_DECISIONS_RAW WHERE run_id = :run_id LIMIT 1`) and adjust
  the `COALESCE` paths. This is an accessor bug, not a model problem — and until it is fixed every
  review-band pair counts as lost.
- **Decisions present but no reasons**: the model is returning an empty array. Add "Respond in JSON" if
  it was removed, and check the model choice; schema adherence on nested arrays varies by model.

Remember the documented behavior: a failed row returns NULL and does not stop the statement. A run that
"completed" can have adjudicated nothing.

## 5. The model says everything matches (or nothing does)

- Check the confidence calibration table (`evaluate-match-accuracy` 6a). If accuracy is flat across
  confidence buckets, the confidence is noise; raise `model_accept_confidence` only after confirming
  that higher buckets are actually more accurate.
- Check the position-bias flip rate. A high flip rate with mostly-MATCH decisions suggests the model is
  anchoring on the first record.
- Check what the band contains. If scoring sends near-certain duplicates to review, the model will say
  MATCH to most of them — correctly. Look at the score distribution of the review band before blaming
  the model.

## 6. Embedding similarity looks wrong

- Run the parity check in `score-candidate-pairs` section 4. A material difference between stored
  cosine and `AI_SIMILARITY` means vectors are stale or from another model or template.
- Check that both sides of every comparison filter on the same `embed_model` and
  `embed_template_version` (rule 12).
- Look at `embed_text` for the two records. A NULL-collapsed or label-only text (`name: ACME`) embeds
  poorly; a text dominated by address tokens makes every business on one street similar. Rebalance the
  template, bump `embed.template_version`, re-embed.
- Remember that very short names make cosine high for unrelated companies sharing words. That is what the
  deterministic features and the substitution guard are for; do not expect cosine alone to separate them.

## 7. Golden ids changed between runs on the same data

```sql
SELECT id_lineage, COUNT(DISTINCT golden_id) FROM ER_CROSSWALK WHERE run_id = :run_id GROUP BY 1;
```

Many `MINTED` ids on unchanged data means `PRIOR_RUN_ID` was not the published run (an experiment id was
passed, or the pointer was not set), or `record_uid` construction changed between runs (rule 4) so no
overlap was found. Confirm `ER_PUBLISHED_RUN` and compare a few `record_uid` values across runs.

## 8. Cost is higher than expected

```sql
SELECT entity_type, band, COUNT(*) FROM ER_SCORED_PAIRS WHERE run_id = :run_id GROUP BY 1, 2;

SELECT COUNT(*) AS records_reembedded
FROM ER_RECORD_EMBEDDINGS WHERE embedded_at >= :run_start;
```

- **Review band large**: thresholds uncalibrated, or a feature mostly NULL in this data so the
  composite clusters in the middle. Calibrate before accepting the bill.
- **Everything re-embedded**: the template or model changed (expected once), or `embed_text_hash` is
  unstable — for example, a timestamp or source-system label inside the template text changes every run.
- **Adjudication not reusing responses**: the prompt changes between runs for unchanged pairs. Anything
  run-specific in the prompt text (a date, a run id) defeats the prompt-hash reuse.
- **AI_SIMILARITY used over pairs** somewhere in a customized query instead of stored vectors (rule 11).
  Search the account's query history for it under the run's query tag.

## 9. Accuracy numbers look too good

On the sandbox, check for leakage before celebrating:

- Do any source ids, names, or prompt texts contain parts of true entity ids? (`02_verify_seed.sql`
  block 6.)
- Was the answer key schema readable from the pipeline, and did any query select from it?
- Are metrics computed only over found pairs (a `LEFT JOIN` from predictions instead of from truth)?
- Are thresholds reported on the same split they were calibrated on?

Then check the hard slices. A headline F1 dominated by exact duplicates says little; the SIBLING,
FRANCHISE, MOVED, ACRONYM and SIZE_VARIANT slices are the test.
