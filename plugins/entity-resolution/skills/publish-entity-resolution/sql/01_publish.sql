-- =====================================================================
-- Phase 7: publish. Promote an evaluated run, expose it through stable
-- views and a semantic view, schedule incremental runs, and create a
-- Cortex Agent for CoWork.
-- Substitute {{SCHEMA}}, {{WAREHOUSE}}, {{RUN_ID}} (the run being promoted),
-- {{STAGE}} (internal stage holding the phase SQL files), {{SCHEDULE}}
-- (cron, e.g. 'USING CRON 0 6 * * 1-5 UTC'), {{AGENT_MODEL}}.
-- =====================================================================

USE SCHEMA {{SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Published-run pointer. Consumers never filter on run_id themselves;
--    they read the CURRENT views, which follow this pointer. Promotion is a
--    deliberate, recorded act after evaluation, never automatic.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ER_PUBLISHED_RUN (
    run_id        VARCHAR,
    experiment_id VARCHAR,
    published_at  TIMESTAMP_NTZ,
    published_by  VARCHAR,
    eval_snapshot VARIANT,
    is_current    BOOLEAN
);

UPDATE ER_PUBLISHED_RUN SET is_current = FALSE WHERE is_current;

INSERT INTO ER_PUBLISHED_RUN
SELECT '{{RUN_ID}}', MAX(experiment_id), CURRENT_TIMESTAMP(), CURRENT_USER(),
       ARRAY_AGG(OBJECT_CONSTRUCT(*)), TRUE
FROM {{EVAL_SCHEMA}}.ER_EVAL_SUMMARY
WHERE run_id = '{{RUN_ID}}';

-- ---------------------------------------------------------------------
-- 2. Current views. Publishable clusters only in the golden view; the
--    crosswalk keeps every record (with status) so nothing silently drops.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW ER_GOLDEN_CURRENT AS
SELECT g.* EXCLUDE (run_id, experiment_id)
FROM ER_GOLDEN_RECORDS g
JOIN ER_PUBLISHED_RUN p ON p.run_id = g.run_id AND p.is_current
WHERE g.cluster_status = 'PUBLISHABLE';

CREATE OR REPLACE VIEW ER_CROSSWALK_CURRENT AS
SELECT x.* EXCLUDE (run_id, experiment_id)
FROM ER_CROSSWALK x
JOIN ER_PUBLISHED_RUN p ON p.run_id = x.run_id AND p.is_current;

CREATE OR REPLACE VIEW ER_RELATIONSHIPS_CURRENT AS
SELECT r.* EXCLUDE (run_id)
FROM ER_ENTITY_RELATIONSHIPS r
JOIN ER_PUBLISHED_RUN p ON p.run_id = r.run_id AND p.is_current;

-- Duplicate summary per golden record, for the semantic view: how many
-- source records, from how many systems, collapsed into each golden record.
CREATE OR REPLACE VIEW ER_DUPLICATE_SUMMARY_CURRENT AS
SELECT x.golden_id, x.entity_type,
       COUNT(*)                         AS source_records,
       COUNT(DISTINCT x.source_system)  AS source_systems,
       COUNT(*) - 1                     AS duplicates_collapsed,
       MIN(x.membership_confidence)     AS weakest_membership_confidence,
       ANY_VALUE(x.cluster_status)      AS cluster_status
FROM ER_CROSSWALK_CURRENT x
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- 3. Semantic view for Cortex Analyst / CoWork. Answers questions like
--    "how many duplicate vendors do we have per ERP", "which customers exist
--    in CRM and billing", "show the golden record for X and its sources".
--    Contains no tax ids, phones or bank fields: those stay out of the
--    analytical surface by default (rule 36). Add them only with an explicit
--    access decision and a masking policy.
-- ---------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW ER_ENTITY_RESOLUTION_SV
  TABLES (
    golden AS ER_GOLDEN_CURRENT
      PRIMARY KEY (golden_id)
      WITH SYNONYMS ('golden record', 'master record', 'resolved entity', 'single customer view')
      COMMENT = 'One row per resolved customer, vendor or product (publishable clusters only)',
    dupes AS ER_DUPLICATE_SUMMARY_CURRENT
      PRIMARY KEY (golden_id)
      COMMENT = 'Duplicate counts per golden record',
    xwalk AS ER_CROSSWALK_CURRENT
      PRIMARY KEY (record_uid)
      WITH SYNONYMS ('source record', 'crosswalk')
      COMMENT = 'Every source record and the golden record it resolved to'
  )
  RELATIONSHIPS (
    xwalk_to_golden AS xwalk (golden_id) REFERENCES golden,
    dupes_to_golden AS dupes (golden_id) REFERENCES golden
  )
  FACTS (
    dupes.duplicates_collapsed_fact AS duplicates_collapsed,
    dupes.source_records_fact AS source_records,
    golden.cluster_confidence_fact AS cluster_confidence
  )
  DIMENSIONS (
    golden.entity_type AS golden.entity_type
      WITH SYNONYMS = ('record type', 'entity type')
      COMMENT = 'CUSTOMER, VENDOR or PRODUCT',
    golden.display_name AS golden.display_name
      WITH SYNONYMS = ('name', 'company name', 'product name')
      COMMENT = 'Survived display name',
    golden.city AS golden.city,
    golden.region AS golden.region,
    golden.country AS golden.country,
    golden.brand AS golden.brand,
    golden.golden_id_dim AS golden.golden_id
      COMMENT = 'Stable golden id; keep for joins to downstream systems',
    xwalk.source_system AS xwalk.source_system
      WITH SYNONYMS = ('system', 'source')
      COMMENT = 'System the source record came from',
    xwalk.source_record_id AS xwalk.source_record_id
      COMMENT = 'Key of the record in its source system',
    xwalk.review_status AS xwalk.review_status
  )
  METRICS (
    golden.golden_record_count AS COUNT(golden.golden_id)
      COMMENT = 'Number of resolved entities',
    xwalk.source_record_count AS COUNT(xwalk.record_uid)
      COMMENT = 'Number of source records',
    dupes.duplicate_records AS SUM(dupes.duplicates_collapsed_fact)
      WITH SYNONYMS = ('duplicates', 'duplicate count')
      COMMENT = 'Source records that are duplicates of another record',
    dupes.multi_system_entities AS COUNT_IF(dupes.source_systems > 1)
      COMMENT = 'Entities present in more than one source system',
    golden.avg_cluster_confidence AS AVG(golden.cluster_confidence_fact)
      COMMENT = 'Average weakest-link confidence of resolved entities'
  )
  COMMENT = 'Entity resolution: golden records, duplicates and source crosswalk for the current published run';

-- ---------------------------------------------------------------------
-- 4. Scheduled incremental runs. Each phase file is staged and executed as
--    a Jinja template (EXECUTE IMMEDIATE FROM ... USING renders {{ KEY }}
--    placeholders; bind variables are accepted in USING). The run id comes
--    from the task graph run group, so every scheduled run is distinct and
--    a task retry re-uses the same run id (idempotent, rule 38).
--
--    Stage the rendered-once constants (schema names, model names,
--    thresholds) directly in the files, and leave RUN_ID, EXPERIMENT_ID and PRIOR_RUN_ID
--    as template variables. Files must not exceed the documented 100,000-byte
--    rendered-template limit.
-- ---------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS {{STAGE}}
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'Entity resolution phase SQL templates';

-- PUT file://.../01_standardize_and_block.sql @{{STAGE}}/er/ AUTO_COMPRESS = FALSE;  (run from a client)

-- Caller's rights: the phase files set QUERY_TAG, which owner's-rights
-- procedures cannot do. Tasks run as the task owner role, which is the caller.
CREATE OR REPLACE PROCEDURE ER_RUN_PHASE(phase_file VARCHAR, run_id VARCHAR, experiment_id VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    path       VARCHAR DEFAULT '@{{STAGE}}/er/' || phase_file;
    prior_run  VARCHAR;
BEGIN
    -- The golden phase inherits ids from the currently published run (rule 26).
    SELECT COALESCE(MAX(run_id), 'none') INTO :prior_run FROM ER_PUBLISHED_RUN WHERE is_current;
    EXECUTE IMMEDIATE 'EXECUTE IMMEDIATE FROM ' || path || ' USING ('
        || 'RUN_ID => '''       || REPLACE(run_id, '''', '')        || ''', '
        || 'EXPERIMENT_ID => ''' || REPLACE(experiment_id, '''', '') || ''', '
        || 'PRIOR_RUN_ID => '''  || REPLACE(prior_run, '''', '')     || ''')';
    RETURN phase_file || ' ok for ' || run_id;
END;
$$;

CREATE OR REPLACE TASK ER_ROOT
  WAREHOUSE = {{WAREHOUSE}}
  SCHEDULE = '{{SCHEDULE}}'
  COMMENT = 'Entity resolution incremental run'
AS
  CALL ER_RUN_PHASE('01_standardize_and_block.sql',
                    SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), 'scheduled');

CREATE OR REPLACE TASK ER_SCORE
  WAREHOUSE = {{WAREHOUSE}}
  AFTER ER_ROOT
AS
  CALL ER_RUN_PHASE('01_embed_and_score.sql',
                    SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), 'scheduled');

CREATE OR REPLACE TASK ER_ADJUDICATE
  WAREHOUSE = {{WAREHOUSE}}
  AFTER ER_SCORE
AS
  CALL ER_RUN_PHASE('01_adjudicate.sql',
                    SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), 'scheduled');

CREATE OR REPLACE TASK ER_GOLDEN
  WAREHOUSE = {{WAREHOUSE}}
  AFTER ER_ADJUDICATE
AS
  CALL ER_RUN_PHASE('01_cluster_and_survive.sql',
                    SYSTEM$TASK_RUNTIME_INFO('CURRENT_TASK_GRAPH_RUN_GROUP_ID'), 'scheduled');

-- Tasks are created suspended. Resume children before the root, and only
-- after the user confirms the schedule and the per-run adjudication cap.
-- ALTER TASK ER_GOLDEN RESUME; ALTER TASK ER_ADJUDICATE RESUME;
-- ALTER TASK ER_SCORE RESUME; ALTER TASK ER_ROOT RESUME;

-- Scheduled runs do NOT auto-promote. A run becomes current only through
-- section 1, after its quality checks pass. Write a promotion check that
-- compares the scheduled run's held-cluster count, cluster-size maximum and
-- model failure count against the published run, and alert rather than
-- promote when they regress.

-- ---------------------------------------------------------------------
-- 5. Cortex Agent for CoWork, over the semantic view. Verify the
--    specification against the CREATE AGENT reference (or the agent-studio
--    skill) before creating; successful creation does not validate tools.
-- ---------------------------------------------------------------------
CREATE OR REPLACE AGENT ER_ENTITY_RESOLUTION_AGENT
  COMMENT = 'Answers questions about resolved customers, vendors and products and their duplicates'
  PROFILE = '{"display_name": "Entity Resolution"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: {{AGENT_MODEL}}
  instructions:
    response: "Answer from the entity resolution semantic view only. State counts exactly as returned. When asked whether two records are the same entity, report the golden ids from the crosswalk and the cluster confidence; do not decide identity yourself. Do not reveal tax ids, phone numbers or bank details. Say plainly when a question needs data that is not in the view."
    orchestration: "Use the Analyst tool for every question about golden records, duplicates, source systems or crosswalk lookups."
    sample_questions:
      - question: "How many duplicate vendor records were found in each ERP?"
      - question: "Which customers exist in both CRM and billing?"
      - question: "Show the golden record and source records for a given customer name"
      - question: "How many products were collapsed into a single item?"
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "EntityResolutionAnalyst"
        description: "Golden records, duplicate counts, and the source-to-golden crosswalk for customers, vendors and products"
  tool_resources:
    EntityResolutionAnalyst:
      semantic_view: "{{DB}}.{{SCHEMA}}.ER_ENTITY_RESOLUTION_SV"
  $$;
