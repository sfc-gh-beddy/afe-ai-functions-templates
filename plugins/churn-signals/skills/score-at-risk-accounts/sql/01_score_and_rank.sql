-- =====================================================================
-- Phase 6: batch scoring, at-risk accounts with evidence, churn-reason
-- analytics, and the incremental refresh.
--
-- SUBSTITUTE (from churn-project.yml):
--   {{DB}}.{{SCHEMA}}
--   {{MODEL_NAME}} {{MODEL_VERSION}}   registered in Phase 5
--   {{ACCOUNT_TABLE}} {{ARR_COL}} {{ACCOUNT_NAME_COL}} {{OWNER_COL}}
--   {{RUN_ID}}                        extraction run feeding the features
--   {{SCORE_RUN_ID}}                  unique per scoring invocation
--   {{HIGH_RISK}} {{WATCH}}           probability bands, set in Phase 7
--   {{NARRATIVE_TOP_N}}               accounts that get an AI narrative
--   {{OUTCOME_TABLE}} {{HORIZON_DAYS}} for the closed-churn reason views
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};
ALTER SESSION SET QUERY_TAG = 'churn-signals:{{SCORE_RUN_ID}}:score';

-- Confirm the method name and output keys before writing any scoring SQL.
-- The training script registers predict_proba with output columns
-- P_RETAINED / P_CHURN. If this shows anything else, stop and fix the
-- extraction of the probability below to match.
SHOW FUNCTIONS IN MODEL {{MODEL_NAME}} VERSION {{MODEL_VERSION}};

-- ---------------------------------------------------------------------
-- 1. Batch score. Warehouse inference via MODEL(...)!method. Feature
--    columns are passed BY NAME so a reordered feature table cannot
--    silently feed the wrong column into the wrong input. The named
--    argument list must match the registered signature exactly.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CHURN_SCORES (
    score_run_id VARCHAR, model_name VARCHAR, model_version VARCHAR, feature_version VARCHAR,
    account_id VARCHAR, as_of_date DATE, renewal_date DATE, split VARCHAR,
    p_churn FLOAT, scored_at TIMESTAMP_NTZ
);

DELETE FROM CHURN_SCORES WHERE score_run_id = '{{SCORE_RUN_ID}}';

INSERT INTO CHURN_SCORES
SELECT '{{SCORE_RUN_ID}}', '{{MODEL_NAME}}', '{{MODEL_VERSION}}', f.feature_version,
       f.account_id, f.as_of_date, f.renewal_date, f.split,
       MODEL({{MODEL_NAME}}, {{MODEL_VERSION}})!PREDICT_PROBA(
           ARR => f.arr::FLOAT, SEG_SMB => f.seg_smb::FLOAT, SEG_MID_MARKET => f.seg_mid_market::FLOAT,
           SEG_ENTERPRISE => f.seg_enterprise::FLOAT, TENURE_DAYS => f.tenure_days::FLOAT,
           UTIL_LAST3 => f.util_last3::FLOAT, UTIL_PRIOR3 => f.util_prior3::FLOAT,
           UTIL_TREND => f.util_trend::FLOAT, LOGINS_RATIO => f.logins_ratio::FLOAT,
           USAGE_MONTHS_AVAILABLE => f.usage_months_available::FLOAT,
           N_INTERACTIONS => f.n_interactions::FLOAT, N_RISK_INTERACTIONS => f.n_risk_interactions::FLOAT,
           N_REASON_PRICE_VALUE => f.n_reason_price_value::FLOAT, N_REASON_PRODUCT_GAP => f.n_reason_product_gap::FLOAT,
           N_REASON_RELIABILITY => f.n_reason_reliability::FLOAT, N_REASON_SUPPORT => f.n_reason_support::FLOAT,
           N_REASON_ADOPTION => f.n_reason_adoption::FLOAT, N_REASON_COMPETITOR => f.n_reason_competitor::FLOAT,
           N_REASON_BUSINESS_CHANGE => f.n_reason_business_change::FLOAT,
           N_REASON_CHAMPION_LOSS => f.n_reason_champion_loss::FLOAT,
           N_INTENT_HIGH => f.n_intent_high::FLOAT, N_INTENT_MEDIUM => f.n_intent_medium::FLOAT,
           MAX_INTENT_SCORE => f.max_intent_score::FLOAT, N_UNRESOLVED_RISK => f.n_unresolved_risk::FLOAT,
           SHARE_NEGATIVE => f.share_negative::FLOAT, N_NEG_SUPPORT => f.n_neg_support::FLOAT,
           N_NEG_PRICE => f.n_neg_price::FLOAT, COMPETITOR_MENTIONED => f.competitor_mentioned::FLOAT,
           DAYS_SINCE_LAST_RISK => f.days_since_last_risk::FLOAT
       ):P_CHURN::FLOAT,
       CURRENT_TIMESTAMP()
FROM ACCOUNT_FEATURES f
-- TEST rows are scored too, so the harness can compute AUC from what the
-- registered model actually returns in SQL, not from the training script.
WHERE f.split IN ('SCORE', 'TEST');

-- ---------------------------------------------------------------------
-- 2. Evidence per account: the grounded quotes behind the score, taken
--    only from interactions BEFORE as_of_date -- the same window the model
--    saw. Evidence the model never saw cannot explain its score.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ACCOUNT_EVIDENCE AS
SELECT s.account_id, s.as_of_date,
       ARRAY_AGG(OBJECT_CONSTRUCT(
           'interaction_id', i.interaction_id,
           'created_at',     i.created_at,
           'channel',        i.channel,
           'reasons',        i.reason_codes,
           'intent',         i.churn_intent,
           'quote',          i.evidence_quote))
         WITHIN GROUP (ORDER BY DECODE(i.churn_intent, 'high', 3, 'medium', 2, 'low', 1, 0) DESC, i.created_at DESC)
                                                                         AS evidence,
       COUNT(*)                                                          AS evidence_count
FROM CHURN_SCORES s
JOIN INTERACTION_SIGNALS i
  ON i.account_id = s.account_id
 AND i.run_id = '{{RUN_ID}}'
 AND i.created_at < s.as_of_date::TIMESTAMP_NTZ
 AND ARRAY_SIZE(i.reason_codes) > 0
 AND i.evidence_grounded                       -- ungrounded quotes are never shown
 AND COALESCE(i.concern_resolved, FALSE) = FALSE
WHERE s.score_run_id = '{{SCORE_RUN_ID}}' AND s.split = 'SCORE'
GROUP BY 1, 2;

-- Reason ranking per account: counts by reason over the same window.
CREATE OR REPLACE TABLE ACCOUNT_REASONS AS
SELECT s.account_id, s.as_of_date, r.value::STRING AS reason_code, COUNT(*) AS mentions,
       MAX(i.created_at) AS last_mentioned_at
FROM CHURN_SCORES s
JOIN INTERACTION_SIGNALS i
  ON i.account_id = s.account_id AND i.run_id = '{{RUN_ID}}'
 AND i.created_at < s.as_of_date::TIMESTAMP_NTZ,
LATERAL FLATTEN(input => i.reason_codes) r
WHERE s.score_run_id = '{{SCORE_RUN_ID}}' AND s.split = 'SCORE'
GROUP BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- 3. The deliverable: one row per open renewal, banded, with ARR at
--    stake, ranked reasons and cited evidence. Score and evidence are
--    per-row guarantees: a HIGH row with no evidence is flagged, not
--    hidden, because usage-only risk is real risk (silent churners).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS AT_RISK_ACCOUNTS (
    score_run_id VARCHAR, model_version VARCHAR, account_id VARCHAR, account_name VARCHAR,
    owner VARCHAR, renewal_date DATE, as_of_date DATE, arr FLOAT, p_churn FLOAT,
    risk_band VARCHAR, arr_at_risk_expected FLOAT, top_reasons ARRAY, evidence VARIANT,
    evidence_count INT, risk_basis VARCHAR, narrative VARCHAR,
    review_status VARCHAR DEFAULT 'NEW', reviewed_by VARCHAR, reviewed_at TIMESTAMP_NTZ,
    created_at TIMESTAMP_NTZ
);

DELETE FROM AT_RISK_ACCOUNTS WHERE score_run_id = '{{SCORE_RUN_ID}}';

INSERT INTO AT_RISK_ACCOUNTS
    (score_run_id, model_version, account_id, account_name, owner, renewal_date, as_of_date, arr,
     p_churn, risk_band, arr_at_risk_expected, top_reasons, evidence, evidence_count, risk_basis,
     narrative, created_at)
WITH rr AS (
    SELECT account_id, as_of_date,
           ARRAY_AGG(reason_code) WITHIN GROUP (ORDER BY mentions DESC, last_mentioned_at DESC) AS reasons
    FROM ACCOUNT_REASONS GROUP BY 1, 2
)
SELECT s.score_run_id, s.model_version, s.account_id,
       a.{{ACCOUNT_NAME_COL}}, a.{{OWNER_COL}}, s.renewal_date, s.as_of_date,
       a.{{ARR_COL}}::FLOAT, s.p_churn,
       CASE WHEN s.p_churn >= {{HIGH_RISK}} THEN 'HIGH'
            WHEN s.p_churn >= {{WATCH}}     THEN 'WATCH'
            ELSE 'LOW' END,
       -- probability-weighted, and only meaningful if the model is calibrated;
       -- Phase 7 reports calibration before anyone sums this column
       ROUND(a.{{ARR_COL}}::FLOAT * s.p_churn, 2),
       ARRAY_SLICE(COALESCE(rr.reasons, ARRAY_CONSTRUCT()), 0, 3),
       COALESCE(e.evidence, ARRAY_CONSTRUCT()),
       COALESCE(e.evidence_count, 0),
       IFF(COALESCE(e.evidence_count, 0) > 0, 'TEXT_AND_USAGE', 'USAGE_ONLY'),
       NULL,
       CURRENT_TIMESTAMP()
FROM CHURN_SCORES s
JOIN {{ACCOUNT_TABLE}} a ON a.account_id = s.account_id
LEFT JOIN ACCOUNT_EVIDENCE e ON e.account_id = s.account_id AND e.as_of_date = s.as_of_date
LEFT JOIN rr               ON rr.account_id = s.account_id AND rr.as_of_date = s.as_of_date
WHERE s.score_run_id = '{{SCORE_RUN_ID}}' AND s.split = 'SCORE';

-- ---------------------------------------------------------------------
-- 4. Narrative for the top N by expected ARR at risk only. AI_SUMMARIZE_AGG
--    over the account's grounded quotes -- the narrative can only restate
--    evidence that is already cited on the row.
-- ---------------------------------------------------------------------
UPDATE AT_RISK_ACCOUNTS t
SET narrative = n.narrative
FROM (
    SELECT r.account_id,
           AI_SUMMARIZE_AGG(
               TO_CHAR(f.value:created_at::TIMESTAMP_NTZ, 'YYYY-MM-DD') || ' ' ||
               f.value:channel::STRING || ': ' || f.value:quote::STRING) AS narrative
    FROM (SELECT * FROM AT_RISK_ACCOUNTS
          WHERE score_run_id = '{{SCORE_RUN_ID}}' AND risk_band IN ('HIGH', 'WATCH') AND evidence_count > 0
          QUALIFY ROW_NUMBER() OVER (ORDER BY arr_at_risk_expected DESC) <= {{NARRATIVE_TOP_N}}) r,
         LATERAL FLATTEN(input => r.evidence) f
    GROUP BY r.account_id
) n
WHERE t.account_id = n.account_id AND t.score_run_id = '{{SCORE_RUN_ID}}';

-- ---------------------------------------------------------------------
-- 5. Churn-reason analytics over CLOSED renewals. This is where the
--    post-cutoff text (non-renewal notices, exit surveys) belongs: it is
--    the clearest statement of why a customer left. Includes it on
--    purpose, and labels it so nobody mistakes it for model input.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW CHURN_REASONS_CLOSED AS
SELECT o.account_id, o.renewal_date, a.{{ARR_COL}}::FLOAT AS arr_lost,
       r.value::STRING                                   AS reason_code,
       i.channel, i.created_at,
       i.created_at >= DATEADD(day, -{{HORIZON_DAYS}}, o.renewal_date)::TIMESTAMP_NTZ AS is_post_cutoff,
       i.evidence_quote
FROM {{OUTCOME_TABLE}} o
JOIN {{ACCOUNT_TABLE}} a ON a.account_id = o.account_id
JOIN INTERACTION_SIGNALS i
  ON i.account_id = o.account_id AND i.run_id = '{{RUN_ID}}'
 AND i.created_at < DATEADD(day, 30, o.renewal_date)::TIMESTAMP_NTZ
 AND i.created_at >= DATEADD(day, -365, o.renewal_date)::TIMESTAMP_NTZ,
LATERAL FLATTEN(input => i.reason_codes) r
WHERE o.outcome = 'CHURNED';

-- Lost ARR by reason. ARR is attributed once per account to its MOST
-- mentioned reason; summing arr_lost across reason rows double-counts.
CREATE OR REPLACE VIEW CHURNED_ARR_BY_REASON AS
WITH ranked AS (
    SELECT account_id, renewal_date, arr_lost, reason_code, COUNT(*) AS mentions,
           ROW_NUMBER() OVER (PARTITION BY account_id, renewal_date
                              ORDER BY COUNT(*) DESC, MAX(created_at) DESC) AS rk
    FROM CHURN_REASONS_CLOSED GROUP BY 1, 2, 3, 4
)
SELECT reason_code AS primary_reason, COUNT(*) AS accounts, SUM(arr_lost) AS arr_lost
FROM ranked WHERE rk = 1
GROUP BY 1 ORDER BY arr_lost DESC;

ALTER SESSION UNSET QUERY_TAG;

-- ---------------------------------------------------------------------
-- 6. Gate verification. Show these results, not a claim.
-- ---------------------------------------------------------------------
SELECT risk_band, COUNT(*) AS accounts, ROUND(SUM(arr), 0) AS arr,
       ROUND(SUM(arr_at_risk_expected), 0) AS expected_arr_at_risk,
       COUNT_IF(p_churn IS NULL)               AS null_scores,        -- must be 0
       COUNT_IF(risk_basis = 'USAGE_ONLY')     AS usage_only_rows,
       COUNT_IF(narrative IS NOT NULL)         AS with_narrative
FROM AT_RISK_ACCOUNTS WHERE score_run_id = '{{SCORE_RUN_ID}}'
GROUP BY 1 ORDER BY 1;

-- Every cited interaction must exist and be pre-cutoff. Must return 0.
SELECT COUNT(*) AS bad_citations
FROM AT_RISK_ACCOUNTS t, LATERAL FLATTEN(input => t.evidence) f
LEFT JOIN INTERACTION_SIGNALS i
  ON i.interaction_id = f.value:interaction_id::STRING AND i.run_id = '{{RUN_ID}}'
WHERE t.score_run_id = '{{SCORE_RUN_ID}}'
  AND (i.interaction_id IS NULL OR i.created_at >= t.as_of_date::TIMESTAMP_NTZ);
