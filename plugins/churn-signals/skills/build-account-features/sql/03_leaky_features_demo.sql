-- =====================================================================
-- SANDBOX ONLY. A deliberately leaky feature table, built so the
-- evaluation can show -- on the customer's own screen -- what leakage
-- looks like: near-perfect AUC that collapses on honest features.
--
-- Never train a production model on this table. Never run this against
-- customer data: the point is the contrast on known synthetic truth.
--
-- The three leaks, matching the traps planted by the seed:
--   1. CRM status column used as a feature
--   2. text features computed over ALL interactions (no as_of cutoff),
--      so the non-renewal notice and exit survey are inputs
--   3. usage "last 3 months" anchored on the renewal date, so the
--      post-churn zero month is an input
--
-- SUBSTITUTE: {{DB}}.{{SCHEMA}}, {{RUN_ID}}
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};

CREATE OR REPLACE TABLE ACCOUNT_FEATURES_LEAKY AS
WITH txt AS (
    SELECT sp.account_id, sp.renewal_date,
           COUNT_IF(ARRAY_SIZE(sig.reason_codes) > 0)   AS n_risk_interactions,
           COUNT_IF(sig.churn_intent = 'high')          AS n_intent_high,
           MAX(DECODE(sig.churn_intent, 'high', 3, 'medium', 2, 'low', 1, 0)) AS max_intent_score
    FROM FEATURE_SPINE sp
    LEFT JOIN INTERACTION_SIGNALS sig
      ON sig.account_id = sp.account_id AND sig.run_id = '{{RUN_ID}}'     -- LEAK 2: no cutoff
    GROUP BY 1, 2
),
usage_w AS (
    SELECT sp.account_id, sp.renewal_date,
           AVG(u.active_users / NULLIF(u.seats_purchased, 0)) AS util_last3
    FROM FEATURE_SPINE sp
    JOIN SYN_USAGE_MONTHLY u
      ON u.account_id = sp.account_id
     AND u.usage_month BETWEEN DATEADD(month, -2, DATE_TRUNC(month, sp.renewal_date))
                           AND DATE_TRUNC(month, sp.renewal_date)       -- LEAK 3: anchored on renewal
    GROUP BY 1, 2
)
SELECT f.account_id, f.as_of_date, f.renewal_date, f.split, f.churned,
       f.arr, f.seg_smb, f.seg_mid_market, f.seg_enterprise, f.tenure_days,
       u.util_last3,
       COALESCE(t.n_risk_interactions, 0) AS n_risk_interactions,
       COALESCE(t.n_intent_high, 0)       AS n_intent_high,
       COALESCE(t.max_intent_score, 0)    AS max_intent_score,
       IFF(a.crm_status = 'CHURNED', 1, 0) AS crm_status_churned            -- LEAK 1
FROM ACCOUNT_FEATURES f
JOIN SYN_ACCOUNTS a USING (account_id)
LEFT JOIN txt t ON t.account_id = f.account_id AND t.renewal_date = f.renewal_date
LEFT JOIN usage_w u ON u.account_id = f.account_id AND u.renewal_date = f.renewal_date
WHERE f.split IN ('TRAIN', 'TEST');
