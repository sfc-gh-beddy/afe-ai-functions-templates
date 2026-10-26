-- =====================================================================
-- Seed verification. Run after 01_seed_sandbox.sql and show every result.
-- Each check names the failure it catches. Same placeholders as 01.
-- These queries read the quarantined schema; that is allowed here and in
-- the evaluation harness only.
-- =====================================================================

-- 1. Every feedback row has labels, and every label points at a row.
--    A mismatch means the plan and the composed text diverged (usually a
--    non-materialized RANDOM() re-roll), and every metric would be noise.
SELECT 'feedback_without_row_label' AS check_name, COUNT(*) AS bad_rows
FROM {{SCHEMA}}.SYNTH_FEEDBACK f
LEFT JOIN {{EVAL_SCHEMA}}.SYNTH_LABEL_ROWS r ON r.feedback_id = f.feedback_id
WHERE r.feedback_id IS NULL
UNION ALL
SELECT 'row_label_without_feedback', COUNT(*)
FROM {{EVAL_SCHEMA}}.SYNTH_LABEL_ROWS r
LEFT JOIN {{SCHEMA}}.SYNTH_FEEDBACK f ON f.feedback_id = r.feedback_id
WHERE f.feedback_id IS NULL
UNION ALL
SELECT 'feedback_rows_with_no_topic_label', COUNT(*)
FROM {{EVAL_SCHEMA}}.SYNTH_LABEL_ROWS r
WHERE r.is_feedback
  AND NOT EXISTS (SELECT 1 FROM {{EVAL_SCHEMA}}.SYNTH_LABEL_TOPICS t
                  WHERE t.feedback_id = r.feedback_id AND t.taxonomy_version = 'v1');
-- Expect 0 for all three.

-- 2. Composed text actually contains its fragments. Catches a plan/text
--    divergence that check 1 cannot see (ids line up, content does not).
SELECT COUNT(*) AS fragments_missing_from_text
FROM {{EVAL_SCHEMA}}.SYNTH_FEEDBACK_PLAN p
JOIN {{EVAL_SCHEMA}}.SYNTH_FRAGMENTS fr ON fr.fragment_id = p.fragment_id
JOIN {{SCHEMA}}.SYNTH_FEEDBACK f       ON f.feedback_id  = p.feedback_id
WHERE POSITION(fr.fragment_text IN f.feedback_text) = 0;
-- Expect 0.

-- 3. Label distribution. Every taxonomy L1 must have enough support for
--    precision and recall to mean anything; a node with a handful of rows
--    produces a metric with no confidence.
SELECT topic_l1, topic_l2, COUNT(DISTINCT feedback_id) AS rows_labeled
FROM {{EVAL_SCHEMA}}.SYNTH_LABEL_TOPICS
WHERE taxonomy_version = 'v1'
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

-- 4. Aspect truth uses all four AI_SENTIMENT polarities that matter.
--    If 'mixed' is absent the within-aspect conflict case is untested.
SELECT expected_sentiment, COUNT(*) AS aspect_claims
FROM {{EVAL_SCHEMA}}.SYNTH_LABEL_ASPECTS
GROUP BY 1 ORDER BY 2 DESC;

-- 5. Emerging themes accelerate. Weekly volume for each planted theme
--    should be zero before onset and rising after; if flat, the trend
--    detector has nothing distinguishable from background to find.
SELECT r.emerging_theme,
       DATE_TRUNC('WEEK', f.created_at) AS week_start,
       COUNT(*) AS mentions
FROM {{EVAL_SCHEMA}}.SYNTH_LABEL_ROWS r
JOIN {{SCHEMA}}.SYNTH_FEEDBACK f ON f.feedback_id = r.feedback_id
WHERE r.emerging_theme IS NOT NULL
GROUP BY 1, 2
ORDER BY 1, 2;

-- 6. Planted themes fall outside taxonomy v1 at L2. If v1 already has a
--    'Hinge Breakage' node the drift test is meaningless.
SELECT t.topic_l2
FROM {{EVAL_SCHEMA}}.SYNTH_LABEL_EMERGING e
JOIN {{DB}}.{{TAXONOMY_SCHEMA}}.VOC_TAXONOMY t
  ON t.topic_l2 = e.v2_topic_l2 AND t.taxonomy_version = 'v1';
-- Expect 0 rows. (Run after build-voc-taxonomy has loaded v1.)

-- 7. The traps are present.
SELECT case_role, COUNT(*) AS n
FROM {{EVAL_SCHEMA}}.SYNTH_LABEL_ROWS
WHERE case_role <> 'BACKGROUND'
GROUP BY 1 ORDER BY 1;

-- Syndicated duplicates: same author, same text, different source_system.
-- Template collisions: same text, DIFFERENT authors -- must NOT be deduped.
SELECT feedback_text,
       COUNT(*)                      AS rows_with_text,
       COUNT(DISTINCT author_handle) AS authors,
       COUNT(DISTINCT source_system) AS systems
FROM {{SCHEMA}}.SYNTH_FEEDBACK
GROUP BY 1
HAVING COUNT(*) > 1 AND LENGTH(feedback_text) < 200
ORDER BY rows_with_text DESC
LIMIT 10;
-- Expect at least: one text with 1 author / 3 systems (syndication),
-- one with 3 authors (template collision), one with 3 spam handles.

-- 8. The over-window case is actually over the AI_SENTIMENT window.
--    AI_COUNT_TOKENS on ai_sentiment is exact for the default model.
SELECT feedback_id,
       AI_COUNT_TOKENS('ai_sentiment', feedback_text) AS sentiment_tokens
FROM {{SCHEMA}}.SYNTH_FEEDBACK
WHERE feedback_id = 'SYN-FB-H016';
-- Expect well above 2048. If not, raise the REPEAT count in 01.

-- 9. Quarantine. Nothing label-bearing is in the pipeline schema.
SELECT table_name
FROM {{DB}}.information_schema.tables
WHERE table_schema = '{{SCHEMA}}'
  AND (table_name ILIKE '%LABEL%' OR table_name ILIKE '%FRAGMENT%'
       OR table_name ILIKE '%PLAN%' OR table_name ILIKE '%ANSWER%');
-- Expect 0 rows.
