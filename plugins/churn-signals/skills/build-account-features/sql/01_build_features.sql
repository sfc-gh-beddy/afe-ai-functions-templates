-- =====================================================================
-- Phase 4: point-in-time account features for the churn model.
--
-- Every feature for an (account, as_of_date) row is computed ONLY from
-- data that existed strictly before as_of_date. That single rule is the
-- difference between a model that predicts churn and a model that reads
-- the answer. It is enforced three ways: the joins below, the audit
-- columns carried on every row, and the leakage audit in 02.
--
-- SUBSTITUTE (from churn-project.yml):
--   {{DB}}.{{SCHEMA}}
--   {{ACCOUNT_TABLE}}  account_id, segment, arr, contract start columns
--   {{OUTCOME_TABLE}}  renewal outcomes; {{OUTCOME_COL}} = '{{CHURN_VALUE}}' marks churn
--   {{USAGE_TABLE}}    monthly usage (account_id, month, active users, seats, logins)
--   {{ARR_COL}} {{SEGMENT_COL}} {{CONTRACT_START_COL}} {{RENEWAL_COL}}
--   {{USAGE_MONTH_COL}} {{ACTIVE_COL}} {{SEATS_COL}} {{LOGINS_COL}}
--   {{HORIZON_DAYS}}   days between the prediction and the renewal
--   {{LOOKBACK_DAYS}}  text window before as_of_date, e.g. 180
--   {{TEST_FRACTION}}  share of the latest renewals held out, e.g. 0.30
--   {{SCORE_AS_OF}}    as-of date for scoring open renewals (sandbox: anchor date)
--   {{RUN_ID}}         the extraction run whose INTERACTION_SIGNALS to use
--   {{FEATURE_VERSION}}
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. The spine: one row per prediction.
--    TRAIN/TEST rows come from observed renewals, as_of = renewal - horizon.
--    SCORE rows are open renewals inside the horizon window, as of today.
--    The split is BY TIME, never random: a random split lets the model
--    train on next quarter's renewals and test on last quarter's, which
--    reports accuracy you will not see in production.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FEATURE_SPINE AS
WITH labeled AS (
    SELECT o.account_id,
           o.{{RENEWAL_COL}}                                    AS renewal_date,
           DATEADD(day, -{{HORIZON_DAYS}}, o.{{RENEWAL_COL}})   AS as_of_date,
           IFF(o.{{OUTCOME_COL}} = '{{CHURN_VALUE}}', 1, 0)     AS churned,
           PERCENT_RANK() OVER (ORDER BY o.{{RENEWAL_COL}}, o.account_id) AS time_rank
    FROM {{OUTCOME_TABLE}} o
),
open_renewals AS (
    SELECT a.account_id,
           a.{{RENEWAL_COL}}                                    AS renewal_date,
           '{{SCORE_AS_OF}}'::DATE                              AS as_of_date
    FROM {{ACCOUNT_TABLE}} a
    WHERE a.{{RENEWAL_COL}} > '{{SCORE_AS_OF}}'::DATE
      AND a.{{RENEWAL_COL}} <= DATEADD(day, {{HORIZON_DAYS}}, '{{SCORE_AS_OF}}'::DATE)
)
, split0 AS (
    SELECT l.*, IFF(time_rank < 1 - {{TEST_FRACTION}}, 'TRAIN', 'TEST') AS split0
    FROM labeled l
),
test_start AS (
    SELECT MIN(as_of_date) AS first_test_as_of FROM split0 WHERE split0 = 'TEST'
)
-- EMBARGO: a training label must have been OBSERVED before the earliest
-- test prediction was made. Without this, a training renewal that closes
-- after a test row's as_of_date teaches the model about the test period.
SELECT s.account_id, s.renewal_date, s.as_of_date, s.churned,
       CASE WHEN s.split0 = 'TRAIN' AND s.renewal_date >= t.first_test_as_of THEN 'EMBARGO'
            ELSE s.split0 END                                 AS split
FROM split0 s CROSS JOIN test_start t
UNION ALL
SELECT account_id, renewal_date, as_of_date, NULL, 'SCORE'
FROM open_renewals;

-- ---------------------------------------------------------------------
-- 2. Text features. Strict inequality on created_at < as_of_date.
--    Post-cutoff interactions -- the non-renewal notice, the offboarding
--    ticket, the exit survey -- still exist in INTERACTION_SIGNALS and are
--    the BEST source for churn-REASON analytics. They are simply not
--    allowed to be model inputs.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FEAT_TEXT AS
WITH w AS (
    SELECT sp.account_id, sp.as_of_date, sig.*
    FROM FEATURE_SPINE sp
    JOIN INTERACTION_SIGNALS sig
      ON sig.account_id = sp.account_id
     AND sig.run_id = '{{RUN_ID}}'
     AND sig.created_at <  sp.as_of_date::TIMESTAMP_NTZ
     AND sig.created_at >= DATEADD(day, -{{LOOKBACK_DAYS}}, sp.as_of_date)::TIMESTAMP_NTZ
)
SELECT
    account_id, as_of_date,
    COUNT(*)                                                                 AS n_interactions,
    COUNT_IF(ARRAY_SIZE(reason_codes) > 0)                                   AS n_risk_interactions,
    COUNT_IF(ARRAY_CONTAINS('PRICE_VALUE'::VARIANT,     reason_codes))       AS n_reason_price_value,
    COUNT_IF(ARRAY_CONTAINS('PRODUCT_GAP'::VARIANT,     reason_codes))       AS n_reason_product_gap,
    COUNT_IF(ARRAY_CONTAINS('RELIABILITY'::VARIANT,     reason_codes))       AS n_reason_reliability,
    COUNT_IF(ARRAY_CONTAINS('SUPPORT'::VARIANT,         reason_codes))       AS n_reason_support,
    COUNT_IF(ARRAY_CONTAINS('ADOPTION'::VARIANT,        reason_codes))       AS n_reason_adoption,
    COUNT_IF(ARRAY_CONTAINS('COMPETITOR'::VARIANT,      reason_codes))       AS n_reason_competitor,
    COUNT_IF(ARRAY_CONTAINS('BUSINESS_CHANGE'::VARIANT, reason_codes))       AS n_reason_business_change,
    COUNT_IF(ARRAY_CONTAINS('CHAMPION_LOSS'::VARIANT,   reason_codes))       AS n_reason_champion_loss,
    COUNT_IF(churn_intent = 'high')                                          AS n_intent_high,
    COUNT_IF(churn_intent = 'medium')                                        AS n_intent_medium,
    MAX(DECODE(churn_intent, 'high', 3, 'medium', 2, 'low', 1, 0))           AS max_intent_score,
    COUNT_IF(ARRAY_SIZE(reason_codes) > 0 AND COALESCE(concern_resolved, FALSE) = FALSE) AS n_unresolved_risk,
    ROUND(COUNT_IF(overall_sentiment IN ('negative', 'mixed')) / NULLIF(COUNT(*), 0), 4) AS share_negative,
    COUNT_IF(ARRAY_CONTAINS('support'::VARIANT, neg_aspects))                AS n_neg_support,
    COUNT_IF(ARRAY_CONTAINS('price'::VARIANT, neg_aspects))                  AS n_neg_price,
    IFF(COUNT(competitor_named) > 0, 1, 0)                                   AS competitor_mentioned,
    DATEDIFF(day, MAX(IFF(ARRAY_SIZE(reason_codes) > 0, created_at, NULL)), as_of_date) AS days_since_last_risk,
    -- audit: must be strictly earlier than as_of_date on every row
    MAX(created_at)                                                          AS max_text_ts_used
FROM w
GROUP BY account_id, as_of_date;

-- ---------------------------------------------------------------------
-- 3. Usage features. A month is usable only if it had FINISHED before
--    as_of_date. "Last 3 months" without this filter reads the post-churn
--    zeros in the renewal month as a predictor.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE FEAT_USAGE AS
WITH u AS (
    SELECT sp.account_id, sp.as_of_date,
           DATEDIFF(month, u.{{USAGE_MONTH_COL}}, DATE_TRUNC(month, sp.as_of_date)) AS months_back,
           u.{{USAGE_MONTH_COL}}                       AS usage_month,
           u.{{ACTIVE_COL}}                            AS active_users,
           NULLIF(u.{{SEATS_COL}}, 0)                  AS seats,
           u.{{LOGINS_COL}}                            AS logins
    FROM FEATURE_SPINE sp
    JOIN {{USAGE_TABLE}} u
      ON u.account_id = sp.account_id
     AND DATEADD(month, 1, u.{{USAGE_MONTH_COL}}) <= sp.as_of_date   -- month complete before cutoff
)
SELECT
    account_id, as_of_date,
    ROUND(AVG(IFF(months_back BETWEEN 1 AND 3, active_users / seats, NULL)), 4)   AS util_last3,
    ROUND(AVG(IFF(months_back BETWEEN 4 AND 6, active_users / seats, NULL)), 4)   AS util_prior3,
    ROUND(AVG(IFF(months_back BETWEEN 1 AND 3, active_users / seats, NULL))
        - AVG(IFF(months_back BETWEEN 4 AND 6, active_users / seats, NULL)), 4)   AS util_trend,
    ROUND(SUM(IFF(months_back BETWEEN 1 AND 3, logins, 0))
        / NULLIF(SUM(IFF(months_back BETWEEN 4 AND 6, logins, 0)), 0), 4)          AS logins_ratio,
    COUNT_IF(months_back BETWEEN 1 AND 6)                                           AS usage_months_available,
    MAX(usage_month)                                                                AS max_usage_month_used
FROM u
GROUP BY account_id, as_of_date;

-- ---------------------------------------------------------------------
-- 4. Assemble. Columns are an EXPLICIT allowlist. No SELECT a.* -- that
--    is how CRM_STATUS and CRM_CANCEL_REASON end up as features.
--    NOTE: ARR and segment here are current values. In a real account,
--    use the value as of as_of_date from billing history if it exists;
--    a downgrade recorded at renewal is a leak of its own.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ACCOUNT_FEATURES AS
SELECT
    '{{FEATURE_VERSION}}'                                     AS feature_version,
    '{{RUN_ID}}'                                              AS extraction_run_id,
    sp.account_id, sp.as_of_date, sp.renewal_date, sp.split, sp.churned,
    -- account
    a.{{ARR_COL}}::FLOAT                                      AS arr,
    IFF(a.{{SEGMENT_COL}} = 'SMB', 1, 0)                      AS seg_smb,
    IFF(a.{{SEGMENT_COL}} = 'MID_MARKET', 1, 0)               AS seg_mid_market,
    IFF(a.{{SEGMENT_COL}} = 'ENTERPRISE', 1, 0)               AS seg_enterprise,
    DATEDIFF(day, a.{{CONTRACT_START_COL}}, sp.as_of_date)    AS tenure_days,
    -- usage
    u.util_last3, u.util_prior3, u.util_trend, u.logins_ratio, u.usage_months_available,
    -- text (zero-filled: no interactions is information, not missing data)
    COALESCE(t.n_interactions, 0)            AS n_interactions,
    COALESCE(t.n_risk_interactions, 0)       AS n_risk_interactions,
    COALESCE(t.n_reason_price_value, 0)      AS n_reason_price_value,
    COALESCE(t.n_reason_product_gap, 0)      AS n_reason_product_gap,
    COALESCE(t.n_reason_reliability, 0)      AS n_reason_reliability,
    COALESCE(t.n_reason_support, 0)          AS n_reason_support,
    COALESCE(t.n_reason_adoption, 0)         AS n_reason_adoption,
    COALESCE(t.n_reason_competitor, 0)       AS n_reason_competitor,
    COALESCE(t.n_reason_business_change, 0)  AS n_reason_business_change,
    COALESCE(t.n_reason_champion_loss, 0)    AS n_reason_champion_loss,
    COALESCE(t.n_intent_high, 0)             AS n_intent_high,
    COALESCE(t.n_intent_medium, 0)           AS n_intent_medium,
    COALESCE(t.max_intent_score, 0)          AS max_intent_score,
    COALESCE(t.n_unresolved_risk, 0)         AS n_unresolved_risk,
    COALESCE(t.share_negative, 0)            AS share_negative,
    COALESCE(t.n_neg_support, 0)             AS n_neg_support,
    COALESCE(t.n_neg_price, 0)               AS n_neg_price,
    COALESCE(t.competitor_mentioned, 0)      AS competitor_mentioned,
    COALESCE(t.days_since_last_risk, {{LOOKBACK_DAYS}} + 1) AS days_since_last_risk,
    -- audit columns: never model inputs
    t.max_text_ts_used,
    u.max_usage_month_used,
    CURRENT_TIMESTAMP()                       AS built_at
FROM FEATURE_SPINE sp
JOIN {{ACCOUNT_TABLE}} a ON a.account_id = sp.account_id
LEFT JOIN FEAT_TEXT  t   ON t.account_id = sp.account_id AND t.as_of_date = sp.as_of_date
LEFT JOIN FEAT_USAGE u   ON u.account_id = sp.account_id AND u.as_of_date = sp.as_of_date;

-- ---------------------------------------------------------------------
-- 5. Gate verification.
-- ---------------------------------------------------------------------
SELECT split,
       COUNT(*)                                   AS rows,
       SUM(churned)                               AS churners,
       ROUND(AVG(churned), 4)                     AS churn_rate,
       MIN(as_of_date)                            AS min_as_of,
       MAX(as_of_date)                            AS max_as_of,
       COUNT_IF(util_last3 IS NULL)               AS rows_no_usage,
       COUNT_IF(n_interactions = 0)               AS rows_no_text
FROM ACCOUNT_FEATURES
GROUP BY split ORDER BY split;
