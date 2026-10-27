-- =====================================================================
-- Phase 3: triage and taxonomy-constrained signal extraction.
--
-- Written against the sandbox source tables. For production, replace the
-- source CTEs in step 1 with the mapping recorded in maintenance-project.yml
-- (sources.*). Nothing else should need to change.
--
-- SUBSTITUTE / SET BEFORE RUNNING:
--   {{DB}}, {{SCHEMA}}           pipeline location (sandbox tables live here too)
--   SET run_id            = '<unique per invocation>';
--   SET experiment_id     = 'exp_001';
--   SET prompt_version    = 'v1';
--   SET taxonomy_version  = 'tax_v1';
--   SET extract_model     = '<pinned GA model from preflight>';
--   SET max_input_tokens  = 6000;
--   SET sample_limit      = 500;   -- first run: a sample. Raise only after the gate.
--
-- Idempotent on run_id: re-running the same run_id inserts nothing new
-- for sources already processed under it.
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};

-- Attribute every AI call in this run (the usage view carries QUERY_TAG).
-- ALTER SESSION does not resolve $variables, so set the tag from a scripting block.
EXECUTE IMMEDIATE $$
BEGIN
    EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || $run_id || '''';
    RETURN 'query_tag set';
END;
$$;

-- ---------------------------------------------------------------------
-- 1. Unified source text. One row per note or inspection, with its own
--    timestamp, the asset FROM THE RECORD (never from text), the WO type
--    as context, and an asset-scoped dedup hash.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_SOURCE_TEXT AS
WITH notes AS (
    SELECT 'WO_NOTE'        AS source_type,
           n.note_id        AS source_id,
           n.wo_id,
           w.asset_id,                       -- from the work order header
           w.wo_type,
           n.note_ts        AS source_ts,
           n.note_text      AS source_text
    FROM SYNTH_WO_NOTES n
    JOIN SYNTH_WORK_ORDERS w ON w.wo_id = n.wo_id
), inspections AS (
    SELECT 'INSPECTION', r.report_id, NULL, r.asset_id, 'INSPECTION', r.inspection_ts, r.report_text
    FROM SYNTH_INSPECTION_REPORTS r
), unioned AS (
    SELECT * FROM notes
    UNION ALL
    SELECT * FROM inspections
)
SELECT u.source_type, u.source_id, u.wo_id, u.asset_id, a.asset_class, u.wo_type, u.source_ts,
       u.source_text,
       LOWER(REGEXP_REPLACE(TRIM(u.source_text), '\\s+', ' '))                       AS normalized_text,
       MD5(u.asset_id || '::' || LOWER(REGEXP_REPLACE(TRIM(u.source_text), '\\s+', ' '))) AS text_hash,
       LENGTH(u.source_text)                                                         AS text_chars
FROM unioned u
JOIN SYNTH_ASSETS a ON a.asset_id = u.asset_id
WHERE u.source_text IS NOT NULL AND LENGTH(TRIM(u.source_text)) > 0;

-- One representative row per (asset, normalized text). The extraction is
-- billed once per representative and fanned back out to every source.
CREATE OR REPLACE TABLE MAINT_SOURCE_DISTINCT AS
SELECT *
FROM MAINT_SOURCE_TEXT
QUALIFY ROW_NUMBER() OVER (PARTITION BY text_hash ORDER BY source_ts, source_id) = 1;

-- ---------------------------------------------------------------------
-- 2. Run-scoped tables (created once; rows accumulate across runs).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS MAINT_TRIAGE (
    run_id          VARCHAR,
    experiment_id   VARCHAR,
    text_hash       VARCHAR,
    asset_class     VARCHAR,
    triage_raw      VARIANT,
    triage_label    VARCHAR,
    triaged_at      TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS MAINT_SIGNAL_RAW (
    run_id            VARCHAR,
    experiment_id     VARCHAR,
    prompt_version    VARCHAR,
    taxonomy_version  VARCHAR,
    taxonomy_hash     VARCHAR,
    extract_model     VARCHAR,
    text_hash         VARCHAR,
    representative_source_type VARCHAR,
    representative_source_id   VARCHAR,
    asset_class       VARCHAR,
    prompt_hash       VARCHAR,
    response          VARIANT,
    extracted_at      TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS MAINT_SIGNALS (
    run_id             VARCHAR,
    experiment_id      VARCHAR,
    prompt_version     VARCHAR,
    prompt_hash        VARCHAR,
    taxonomy_version   VARCHAR,
    taxonomy_hash      VARCHAR,
    extract_model      VARCHAR,
    source_type        VARCHAR,
    source_id          VARCHAR,
    wo_id              VARCHAR,
    asset_id           VARCHAR,
    asset_class        VARCHAR,
    wo_type            VARCHAR,
    source_ts          TIMESTAMP_NTZ,
    signal_no          INT,
    component_code     VARCHAR,
    assembly_code      VARCHAR,
    component_mention  VARCHAR,
    failure_mode_code  VARCHAR,
    polarity           VARCHAR,
    severity           VARCHAR,
    measured_value     VARCHAR,
    cause_text         VARCHAR,
    action_text        VARCHAR,
    evidence_span      VARCHAR,
    evidence_found_in_source BOOLEAN,
    component_in_taxonomy    BOOLEAN,
    mode_in_taxonomy         BOOLEAN,
    loaded_at          TIMESTAMP_NTZ
);

CREATE TABLE IF NOT EXISTS PIPELINE_QUALITY_LOG (
    run_id        VARCHAR,
    stage         VARCHAR,
    metric        VARCHAR,
    value         NUMBER(38, 4),
    detail        VARIANT,
    logged_at     TIMESTAMP_NTZ
);

-- ---------------------------------------------------------------------
-- 3. Triage with AI_CLASSIFY on distinct texts. Categories are case
--    sensitive; compare exactly. Errs toward MAINTENANCE_FINDING.
--    Gate: estimate first with
--      SELECT SUM(AI_COUNT_TOKENS('ai_classify', source_text, <categories>)) ...
-- ---------------------------------------------------------------------
INSERT INTO MAINT_TRIAGE
WITH todo AS (
    SELECT d.*
    FROM MAINT_SOURCE_DISTINCT d
    WHERE NOT EXISTS (SELECT 1 FROM MAINT_TRIAGE t WHERE t.run_id = $run_id AND t.text_hash = d.text_hash)
    ORDER BY d.text_hash
    LIMIT $sample_limit
)
SELECT $run_id, $experiment_id, text_hash, asset_class,
       c.triage_raw,
       c.triage_raw:labels[0]::STRING,
       CURRENT_TIMESTAMP()
FROM (
    SELECT todo.*,
           AI_CLASSIFY(
               source_text,
               [
                 {'label': 'MAINTENANCE_FINDING',
                  'description': 'Mentions equipment condition, a measurement, a defect, a check result, or work done on a component'},
                 {'label': 'ADMIN_ONLY',
                  'description': 'Only scheduling, access, permits, parts ordering or travel, with no equipment condition'},
                 {'label': 'CLOSEOUT_BOILERPLATE',
                  'description': 'Only standard completion text such as job complete, area clean, permit closed'}
               ],
               {'task_description': 'Triage maintenance work order notes and inspection text before detailed extraction. If any equipment condition or component work is mentioned, choose MAINTENANCE_FINDING.'}
           ) AS triage_raw
    FROM todo
) c;

INSERT INTO PIPELINE_QUALITY_LOG
SELECT $run_id, 'triage', 'label_' || COALESCE(triage_label, 'NULL'), COUNT(*), NULL, CURRENT_TIMESTAMP()
FROM MAINT_TRIAGE WHERE run_id = $run_id
GROUP BY triage_label;

-- ---------------------------------------------------------------------
-- 4. Prompt assembly, once, in one column. The SAME column is hashed and
--    sent. Long texts are routed to segmentation (step 4b), never truncated.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE TMP_EXTRACT_PROMPTS AS
SELECT d.text_hash, d.source_type, d.source_id, d.asset_class, d.wo_type,
       x.taxonomy_hash, x.component_enum, x.mode_enum,
       'You are a reliability engineer extracting maintenance findings from one '
       || CASE d.source_type WHEN 'INSPECTION' THEN 'inspection report' ELSE 'work order note' END
       || ' for an asset of class ' || d.asset_class || '. Work order type: ' || COALESCE(d.wo_type, 'unknown') || '.\n\n'
       || 'Rules:\n'
       || '1. Return one signal per distinct component finding. Return an empty signals array if the text mentions no equipment condition, measurement, defect, check result, or work on a component.\n'
       || '2. polarity: OBSERVED = a fault, degradation or abnormal condition was seen or measured, even if mild (slight weep, trending up). '
       || 'RULED_OUT = checked and found normal, or explicitly negated (no leaks, OK, normal, N on a checklist, within tolerance, no fault found). '
       || 'ACTION_ONLY = work was done with no stated fault (greased, replaced per PM interval, retensioned). '
       || 'UNCLEAR = hedged or second-hand and not confirmed (operator thinks, possibly, may, could not find).\n'
       || '3. A replacement or repair is not itself a failure. Use ACTION_ONLY unless the text states the fault.\n'
       || '4. failure_mode_code is the observed effect, not the cause and not the action. Use NONE with RULED_OUT and ACTION_ONLY. Use OTHER only for a real finding that no code fits.\n'
       || '5. component_code must be one of the codes listed for this asset class. Use OTHER only if none fits. Always put the technician''s own words for the component in component_mention.\n'
       || '6. evidence_span: copy the exact words from the text that support the signal. Do not paraphrase, summarize or translate.\n'
       || '7. cause_text and action_text only when stated in the text; otherwise an empty string. measured_value only when a number with a unit is given.\n'
       || '8. Use the glossary to read shorthand.\n\n'
       || 'Components for ' || d.asset_class || ':\n' || x.component_text || '\n\n'
       || 'Failure modes (observed effect):\n' || x.mode_text || '\n\n'
       || 'Glossary:\n' || x.glossary_text || '\n\n'
       || 'TEXT:\n<<<\n' || d.source_text || '\n>>>\n\nRespond in JSON.'  AS prompt,
       AI_COUNT_TOKENS('ai_complete', $extract_model, d.source_text)      AS text_tokens
FROM MAINT_SOURCE_DISTINCT d
JOIN MAINT_TRIAGE t
  ON t.text_hash = d.text_hash AND t.run_id = $run_id
JOIN TAX_CLASS_CONTEXT x
  ON x.asset_class = d.asset_class AND x.taxonomy_version = $taxonomy_version
WHERE COALESCE(t.triage_label, 'MAINTENANCE_FINDING') = 'MAINTENANCE_FINDING'   -- a failed triage is NOT an exit
  AND NOT EXISTS (SELECT 1 FROM MAINT_SIGNAL_RAW r WHERE r.run_id = $run_id AND r.text_hash = d.text_hash);

-- 4b. Oversized texts: report, then segment (see SKILL.md). Must be zero
--     before step 5 runs on them, or they must be excluded explicitly.
SELECT COUNT(*) AS oversized_texts
FROM TMP_EXTRACT_PROMPTS
WHERE text_tokens > $max_input_tokens;

-- ---------------------------------------------------------------------
-- 5. Extraction. response_format is built PER ROW from the class enums, so
--    the schema and the prompt come from the same taxonomy rows.
--    return_error_details => TRUE: failures carry an error, not a bare NULL.
-- ---------------------------------------------------------------------
INSERT INTO MAINT_SIGNAL_RAW
SELECT $run_id, $experiment_id, $prompt_version, $taxonomy_version, p.taxonomy_hash, $extract_model,
       p.text_hash, p.source_type, p.source_id, p.asset_class,
       SHA2(p.prompt, 256),
       AI_COMPLETE(
           model            => $extract_model,
           prompt           => p.prompt,
           model_parameters => {'temperature': 0, 'max_tokens': 2048},
           response_format  => OBJECT_CONSTRUCT(
               'type', 'json',
               'schema', OBJECT_CONSTRUCT(
                   'type', 'object',
                   'properties', OBJECT_CONSTRUCT(
                       'has_maintenance_finding', OBJECT_CONSTRUCT('type', 'boolean'),
                       'signals', OBJECT_CONSTRUCT(
                           'type', 'array',
                           'items', OBJECT_CONSTRUCT(
                               'type', 'object',
                               'properties', OBJECT_CONSTRUCT(
                                   'component_code',    OBJECT_CONSTRUCT('type', 'string', 'enum', p.component_enum),
                                   'component_mention', OBJECT_CONSTRUCT('type', 'string'),
                                   'failure_mode_code', OBJECT_CONSTRUCT('type', 'string', 'enum', p.mode_enum),
                                   'polarity',          OBJECT_CONSTRUCT('type', 'string', 'enum',
                                                            ARRAY_CONSTRUCT('OBSERVED', 'RULED_OUT', 'ACTION_ONLY', 'UNCLEAR')),
                                   'severity',          OBJECT_CONSTRUCT('type', 'string', 'enum',
                                                            ARRAY_CONSTRUCT('LOW', 'MEDIUM', 'HIGH', 'UNKNOWN')),
                                   'measured_value',    OBJECT_CONSTRUCT('type', 'string'),
                                   'cause_text',        OBJECT_CONSTRUCT('type', 'string'),
                                   'action_text',       OBJECT_CONSTRUCT('type', 'string'),
                                   'evidence_span',     OBJECT_CONSTRUCT('type', 'string',
                                                            'description', 'Exact words copied from the text. Do not paraphrase.')
                               ),
                               'required', ARRAY_CONSTRUCT('component_code', 'component_mention', 'failure_mode_code',
                                                           'polarity', 'severity', 'evidence_span')
                           )
                       )
                   ),
                   'required', ARRAY_CONSTRUCT('has_maintenance_finding', 'signals')
               )
           ),
           show_details         => TRUE,
           return_error_details => TRUE
       ),
       CURRENT_TIMESTAMP()
FROM TMP_EXTRACT_PROMPTS p
WHERE p.text_tokens <= $max_input_tokens;

-- Quality log: errors, unparseable, empty (JSON null is not SQL NULL -- cast).
INSERT INTO PIPELINE_QUALITY_LOG
SELECT $run_id, 'extract', m.metric, m.value, NULL, CURRENT_TIMESTAMP()
FROM (
    SELECT (COUNT(*))::NUMBER(38, 4) AS calls,
           (COUNT_IF(response:error::STRING IS NOT NULL))::NUMBER(38, 4) AS errored,
           (COUNT_IF(response:error::STRING IS NULL
                    AND response:value:structured_output[0]:raw_message:signals IS NULL))::NUMBER(38, 4) AS unparseable,
           (COUNT_IF(ARRAY_SIZE(response:value:structured_output[0]:raw_message:signals) = 0))::NUMBER(38, 4) AS empty_signals,
           (SUM(response:value:usage:prompt_tokens::INT))::NUMBER(38, 4)     AS prompt_tokens,
           (SUM(response:value:usage:completion_tokens::INT))::NUMBER(38, 4) AS completion_tokens
    FROM MAINT_SIGNAL_RAW WHERE run_id = $run_id
) UNPIVOT (value FOR metric IN (calls, errored, unparseable, empty_signals, prompt_tokens, completion_tokens)) m;

-- ---------------------------------------------------------------------
-- 6. Flatten, validate, fan out to every source sharing the text hash.
-- ---------------------------------------------------------------------
INSERT INTO MAINT_SIGNALS
WITH flat AS (
    SELECT r.run_id, r.experiment_id, r.prompt_version, r.prompt_hash, r.taxonomy_version, r.taxonomy_hash,
           r.extract_model, r.text_hash, r.asset_class,
           f.index                                 AS signal_no,
           f.value:component_code::STRING          AS component_code,
           f.value:component_mention::STRING       AS component_mention,
           f.value:failure_mode_code::STRING       AS failure_mode_code,
           f.value:polarity::STRING                AS polarity,
           f.value:severity::STRING                AS severity,
           NULLIF(f.value:measured_value::STRING, '') AS measured_value,
           NULLIF(f.value:cause_text::STRING, '')     AS cause_text,
           NULLIF(f.value:action_text::STRING, '')    AS action_text,
           f.value:evidence_span::STRING           AS evidence_span
    FROM MAINT_SIGNAL_RAW r,
         LATERAL FLATTEN(input => r.response:value:structured_output[0]:raw_message:signals) f
    WHERE r.run_id = $run_id
)
SELECT f.run_id, f.experiment_id, f.prompt_version, f.prompt_hash, f.taxonomy_version, f.taxonomy_hash,
       f.extract_model,
       s.source_type, s.source_id, s.wo_id, s.asset_id, s.asset_class, s.wo_type, s.source_ts,
       f.signal_no, f.component_code, c.assembly_code, f.component_mention, f.failure_mode_code,
       f.polarity, f.severity, f.measured_value, f.cause_text, f.action_text, f.evidence_span,
       CONTAINS(s.normalized_text, LOWER(REGEXP_REPLACE(TRIM(f.evidence_span), '\\s+', ' '))) AS evidence_found_in_source,
       c.component_code IS NOT NULL                                                          AS component_in_taxonomy,
       m.failure_mode_code IS NOT NULL                                                       AS mode_in_taxonomy,
       CURRENT_TIMESTAMP()
FROM flat f
JOIN MAINT_SOURCE_TEXT s ON s.text_hash = f.text_hash
LEFT JOIN TAX_COMPONENT c
  ON c.taxonomy_version = f.taxonomy_version AND c.asset_class = f.asset_class AND c.component_code = f.component_code
LEFT JOIN TAX_FAILURE_MODE m
  ON m.taxonomy_version = f.taxonomy_version AND m.failure_mode_code = f.failure_mode_code
WHERE NOT EXISTS (
    SELECT 1 FROM MAINT_SIGNALS x
    WHERE x.run_id = f.run_id AND x.source_type = s.source_type AND x.source_id = s.source_id
);

INSERT INTO PIPELINE_QUALITY_LOG
SELECT $run_id, 'signals', m.metric, m.value, NULL, CURRENT_TIMESTAMP()
FROM (
    SELECT (COUNT(*))::NUMBER(38, 4)                                    AS signals,
           (COUNT_IF(NOT evidence_found_in_source))::NUMBER(38, 4)      AS evidence_not_found,
           (COUNT_IF(NOT component_in_taxonomy))::NUMBER(38, 4)         AS component_not_in_taxonomy,
           (COUNT_IF(NOT mode_in_taxonomy))::NUMBER(38, 4)              AS mode_not_in_taxonomy,
           (COUNT_IF(component_code = 'OTHER'))::NUMBER(38, 4)          AS component_other,
           (COUNT_IF(polarity = 'OBSERVED'))::NUMBER(38, 4)             AS observed,
           (COUNT_IF(polarity = 'RULED_OUT'))::NUMBER(38, 4)            AS ruled_out,
           (COUNT_IF(polarity = 'ACTION_ONLY'))::NUMBER(38, 4)          AS action_only,
           (COUNT_IF(polarity = 'UNCLEAR'))::NUMBER(38, 4)              AS unclear
    FROM MAINT_SIGNALS WHERE run_id = $run_id
) UNPIVOT (value FOR metric IN (signals, evidence_not_found, component_not_in_taxonomy, mode_not_in_taxonomy,
                                component_other, observed, ruled_out, action_only, unclear)) m;

-- ---------------------------------------------------------------------
-- 7. The only view downstream consumers may read for failure statistics.
--    Polarity and provenance filters live here, once.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW MAINT_SIGNALS_OBSERVED AS
SELECT *
FROM MAINT_SIGNALS
WHERE polarity = 'OBSERVED'
  AND evidence_found_in_source
  AND component_in_taxonomy
  AND mode_in_taxonomy;

-- Gate summary for this run.
SELECT stage, metric, value FROM PIPELINE_QUALITY_LOG WHERE run_id = $run_id ORDER BY stage, metric;

ALTER SESSION UNSET QUERY_TAG;
