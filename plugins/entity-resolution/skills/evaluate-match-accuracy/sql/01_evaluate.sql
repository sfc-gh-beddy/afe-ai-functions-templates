-- =====================================================================
-- Phase 6: evaluation against the labeled answer key. Read-mostly; writes
-- only to {{EVAL_SCHEMA}}. No AI calls.
-- Substitute {{SCHEMA}}, {{EVAL_SCHEMA}}, {{RUN_ID}}, {{EXPERIMENT_ID}}.
--
-- Every metric is built FROM GROUND TRUTH OUTWARD (rule 28): a true pair the
-- pipeline never generated, never scored, or failed to adjudicate is a false
-- negative, never an absent row.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. True pairs, within entity type, with difficulty and case roles, and a
--    calibration / holdout split by true entity (rule 31).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.ER_EVAL_TRUE_PAIRS AS
WITH ak AS (
    SELECT k.*, DECODE(k.difficulty, 'EASY', 1, 'MEDIUM', 2, 'HARD', 3) AS diff_rank,
           IFF(MOD(ABS(HASH(k.true_entity_id, 'split')), 2) = 0, 'CALIBRATION', 'HOLDOUT') AS split
    FROM {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE k
    -- Restrict to records that are in scope for this build.
    WHERE EXISTS (SELECT 1 FROM {{SCHEMA}}.ER_RECORDS r WHERE r.record_uid = k.record_uid)
)
SELECT a.entity_type,
       a.record_uid AS record_uid_a,
       b.record_uid AS record_uid_b,
       a.true_entity_id,
       a.case_role,
       DECODE(GREATEST(a.diff_rank, b.diff_rank), 1, 'EASY', 2, 'MEDIUM', 3, 'HARD') AS pair_difficulty,
       a.split
FROM ak a
JOIN ak b
  ON a.true_entity_id = b.true_entity_id
 AND a.record_uid < b.record_uid;

-- ---------------------------------------------------------------------
-- 2. Stage-by-stage fate of every true pair (rule 28). The first stage at
--    which a pair is lost is the stage to fix.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.ER_EVAL_PAIR_STAGES AS
SELECT
    '{{RUN_ID}}' AS run_id, '{{EXPERIMENT_ID}}' AS experiment_id,
    t.*,
    cp.pair_id IS NOT NULL                                 AS in_candidates,
    cp.block_rules,
    sp.band,
    sp.band_source,
    sp.composite_score,
    sp.cannot_link_reason,
    d.outcome                                              AS model_outcome,
    d.relationship                                         AS model_relationship,
    xa.golden_id IS NOT NULL AND xa.golden_id = xb.golden_id AS same_golden,
    xa.cluster_status                                      AS cluster_status,
    CASE
        WHEN cp.pair_id IS NULL                            THEN 'LOST_AT_BLOCKING'
        WHEN sp.band = 'AUTO_REJECT'                       THEN 'LOST_AT_SCORING'
        WHEN sp.band = 'REVIEW' AND d.outcome IS NULL      THEN 'NOT_ADJUDICATED'
        WHEN sp.band = 'REVIEW' AND d.outcome = 'MODEL_FAILED' THEN 'MODEL_FAILED'
        WHEN sp.band = 'REVIEW' AND d.outcome IN ('MODEL_NO_MATCH','STEWARD_REVIEW')
             AND NOT COALESCE(xa.golden_id = xb.golden_id, FALSE) THEN 'LOST_AT_ADJUDICATION'
        WHEN COALESCE(xa.golden_id = xb.golden_id, FALSE)  THEN 'FOUND'
        ELSE 'NOT_CLUSTERED'
    END                                                    AS fate
FROM {{EVAL_SCHEMA}}.ER_EVAL_TRUE_PAIRS t
LEFT JOIN {{SCHEMA}}.ER_CANDIDATE_PAIRS cp
       ON cp.record_uid_a = t.record_uid_a AND cp.record_uid_b = t.record_uid_b
LEFT JOIN {{SCHEMA}}.ER_SCORED_PAIRS sp
       ON sp.pair_id = cp.pair_id AND sp.run_id = '{{RUN_ID}}'
LEFT JOIN {{SCHEMA}}.ER_MATCH_DECISIONS d
       ON d.pair_id = cp.pair_id AND d.run_id = '{{RUN_ID}}' AND NOT d.is_swap_probe
LEFT JOIN {{SCHEMA}}.ER_CROSSWALK xa
       ON xa.record_uid = t.record_uid_a AND xa.run_id = '{{RUN_ID}}'
LEFT JOIN {{SCHEMA}}.ER_CROSSWALK xb
       ON xb.record_uid = t.record_uid_b AND xb.run_id = '{{RUN_ID}}';

-- 2a. Blocking recall (pair completeness) and stage losses, by type, role
--     and difficulty. Run this right after Phase 2 as well (it only needs
--     ER_CANDIDATE_PAIRS).
SELECT entity_type, case_role, pair_difficulty,
       COUNT(*)                                             AS true_pairs,
       ROUND(COUNT_IF(in_candidates) / COUNT(*), 4)         AS pair_completeness,
       COUNT_IF(fate = 'LOST_AT_BLOCKING')                  AS lost_blocking,
       COUNT_IF(fate = 'LOST_AT_SCORING')                   AS lost_scoring,
       COUNT_IF(fate IN ('NOT_ADJUDICATED','MODEL_FAILED')) AS lost_unadjudicated,
       COUNT_IF(fate = 'LOST_AT_ADJUDICATION')              AS lost_adjudication,
       COUNT_IF(fate = 'NOT_CLUSTERED')                     AS lost_other,
       COUNT_IF(fate = 'FOUND')                             AS found
FROM {{EVAL_SCHEMA}}.ER_EVAL_PAIR_STAGES
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- 3. Final pairwise precision / recall / F1 from the crosswalk. Predicted
--    pairs are all record pairs sharing a golden id. Reported for all
--    clusters and for PUBLISHABLE clusters only.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.ER_EVAL_PAIRWISE AS
WITH x AS (
    SELECT c.record_uid, c.entity_type, c.golden_id, c.cluster_status, k.true_entity_id
    FROM {{SCHEMA}}.ER_CROSSWALK c
    JOIN {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE k ON k.record_uid = c.record_uid
    WHERE c.run_id = '{{RUN_ID}}'
),
pred AS (
    SELECT a.entity_type, a.record_uid AS uid_a, b.record_uid AS uid_b,
           a.cluster_status, a.true_entity_id = b.true_entity_id AS correct
    FROM x a JOIN x b ON a.golden_id = b.golden_id AND a.record_uid < b.record_uid
),
truth AS (
    SELECT entity_type, COUNT(*) AS true_pairs FROM {{EVAL_SCHEMA}}.ER_EVAL_TRUE_PAIRS GROUP BY 1
),
scopes AS (
    SELECT 'ALL' AS scope, p.* FROM pred p
    UNION ALL
    SELECT 'PUBLISHABLE_ONLY', p.* FROM pred p WHERE p.cluster_status = 'PUBLISHABLE'
)
SELECT '{{RUN_ID}}' AS run_id, '{{EXPERIMENT_ID}}' AS experiment_id,
       t.entity_type, s.scope,
       COALESCE(COUNT(s.uid_a), 0)                       AS predicted_pairs,
       COALESCE(COUNT_IF(s.correct), 0)                  AS true_positive_pairs,
       t.true_pairs,
       COUNT_IF(s.correct) / NULLIF(COUNT(s.uid_a), 0)   AS pairwise_precision,
       COUNT_IF(s.correct) / NULLIF(t.true_pairs, 0)     AS pairwise_recall,
       2 * pairwise_precision * pairwise_recall / NULLIF(pairwise_precision + pairwise_recall, 0) AS pairwise_f1
FROM truth t
LEFT JOIN scopes s ON s.entity_type = t.entity_type
GROUP BY t.entity_type, s.scope, t.true_pairs;

SELECT * FROM {{EVAL_SCHEMA}}.ER_EVAL_PAIRWISE ORDER BY entity_type, scope;

-- ---------------------------------------------------------------------
-- 4. B-cubed cluster precision / recall / F1 (rule 29). Every record counts
--    once, singletons included.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.ER_EVAL_BCUBED AS
WITH x AS (
    SELECT c.record_uid, c.entity_type, c.golden_id, k.true_entity_id, k.case_role, k.difficulty
    FROM {{SCHEMA}}.ER_CROSSWALK c
    JOIN {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE k ON k.record_uid = c.record_uid
    WHERE c.run_id = '{{RUN_ID}}'
),
sized AS (
    SELECT x.*,
           COUNT(*) OVER (PARTITION BY golden_id)                 AS pred_size,
           COUNT(*) OVER (PARTITION BY true_entity_id)            AS true_size,
           COUNT(*) OVER (PARTITION BY golden_id, true_entity_id) AS overlap
    FROM x
)
SELECT '{{RUN_ID}}' AS run_id, '{{EXPERIMENT_ID}}' AS experiment_id,
       record_uid, entity_type, case_role, difficulty,
       overlap / pred_size AS b3_precision,
       overlap / true_size AS b3_recall
FROM sized;

SELECT entity_type,
       COUNT(*)                                   AS records,
       ROUND(AVG(b3_precision), 4)                AS bcubed_precision,
       ROUND(AVG(b3_recall), 4)                   AS bcubed_recall,
       ROUND(2 * AVG(b3_precision) * AVG(b3_recall) / NULLIF(AVG(b3_precision) + AVG(b3_recall), 0), 4) AS bcubed_f1
FROM {{EVAL_SCHEMA}}.ER_EVAL_BCUBED
GROUP BY 1
ORDER BY 1;

-- 4a. B-cubed by case role and difficulty. The hard slices are the test.
SELECT entity_type, case_role, difficulty, COUNT(*) AS records,
       ROUND(AVG(b3_precision), 4) AS bcubed_precision,
       ROUND(AVG(b3_recall), 4)    AS bcubed_recall
FROM {{EVAL_SCHEMA}}.ER_EVAL_BCUBED
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- 5. Over-merging on hard negatives: records of SIBLING, FRANCHISE,
--    SIZE_VARIANT entities whose golden record also contains another true
--    entity. And cross-type leakage for BOTH_TYPES (must be zero when
--    scope.cross_type_party is false; within-type resolution cannot merge
--    across type, so this checks the pipeline did not bypass scope).
-- ---------------------------------------------------------------------
WITH x AS (
    SELECT c.record_uid, c.entity_type, c.golden_id, k.true_entity_id, k.case_role
    FROM {{SCHEMA}}.ER_CROSSWALK c
    JOIN {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE k ON k.record_uid = c.record_uid
    WHERE c.run_id = '{{RUN_ID}}'
),
impure AS (
    SELECT golden_id FROM x GROUP BY 1 HAVING COUNT(DISTINCT true_entity_id) > 1
)
SELECT x.entity_type, x.case_role,
       COUNT(DISTINCT x.true_entity_id)                                     AS entities,
       COUNT(DISTINCT IFF(i.golden_id IS NOT NULL, x.true_entity_id, NULL))  AS entities_over_merged
FROM x
LEFT JOIN impure i ON i.golden_id = x.golden_id
GROUP BY 1, 2
ORDER BY 1, 2;

-- ---------------------------------------------------------------------
-- 6. Decision-level precision by source: of accepted edges, how many join
--    records of the same true entity. Tells you which source over-merges.
-- ---------------------------------------------------------------------
SELECT e.entity_type, e.decision_source,
       COUNT(*)                                                  AS edges,
       COUNT_IF(ka.true_entity_id = kb.true_entity_id)           AS correct,
       ROUND(COUNT_IF(ka.true_entity_id = kb.true_entity_id) / COUNT(*), 4) AS edge_precision
FROM {{SCHEMA}}.ER_ACCEPTED_EDGES e
JOIN {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE ka ON ka.record_uid = e.record_uid_a
JOIN {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE kb ON kb.record_uid = e.record_uid_b
WHERE e.run_id = '{{RUN_ID}}'
GROUP BY 1, 2
ORDER BY 1, 2;

-- 6a. Is model confidence calibrated? Accuracy of model decisions by
--     confidence bucket. Set model_accept_confidence from this, not from the
--     model's own number.
SELECT sp.entity_type,
       FLOOR(d.confidence * 10) / 10                              AS confidence_bucket,
       d.decision,
       COUNT(*)                                                   AS decisions,
       ROUND(COUNT_IF((d.decision = 'MATCH') = (ka.true_entity_id = kb.true_entity_id)) / COUNT(*), 4) AS accuracy
FROM {{SCHEMA}}.ER_MATCH_DECISIONS d
JOIN {{SCHEMA}}.ER_SCORED_PAIRS sp ON sp.pair_id = d.pair_id AND sp.run_id = d.run_id
JOIN {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE ka ON ka.record_uid = sp.record_uid_a
JOIN {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE kb ON kb.record_uid = sp.record_uid_b
WHERE d.run_id = '{{RUN_ID}}' AND NOT d.is_swap_probe AND d.decision IN ('MATCH', 'NO_MATCH')
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- 7. Threshold sweep on the CALIBRATION split (rule 31). For SCORE-banded
--    pairs only (rules and cannot-link are unaffected by thresholds). For
--    each auto_match threshold: precision of what would auto-match; for each
--    auto_reject threshold: true pairs that would be auto-rejected; and the
--    review band size that remains. Pick values, then report on HOLDOUT.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.ER_EVAL_THRESHOLD_SWEEP AS
WITH labeled AS (
    SELECT sp.entity_type, sp.composite_score, sp.token_substitution, sp.core_jw,
           ka.true_entity_id = kb.true_entity_id AS is_match,
           IFF(MOD(ABS(HASH(ka.true_entity_id, 'split')), 2) = 0, 'CALIBRATION', 'HOLDOUT') AS split
    FROM {{SCHEMA}}.ER_SCORED_PAIRS sp
    JOIN {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE ka ON ka.record_uid = sp.record_uid_a
    JOIN {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE kb ON kb.record_uid = sp.record_uid_b
    WHERE sp.run_id = '{{RUN_ID}}' AND sp.band_source = 'SCORE'
),
grid AS (
    SELECT ROUND(0.50 + SEQ4() * 0.01, 2) AS t
    FROM TABLE(GENERATOR(ROWCOUNT => 50))
)
SELECT '{{RUN_ID}}' AS run_id, l.entity_type, l.split, g.t AS threshold,
       COUNT_IF(l.composite_score >= g.t AND (NOT l.token_substitution OR l.core_jw >= 0.97)) AS would_auto_match,
       COUNT_IF(l.composite_score >= g.t AND (NOT l.token_substitution OR l.core_jw >= 0.97) AND l.is_match) AS auto_match_correct,
       COUNT_IF(l.composite_score <  g.t)                       AS would_auto_reject,
       COUNT_IF(l.composite_score <  g.t AND l.is_match)        AS true_pairs_auto_rejected,
       COUNT_IF(l.is_match)                                     AS true_pairs_in_score_band
FROM labeled l CROSS JOIN grid g
GROUP BY 1, 2, 3, 4;

-- Calibration view: choose auto_match as the lowest threshold whose
-- auto-match precision meets the agreed target, and auto_reject as the
-- highest threshold whose lost-true-pair count is acceptable. The targets
-- are the customer's call (POC criteria), not defaults.
SELECT entity_type, threshold,
       would_auto_match, ROUND(auto_match_correct / NULLIF(would_auto_match, 0), 4) AS auto_match_precision,
       would_auto_reject, true_pairs_auto_rejected,
       ROUND(true_pairs_auto_rejected / NULLIF(true_pairs_in_score_band, 0), 4)   AS share_true_lost_if_reject_here
FROM {{EVAL_SCHEMA}}.ER_EVAL_THRESHOLD_SWEEP
WHERE split = 'CALIBRATION'
ORDER BY entity_type, threshold;

-- ---------------------------------------------------------------------
-- 8. Parse-failure and lost-decision accounting (rule 19), and what they
--    cost in recall.
-- ---------------------------------------------------------------------
SELECT d.outcome,
       COUNT(*)                                     AS decisions,
       COUNT_IF(d.reason_count = 0)                 AS without_reasons,
       COUNT_IF(d.invalid_reason_count > 0)         AS with_invalid_reasons,
       COUNT_IF(d.error_message IS NOT NULL)        AS with_errors,
       COUNT_IF(ka.true_entity_id = kb.true_entity_id) AS of_which_true_pairs
FROM {{SCHEMA}}.ER_MATCH_DECISIONS d
JOIN {{SCHEMA}}.ER_SCORED_PAIRS sp ON sp.pair_id = d.pair_id AND sp.run_id = d.run_id
JOIN {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE ka ON ka.record_uid = sp.record_uid_a
JOIN {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE kb ON kb.record_uid = sp.record_uid_b
WHERE d.run_id = '{{RUN_ID}}' AND NOT d.is_swap_probe
GROUP BY 1
ORDER BY 2 DESC;

-- ---------------------------------------------------------------------
-- 9. Cost per 1,000 source records, in tokens, from billed usage (rule 32).
--    Relies on the QUERY_TAG set by the score and adjudicate SQL. ACCOUNT_USAGE
--    has ingestion latency; if rows are missing, re-run later rather than
--    substituting estimates silently.
-- ---------------------------------------------------------------------
WITH tagged AS (
    SELECT q.query_id, SPLIT_PART(q.query_tag, ':', 3) AS phase
    FROM SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q
    WHERE q.query_tag LIKE 'er:{{RUN_ID}}:%'
),
usage AS (
    SELECT t.phase, u.function_name, u.model_name, SUM(u.tokens) AS tokens, SUM(u.token_credits) AS token_credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY u
    JOIN tagged t ON t.query_id = u.query_id
    GROUP BY 1, 2, 3
),
n AS (SELECT COUNT(*) AS records FROM {{SCHEMA}}.ER_RECORDS)
SELECT u.phase, u.function_name, u.model_name, u.tokens,
       ROUND(1000 * u.tokens / NULLIF(n.records, 0), 1) AS tokens_per_1k_records
FROM usage u CROSS JOIN n
ORDER BY 1, 2;
-- Report tokens. Credits are shown in the view; do not convert to currency.

-- 9a. Cost-control evidence: share of candidate pairs that reached the model.
WITH rec AS (SELECT entity_type, COUNT(*) AS records FROM {{SCHEMA}}.ER_RECORDS GROUP BY 1)
SELECT sp.entity_type,
       COUNT(*)                                                  AS candidate_pairs,
       COUNT_IF(sp.band = 'REVIEW')                              AS review_pairs,
       ROUND(COUNT_IF(sp.band = 'REVIEW') / COUNT(*), 4)         AS share_to_model,
       ANY_VALUE(rec.records)                                    AS records,
       ROUND(1000 * COUNT_IF(sp.band = 'REVIEW') / NULLIF(ANY_VALUE(rec.records), 0), 1) AS model_calls_per_1k_records
FROM {{SCHEMA}}.ER_SCORED_PAIRS sp
JOIN rec ON rec.entity_type = sp.entity_type
WHERE sp.run_id = '{{RUN_ID}}'
GROUP BY 1;

-- ---------------------------------------------------------------------
-- 10. Experiment summary: accumulates, one row per run and entity type.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS {{EVAL_SCHEMA}}.ER_EVAL_SUMMARY (
    run_id               VARCHAR,
    experiment_id        VARCHAR,
    entity_type          VARCHAR,
    pair_completeness    FLOAT,
    pairwise_precision   FLOAT,
    pairwise_recall      FLOAT,
    pairwise_f1          FLOAT,
    bcubed_precision     FLOAT,
    bcubed_recall        FLOAT,
    bcubed_f1            FLOAT,
    review_pairs         INT,
    model_failed         INT,
    evaluated_at         TIMESTAMP_NTZ
);

DELETE FROM {{EVAL_SCHEMA}}.ER_EVAL_SUMMARY WHERE run_id = '{{RUN_ID}}';

INSERT INTO {{EVAL_SCHEMA}}.ER_EVAL_SUMMARY
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', pw.entity_type,
       st.pair_completeness,
       pw.pairwise_precision, pw.pairwise_recall, pw.pairwise_f1,
       b3.p, b3.r, 2 * b3.p * b3.r / NULLIF(b3.p + b3.r, 0),
       rv.review_pairs, rv.model_failed,
       CURRENT_TIMESTAMP()
FROM {{EVAL_SCHEMA}}.ER_EVAL_PAIRWISE pw
JOIN (SELECT entity_type, COUNT_IF(in_candidates) / COUNT(*) AS pair_completeness
      FROM {{EVAL_SCHEMA}}.ER_EVAL_PAIR_STAGES GROUP BY 1) st USING (entity_type)
JOIN (SELECT entity_type, AVG(b3_precision) AS p, AVG(b3_recall) AS r
      FROM {{EVAL_SCHEMA}}.ER_EVAL_BCUBED GROUP BY 1) b3 USING (entity_type)
LEFT JOIN (
      SELECT sp.entity_type,
             COUNT_IF(sp.band = 'REVIEW') AS review_pairs,
             COUNT_IF(d.outcome = 'MODEL_FAILED') AS model_failed
      FROM {{SCHEMA}}.ER_SCORED_PAIRS sp
      LEFT JOIN {{SCHEMA}}.ER_MATCH_DECISIONS d
             ON d.pair_id = sp.pair_id AND d.run_id = sp.run_id AND NOT d.is_swap_probe
      WHERE sp.run_id = '{{RUN_ID}}'
      GROUP BY 1) rv USING (entity_type)
WHERE pw.scope = 'ALL';

-- 10a. Compare experiments.
SELECT experiment_id, run_id, entity_type, pair_completeness,
       ROUND(pairwise_precision, 4) AS pw_p, ROUND(pairwise_recall, 4) AS pw_r, ROUND(pairwise_f1, 4) AS pw_f1,
       ROUND(bcubed_precision, 4) AS b3_p, ROUND(bcubed_recall, 4) AS b3_r, ROUND(bcubed_f1, 4) AS b3_f1,
       review_pairs, model_failed, evaluated_at
FROM {{EVAL_SCHEMA}}.ER_EVAL_SUMMARY
ORDER BY entity_type, evaluated_at;
