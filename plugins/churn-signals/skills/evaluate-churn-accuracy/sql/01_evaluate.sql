-- =====================================================================
-- Phase 7: accuracy and cost. Reads the quarantined answer key -- the
-- ONLY code in this plugin allowed to.
--
-- SUBSTITUTE: {{DB}}.{{SCHEMA}}, {{EVAL_SCHEMA}}, {{RUN_ID}}, {{SCORE_RUN_ID}},
--             {{RUN_START}} (timestamp the extraction run began)
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};

-- ---------------------------------------------------------------------
-- 0. One normalisation for both sides. Truth codes and predicted codes
--    are both upper-cased reason codes from REASON_TAXONOMY; anything
--    else is reported, not silently dropped.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _EVAL_PAIRS AS
SELECT
    k.interaction_id, k.account_id, k.case_type, k.is_after_cutoff,
    ARRAY_DISTINCT(TRANSFORM(k.true_reasons, x -> UPPER(TRIM(x::STRING))::VARIANT)) AS truth,
    -- Join FROM the answer key: an interaction the pipeline never produced
    -- (dropped in staging, failed, filtered) is a miss, not an absence.
    COALESCE(ARRAY_DISTINCT(TRANSFORM(s.reason_codes, x -> UPPER(TRIM(x::STRING))::VARIANT)),
             ARRAY_CONSTRUCT())                                                 AS pred,
    s.interaction_id IS NULL                                                    AS missing_from_output,
    COALESCE(s.classify_failed, FALSE)                                          AS classify_failed,
    s.churn_intent, s.evidence_grounded, s.evidence_failed, s.channel
FROM {{EVAL_SCHEMA}}.SYN_INTERACTION_LABELS k
LEFT JOIN INTERACTION_SIGNALS s
  ON s.interaction_id = k.interaction_id AND s.run_id = '{{RUN_ID}}';

-- Coverage and silent loss first. If these are not near zero, every
-- number below is measured on a subset.
SELECT COUNT(*)                                      AS labeled_interactions,
       COUNT_IF(missing_from_output)                 AS missing_from_output,
       COUNT_IF(classify_failed)                     AS classify_failed,
       COUNT_IF(evidence_failed)                     AS evidence_failed,
       COUNT_IF(evidence_grounded = FALSE)           AS ungrounded_quotes,
       ROUND(COUNT_IF(evidence_grounded) / NULLIF(COUNT_IF(evidence_grounded IS NOT NULL), 0), 4) AS grounding_rate
FROM _EVAL_PAIRS;

-- ---------------------------------------------------------------------
-- 1. Per-reason precision / recall / F1, plus micro and macro.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _EVAL_PER_REASON AS
WITH codes AS (
    SELECT reason_code FROM REASON_TAXONOMY WHERE reason_code <> 'NONE'
),
grid AS (
    SELECT p.interaction_id, p.case_type, c.reason_code,
           ARRAY_CONTAINS(c.reason_code::VARIANT, p.truth) AS is_true,
           ARRAY_CONTAINS(c.reason_code::VARIANT, p.pred)  AS is_pred
    FROM _EVAL_PAIRS p CROSS JOIN codes c
)
SELECT reason_code,
       COUNT_IF(is_true AND is_pred)          AS tp,
       COUNT_IF(NOT is_true AND is_pred)      AS fp,
       COUNT_IF(is_true AND NOT is_pred)      AS fn,
       COUNT_IF(is_true)                      AS support
FROM grid GROUP BY reason_code;

SELECT reason_code, support, tp, fp, fn,
       ROUND(tp / NULLIF(tp + fp, 0), 4)                          AS precision,
       ROUND(tp / NULLIF(tp + fn, 0), 4)                          AS recall,
       ROUND(2 * tp / NULLIF(2 * tp + fp + fn, 0), 4)             AS f1
FROM _EVAL_PER_REASON
ORDER BY support DESC;

SELECT 'micro' AS average,
       ROUND(SUM(tp) / NULLIF(SUM(tp) + SUM(fp), 0), 4)            AS precision,
       ROUND(SUM(tp) / NULLIF(SUM(tp) + SUM(fn), 0), 4)            AS recall,
       ROUND(2 * SUM(tp) / NULLIF(2 * SUM(tp) + SUM(fp) + SUM(fn), 0), 4) AS f1
FROM _EVAL_PER_REASON
UNION ALL
-- Macro: every reason counts equally. A pipeline strong on price and weak
-- on champion loss shows good micro and poor macro.
SELECT 'macro',
       ROUND(AVG(tp / NULLIF(tp + fp, 0)), 4),
       ROUND(AVG(tp / NULLIF(tp + fn, 0)), 4),
       ROUND(AVG(2 * tp / NULLIF(2 * tp + fp + fn, 0)), 4)
FROM _EVAL_PER_REASON;

-- ---------------------------------------------------------------------
-- 2. Binary risk detection and the over-calling check.
--    Distractors were written to fool a keyword or naive classifier; the
--    false-positive rate on them is the number that says whether CSMs
--    will trust the queue.
-- ---------------------------------------------------------------------
SELECT case_type,
       COUNT(*)                                                    AS n,
       COUNT_IF(ARRAY_SIZE(pred) > 0)                              AS flagged,
       ROUND(COUNT_IF(ARRAY_SIZE(pred) > 0) / NULLIF(COUNT(*), 0), 4) AS flag_rate,
       -- exact-set match: every true reason and nothing else
       ROUND(COUNT_IF(ARRAY_SIZE(ARRAY_EXCEPT(truth, pred)) = 0
                      AND ARRAY_SIZE(ARRAY_EXCEPT(pred, truth)) = 0) / NULLIF(COUNT(*), 0), 4) AS exact_set_match
FROM _EVAL_PAIRS
GROUP BY case_type ORDER BY case_type;
-- Expected shape: SIGNAL and POST_OUTCOME flag_rate high (that is recall),
-- NOISE and DISTRACTOR flag_rate low (that is the false-positive rate).

-- Which distractor pattern leaks? Subject identifies the template family
-- (survey rows share the subject 'Survey response').
SELECT i.subject, COUNT(*) AS n,
       COUNT_IF(ARRAY_SIZE(e.pred) > 0)                           AS flagged,
       ARRAY_UNION_AGG(e.pred)                                    AS reasons_assigned
FROM _EVAL_PAIRS e
JOIN SYN_INTERACTIONS i USING (interaction_id)
WHERE e.case_type = 'DISTRACTOR'
GROUP BY 1 ORDER BY flagged DESC;

-- Per channel: surveys are short, call notes are third-person. A reason
-- recall that holds on tickets and collapses on call notes is a prompt fix.
SELECT channel,
       COUNT_IF(ARRAY_SIZE(truth) > 0)                                        AS risk_rows,
       ROUND(COUNT_IF(ARRAY_SIZE(truth) > 0 AND ARRAY_SIZE(ARRAY_INTERSECTION(truth, pred)) > 0)
             / NULLIF(COUNT_IF(ARRAY_SIZE(truth) > 0), 0), 4)                 AS any_reason_recall,
       ROUND(COUNT_IF(ARRAY_SIZE(truth) = 0 AND ARRAY_SIZE(pred) > 0)
             / NULLIF(COUNT_IF(ARRAY_SIZE(truth) = 0), 0), 4)                 AS false_flag_rate
FROM _EVAL_PAIRS GROUP BY channel ORDER BY channel;

-- Intent calibration against case type. POST_OUTCOME texts state the
-- customer is leaving: anything but 'high' there is an intent miss.
SELECT case_type, churn_intent, COUNT(*) AS n
FROM _EVAL_PAIRS
WHERE case_type IN ('SIGNAL', 'POST_OUTCOME', 'DISTRACTOR')
GROUP BY 1, 2 ORDER BY 1, 2;

-- Confusion between reasons: which true reason is predicted as which.
SELECT t.value::STRING AS true_reason, p.value::STRING AS predicted_reason, COUNT(*) AS n
FROM _EVAL_PAIRS e,
     LATERAL FLATTEN(input => e.truth) t,
     LATERAL FLATTEN(input => e.pred)  p
WHERE t.value::STRING <> p.value::STRING
GROUP BY 1, 2 ORDER BY n DESC LIMIT 20;

-- ---------------------------------------------------------------------
-- 3. Model: AUC, PR-style precision at k, lift, calibration -- computed
--    in SQL from what the REGISTERED model returned via MODEL()!method on
--    the TEST split. This is independent of the training script's own
--    numbers; if the two disagree, the deployed artifact is not the one
--    that was evaluated.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _EVAL_SCORES AS
SELECT s.account_id, s.as_of_date, s.p_churn, f.churned, t.cohort
FROM CHURN_SCORES s
JOIN ACCOUNT_FEATURES f ON f.account_id = s.account_id AND f.as_of_date = s.as_of_date
JOIN {{EVAL_SCHEMA}}.SYN_ACCOUNT_TRUTH t ON t.account_id = s.account_id
WHERE s.score_run_id = '{{SCORE_RUN_ID}}' AND s.split = 'TEST';

-- AUC via Mann-Whitney with average ranks for ties.
WITH r AS (
    SELECT churned,
           RANK() OVER (ORDER BY p_churn) + (COUNT(*) OVER (PARTITION BY p_churn) - 1) / 2.0 AS rnk
    FROM _EVAL_SCORES
)
SELECT COUNT(*) AS n_test, SUM(churned) AS n_churners,
       ROUND((SUM(IFF(churned = 1, rnk, 0)) - SUM(churned) * (SUM(churned) + 1) / 2)
             / NULLIF(SUM(churned) * (COUNT(*) - SUM(churned)), 0), 4) AS auc_sql
FROM r;

-- Decile lift and calibration. Decile 1 = highest scores.
WITH d AS (
    SELECT *, NTILE(10) OVER (ORDER BY p_churn DESC) AS decile FROM _EVAL_SCORES
),
base AS (SELECT AVG(churned) AS base_rate FROM _EVAL_SCORES)
SELECT decile, COUNT(*) AS n, SUM(churned) AS churners,
       ROUND(AVG(churned), 4)                                           AS observed_rate,
       ROUND(AVG(p_churn), 4)                                           AS mean_predicted,
       ROUND(AVG(churned) / NULLIF(MAX(base.base_rate), 0), 3)          AS lift,
       ROUND(SUM(SUM(churned)) OVER (ORDER BY decile)
             / NULLIF(SUM(SUM(churned)) OVER (), 0), 4)                 AS cumulative_capture
FROM d CROSS JOIN base
GROUP BY decile ORDER BY decile;
-- mean_predicted far from observed_rate means the model ranks but is not
-- calibrated: the ranking is usable, the expected-ARR-at-risk column is not.

-- Where text earns its keep: capture of churners in the top two deciles
-- by latent cohort. SILENT churners left no text signal; text cannot find
-- them, and the readout must say so rather than average it away.
WITH d AS (SELECT *, NTILE(10) OVER (ORDER BY p_churn DESC) AS decile FROM _EVAL_SCORES)
SELECT cohort, COUNT(*) AS accounts, SUM(churned) AS churners,
       COUNT_IF(churned = 1 AND decile <= 2) AS churners_in_top_20pct,
       ROUND(COUNT_IF(churned = 1 AND decile <= 2) / NULLIF(SUM(churned), 0), 4) AS top20_capture
FROM d GROUP BY cohort ORDER BY cohort;

-- Experiments side by side, including the leaky demo row when present.
SELECT experiment_id, feature_set, model_version,
       metrics:auc::FLOAT              AS auc,
       metrics:auc_ci95                AS auc_ci95,
       metrics:pr_auc::FLOAT           AS pr_auc,
       metrics:top_decile_lift::FLOAT  AS top_decile_lift,
       metrics:brier::FLOAT            AS brier,
       run_at
FROM MODEL_EXPERIMENTS
ORDER BY run_at DESC, feature_set;

-- ---------------------------------------------------------------------
-- 4. Cost, measured. Credits and tokens from the account system of
--    record, attributed by QUERY_TAG. ACCOUNT_USAGE lags -- re-run this
--    a few hours after the extraction if it returns nothing.
-- ---------------------------------------------------------------------
WITH usage AS (
    SELECT function_name, model_name, SUM(credits) AS credits, COUNT(DISTINCT query_id) AS queries
    FROM snowflake.account_usage.cortex_ai_functions_usage_history
    WHERE start_time >= '{{RUN_START}}'::TIMESTAMP_LTZ
      AND query_tag LIKE 'churn-signals:{{RUN_ID}}:%'
    GROUP BY 1, 2
),
volume AS (
    SELECT COUNT(*) AS interactions FROM STG_INTERACTIONS
)
SELECT u.function_name, u.model_name, u.queries,
       ROUND(u.credits, 6)                                      AS credits,
       ROUND(1000 * u.credits / NULLIF(v.interactions, 0), 6)   AS credits_per_1k_interactions
FROM usage u CROSS JOIN volume v
ORDER BY credits DESC;

-- Per-call tokens for the evidence stage, from show_details, as a check on
-- the account view and on the AI_COUNT_TOKENS estimate made at the gate.
SELECT COUNT(*) AS evidence_calls,
       ROUND(AVG(prompt_tokens), 0)     AS avg_prompt_tokens,
       ROUND(AVG(completion_tokens), 0) AS avg_completion_tokens,
       SUM(prompt_tokens + completion_tokens) AS total_tokens
FROM INTERACTION_SIGNALS
WHERE run_id = '{{RUN_ID}}' AND prompt_tokens IS NOT NULL;
