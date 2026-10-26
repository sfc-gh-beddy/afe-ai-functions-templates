-- =====================================================================
-- Phase 6b. Schedule the pipeline.
--
-- Design:
--   - The phase SQL files are staged as Jinja templates and executed with
--     EXECUTE IMMEDIATE FROM ... USING (...). Their {{NAME}} placeholders
--     are valid Jinja variables, so the same files run by hand and on a
--     schedule.
--   - One procedure runs parse -> extract -> reconcile for one run, with the
--     as-of date pinned ONCE at the start and recorded (rule 14).
--   - A stream on the contract stage's directory table records arrivals;
--     parse caching (content hash) means only new or changed contracts are
--     parsed, so a daily full run costs little on days nothing arrived.
--   - Extraction reruns only when contracts changed. Reconciliation reruns
--     every time, because spend changes daily and terms do not.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}} {{SCHEMA}} {{WAREHOUSE}} {{CODE_STAGE}} {{CONTRACT_STAGE}}
--   {{PROD_EXPERIMENT_ID}} {{PROMPT_VERSION}} {{SCHEDULE_CRON}}
--   and every pipeline parameter the phase files take (listed in
--   RUN_LEAKAGE_PIPELINE below), from spend-leakage-project.yml.
-- =====================================================================

USE DATABASE {{DB}};
USE SCHEMA {{SCHEMA}};

-- 1. Code stage. Upload the phase files here UNSUBSTITUTED (as templates):
--      parse-contract-documents/sql/02_parse_and_register.sql
--      extract-contract-terms/sql/01_extract_terms.sql
--      reconcile-spend-to-contract/sql/01_reconcile.sql
--    A USING clause is enough to make EXECUTE IMMEDIATE FROM render them as
--    Jinja. Jinja renders an undefined variable as an empty string, so the
--    procedure passes every placeholder each file uses; check that list
--    again whenever a file gains a placeholder.
CREATE STAGE IF NOT EXISTS {{CODE_STAGE}}
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  DIRECTORY = (ENABLE = TRUE);

-- 2. Run log. One row per scheduled run, with the pinned as-of date and the
--    hashes of the code that ran.
CREATE TABLE IF NOT EXISTS PIPELINE_RUNS (
    run_id VARCHAR, experiment_id VARCHAR, prompt_version VARCHAR,
    as_of_date DATE, started_at TIMESTAMP_NTZ, finished_at TIMESTAMP_NTZ,
    contracts_changed BOOLEAN, status VARCHAR, error VARCHAR,
    extract_code_md5 VARCHAR, reconcile_code_md5 VARCHAR
);

-- 3. Arrivals. The stream on the stage's directory table is consumed into
--    this log so the stream offset advances.
CREATE STREAM IF NOT EXISTS CONTRACT_FILES_STREAM ON STAGE {{CONTRACT_STAGE}};

CREATE TABLE IF NOT EXISTS CONTRACT_ARRIVALS (
    relative_path VARCHAR, md5 VARCHAR, size NUMBER, change_type VARCHAR, seen_at TIMESTAMP_NTZ
);

-- 4. The run procedure.
CREATE OR REPLACE PROCEDURE RUN_LEAKAGE_PIPELINE(AS_OF DATE, FORCE_EXTRACT BOOLEAN)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  run_id      VARCHAR DEFAULT 'sched_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDD_HH24MISS');
  changed     BOOLEAN DEFAULT FALSE;
  extract_md5 VARCHAR;
  recon_md5   VARCHAR;
  common      VARCHAR;
BEGIN
  -- Code hashes stand in for PROMPT_HASH / PARAM_HASH: they change exactly
  -- when the staged prompt or parameter files change.
  SELECT MAX(IFF(relative_path ILIKE '%01_extract_terms.sql', md5, NULL)),
         MAX(IFF(relative_path ILIKE '%01_reconcile.sql', md5, NULL))
    INTO :extract_md5, :recon_md5
    FROM DIRECTORY(@{{CODE_STAGE}});

  INSERT INTO PIPELINE_RUNS (run_id, experiment_id, prompt_version, as_of_date, started_at, status,
                             extract_code_md5, reconcile_code_md5)
  VALUES (:run_id, '{{PROD_EXPERIMENT_ID}}', '{{PROMPT_VERSION}}', :AS_OF, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ,
          'RUNNING', :extract_md5, :recon_md5);

  -- Consume arrivals.
  INSERT INTO CONTRACT_ARRIVALS
  SELECT relative_path, md5, size, METADATA$ACTION, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
  FROM CONTRACT_FILES_STREAM;
  changed := (SQLROWCOUNT > 0) OR FORCE_EXTRACT;

  common := 'DB => ''{{DB}}'', SCHEMA => ''{{SCHEMA}}'', RUN_ID => ''' || run_id || ''', '
         || 'EXPERIMENT_ID => ''{{PROD_EXPERIMENT_ID}}'', PROMPT_VERSION => ''{{PROMPT_VERSION}}'', '
         || 'QUERY_TAG_PREFIX => ''{{QUERY_TAG_PREFIX}}'', AS_OF_DATE => ''' || TO_VARCHAR(AS_OF) || '''';

  IF (changed) THEN
    EXECUTE IMMEDIATE 'EXECUTE IMMEDIATE FROM ''@{{CODE_STAGE}}/02_parse_and_register.sql'' USING ('
      || common || ', STAGE => ''@{{CONTRACT_STAGE}}'', PARSE_SOURCE => ''{{PARSE_SOURCE}}'', '
      || 'MIN_CHARS_PER_PAGE => ''{{MIN_CHARS_PER_PAGE}}'', NEAR_DUP_SIM => ''{{NEAR_DUP_SIM}}'', '
      || 'BUYER_NAME => ''{{BUYER_NAME}}'', VENDOR_JW_MIN => ''{{VENDOR_JW_MIN}}'')';
    EXECUTE IMMEDIATE 'EXECUTE IMMEDIATE FROM ''@{{CODE_STAGE}}/01_extract_terms.sql'' USING ('
      || common || ', PROMPT_HASH => ''' || extract_md5 || ''', MODEL => ''{{MODEL}}'', '
      || 'QUOTE_MIN_CHARS => ''{{QUOTE_MIN_CHARS}}'')';
  END IF;

  EXECUTE IMMEDIATE 'EXECUTE IMMEDIATE FROM ''@{{CODE_STAGE}}/01_reconcile.sql'' USING ('
    || common || ', PROMPT_HASH => ''' || COALESCE(extract_md5, '') || ''', PARAM_HASH => ''' || recon_md5 || ''', '
    || 'PRICE_TOL_ABS => ''{{PRICE_TOL_ABS}}'', PRICE_TOL_REL_PCT => ''{{PRICE_TOL_REL_PCT}}'', '
    || 'HORIZON_DAYS => ''{{HORIZON_DAYS}}'', EXPOSURE_MONTHS => ''{{EXPOSURE_MONTHS}}'', '
    || 'SKU_SIM_MIN => ''{{SKU_SIM_MIN}}'', SKU_SIM_MARGIN => ''{{SKU_SIM_MARGIN}}'')';

  UPDATE PIPELINE_RUNS SET finished_at = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, status = 'DONE',
         contracts_changed = :changed
   WHERE run_id = :run_id;
  RETURN run_id;
EXCEPTION
  WHEN OTHER THEN
    UPDATE PIPELINE_RUNS SET finished_at = CURRENT_TIMESTAMP()::TIMESTAMP_NTZ, status = 'FAILED',
           error = :SQLERRM
     WHERE run_id = :run_id;
    RAISE;
END;
$$;

-- 5. The task. CURRENT_DATE() is evaluated once, here, at the start of the
--    run, and the procedure records it; no business logic reads the clock.
--    Prefer weekday business hours: the output is acted on by people.
CREATE OR REPLACE TASK LEAKAGE_PIPELINE_DAILY
  WAREHOUSE = {{WAREHOUSE}}
  SCHEDULE = 'USING CRON {{SCHEDULE_CRON}}'
  USER_TASK_TIMEOUT_MS = 14400000
  SUSPEND_TASK_AFTER_NUM_FAILURES = 2
  COMMENT = 'Spend and contract leakage: parse and extract changed contracts, reconcile all spend.'
AS
  CALL RUN_LEAKAGE_PIPELINE(CURRENT_DATE(), FALSE);

-- Tasks are created suspended. Resume only after the user confirms.
-- ALTER TASK LEAKAGE_PIPELINE_DAILY RESUME;

-- =====================================================================
-- Verification.
-- =====================================================================
-- V1. A manual run end to end, before resuming the schedule.
--     CALL RUN_LEAKAGE_PIPELINE('{{AS_OF_DATE}}'::DATE, TRUE);
SELECT * FROM PIPELINE_RUNS ORDER BY started_at DESC LIMIT 5;

-- V2. Task history after the first scheduled run.
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'LEAKAGE_PIPELINE_DAILY'))
ORDER BY scheduled_time DESC LIMIT 10;
