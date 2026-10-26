-- =====================================================================
-- Phase 6b: operationalize. Incremental extraction on new interactions,
-- a scheduled re-score, and a semantic view for the Cortex Agent.
--
-- Everything here is created SUSPENDED or as definitions only. Resuming
-- a task is a separate, explicit, confirmed step: it starts recurring
-- AI spend.
--
-- SUBSTITUTE: {{DB}}.{{SCHEMA}}, {{SOURCE_TABLE}}, {{ID_COL}}, {{ACCOUNT_COL}},
--   {{TEXT_COL}}, {{CHANNEL_COL}}, {{CREATED_COL}}, {{WAREHOUSE}},
--   {{EVIDENCE_MODEL}}, {{PROD_RUN_ID}} (stable, e.g. 'prod_v1'),
--   {{CATEGORIES_LITERAL}}, {{TASK_DESCRIPTION}}, {{PROMPT_VERSION}},
--   {{EXTRACT_SCHEDULE}} e.g. 'USING CRON 0 */2 * * * UTC',
--   {{SCORE_SCHEDULE}}   e.g. 'USING CRON 0 6 * * 1 UTC'
--   {{ACCOUNT_TABLE}} {{ACCOUNT_NAME_COL}} {{OWNER_COL}}
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Stream on the source. APPEND_ONLY: we extract each interaction
--    once. Edited tickets are a policy choice -- see SKILL.md -- and are
--    not re-extracted by default, because re-extraction re-bills.
-- ---------------------------------------------------------------------
CREATE STREAM IF NOT EXISTS INTERACTIONS_STREAM
    ON TABLE {{SOURCE_TABLE}} APPEND_ONLY = TRUE;

-- Inbox: the stream is drained into a permanent table by a plain INSERT,
-- which is what advances a stream offset. Rows then wait here until they
-- are extracted, so an AI failure delays them instead of losing them.
CREATE TABLE IF NOT EXISTS INTERACTIONS_INBOX (
    interaction_id VARCHAR, account_id VARCHAR, channel VARCHAR, created_at TIMESTAMP_NTZ,
    body VARCHAR, received_at TIMESTAMP_NTZ, processed_at TIMESTAMP_NTZ, skipped_reason VARCHAR
);

-- ---------------------------------------------------------------------
-- 2. Incremental extraction procedure. Same prompts, same categories
--    literal, same grounding check as the batch path -- they must not
--    diverge, or production rows and evaluated rows come from different
--    pipelines. No explicit transaction: the CREATE TEMPORARY TABLE
--    statements are DDL and would commit it implicitly anyway. Instead
--    every step is idempotent and keyed on interaction_id.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE REFRESH_INTERACTION_SIGNALS(MAX_BATCH INT)
RETURNS VARIANT
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    n_new INT DEFAULT 0;
BEGIN
    ALTER SESSION SET QUERY_TAG = 'churn-signals:{{PROD_RUN_ID}}:incremental';

    -- Drain the stream (DML consumes it; the offset advances on commit).
    INSERT INTO INTERACTIONS_INBOX
    SELECT {{ID_COL}}::STRING, {{ACCOUNT_COL}}::STRING, {{CHANNEL_COL}}::STRING,
           {{CREATED_COL}}::TIMESTAMP_NTZ, TRIM(REGEXP_REPLACE({{TEXT_COL}}, '\\s+', ' ')),
           CURRENT_TIMESTAMP(), NULL,
           IFF({{TEXT_COL}} IS NULL OR LENGTH(TRIM({{TEXT_COL}})) < 15, 'too_short_or_null', NULL)
    FROM INTERACTIONS_STREAM
    WHERE METADATA$ACTION = 'INSERT';

    -- Short rows are recorded as skipped, not silently dropped.
    UPDATE INTERACTIONS_INBOX SET processed_at = CURRENT_TIMESTAMP()
    WHERE processed_at IS NULL AND skipped_reason IS NOT NULL;

    CREATE OR REPLACE TEMPORARY TABLE _NEW_INTERACTIONS AS
    SELECT interaction_id, account_id, channel, created_at, body
    FROM INTERACTIONS_INBOX
    WHERE processed_at IS NULL
      AND interaction_id NOT IN (SELECT interaction_id FROM INTERACTION_SIGNALS
                                 WHERE run_id = '{{PROD_RUN_ID}}')
    ORDER BY received_at
    LIMIT :MAX_BATCH;

    n_new := (SELECT COUNT(*) FROM _NEW_INTERACTIONS);

    IF (n_new > 0) THEN
        CREATE OR REPLACE TEMPORARY TABLE _NEW_SCORED AS
        SELECT n.*,
               AI_SENTIMENT(n.body, ['price', 'product features', 'reliability', 'support',
                                     'ease of use', 'competitors', 'renewal'], TRUE)         AS sent,
               AI_CLASSIFY('Channel: ' || n.channel || '. Text: ' || n.body,
                           {{CATEGORIES_LITERAL}},
                           {'task_description': '{{TASK_DESCRIPTION}}', 'output_mode': 'multi'},
                           TRUE)                                                            AS cls
        FROM _NEW_INTERACTIONS n;

        CREATE OR REPLACE TEMPORARY TABLE _NEW_CODES AS
        SELECT s.interaction_id,
               ARRAY_EXCEPT(COALESCE(ARRAY_AGG(DISTINCT t.reason_code), ARRAY_CONSTRUCT()),
                            ARRAY_CONSTRUCT('NONE')) AS reason_codes
        FROM _NEW_SCORED s
        LEFT JOIN LATERAL FLATTEN(input => s.cls:value:labels, OUTER => TRUE) l
        LEFT JOIN REASON_TAXONOMY t ON LOWER(TRIM(t.label)) = LOWER(TRIM(l.value::STRING))
        GROUP BY s.interaction_id;

        INSERT INTO INTERACTION_SIGNALS
            (run_id, experiment_id, prompt_version, evidence_model, interaction_id, account_id,
             channel, created_at, reason_codes, none_conflict, classify_failed, sentiment,
             overall_sentiment, neg_aspects, churn_intent, concern_resolved, competitor_named,
             evidence_quote, evidence_grounded, evidence_failed, prompt_tokens, completion_tokens,
             extracted_at)
        WITH ev AS (
            SELECT s.interaction_id,
                   AI_COMPLETE(
                       model => '{{EVIDENCE_MODEL}}',
                       prompt => 'You are reviewing one customer interaction for retention risk. ' ||
                                 'The detected risk categories are: ' || ARRAY_TO_STRING(c.reason_codes, ', ') || '. ' ||
                                 'Copy the single sentence from the text that best shows the risk, exactly as written, into evidence_quote. ' ||
                                 'Do not paraphrase. If no sentence shows a risk, return an empty string. ' ||
                                 'Set churn_intent: high if the customer states they will leave, cancel, or not renew; ' ||
                                 'medium if they are actively evaluating alternatives or questioning renewal; ' ||
                                 'low if they express a concern without questioning the relationship; none otherwise. ' ||
                                 'Set concern_resolved true only if the text says the issue was fixed and the customer is satisfied. ' ||
                                 'Put a named competitor product in competitor_named, otherwise an empty string. Respond in JSON.' ||
                                 CHR(10) || CHR(10) || 'Channel: ' || s.channel || CHR(10) || 'Text: ' || s.body,
                       model_parameters => {'temperature': 0, 'max_tokens': 400},
                       response_format => {'type': 'json', 'schema': {'type': 'object', 'properties': {
                           'evidence_quote':   {'type': 'string'},
                           'churn_intent':     {'type': 'string', 'enum': ['none', 'low', 'medium', 'high']},
                           'concern_resolved': {'type': 'boolean'},
                           'competitor_named': {'type': 'string'}},
                           'required': ['evidence_quote', 'churn_intent', 'concern_resolved', 'competitor_named']}},
                       show_details => TRUE) AS r
            FROM _NEW_SCORED s JOIN _NEW_CODES c USING (interaction_id)
            WHERE ARRAY_SIZE(c.reason_codes) > 0
        ),
        sf AS (
            SELECT s.interaction_id,
                   MAX(IFF(f.value:name::STRING = 'overall', f.value:sentiment::STRING, NULL)) AS overall_sentiment,
                   ARRAY_AGG(IFF(f.value:sentiment::STRING IN ('negative', 'mixed') AND f.value:name::STRING <> 'overall',
                                 f.value:name::STRING, NULL)) AS neg_aspects
            FROM _NEW_SCORED s, LATERAL FLATTEN(input => s.sent:value:categories, OUTER => TRUE) f
            GROUP BY 1
        )
        SELECT '{{PROD_RUN_ID}}', 'production', '{{PROMPT_VERSION}}', '{{EVIDENCE_MODEL}}',
               s.interaction_id, s.account_id, s.channel, s.created_at,
               c.reason_codes, NULL, s.cls:value IS NULL, s.sent:value:categories,
               sf.overall_sentiment, sf.neg_aspects,
               COALESCE(ev.r:structured_output[0]:raw_message:churn_intent::STRING,
                        IFF(ARRAY_SIZE(c.reason_codes) = 0, 'none', NULL)),
               ev.r:structured_output[0]:raw_message:concern_resolved::BOOLEAN,
               NULLIF(TRIM(ev.r:structured_output[0]:raw_message:competitor_named::STRING), ''),
               IFF(CONTAINS(LOWER(s.body), LOWER(TRIM(ev.r:structured_output[0]:raw_message:evidence_quote::STRING)))
                   AND LENGTH(TRIM(ev.r:structured_output[0]:raw_message:evidence_quote::STRING)) > 0,
                   ev.r:structured_output[0]:raw_message:evidence_quote::STRING, NULL),
               IFF(ev.r IS NULL, NULL,
                   CONTAINS(LOWER(s.body), LOWER(TRIM(ev.r:structured_output[0]:raw_message:evidence_quote::STRING)))
                   AND LENGTH(TRIM(ev.r:structured_output[0]:raw_message:evidence_quote::STRING)) > 0),
               ARRAY_SIZE(c.reason_codes) > 0 AND ev.r:structured_output IS NULL,
               ev.r:usage:prompt_tokens::INT, ev.r:usage:completion_tokens::INT,
               CURRENT_TIMESTAMP()
        FROM _NEW_SCORED s
        JOIN _NEW_CODES c USING (interaction_id)
        LEFT JOIN sf USING (interaction_id)
        LEFT JOIN ev USING (interaction_id);
    END IF;

    UPDATE INTERACTIONS_INBOX SET processed_at = CURRENT_TIMESTAMP()
    WHERE processed_at IS NULL
      AND interaction_id IN (SELECT interaction_id FROM INTERACTION_SIGNALS
                             WHERE run_id = '{{PROD_RUN_ID}}');

    INSERT INTO PIPELINE_QUALITY_LOG
    SELECT '{{PROD_RUN_ID}}', 'incremental', :n_new,
           (SELECT COUNT_IF(classify_failed OR evidence_failed) FROM INTERACTION_SIGNALS
             WHERE run_id = '{{PROD_RUN_ID}}' AND extracted_at >= DATEADD(minute, -30, CURRENT_TIMESTAMP())),
           NULL, CURRENT_TIMESTAMP();

    RETURN OBJECT_CONSTRUCT('new_interactions', :n_new);
END;
$$;

-- ---------------------------------------------------------------------
-- 3. Tasks, created suspended. MAX_BATCH caps the AI spend of any
--    single run; a backlog drains over several runs instead of one large one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TASK REFRESH_SIGNALS_TASK
    WAREHOUSE = {{WAREHOUSE}}
    SCHEDULE = '{{EXTRACT_SCHEDULE}}'
    SUSPEND_TASK_AFTER_NUM_FAILURES = 3
    -- No WHEN SYSTEM$STREAM_HAS_DATA clause on purpose: a backlog larger
    -- than MAX_BATCH lives in the inbox, not the stream, and would stall
    -- until new data arrived. The procedure exits cheaply when idle.
AS
    CALL REFRESH_INTERACTION_SIGNALS(5000);

-- Re-scoring is a separate task because it rebuilds features for the
-- SCORE spine and calls the model; its body is the substituted
-- build-account-features/sql/01_build_features.sql (SCORE split only)
-- followed by 01_score_and_rank.sql, wrapped in a procedure by the
-- score-at-risk-accounts skill. Created suspended.
-- CREATE OR REPLACE TASK RESCORE_ACCOUNTS_TASK
--     WAREHOUSE = {{WAREHOUSE}}
--     SCHEDULE = '{{SCORE_SCHEDULE}}'
-- AS
--     CALL RESCORE_ACCOUNTS();

-- To start (separate confirmed step):  ALTER TASK REFRESH_SIGNALS_TASK RESUME;

-- ---------------------------------------------------------------------
-- 4. Semantic view over the deliverables, for Cortex Analyst and the
--    CoWork agent. Build or extend it through the agent-studio skill; this
--    is the starting definition.
-- ---------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW CHURN_SIGNALS_SV
  TABLES (
    risk AS AT_RISK_ACCOUNTS
      PRIMARY KEY (score_run_id, account_id)
      WITH SYNONYMS = ('at risk accounts', 'churn risk', 'renewal risk')
      COMMENT = 'One row per open renewal per scoring run, with churn probability, band, reasons and cited evidence.',
    lost AS CHURN_REASONS_CLOSED
      WITH SYNONYMS = ('churned accounts', 'lost customers', 'churn reasons')
      COMMENT = 'Closed churned renewals with every reason mention, including exit surveys after the prediction cutoff.'
  )
  FACTS (
    risk.arr_fact AS arr,
    risk.p_churn_fact AS p_churn,
    risk.expected_at_risk_fact AS arr_at_risk_expected,
    lost.arr_lost_fact AS arr_lost
  )
  DIMENSIONS (
    risk.account_name AS account_name,
    risk.owner AS owner WITH SYNONYMS = ('csm', 'account owner'),
    risk.risk_band AS risk_band WITH SYNONYMS = ('risk level'),
    risk.renewal_date AS renewal_date,
    risk.risk_basis AS risk_basis
      COMMENT = 'TEXT_AND_USAGE when cited text evidence exists; USAGE_ONLY when the score rests on usage alone.',
    risk.score_run_id AS score_run_id,
    lost.reason_code AS reason_code WITH SYNONYMS = ('churn reason', 'why they left'),
    lost.channel AS channel,
    lost.is_post_cutoff AS is_post_cutoff
  )
  METRICS (
    risk.total_arr AS SUM(risk.arr_fact),
    risk.expected_arr_at_risk AS SUM(risk.expected_at_risk_fact)
      COMMENT = 'Probability-weighted ARR at risk. Valid only if calibration was checked in evaluation.',
    risk.accounts_at_risk AS COUNT(risk.account_name),
    lost.reason_mentions AS COUNT(lost.reason_code)
  )
  COMMENT = 'churn-signals play: at-risk renewals and churn reasons from unstructured customer interactions'
  AI_SQL_GENERATION 'Always filter risk to the latest score_run_id unless the user asks for history. Never sum arr_lost across reason rows; one account can have several reasons.';
