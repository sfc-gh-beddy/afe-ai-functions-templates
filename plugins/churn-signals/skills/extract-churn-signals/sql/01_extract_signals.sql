-- =====================================================================
-- Phase 3: per-interaction churn-signal extraction.
--
-- SUBSTITUTE BEFORE RUNNING (values come from churn-project.yml):
--   {{DB}}.{{SCHEMA}}          pipeline schema
--   {{SOURCE_TABLE}}           interactions table (sandbox: SYN_INTERACTIONS)
--   {{ID_COL}} {{ACCOUNT_COL}} {{TEXT_COL}} {{CHANNEL_COL}} {{CREATED_COL}}
--   {{EVIDENCE_MODEL}}         GA model pinned at preflight for AI_COMPLETE
--   {{RUN_ID}} {{EXPERIMENT_ID}} {{PROMPT_VERSION}}
--   {{CATEGORIES_LITERAL}}     rendered from REASON_TAXONOMY by 00_render_categories.sql
--   {{TASK_DESCRIPTION}}       <= 50 words (AI_CLASSIFY limit)
--   {{SAMPLE_LIMIT}}           row cap for a sizing run; remove for full runs
--
-- Three stages, cheapest first:
--   A. AI_SENTIMENT with aspects           every interaction
--   B. AI_CLASSIFY multi-label reasons     every interaction
--   C. AI_COMPLETE evidence + intent       ONLY rows B flagged with a reason
-- Each stage lands in its own table so a failure in C never costs a re-run
-- of A and B, and so per-stage parse failures are countable.
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};
ALTER SESSION SET QUERY_TAG = 'churn-signals:{{RUN_ID}}:extract';

-- ---------------------------------------------------------------------
-- 0. Normalised input. Whitespace-collapsed, empty text excluded and
--    COUNTED (not silently dropped), dedup scoped to the account.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE STG_INTERACTIONS AS
SELECT
    {{ID_COL}}::STRING                                        AS interaction_id,
    {{ACCOUNT_COL}}::STRING                                   AS account_id,
    {{CHANNEL_COL}}::STRING                                   AS channel,
    {{CREATED_COL}}::TIMESTAMP_NTZ                            AS created_at,
    TRIM(REGEXP_REPLACE({{TEXT_COL}}, '\\s+', ' '))           AS body,
    MD5({{ACCOUNT_COL}}::STRING || '::' || LOWER(TRIM(REGEXP_REPLACE({{TEXT_COL}}, '\\s+', ' ')))) AS content_hash
FROM {{SOURCE_TABLE}}
WHERE {{TEXT_COL}} IS NOT NULL
  AND LENGTH(TRIM({{TEXT_COL}})) >= 15
QUALIFY ROW_NUMBER() OVER (PARTITION BY content_hash ORDER BY {{CREATED_COL}}, {{ID_COL}}) = 1;

-- What was excluded, and why. Shown at the gate.
SELECT
    (SELECT COUNT(*) FROM {{SOURCE_TABLE}})                                     AS source_rows,
    (SELECT COUNT(*) FROM {{SOURCE_TABLE}}
      WHERE {{TEXT_COL}} IS NULL OR LENGTH(TRIM({{TEXT_COL}})) < 15)            AS too_short_or_null,
    (SELECT COUNT(*) FROM STG_INTERACTIONS)                                     AS staged_rows;

-- ---------------------------------------------------------------------
-- A. Aspect sentiment. Aspect names <= 30 chars, at most 10 (documented
--    limits). return_error_details => TRUE so an errored row is
--    distinguishable from a row with no sentiment.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SIG_SENTIMENT_RAW (
    run_id VARCHAR, experiment_id VARCHAR, interaction_id VARCHAR,
    response VARIANT, scored_at TIMESTAMP_NTZ
);

DELETE FROM SIG_SENTIMENT_RAW WHERE run_id = '{{RUN_ID}}';

INSERT INTO SIG_SENTIMENT_RAW
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', interaction_id,
       AI_SENTIMENT(body,
                    ['price', 'product features', 'reliability', 'support',
                     'ease of use', 'competitors', 'renewal'],
                    TRUE),
       CURRENT_TIMESTAMP()
FROM STG_INTERACTIONS
-- {{SAMPLE_LIMIT}}
;

-- ---------------------------------------------------------------------
-- B. Multi-label reason classification.
--    Categories are label + description OBJECTS built from the taxonomy
--    table (rendered to a literal so the call is reproducible and its
--    hash can be recorded). 'no retention risk' is a category, so the
--    model has a sanctioned way to say "nothing here" -- without it, multi
--    mode forces a reason onto routine traffic.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SIG_CLASSIFY_RAW (
    run_id VARCHAR, experiment_id VARCHAR, prompt_version VARCHAR, prompt_hash VARCHAR,
    interaction_id VARCHAR, response VARIANT, scored_at TIMESTAMP_NTZ
);

DELETE FROM SIG_CLASSIFY_RAW WHERE run_id = '{{RUN_ID}}';

INSERT INTO SIG_CLASSIFY_RAW
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{PROMPT_VERSION}}',
       SHA2($${{CATEGORIES_LITERAL}}||{{TASK_DESCRIPTION}}$$, 256),
       interaction_id,
       AI_CLASSIFY(
           'Channel: ' || channel || '. Text: ' || body,
           {{CATEGORIES_LITERAL}},
           {
             'task_description': '{{TASK_DESCRIPTION}}',
             'output_mode': 'multi',
             'examples': [
               {'input': 'We looked at another vendor last quarter and decided to stay with you.',
                'labels': ['no retention risk'],
                'explanation': 'A past evaluation the customer decided against is not an active competitor risk.'},
               {'input': 'The bug was frustrating but your team fixed it within the hour. Thanks.',
                'labels': ['no retention risk'],
                'explanation': 'A resolved issue with a positive outcome is not a reliability risk.'},
               {'input': 'Our admin left and nobody owns the tool; also the renewal price seems high for what we use.',
                'labels': ['loss of internal champion', 'price or value concerns'],
                'explanation': 'Two independent risks are both present.'}
             ]
           },
           TRUE),
       CURRENT_TIMESTAMP()
FROM STG_INTERACTIONS
-- {{SAMPLE_LIMIT}}
;

-- ---------------------------------------------------------------------
-- B2. Parse classification into reason codes. Labels map to codes
--     through the taxonomy with ONE normalisation expression; the
--     harness uses the same expression on the answer key.
--     Conflict rule: 'no retention risk' returned together with a real
--     reason -> the real reasons win, and the conflict is counted.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SIG_CLASSIFIED AS
WITH r AS (
    SELECT c.run_id, c.experiment_id, c.prompt_version, c.prompt_hash, c.interaction_id,
           c.response:value:labels                AS labels,
           c.response:error::STRING               AS classify_error
    FROM SIG_CLASSIFY_RAW c
    WHERE c.run_id = '{{RUN_ID}}'
),
f AS (
    SELECT r.interaction_id, t.reason_code
    FROM r, LATERAL FLATTEN(input => r.labels) l
    JOIN REASON_TAXONOMY t ON LOWER(TRIM(t.label)) = LOWER(TRIM(l.value::STRING))
),
agg AS (
    SELECT interaction_id,
           ARRAY_AGG(DISTINCT reason_code) WITHIN GROUP (ORDER BY reason_code) AS all_codes
    FROM f GROUP BY 1
)
SELECT
    r.run_id, r.experiment_id, r.prompt_version, r.prompt_hash, r.interaction_id,
    r.labels                                                    AS raw_labels,
    r.classify_error,
    ARRAY_EXCEPT(COALESCE(a.all_codes, ARRAY_CONSTRUCT()), ARRAY_CONSTRUCT('NONE')) AS reason_codes,
    ARRAY_CONTAINS('NONE'::VARIANT, COALESCE(a.all_codes, ARRAY_CONSTRUCT()))
        AND ARRAY_SIZE(ARRAY_EXCEPT(COALESCE(a.all_codes, ARRAY_CONSTRUCT()), ARRAY_CONSTRUCT('NONE'))) > 0
                                                                AS none_conflict,
    -- returned labels that are not in the taxonomy: should be zero
    ARRAY_SIZE(COALESCE(r.labels, ARRAY_CONSTRUCT()))
        - COALESCE(ARRAY_SIZE(a.all_codes), 0)                 AS unmapped_label_count,
    r.labels IS NULL                                            AS classify_failed
FROM r LEFT JOIN agg a USING (interaction_id);

-- ---------------------------------------------------------------------
-- C. Evidence and intent, only where B found a reason. This is the
--    expensive stage; gating it on B is the main cost lever.
--    The quote must be VERBATIM -- enforced in C2, not trusted.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SIG_EVIDENCE_RAW (
    run_id VARCHAR, experiment_id VARCHAR, prompt_version VARCHAR, prompt_hash VARCHAR,
    model_used VARCHAR, interaction_id VARCHAR, response VARIANT, scored_at TIMESTAMP_NTZ
);

DELETE FROM SIG_EVIDENCE_RAW WHERE run_id = '{{RUN_ID}}';

INSERT INTO SIG_EVIDENCE_RAW
WITH p AS (
    SELECT s.interaction_id,
           'You are reviewing one customer interaction for retention risk. ' ||
           'The detected risk categories are: ' || ARRAY_TO_STRING(c.reason_codes, ', ') || '. ' ||
           'Copy the single sentence from the text that best shows the risk, exactly as written, into evidence_quote. ' ||
           'Do not paraphrase. If no sentence shows a risk, return an empty string. ' ||
           'Set churn_intent: high if the customer states they will leave, cancel, or not renew; ' ||
           'medium if they are actively evaluating alternatives or questioning renewal; ' ||
           'low if they express a concern without questioning the relationship; none otherwise. ' ||
           'Set concern_resolved true only if the text says the issue was fixed and the customer is satisfied. ' ||
           'Put a named competitor product in competitor_named, otherwise an empty string. Respond in JSON.' ||
           CHR(10) || CHR(10) || 'Channel: ' || s.channel || CHR(10) || 'Text: ' || s.body AS prompt_text
    FROM STG_INTERACTIONS s
    JOIN SIG_CLASSIFIED c ON c.interaction_id = s.interaction_id
    WHERE ARRAY_SIZE(c.reason_codes) > 0
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{PROMPT_VERSION}}',
       SHA2(REGEXP_REPLACE(prompt_text, 'Channel: .*$', ''), 256),   -- hash the instruction, not the data
       '{{EVIDENCE_MODEL}}', interaction_id,
       AI_COMPLETE(
           model => '{{EVIDENCE_MODEL}}',
           prompt => prompt_text,
           model_parameters => {'temperature': 0, 'max_tokens': 400},
           response_format => {
             'type': 'json',
             'schema': {
               'type': 'object',
               'properties': {
                 'evidence_quote':   {'type': 'string', 'description': 'One sentence copied verbatim from the text, or empty.'},
                 'churn_intent':     {'type': 'string', 'enum': ['none', 'low', 'medium', 'high']},
                 'concern_resolved': {'type': 'boolean'},
                 'competitor_named': {'type': 'string', 'description': 'Competitor product named in the text, or empty.'}
               },
               'required': ['evidence_quote', 'churn_intent', 'concern_resolved', 'competitor_named']
             }
           },
           show_details => TRUE),
       CURRENT_TIMESTAMP()
FROM p;

-- ---------------------------------------------------------------------
-- C2. Land the per-interaction signal table. Grounding check: the quote
--     must appear in the body after the same whitespace normalisation.
--     An ungrounded quote is nulled and flagged, never shown as evidence.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS INTERACTION_SIGNALS (
    run_id VARCHAR, experiment_id VARCHAR, prompt_version VARCHAR,
    classify_prompt_hash VARCHAR, evidence_prompt_hash VARCHAR, evidence_model VARCHAR,
    interaction_id VARCHAR, account_id VARCHAR, channel VARCHAR, created_at TIMESTAMP_NTZ,
    reason_codes ARRAY, none_conflict BOOLEAN, classify_failed BOOLEAN,
    sentiment VARIANT,           -- full aspect array, kept as VARIANT
    overall_sentiment VARCHAR,
    neg_aspects ARRAY,
    churn_intent VARCHAR,
    concern_resolved BOOLEAN,
    competitor_named VARCHAR,
    evidence_quote VARCHAR,      -- no length limit: model-generated text
    evidence_grounded BOOLEAN,
    evidence_failed BOOLEAN,
    prompt_tokens INT, completion_tokens INT,
    extracted_at TIMESTAMP_NTZ
);

DELETE FROM INTERACTION_SIGNALS WHERE run_id = '{{RUN_ID}}';

INSERT INTO INTERACTION_SIGNALS
WITH sent AS (
    SELECT interaction_id,
           response:value:categories AS cats,
           response:error::STRING    AS sent_error
    FROM SIG_SENTIMENT_RAW WHERE run_id = '{{RUN_ID}}'
),
sent_flat AS (
    SELECT s.interaction_id,
           MAX(IFF(f.value:name::STRING = 'overall', f.value:sentiment::STRING, NULL)) AS overall_sentiment,
           ARRAY_AGG(IFF(f.value:sentiment::STRING IN ('negative', 'mixed')
                         AND f.value:name::STRING <> 'overall',
                         f.value:name::STRING, NULL))                                    AS neg_aspects
    FROM sent s, LATERAL FLATTEN(input => s.cats, OUTER => TRUE) f
    GROUP BY 1
),
ev AS (
    SELECT interaction_id, prompt_hash, model_used,
           response:structured_output[0]:raw_message AS j,
           response:usage:prompt_tokens::INT     AS prompt_tokens,
           response:usage:completion_tokens::INT AS completion_tokens
    FROM SIG_EVIDENCE_RAW WHERE run_id = '{{RUN_ID}}'
)
SELECT
    c.run_id, c.experiment_id, c.prompt_version,
    c.prompt_hash, ev.prompt_hash, ev.model_used,
    s.interaction_id, s.account_id, s.channel, s.created_at,
    c.reason_codes, c.none_conflict, c.classify_failed,
    se.cats,
    sf.overall_sentiment,
    sf.neg_aspects,
    COALESCE(ev.j:churn_intent::STRING, IFF(ARRAY_SIZE(c.reason_codes) = 0, 'none', NULL)),
    ev.j:concern_resolved::BOOLEAN,
    NULLIF(TRIM(ev.j:competitor_named::STRING), ''),
    IFF(CONTAINS(LOWER(s.body), LOWER(TRIM(REGEXP_REPLACE(ev.j:evidence_quote::STRING, '\\s+', ' '))))
        AND LENGTH(TRIM(ev.j:evidence_quote::STRING)) > 0,
        ev.j:evidence_quote::STRING, NULL),
    CASE WHEN ev.j IS NULL THEN NULL
         ELSE CONTAINS(LOWER(s.body), LOWER(TRIM(REGEXP_REPLACE(ev.j:evidence_quote::STRING, '\\s+', ' '))))
              AND LENGTH(TRIM(ev.j:evidence_quote::STRING)) > 0 END,
    -- a reason was flagged but stage C produced nothing parseable
    ARRAY_SIZE(c.reason_codes) > 0 AND ev.j IS NULL,
    ev.prompt_tokens, ev.completion_tokens,
    CURRENT_TIMESTAMP()
FROM STG_INTERACTIONS s
JOIN SIG_CLASSIFIED c   ON c.interaction_id = s.interaction_id
LEFT JOIN sent se       ON se.interaction_id = s.interaction_id
LEFT JOIN sent_flat sf  ON sf.interaction_id = s.interaction_id
LEFT JOIN ev            ON ev.interaction_id = s.interaction_id;

-- ---------------------------------------------------------------------
-- Quality log. Part of every run, not an afterthought.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS PIPELINE_QUALITY_LOG (
    run_id VARCHAR, stage VARCHAR, total_rows INT, failed_rows INT,
    detail VARIANT, logged_at TIMESTAMP_NTZ
);

INSERT INTO PIPELINE_QUALITY_LOG
SELECT '{{RUN_ID}}', 'sentiment', COUNT(*), COUNT_IF(response:value IS NULL),
       OBJECT_CONSTRUCT('sample_error', ANY_VALUE(response:error::STRING)), CURRENT_TIMESTAMP()
FROM SIG_SENTIMENT_RAW WHERE run_id = '{{RUN_ID}}'
UNION ALL
SELECT '{{RUN_ID}}', 'classify', COUNT(*), COUNT_IF(classify_failed),
       OBJECT_CONSTRUCT('none_conflicts', COUNT_IF(none_conflict),
                        'unmapped_labels', SUM(unmapped_label_count),
                        'flagged_with_reason', COUNT_IF(ARRAY_SIZE(reason_codes) > 0)),
       CURRENT_TIMESTAMP()
FROM SIG_CLASSIFIED WHERE run_id = '{{RUN_ID}}'
UNION ALL
SELECT '{{RUN_ID}}', 'evidence', COUNT_IF(ARRAY_SIZE(reason_codes) > 0), COUNT_IF(evidence_failed),
       OBJECT_CONSTRUCT('ungrounded_quotes', COUNT_IF(evidence_grounded = FALSE),
                        'empty_or_null_quotes', COUNT_IF(ARRAY_SIZE(reason_codes) > 0 AND evidence_quote IS NULL)),
       CURRENT_TIMESTAMP()
FROM INTERACTION_SIGNALS WHERE run_id = '{{RUN_ID}}';

ALTER SESSION UNSET QUERY_TAG;
