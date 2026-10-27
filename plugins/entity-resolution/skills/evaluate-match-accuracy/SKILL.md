---
name: evaluate-match-accuracy
description: "Phase 6 of the entity-resolution build. Measures whether the matching is actually right and what it cost, joining from ground truth outward so lost pairs are counted. Reports blocking pair completeness and reduction ratio, the stage at which each true pair was lost (blocking, scoring, adjudication, clustering), final pairwise precision/recall/F1 for all and publishable-only clusters, B-cubed cluster precision/recall/F1 including singletons, breakdowns by case role and difficulty, over-merging on hard negatives (siblings, franchises, size variants), decision-level precision by source, model confidence calibration, a threshold sweep on a calibration split with holdout reporting, parse-failure and lost-decision accounting, billed tokens per 1,000 records reconciled from account usage via query tags, share of pairs that reached the model, experiment comparison, and regression gates. Also covers building a steward-labeled sample on real data. Use for match accuracy, precision and recall, over-merging, threshold tuning, or cost per record questions."
parent_skill: entity-resolution
---

# Evaluate match accuracy and cost

An entity resolution pipeline nobody has measured merges records at an unknown false-merge rate. This
phase answers, with numbers from this data: how many duplicates were found, how many merges are wrong,
where the lost duplicates were lost, and what it cost per thousand records.

Do not skip it. If the user wants to stop before it, say plainly what they will not know — in
particular, that blocking recall is invisible without it.

`sql/01_evaluate.sql` is the harness. It writes only to `eval_schema`.

## The distinction that matters most

Per-pair confidence (a composite score, a model's self-reported confidence) is what the pipeline thinks
about one pair. Pipeline accuracy is how often it is right. They are different measurements, and a
pipeline can be uniformly confident and frequently wrong. Section 6a checks whether the model's
confidence means anything on this data; section 7 sets thresholds from measured precision, not from the
pipeline's own numbers.

## Join from ground truth, always

`ER_EVAL_TRUE_PAIRS` is every pair of in-scope records that share a true entity (within type). Every
recall figure starts there and `LEFT JOIN`s outward to candidates, scores, decisions, and the
crosswalk. A harness that starts from candidate pairs or accepted edges cannot see what blocking
dropped, and reports recall on a pre-filtered population (rule 28). The same applies to any upstream
`WHERE ... IS NOT NULL` filter — do not add one.

## What the harness reports

### 1. Stage-by-stage fate of every true pair (section 2)

Each true pair is assigned the first stage that lost it: `LOST_AT_BLOCKING`, `LOST_AT_SCORING`
(auto-rejected), `NOT_ADJUDICATED` or `MODEL_FAILED`, `LOST_AT_ADJUDICATION`, `NOT_CLUSTERED`, or
`FOUND`. Broken down by entity type, case role, and difficulty. This is the table to read first — it
says which phase to fix.

**Pair completeness** (share of true pairs that are candidate pairs) is blocking recall. Report it next
to the reduction ratio from Phase 2, always together. Run section 2a right after Phase 2 as well; it
needs only `ER_CANDIDATE_PAIRS`.

What to expect on the sandbox, as a sanity check rather than a target: `MOVED` pairs should be found
only through tax-id rules; `ACRONYM` pairs through phone, domain or tax id; recipe-7 pairs (typo plus
abbreviation plus missing postal) are the most likely to be lost at blocking. If they are found by
name-based rules alone, check the answer key for leakage before celebrating.

### 2. Pairwise precision, recall, F1 (section 3)

Predicted pairs are all record pairs sharing a golden id. Reported for all clusters and for
publishable clusters only — the difference is what the guards are holding back.

### 3. B-cubed precision, recall, F1 (section 4)

Per record: precision is the share of its predicted cluster that truly belongs with it; recall is the
share of its true cluster that ended up with it; averaged over all records, singletons included.
Pairwise metrics are dominated by large clusters; B-cubed weights every record equally. Report both
(rule 29), and report both by case role and difficulty — exact duplicates inflate every headline
number, and the hard slices are where the pipeline is tested.

### 4. Over-merging on hard negatives (section 5)

For `SIBLING`, `FRANCHISE`, and `SIZE_VARIANT` entities: how many ended up in a golden record that also
contains another true entity. This is the false-merge rate on exactly the cases embeddings cannot tell
apart (rule 15). Any non-zero number deserves a look at the edges involved — section 6 says which
decision source produced them.

### 5. Decision-level precision by source (section 6), and model calibration (6a)

Precision of accepted edges split by `RULE`, `SCORE`, `MODEL`. A low `RULE` precision usually means the
tax-id rule is wrong for this customer's data (shared tax ids across separately managed vendors); a low
`SCORE` precision means `auto_match` is too low or the substitution guard is not catching siblings; a
low `MODEL` precision means the prompt rules or the acceptance confidence need work.

Section 6a buckets model decisions by confidence and reports accuracy per bucket. Set
`thresholds.model_accept_confidence` to the lowest bucket whose accuracy meets the agreed target.

### 6. Threshold sweep (section 7)

For score-banded pairs only (rules and cannot-link pairs do not depend on thresholds), across
thresholds from 0.50 to 0.99, on the **calibration** split:

- if `auto_match` were here: how many pairs would auto-match, and the precision of that band
- if `auto_reject` were here: how many true pairs would be auto-rejected, as a count and a share
- by implication, how many pairs would remain in review — the model call count

Choose `auto_match` as the lowest threshold meeting the agreed auto-match precision target, and
`auto_reject` as the highest threshold whose lost-true-pair share is acceptable. **The targets are the
customer's**, set in the POC criteria — not plugin defaults. Then re-band in Phase 3 (free), re-run
Phases 4 and 5 for any newly reviewed pairs, and report final metrics on the **holdout** split. The split
is by true entity, so no entity contributes pairs to both halves (rule 31).

If the true-match and non-match score distributions do not separate — precision rises slowly and never
reaches the target before recall collapses — say so. The fix is in features or the embedding template,
not in finding a cleverer threshold.

### 7. Parse failures and lost decisions (section 8)

Counts of `MODEL_FAILED`, decisions without reasons, decisions with invalid reasons, and errors — and
how many of each were true pairs. Every one of these is lost recall that would otherwise be invisible
(rule 19). A pipeline that cannot report this number cannot make a recall claim.

### 8. Cost (section 9)

Billed tokens per phase, function and model, from
`SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` filtered on the
`er:<run_id>:<phase>` query tag that the score and adjudicate SQL set — then normalized to **tokens per
1,000 source records**. Section 9a gives the share of candidate pairs that reached the model and model
calls per 1,000 records: that is the measured effect of blocking and banding as cost controls on this
data.

Account usage views have ingestion latency. If the run is recent and rows are missing, say so and
re-run later; do not substitute `AI_COUNT_TOKENS` estimates without labeling them as estimates. Report
tokens; never convert to currency.

## Experiments and regression gates

`ER_EVAL_SUMMARY` accumulates one row per run and entity type. Section 10a compares experiments. When a
user asks whether a change helped, compare on these metrics — and check `prompt_hash` and
`embed_template_version` to confirm what actually differed between the runs (rule 35).

After the first accepted run, set `thresholds.min_acceptable_pairwise_precision` and
`thresholds.min_acceptable_bcubed_f1` just under the achieved values. In dbt mode these become
build-failing tests (see `DBT_MATERIALIZATION.md`); in SQL mode, check them at the end of every run and
report a regression as a failure, not a warning.

## On real data: a steward-labeled sample

There is no answer key on real data. Build a labeled sample, stratified so it measures the boundary
rather than the easy cases:

```sql
-- Draw pairs per entity type across score buckets and bands, so the sample
-- covers auto-match, the review band, and the top of auto-reject.
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.ER_LABEL_SAMPLE AS
SELECT sp.run_id, sp.pair_id, sp.entity_type, sp.band, sp.band_source,
       WIDTH_BUCKET(sp.composite_score, 0, 1, 10) AS score_bucket,
       sp.record_uid_a, sp.record_uid_b,
       NULL::VARCHAR AS steward_label,      -- SAME_ENTITY | DIFFERENT | RELATED | UNSURE
       NULL::VARCHAR AS labeled_by,
       NULL::TIMESTAMP_NTZ AS labeled_at
FROM {{SCHEMA}}.ER_SCORED_PAIRS sp
WHERE sp.run_id = '{{RUN_ID}}'
QUALIFY ROW_NUMBER() OVER (PARTITION BY sp.entity_type, sp.band, WIDTH_BUCKET(sp.composite_score, 0, 1, 10)
                           ORDER BY HASH(sp.pair_id)) <= 30;
```

Be honest about what it supports:

- **Precision** per band and bucket: yes, directly.
- **Threshold calibration**: yes, within the sampled range.
- **Recall**: only partially. A sample of candidate pairs says nothing about pairs blocking never
  produced. To estimate blocking recall, stewards also need a sample of known duplicates found another
  way — for example, records the business already merged in a source system (the `MERGED` status the
  preflight filter excludes is a free source of known-true pairs), or a small exhaustive review of one
  region or one name prefix.
- **B-cubed**: not from a pair sample. It needs complete cluster truth for the sampled entities.

Stewards label in the session or in a sheet the customer controls; labels are written back into the
table. Never send sample contents outside the account to get them labeled.

## Gate verification

Show, per entity type: pair completeness and reduction ratio; the stage-loss table; pairwise and
B-cubed precision, recall and F1, overall and for the hard slices; hard-negative over-merge counts;
decision precision by source; parse-failure counts; tokens per 1,000 records and share of pairs to the
model. Then write `phases.eval: done`.
