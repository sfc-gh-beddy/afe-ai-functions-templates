-- =====================================================================
-- Phase 3 prelude: render the AI_CLASSIFY categories literal from the
-- taxonomy, and estimate input tokens before any batch AI call.
--
-- SUBSTITUTE: {{DB}}.{{SCHEMA}}, {{SOURCE_TABLE}}, {{TEXT_COL}},
--             {{EVIDENCE_MODEL}}, {{SAMPLE_N}} (e.g. 500)
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Render the categories literal. Paste the output into
--    01_extract_signals.sql as {{CATEGORIES_LITERAL}} and record its
--    SHA2 in churn-project.yml (extraction.categories_hash). Rendering to
--    a literal, rather than passing a subquery, keeps every run's prompt
--    inspectable and hashable.
-- ---------------------------------------------------------------------
SELECT
    '[' || LISTAGG(
        '{''label'': ''' || REPLACE(label, '''', '''''') || ''', ''description'': '''
                         || REPLACE(description, '''', '''''') || '''}',
        ', ') WITHIN GROUP (ORDER BY sort_order) || ']'           AS categories_literal,
    COUNT(*)                                                       AS n_categories,
    SHA2(LISTAGG(label || '|' || description, '||') WITHIN GROUP (ORDER BY sort_order), 256) AS categories_hash
FROM REASON_TAXONOMY;

-- Guardrails on the taxonomy itself. Each failure here degrades
-- classification accuracy silently, so stop and fix before extracting.
SELECT
    COUNT(*)                                                        AS n_labels,
    COUNT(*) > 20                                                   AS too_many_labels,       -- docs: >20 may reduce accuracy
    COUNT_IF(label <> LOWER(label))                                 AS labels_with_capitals,  -- labels are case sensitive; keep one convention
    COUNT_IF(REGEXP_LIKE(label, '.*[^a-z ].*'))                     AS labels_with_special_chars,
    COUNT_IF(reason_code = 'NONE')                                  AS has_none_label,        -- must be exactly 1
    COUNT(*) - COUNT(DISTINCT LOWER(label))                         AS duplicate_labels
FROM REASON_TAXONOMY;

-- ---------------------------------------------------------------------
-- 2. Sample-based token estimate. AI_COUNT_TOKENS estimates INPUT tokens
--    only, and AI_CLASSIFY adds its own prompt on top of the text, so
--    treat every figure as a floor. Output tokens bill on top.
--    return_error_details is not used here: a NULL count would read as
--    zero tokens, so check null_counts instead.
-- ---------------------------------------------------------------------
WITH s AS (
    SELECT {{TEXT_COL}} AS body
    FROM {{SOURCE_TABLE}}
    WHERE {{TEXT_COL}} IS NOT NULL
    SAMPLE ({{SAMPLE_N}} ROWS)
),
t AS (
    SELECT
        AI_COUNT_TOKENS('ai_sentiment', body)                                AS sentiment_tokens,
        AI_COUNT_TOKENS('ai_classify', body,
            ['price or value concerns', 'missing product capability',
             'reliability or performance problems', 'poor support experience',
             'low adoption or onboarding difficulty', 'evaluating a competitor',
             'budget cuts or business change', 'loss of internal champion',
             'no retention risk'])                                           AS classify_tokens,
        AI_COUNT_TOKENS('ai_complete', '{{EVIDENCE_MODEL}}', body)           AS evidence_text_tokens
    FROM s
)
SELECT
    COUNT(*)                                       AS sampled_rows,
    ROUND(AVG(sentiment_tokens), 0)                AS avg_sentiment_in,
    MAX(sentiment_tokens)                          AS max_sentiment_in,
    COUNT_IF(sentiment_tokens > 2048)              AS rows_over_sentiment_window,  -- these ERROR in AI_SENTIMENT
    ROUND(AVG(classify_tokens), 0)                 AS avg_classify_in,
    ROUND(AVG(evidence_text_tokens), 0)            AS avg_evidence_text_in,
    COUNT_IF(sentiment_tokens IS NULL OR classify_tokens IS NULL
             OR evidence_text_tokens IS NULL)      AS null_counts
FROM t;

-- Scale to the full table. The evidence stage runs only on rows the
-- classifier flags, so its total is (flag rate x rows), and the flag rate
-- is unknown until a sample run. Report a range using the sample's
-- observed flag rate, not an assumed one.
SELECT COUNT(*) AS rows_to_process,
       COUNT_IF({{TEXT_COL}} IS NULL OR LENGTH(TRIM({{TEXT_COL}})) < 15) AS rows_excluded
FROM {{SOURCE_TABLE}};
