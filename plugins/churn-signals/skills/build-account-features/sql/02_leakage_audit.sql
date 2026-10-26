-- =====================================================================
-- Phase 4 gate: label-leakage audit. Run after 01_build_features.sql and
-- again before every training run. Every check must return zero rows /
-- zero counts. A non-zero result blocks training -- it is not a warning.
--
-- SUBSTITUTE: {{DB}}.{{SCHEMA}}, {{OUTCOME_TABLE}}, {{ACCOUNT_TABLE}}
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Temporal: nothing used may be at or after as_of_date.
-- ---------------------------------------------------------------------
SELECT 'text_after_cutoff' AS check_name, COUNT(*) AS violations
FROM ACCOUNT_FEATURES
WHERE max_text_ts_used >= as_of_date::TIMESTAMP_NTZ
UNION ALL
SELECT 'usage_month_not_complete_before_cutoff', COUNT(*)
FROM ACCOUNT_FEATURES
WHERE DATEADD(month, 1, max_usage_month_used) > as_of_date
UNION ALL
-- 2. Label observation: the label must not have been known at as_of_date.
--    If the outcome was recorded (or notice given) before the prediction
--    point, the "prediction" is a lookup.
SELECT 'outcome_known_at_prediction_time', COUNT(*)
FROM ACCOUNT_FEATURES f
JOIN {{OUTCOME_TABLE}} o ON o.account_id = f.account_id AND o.renewal_date = f.renewal_date
WHERE f.split IN ('TRAIN', 'TEST')
  AND (o.recorded_at <= f.as_of_date::TIMESTAMP_NTZ
       OR (o.notice_date IS NOT NULL AND o.notice_date <= f.as_of_date))
UNION ALL
-- 3. Split hygiene: no account-renewal in both TRAIN and TEST, and no
--    TRAIN label observed after the first TEST prediction.
SELECT 'row_in_train_and_test', COUNT(*)
FROM (SELECT account_id, renewal_date FROM ACCOUNT_FEATURES
      WHERE split IN ('TRAIN', 'TEST')
      GROUP BY 1, 2 HAVING COUNT(DISTINCT split) > 1)
UNION ALL
SELECT 'train_label_after_first_test_prediction', COUNT(*)
FROM ACCOUNT_FEATURES tr
WHERE tr.split = 'TRAIN'
  AND tr.renewal_date >= (SELECT MIN(as_of_date) FROM ACCOUNT_FEATURES WHERE split = 'TEST');

-- ---------------------------------------------------------------------
-- 4. Forbidden columns. The feature table must not carry any column whose
--    name suggests it was written because of the outcome. Extend the
--    pattern with the customer's own CRM field names found at preflight.
-- ---------------------------------------------------------------------
SELECT column_name AS forbidden_feature_column
FROM information_schema.columns
WHERE table_schema = CURRENT_SCHEMA()
  AND table_name = 'ACCOUNT_FEATURES'
  AND REGEXP_LIKE(column_name,
      '.*(STATUS|CANCEL|CHURN_DATE|CHURN_REASON|NOTICE|TERMINAT|CLOSED|LOST|OUTCOME|RISK_FLAG).*', 'i');

-- ---------------------------------------------------------------------
-- 5. Single-feature separation. Any one feature that alone separates the
--    labels almost perfectly on TRAIN is a leak until proven otherwise.
--    Computes a rank-based AUC per feature (Mann-Whitney); flag > 0.95 or
--    < 0.05. Add columns here when the feature allowlist grows.
-- ---------------------------------------------------------------------
WITH typed AS (
    -- UNPIVOT requires one column type; cast the allowlist to FLOAT first.
    SELECT account_id, as_of_date, churned, split,
           arr::FLOAT AS arr, tenure_days::FLOAT AS tenure_days,
           util_last3::FLOAT AS util_last3, util_prior3::FLOAT AS util_prior3,
           util_trend::FLOAT AS util_trend, logins_ratio::FLOAT AS logins_ratio,
           n_interactions::FLOAT AS n_interactions, n_risk_interactions::FLOAT AS n_risk_interactions,
           n_reason_price_value::FLOAT AS n_reason_price_value, n_reason_product_gap::FLOAT AS n_reason_product_gap,
           n_reason_reliability::FLOAT AS n_reason_reliability, n_reason_support::FLOAT AS n_reason_support,
           n_reason_adoption::FLOAT AS n_reason_adoption, n_reason_competitor::FLOAT AS n_reason_competitor,
           n_reason_business_change::FLOAT AS n_reason_business_change, n_reason_champion_loss::FLOAT AS n_reason_champion_loss,
           n_intent_high::FLOAT AS n_intent_high, n_intent_medium::FLOAT AS n_intent_medium,
           max_intent_score::FLOAT AS max_intent_score, n_unresolved_risk::FLOAT AS n_unresolved_risk,
           share_negative::FLOAT AS share_negative, n_neg_support::FLOAT AS n_neg_support,
           n_neg_price::FLOAT AS n_neg_price, competitor_mentioned::FLOAT AS competitor_mentioned,
           days_since_last_risk::FLOAT AS days_since_last_risk
    FROM ACCOUNT_FEATURES
),
long AS (
    SELECT account_id, as_of_date, churned, feature, value
    FROM typed
    UNPIVOT INCLUDE NULLS (value FOR feature IN (
        arr, tenure_days, util_last3, util_prior3, util_trend, logins_ratio,
        n_interactions, n_risk_interactions, n_reason_price_value, n_reason_product_gap,
        n_reason_reliability, n_reason_support, n_reason_adoption, n_reason_competitor,
        n_reason_business_change, n_reason_champion_loss, n_intent_high, n_intent_medium,
        max_intent_score, n_unresolved_risk, share_negative, n_neg_support, n_neg_price,
        competitor_mentioned, days_since_last_risk))
    WHERE split = 'TRAIN'
),
ranked AS (
    SELECT feature, churned,
           -- average rank for ties (Mann-Whitney requires it; RANK alone biases count features)
           RANK() OVER (PARTITION BY feature ORDER BY COALESCE(value, -1e18))
             + (COUNT(*) OVER (PARTITION BY feature, COALESCE(value, -1e18)) - 1) / 2.0 AS r
    FROM long
),
auc AS (
    SELECT feature,
           SUM(churned)                     AS n_pos,
           SUM(1 - churned)                 AS n_neg,
           SUM(IFF(churned = 1, r, 0))      AS rank_sum_pos
    FROM ranked GROUP BY feature
)
SELECT feature,
       ROUND((rank_sum_pos - n_pos * (n_pos + 1) / 2) / NULLIF(n_pos * n_neg, 0), 4) AS single_feature_auc,
       ABS((rank_sum_pos - n_pos * (n_pos + 1) / 2) / NULLIF(n_pos * n_neg, 0) - 0.5) > 0.45 AS suspicious
FROM auc
ORDER BY ABS(single_feature_auc - 0.5) DESC;
-- NULLs rank lowest. A feature that is NULL for exactly one class (e.g.
-- usage that only exists for retained accounts) will show up here too --
-- which is the point.
