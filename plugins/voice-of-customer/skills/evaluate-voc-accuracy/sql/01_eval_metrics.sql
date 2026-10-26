-- =====================================================================
-- Voice-of-customer accuracy, cost and failure accounting.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}                 database
--   {{PIPE}}               pipeline schema (VOC_FEEDBACK_STG, VOC_TOPICS, ...)
--   {{TAX}}                taxonomy schema
--   {{EVAL}}               quarantined eval schema (answer key)
--   {{EXPERIMENT_ID}}      experiment to score
--   {{RUN_ID}}             run to score
--   {{TAXONOMY_VERSION}}   taxonomy version the run used (v1 | v2 | ...)
--
-- For a customer build, the answer key is the labeled real sample in
-- {{EVAL}} (see SKILL.md, "Labeling real data"), with the same shapes:
--   LABEL_ROWS(feedback_id, is_feedback, canonical_feedback_id, expected_sku,
--              expected_language, expected_return_intent, expected_overall, case_role)
--   LABEL_TOPICS(feedback_id, taxonomy_version, topic_l1, topic_l2)
--   LABEL_ASPECTS(feedback_id, aspect, expected_sentiment)
-- Sandbox names are SYNTH_LABEL_*; replace the table names, not the logic.
--
-- Every metric is built FROM ground truth outward. An item the pipeline
-- excluded, errored on, or returned nothing for counts as false negatives
-- for every label it carries.
-- =====================================================================

USE DATABASE {{DB}};

-- ---------------------------------------------------------------------
-- 0. Few-shot leakage. Fail the evaluation if any example text is a
--    labeled item. Normalized comparison, both sides the same expression.
-- ---------------------------------------------------------------------
SELECT COUNT(*) AS leaked_examples
FROM {{TAX}}.VOC_TAXONOMY_EXAMPLES x
JOIN {{PIPE}}.VOC_FEEDBACK_STG f
  ON LOWER(REGEXP_REPLACE(TRIM(x.example_input), '\\s+', ' '))
   = LOWER(REGEXP_REPLACE(TRIM(f.original_text), '\\s+', ' '))
JOIN {{EVAL}}.SYNTH_LABEL_ROWS r ON r.feedback_id = f.feedback_id;
-- Expect 0. Non-zero invalidates every topic metric below.

-- ---------------------------------------------------------------------
-- 1. Scoring universe: canonical, genuine feedback items in the key.
--    Duplicates are scored once (via the canonical id) and dedup is
--    measured on its own in section 7.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{EVAL}}.EVAL_UNIVERSE AS
SELECT r.*
FROM {{EVAL}}.SYNTH_LABEL_ROWS r
WHERE r.is_feedback
  AND r.feedback_id = r.canonical_feedback_id;

-- ---------------------------------------------------------------------
-- 2. Topic L1: multi-label set comparison, one row per (item, label).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{EVAL}}.EVAL_TOPIC_L1_PAIRS AS
WITH truth AS (
    SELECT DISTINCT t.feedback_id, t.topic_l1 AS label
    FROM {{EVAL}}.SYNTH_LABEL_TOPICS t
    JOIN {{EVAL}}.EVAL_UNIVERSE u ON u.feedback_id = t.feedback_id
    WHERE t.taxonomy_version = '{{TAXONOMY_VERSION}}'
),
pred AS (
    -- Predictions on every canonical item, including non-feedback items the
    -- gate let through: a topic assigned to spam is a false positive.
    SELECT DISTINCT p.feedback_id, p.topic_l1 AS label
    FROM {{PIPE}}.VOC_TOPICS p
    JOIN {{EVAL}}.SYNTH_LABEL_ROWS r
      ON r.feedback_id = p.feedback_id AND r.feedback_id = r.canonical_feedback_id
    WHERE p.experiment_id = '{{EXPERIMENT_ID}}'
      AND p.taxonomy_version = '{{TAXONOMY_VERSION}}'
)
SELECT COALESCE(t.feedback_id, p.feedback_id) AS feedback_id,
       COALESCE(t.label, p.label)             AS label,
       t.label IS NOT NULL                    AS in_truth,
       p.label IS NOT NULL                    AS in_pred
FROM truth t
FULL OUTER JOIN pred p
  ON p.feedback_id = t.feedback_id AND p.label = t.label;

-- ---------------------------------------------------------------------
-- 3. Topic L2: scored only where L2 is labeled, and only under the right
--    parent. Predictions under an L1 whose truth is L1-only are excluded
--    rather than counted wrong.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{EVAL}}.EVAL_TOPIC_L2_PAIRS AS
WITH truth AS (
    SELECT DISTINCT t.feedback_id, t.topic_l1 || ' > ' || t.topic_l2 AS label, t.topic_l1
    FROM {{EVAL}}.SYNTH_LABEL_TOPICS t
    JOIN {{EVAL}}.EVAL_UNIVERSE u ON u.feedback_id = t.feedback_id
    WHERE t.taxonomy_version = '{{TAXONOMY_VERSION}}' AND t.topic_l2 IS NOT NULL
),
l1_only AS (
    SELECT DISTINCT t.feedback_id, t.topic_l1
    FROM {{EVAL}}.SYNTH_LABEL_TOPICS t
    WHERE t.taxonomy_version = '{{TAXONOMY_VERSION}}' AND t.topic_l2 IS NULL
      AND NOT EXISTS (SELECT 1 FROM {{EVAL}}.SYNTH_LABEL_TOPICS t2
                      WHERE t2.feedback_id = t.feedback_id AND t2.taxonomy_version = t.taxonomy_version
                        AND t2.topic_l1 = t.topic_l1 AND t2.topic_l2 IS NOT NULL)
),
pred AS (
    SELECT DISTINCT p.feedback_id, p.topic_l1 || ' > ' || p.topic_l2 AS label, p.topic_l1
    FROM {{PIPE}}.VOC_TOPICS p
    JOIN {{EVAL}}.SYNTH_LABEL_ROWS r
      ON r.feedback_id = p.feedback_id AND r.feedback_id = r.canonical_feedback_id
    WHERE p.experiment_id = '{{EXPERIMENT_ID}}'
      AND p.taxonomy_version = '{{TAXONOMY_VERSION}}'
      AND p.topic_l2 IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM l1_only o
                      WHERE o.feedback_id = p.feedback_id AND o.topic_l1 = p.topic_l1)
)
SELECT COALESCE(t.feedback_id, p.feedback_id) AS feedback_id,
       COALESCE(t.label, p.label)             AS label,
       COALESCE(t.topic_l1, p.topic_l1)       AS topic_l1,
       t.label IS NOT NULL                    AS in_truth,
       p.label IS NOT NULL                    AS in_pred
FROM truth t
FULL OUTER JOIN pred p
  ON p.feedback_id = t.feedback_id AND p.label = t.label;

-- Micro and macro P/R/F1 for both levels.
CREATE OR REPLACE VIEW {{EVAL}}.EVAL_TOPIC_METRICS AS
WITH pairs AS (
    SELECT 'L1' AS level, label, in_truth, in_pred FROM {{EVAL}}.EVAL_TOPIC_L1_PAIRS
    UNION ALL
    SELECT 'L2', label, in_truth, in_pred FROM {{EVAL}}.EVAL_TOPIC_L2_PAIRS
),
per_label AS (
    SELECT level, label,
           COUNT_IF(in_truth AND in_pred)     AS tp,
           COUNT_IF(in_pred AND NOT in_truth) AS fp,
           COUNT_IF(in_truth AND NOT in_pred) AS fn,
           COUNT_IF(in_truth)                 AS support
    FROM pairs GROUP BY 1, 2
),
scored AS (
    SELECT p.*,
           tp / NULLIF(tp + fp, 0) AS precision,
           tp / NULLIF(tp + fn, 0) AS recall,
           2 * tp / NULLIF(2 * tp + fp + fn, 0) AS f1
    FROM per_label p
)
SELECT level,
       SUM(tp) / NULLIF(SUM(tp) + SUM(fp), 0)                 AS micro_precision,
       SUM(tp) / NULLIF(SUM(tp) + SUM(fn), 0)                 AS micro_recall,
       2 * SUM(tp) / NULLIF(2 * SUM(tp) + SUM(fp) + SUM(fn), 0) AS micro_f1,
       -- Macro over labels that have support; a label never in truth has no recall.
       AVG(IFF(support > 0, precision, NULL))                 AS macro_precision,
       AVG(IFF(support > 0, recall, NULL))                    AS macro_recall,
       AVG(IFF(support > 0, f1, NULL))                        AS macro_f1,
       MIN(IFF(support > 0, f1, NULL))                        AS worst_label_f1,
       COUNT_IF(support > 0)                                  AS labels_scored,
       COUNT_IF(support = 0 AND fp > 0)                       AS labels_predicted_never_true
FROM scored
GROUP BY level;

-- Per-label detail: show this table, sorted worst first.
CREATE OR REPLACE VIEW {{EVAL}}.EVAL_TOPIC_PER_LABEL AS
SELECT level, label,
       COUNT_IF(in_truth AND in_pred)     AS tp,
       COUNT_IF(in_pred AND NOT in_truth) AS fp,
       COUNT_IF(in_truth AND NOT in_pred) AS fn,
       COUNT_IF(in_truth AND in_pred) / NULLIF(COUNT_IF(in_pred), 0)  AS precision,
       COUNT_IF(in_truth AND in_pred) / NULLIF(COUNT_IF(in_truth), 0) AS recall
FROM (SELECT 'L1' AS level, label, in_truth, in_pred FROM {{EVAL}}.EVAL_TOPIC_L1_PAIRS
      UNION ALL
      SELECT 'L2', label, in_truth, in_pred FROM {{EVAL}}.EVAL_TOPIC_L2_PAIRS)
GROUP BY 1, 2;

-- Recall by slice: case role, channel, translated. A slice far below the
-- aggregate is a blind spot the aggregate hides.
SELECT u.case_role, s.source_channel, s.was_translated,
       COUNT_IF(pr.in_truth)                                         AS truth_labels,
       COUNT_IF(pr.in_truth AND pr.in_pred) / NULLIF(COUNT_IF(pr.in_truth), 0) AS l1_recall,
       COUNT_IF(pr.in_pred AND NOT pr.in_truth)                      AS l1_false_positives
FROM {{EVAL}}.EVAL_TOPIC_L1_PAIRS pr
JOIN {{EVAL}}.SYNTH_LABEL_ROWS u ON u.feedback_id = pr.feedback_id
LEFT JOIN {{PIPE}}.VOC_FEEDBACK_STG s ON s.feedback_id = pr.feedback_id
GROUP BY 1, 2, 3
ORDER BY l1_recall NULLS FIRST;

-- ---------------------------------------------------------------------
-- 4. Aspect sentiment. Universe = every scored item x every bound aspect,
--    so "not mentioned" is truth too. Missing predictions are 'MISSING',
--    not unknown: an error must not score as a correct "not mentioned".
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{EVAL}}.EVAL_ASPECT_PAIRS AS
WITH aspects AS (
    SELECT a.value::STRING AS aspect
    FROM {{TAX}}.VOC_TAXONOMY_ASPECTS v, LATERAL FLATTEN(input => v.aspects) a
    WHERE v.taxonomy_version = '{{TAXONOMY_VERSION}}'
),
grid AS (
    SELECT u.feedback_id, u.case_role, a.aspect FROM {{EVAL}}.EVAL_UNIVERSE u CROSS JOIN aspects a
)
SELECT g.feedback_id, g.case_role, g.aspect,
       COALESCE(t.expected_sentiment, 'unknown')  AS truth_sentiment,
       COALESCE(p.sentiment, 'MISSING')           AS pred_sentiment
FROM grid g
LEFT JOIN {{EVAL}}.SYNTH_LABEL_ASPECTS t
  ON t.feedback_id = g.feedback_id AND t.aspect = g.aspect
LEFT JOIN {{PIPE}}.VOC_ASPECT_SENTIMENT p
  ON p.feedback_id = g.feedback_id AND p.aspect = g.aspect
 AND p.experiment_id = '{{EXPERIMENT_ID}}';

CREATE OR REPLACE VIEW {{EVAL}}.EVAL_ASPECT_METRICS AS
SELECT
    -- Detection: was the aspect mentioned?
    COUNT_IF(truth_sentiment <> 'unknown' AND pred_sentiment NOT IN ('unknown', 'MISSING'))
      / NULLIF(COUNT_IF(pred_sentiment NOT IN ('unknown', 'MISSING')), 0)   AS detection_precision,
    COUNT_IF(truth_sentiment <> 'unknown' AND pred_sentiment NOT IN ('unknown', 'MISSING'))
      / NULLIF(COUNT_IF(truth_sentiment <> 'unknown'), 0)                   AS detection_recall,
    -- Polarity, given both sides say mentioned.
    COUNT_IF(truth_sentiment <> 'unknown' AND pred_sentiment = truth_sentiment)
      / NULLIF(COUNT_IF(truth_sentiment <> 'unknown' AND pred_sentiment NOT IN ('unknown', 'MISSING')), 0)
                                                                            AS polarity_accuracy_when_detected,
    -- End to end: exact five-way agreement on mentioned aspects.
    COUNT_IF(truth_sentiment <> 'unknown' AND pred_sentiment = truth_sentiment)
      / NULLIF(COUNT_IF(truth_sentiment <> 'unknown'), 0)                   AS mentioned_aspect_accuracy,
    -- Micro F1 over mentioned (aspect, polarity) claims.
    2 * COUNT_IF(truth_sentiment <> 'unknown' AND pred_sentiment = truth_sentiment)
      / NULLIF(COUNT_IF(truth_sentiment <> 'unknown')
             + COUNT_IF(pred_sentiment NOT IN ('unknown', 'MISSING')), 0)   AS aspect_claim_f1,
    COUNT_IF(pred_sentiment = 'MISSING')                                    AS missing_predictions
FROM {{EVAL}}.EVAL_ASPECT_PAIRS;

-- Per-polarity precision and recall over mentioned aspects.
SELECT cls,
       COUNT_IF(truth_sentiment = cls AND pred_sentiment = cls) / NULLIF(COUNT_IF(pred_sentiment = cls), 0) AS precision,
       COUNT_IF(truth_sentiment = cls AND pred_sentiment = cls) / NULLIF(COUNT_IF(truth_sentiment = cls), 0) AS recall,
       COUNT_IF(truth_sentiment = cls)                                                                   AS support
FROM {{EVAL}}.EVAL_ASPECT_PAIRS
CROSS JOIN (SELECT column1 AS cls FROM VALUES ('positive'), ('negative'), ('mixed'), ('neutral')) c
GROUP BY cls ORDER BY cls;

-- Full confusion matrix, including unknown and MISSING.
SELECT truth_sentiment, pred_sentiment, COUNT(*) AS n
FROM {{EVAL}}.EVAL_ASPECT_PAIRS
GROUP BY 1, 2 ORDER BY 1, 2;

-- Hard cases, one line each. This is the table to read with the customer.
SELECT case_role, feedback_id, aspect, truth_sentiment, pred_sentiment,
       truth_sentiment = pred_sentiment AS correct
FROM {{EVAL}}.EVAL_ASPECT_PAIRS
WHERE case_role <> 'BACKGROUND' AND (truth_sentiment <> 'unknown' OR pred_sentiment <> 'unknown')
ORDER BY correct, case_role, feedback_id;

-- Overall sentiment versus the item-level truth.
SELECT u.case_role,
       COUNT(*)                                                     AS items,
       COUNT_IF(COALESCE(p.sentiment, 'MISSING') = u.expected_overall) / COUNT(*) AS overall_accuracy
FROM {{EVAL}}.EVAL_UNIVERSE u
LEFT JOIN {{PIPE}}.VOC_ASPECT_SENTIMENT p
  ON p.feedback_id = u.feedback_id AND p.aspect = 'overall' AND p.experiment_id = '{{EXPERIMENT_ID}}'
WHERE u.expected_overall IS NOT NULL
GROUP BY 1 ORDER BY 3;

-- Star rating is NOT a label: show how often it disagrees with text truth,
-- so nobody is tempted to use it as one.
SELECT f.star_rating, u.expected_overall, COUNT(*) AS items
FROM {{EVAL}}.EVAL_UNIVERSE u
JOIN {{PIPE}}.VOC_FEEDBACK_STG f ON f.feedback_id = u.feedback_id
WHERE f.star_rating IS NOT NULL
GROUP BY 1, 2 ORDER BY 1, 2;

-- ---------------------------------------------------------------------
-- 5. Topic-level sentiment, end to end: the number a dashboard shows.
--    True positive = right topic AND right sentiment for that topic.
-- ---------------------------------------------------------------------
WITH truth AS (
    SELECT DISTINCT t.feedback_id, t.topic_l1, a.expected_sentiment
    FROM {{EVAL}}.SYNTH_LABEL_TOPICS t
    JOIN {{EVAL}}.EVAL_UNIVERSE u ON u.feedback_id = t.feedback_id
    JOIN {{TAX}}.VOC_TAXONOMY x
      ON x.taxonomy_version = t.taxonomy_version AND x.topic_l1 = t.topic_l1
    JOIN {{EVAL}}.SYNTH_LABEL_ASPECTS a
      ON a.feedback_id = t.feedback_id AND a.aspect = x.aspect_name
    WHERE t.taxonomy_version = '{{TAXONOMY_VERSION}}'
),
pred AS (
    SELECT DISTINCT feedback_id, topic_l1, topic_sentiment
    FROM {{PIPE}}.VOC_TOPIC_SENTIMENT
    WHERE experiment_id = '{{EXPERIMENT_ID}}' AND taxonomy_version = '{{TAXONOMY_VERSION}}'
)
SELECT COUNT_IF(t.feedback_id IS NOT NULL AND p.topic_sentiment = t.expected_sentiment)
         / NULLIF(COUNT_IF(t.feedback_id IS NOT NULL), 0) AS topic_sentiment_recall,
       COUNT_IF(t.feedback_id IS NOT NULL AND p.topic_sentiment = t.expected_sentiment)
         / NULLIF(COUNT_IF(p.feedback_id IS NOT NULL AND p.topic_sentiment <> 'unknown'), 0) AS topic_sentiment_precision
FROM truth t
FULL OUTER JOIN pred p ON p.feedback_id = t.feedback_id AND p.topic_l1 = t.topic_l1;

-- ---------------------------------------------------------------------
-- 6. Derived flag: return intent (hard cases carry labels).
-- ---------------------------------------------------------------------
SELECT
    COUNT_IF(u.expected_return_intent AND ri.raw_response:value:labels[0]::STRING = 'Return intent')
      / NULLIF(COUNT_IF(ri.raw_response:value:labels[0]::STRING = 'Return intent'), 0) AS precision,
    COUNT_IF(u.expected_return_intent AND ri.raw_response:value:labels[0]::STRING = 'Return intent')
      / NULLIF(COUNT_IF(u.expected_return_intent), 0)                                 AS recall,
    COUNT_IF(u.expected_return_intent)                                                AS support
FROM {{EVAL}}.EVAL_UNIVERSE u
LEFT JOIN {{PIPE}}.VOC_RETURN_INTENT ri
  ON ri.feedback_id = u.feedback_id AND ri.experiment_id = '{{EXPERIMENT_ID}}'
WHERE u.expected_return_intent IS NOT NULL;

-- ---------------------------------------------------------------------
-- 7. Normalization: gate, dedup, language, SKU linking.
-- ---------------------------------------------------------------------
SELECT 'gate' AS step,
       COUNT_IF(NOT r.is_feedback AND s.exclusion_reason = 'NOT_FEEDBACK')
         / NULLIF(COUNT_IF(s.exclusion_reason = 'NOT_FEEDBACK'), 0)      AS precision_of_exclusion,
       COUNT_IF(NOT r.is_feedback AND s.exclusion_reason = 'NOT_FEEDBACK')
         / NULLIF(COUNT_IF(NOT r.is_feedback), 0)                         AS recall_of_exclusion,
       COUNT_IF(r.is_feedback AND s.exclusion_reason = 'NOT_FEEDBACK')    AS genuine_feedback_lost
FROM {{EVAL}}.SYNTH_LABEL_ROWS r
JOIN {{PIPE}}.VOC_FEEDBACK_STG s ON s.feedback_id = r.feedback_id
WHERE r.feedback_id = r.canonical_feedback_id;

SELECT r.case_role, r.feedback_id, r.canonical_feedback_id AS expected_canonical,
       s.canonical_feedback_id AS actual_canonical, s.exclusion_reason,
       EQUAL_NULL(r.canonical_feedback_id, s.canonical_feedback_id) AS correct
FROM {{EVAL}}.SYNTH_LABEL_ROWS r
JOIN {{PIPE}}.VOC_FEEDBACK_STG s ON s.feedback_id = r.feedback_id
WHERE r.case_role IN ('SYNDICATED_CANONICAL', 'SYNDICATED_DUPLICATE', 'TEMPLATE_COLLISION')
ORDER BY correct, r.feedback_id;

SELECT r.expected_language, s.original_language, COUNT(*) AS items
FROM {{EVAL}}.SYNTH_LABEL_ROWS r
JOIN {{PIPE}}.VOC_FEEDBACK_STG s ON s.feedback_id = r.feedback_id
WHERE r.expected_language <> 'en' OR s.original_language <> 'en'
GROUP BY 1, 2;

SELECT COUNT_IF(s.sku = r.expected_sku) / NULLIF(COUNT(*), 0) AS link_accuracy,
       COUNT_IF(s.sku_source = 'unresolved')                    AS unresolved,
       COUNT_IF(s.sku IS NOT NULL AND s.sku <> r.expected_sku)  AS wrong_link,
       COUNT(*)                                                 AS linkable_items
FROM {{EVAL}}.SYNTH_LABEL_ROWS r
JOIN {{PIPE}}.VOC_FEEDBACK_STG s ON s.feedback_id = r.feedback_id
WHERE s.sku_source IN ('linked', 'unresolved') AND r.expected_sku IS NOT NULL;

-- ---------------------------------------------------------------------
-- 8. Emerging themes: detection lag, false alarms, precursor.
--    Under v1 the planted themes live inside their v1 parent node; the
--    expected L2 is looked up through the version map.
-- ---------------------------------------------------------------------
WITH expected AS (
    SELECT e.*,
           IFF('{{TAXONOMY_VERSION}}' = 'v1',
               (SELECT MAX(m.from_l2) FROM {{TAX}}.VOC_TAXONOMY_MAP m
                WHERE m.to_version = 'v2' AND m.to_l2 = e.v2_topic_l2 AND m.from_version = 'v1'),
               e.v2_topic_l2) AS expected_l2
    FROM {{EVAL}}.SYNTH_LABEL_EMERGING e
)
SELECT x.theme_key, x.onset_week_start,
       MIN(s.week_start)                                    AS first_candidate_week,
       DATEDIFF(WEEK, x.onset_week_start, MIN(s.week_start)) AS lag_weeks
FROM expected x
LEFT JOIN {{PIPE}}.VOC_THEME_SCORES s
  ON s.is_candidate
 AND s.topic_l1 = x.topic_l1 AND s.topic_l2 = x.expected_l2
 AND EQUAL_NULL(s.sku, x.sku)
 AND EQUAL_NULL(s.region_code, x.region_code)
 AND EQUAL_NULL(s.source_channel, x.source_channel)
GROUP BY 1, 2;
-- NULL first_candidate_week = missed at the planted grain. Check coarser
-- grains and the sub-theme discovery output before concluding it was missed.

-- Candidates that do not correspond to a planted theme (false alarms), with
-- the number of series tested so the rate is interpretable.
SELECT COUNT(DISTINCT topic_l1 || '|' || topic_l2 || '|' || COALESCE(sku, '*') || '|'
             || COALESCE(region_code, '*') || '|' || COALESCE(source_channel, '*')) AS false_alarm_series,
       (SELECT COUNT(DISTINCT topic_l1 || '|' || topic_l2 || '|' || COALESCE(sku, '*') || '|'
                     || COALESCE(region_code, '*') || '|' || COALESCE(source_channel, '*'))
        FROM {{PIPE}}.VOC_THEME_SCORES)                                       AS series_tested
FROM {{PIPE}}.VOC_THEME_SCORES s
WHERE s.is_candidate
  AND NOT (s.topic_l1 = 'Product Quality' AND COALESCE(s.sku, 'SYN-SKU-HP-200') = 'SYN-SKU-HP-200'
           AND COALESCE(s.region_code, 'SYN-EU') = 'SYN-EU')
  AND NOT (s.topic_l1 = 'Price and Value' AND COALESCE(s.source_channel, 'SOCIAL') = 'SOCIAL');

-- The single week-2 hinge precursor in SYN-NAE must not fire.
SELECT COUNT(*) AS precursor_false_alarms
FROM {{PIPE}}.VOC_THEME_SCORES
WHERE is_candidate AND sku = 'SYN-SKU-HP-200' AND region_code = 'SYN-NAE'
  AND topic_l1 = 'Product Quality';
-- Expect 0.

-- Did discovery name the themes? Show the closest proposal per theme for a
-- human to judge, with a similarity score as a sorting aid only.
SELECT e.theme_key, p.value:label::STRING AS proposed_label,
       p.value:description::STRING AS proposed_description,
       AI_SIMILARITY(e.description, p.value:label::STRING || '. ' || p.value:description::STRING) AS similarity
FROM {{EVAL}}.SYNTH_LABEL_EMERGING e
CROSS JOIN {{PIPE}}.VOC_THEME_DISCOVERY d,
     LATERAL FLATTEN(input => d.response:structured_output[0]:raw_message:issues) p
WHERE d.run_id = '{{RUN_ID}}'
QUALIFY ROW_NUMBER() OVER (PARTITION BY e.theme_key ORDER BY similarity DESC) <= 3;

-- ---------------------------------------------------------------------
-- 9. Failure accounting. A recall claim without these numbers is not a claim.
-- ---------------------------------------------------------------------
SELECT stage, COUNT(*) AS errors, ANY_VALUE(error_message) AS sample_error
FROM {{PIPE}}.VOC_QUALITY_LOG
WHERE run_id = '{{RUN_ID}}'
GROUP BY 1 ORDER BY 2 DESC;

SELECT
    (SELECT COUNT(*) FROM {{PIPE}}.VOC_FEEDBACK_STG WHERE is_included)                      AS included,
    (SELECT COUNT(DISTINCT feedback_id) FROM {{PIPE}}.VOC_TOPICS
      WHERE experiment_id = '{{EXPERIMENT_ID}}')                                            AS with_topics,
    (SELECT COUNT(*) FROM {{PIPE}}.VOC_TOPICS_RAW
      WHERE experiment_id = '{{EXPERIMENT_ID}}' AND level = 'L1'
        AND raw_response:error IS NULL AND ARRAY_SIZE(raw_response:value:labels) = 0)       AS empty_l1,
    (SELECT COUNT(DISTINCT feedback_id) FROM {{PIPE}}.VOC_ASPECT_SENTIMENT
      WHERE experiment_id = '{{EXPERIMENT_ID}}' AND aspect = 'overall')                     AS with_sentiment,
    (SELECT COUNT(DISTINCT feedback_id) FROM {{PIPE}}.VOC_ASPECT_SENTIMENT
      WHERE experiment_id = '{{EXPERIMENT_ID}}' AND was_segmented)                          AS segmented;

-- ---------------------------------------------------------------------
-- 10. Cost per 1K items. The usage view has no timestamp: attribute via
--     QUERY_HISTORY on the run's QUERY_TAG ('voc:<run_id>'). Usage can lag
--     by a few hours. Tokens and credits only; never currency.
-- ---------------------------------------------------------------------
WITH usage AS (
    SELECT u.function_name, u.model_name, SUM(u.tokens) AS tokens, SUM(u.token_credits) AS credits
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY u
    JOIN SNOWFLAKE.ACCOUNT_USAGE.QUERY_HISTORY q ON q.query_id = u.query_id
    WHERE q.query_tag = 'voc:{{RUN_ID}}'
    GROUP BY 1, 2
),
n AS (SELECT COUNT(*) AS source_items FROM {{PIPE}}.VOC_FEEDBACK_STG)
SELECT u.function_name, u.model_name, u.tokens, u.credits,
       ROUND(1000 * u.tokens  / NULLIF(n.source_items, 0), 1) AS tokens_per_1k_source_items,
       ROUND(1000 * u.credits / NULLIF(n.source_items, 0), 4) AS credits_per_1k_source_items
FROM usage u CROSS JOIN n
ORDER BY u.tokens DESC;

-- ---------------------------------------------------------------------
-- 11. Persist the experiment summary (accumulates across runs).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS {{EVAL}}.EVAL_EXPERIMENT_SUMMARY (
    run_id VARCHAR, experiment_id VARCHAR, taxonomy_version VARCHAR, evaluated_at TIMESTAMP_NTZ,
    l1_micro_f1 FLOAT, l1_macro_f1 FLOAT, l1_micro_precision FLOAT, l1_micro_recall FLOAT,
    l2_micro_f1 FLOAT, l2_macro_f1 FLOAT,
    aspect_detection_recall FLOAT, aspect_polarity_accuracy FLOAT, aspect_micro_f1 FLOAT,
    missing_aspect_predictions INT
);

MERGE INTO {{EVAL}}.EVAL_EXPERIMENT_SUMMARY t
USING (
    SELECT '{{RUN_ID}}' AS run_id, '{{EXPERIMENT_ID}}' AS experiment_id,
           '{{TAXONOMY_VERSION}}' AS taxonomy_version, CURRENT_TIMESTAMP() AS evaluated_at,
           MAX(IFF(m.level = 'L1', m.micro_f1, NULL))        AS l1_micro_f1,
           MAX(IFF(m.level = 'L1', m.macro_f1, NULL))        AS l1_macro_f1,
           MAX(IFF(m.level = 'L1', m.micro_precision, NULL)) AS l1_micro_precision,
           MAX(IFF(m.level = 'L1', m.micro_recall, NULL))    AS l1_micro_recall,
           MAX(IFF(m.level = 'L2', m.micro_f1, NULL))        AS l2_micro_f1,
           MAX(IFF(m.level = 'L2', m.macro_f1, NULL))        AS l2_macro_f1,
           ANY_VALUE(a.detection_recall)                     AS aspect_detection_recall,
           ANY_VALUE(a.polarity_accuracy_when_detected)      AS aspect_polarity_accuracy,
           ANY_VALUE(a.aspect_claim_f1)                      AS aspect_micro_f1,
           ANY_VALUE(a.missing_predictions)                  AS missing_aspect_predictions
    FROM {{EVAL}}.EVAL_TOPIC_METRICS m
    CROSS JOIN {{EVAL}}.EVAL_ASPECT_METRICS a
) s
ON t.run_id = s.run_id AND t.experiment_id = s.experiment_id AND t.taxonomy_version = s.taxonomy_version
WHEN MATCHED THEN UPDATE SET
    evaluated_at = s.evaluated_at, l1_micro_f1 = s.l1_micro_f1, l1_macro_f1 = s.l1_macro_f1,
    l1_micro_precision = s.l1_micro_precision, l1_micro_recall = s.l1_micro_recall,
    l2_micro_f1 = s.l2_micro_f1, l2_macro_f1 = s.l2_macro_f1,
    aspect_detection_recall = s.aspect_detection_recall, aspect_polarity_accuracy = s.aspect_polarity_accuracy,
    aspect_micro_f1 = s.aspect_micro_f1, missing_aspect_predictions = s.missing_aspect_predictions
WHEN NOT MATCHED THEN INSERT VALUES (
    s.run_id, s.experiment_id, s.taxonomy_version, s.evaluated_at,
    s.l1_micro_f1, s.l1_macro_f1, s.l1_micro_precision, s.l1_micro_recall,
    s.l2_micro_f1, s.l2_macro_f1,
    s.aspect_detection_recall, s.aspect_polarity_accuracy, s.aspect_micro_f1, s.missing_aspect_predictions);
