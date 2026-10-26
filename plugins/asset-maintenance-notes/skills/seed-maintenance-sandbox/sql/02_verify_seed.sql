-- =====================================================================
-- Verification for the synthetic maintenance sandbox. Read-only.
-- Same placeholders as 01_seed_sandbox.sql. Run every check and show the
-- result at the Phase 1 gate; a check that returns rows where it should
-- return none is a generator bug, not a pipeline bug.
-- =====================================================================

-- 1. Row counts per table.
SELECT 'SYNTH_ASSETS' AS tbl, COUNT(*) AS n FROM {{DB}}.{{SCHEMA}}.SYNTH_ASSETS
UNION ALL SELECT 'SYNTH_WORK_ORDERS',        COUNT(*) FROM {{DB}}.{{SCHEMA}}.SYNTH_WORK_ORDERS
UNION ALL SELECT 'SYNTH_WO_NOTES',           COUNT(*) FROM {{DB}}.{{SCHEMA}}.SYNTH_WO_NOTES
UNION ALL SELECT 'SYNTH_INSPECTION_REPORTS', COUNT(*) FROM {{DB}}.{{SCHEMA}}.SYNTH_INSPECTION_REPORTS
UNION ALL SELECT 'SYNTH_SENSOR_DAILY',       COUNT(*) FROM {{DB}}.{{SCHEMA}}.SYNTH_SENSOR_DAILY
UNION ALL SELECT 'SYNTH_DOWNTIME_EVENTS',    COUNT(*) FROM {{DB}}.{{SCHEMA}}.SYNTH_DOWNTIME_EVENTS
UNION ALL SELECT 'ANSWER_KEY_SOURCES',       COUNT(*) FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_SOURCES
UNION ALL SELECT 'ANSWER_KEY_SIGNALS',       COUNT(*) FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_SIGNALS
UNION ALL SELECT 'ANSWER_KEY_PRECURSORS',    COUNT(*) FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_PRECURSORS
UNION ALL SELECT 'ANSWER_KEY_RECURRING',     COUNT(*) FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_RECURRING
UNION ALL SELECT 'ANSWER_KEY_LEAKAGE_CANARY',COUNT(*) FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_LEAKAGE_CANARY;

-- 2. Every generated text produced exactly one pipeline row (no template
--    failed to match). Must return zero rows.
SELECT k.source_type, k.source_id
FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_SOURCES k
LEFT JOIN {{DB}}.{{SCHEMA}}.SYNTH_WO_NOTES n
  ON k.source_type = 'WO_NOTE' AND n.note_id = k.source_id
LEFT JOIN {{DB}}.{{SCHEMA}}.SYNTH_INSPECTION_REPORTS r
  ON k.source_type = 'INSPECTION' AND r.report_id = k.source_id
WHERE n.note_id IS NULL AND r.report_id IS NULL;

-- 3. Every work order has a main note. Must return zero rows.
SELECT w.wo_id
FROM {{DB}}.{{SCHEMA}}.SYNTH_WORK_ORDERS w
LEFT JOIN {{DB}}.{{SCHEMA}}.SYNTH_WO_NOTES n ON n.note_id = w.wo_id || '-N1'
WHERE n.note_id IS NULL;

-- 4. No placeholder survived. Must return zero.
SELECT COUNT(*) AS unfilled
FROM {{DB}}.{{EVAL_SCHEMA}}.SYNTH_GEN_TEXT
WHERE source_text LIKE '%{TAG}%' OR source_text LIKE '%{V1}%' OR source_text LIKE '%{T1}%';

-- 5. Label mix, the shape the extractor must reproduce.
SELECT k.kind, COUNT(DISTINCT k.source_id) AS sources,
       COUNT(s.source_id) AS labels,
       COUNT_IF(s.polarity = 'OBSERVED')    AS observed,
       COUNT_IF(s.polarity = 'RULED_OUT')   AS ruled_out,
       COUNT_IF(s.polarity = 'ACTION_ONLY') AS action_only,
       COUNT_IF(s.polarity = 'UNCLEAR')     AS unclear
FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_SOURCES k
LEFT JOIN {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_SIGNALS s
  ON s.source_type = k.source_type AND s.source_id = k.source_id
GROUP BY 1 ORDER BY 2 DESC;

-- 6. Quarantine: no pipeline-schema column name suggests a label.
--    Must return zero rows.
SELECT table_name, column_name
FROM {{DB}}.information_schema.columns
WHERE table_schema = '{{SCHEMA}}'
  AND (column_name ILIKE '%TEMPLATE%' OR column_name ILIKE '%SCENARIO%'
    OR column_name ILIKE '%LABEL%'    OR column_name ILIKE '%GEN_ROLE%'
    OR column_name ILIKE 'KIND');

-- 7. Planted failure chain is complete per asset: 3 precursor texts before
--    the event, one unplanned downtime event, one emergency WO.
WITH texts AS (
    SELECT p.asset_id,
           COUNT_IF(k.gen_role IN ('SCEN_PRECURSOR', 'SCEN_ROUTE') AND k.source_ts < p.failure_ts) AS precursor_texts
    FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_PRECURSORS p
    JOIN {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_SOURCES k ON k.asset_id = p.asset_id
    WHERE p.scenario = 'PLANTED_FAILURE'
    GROUP BY p.asset_id
), events AS (
    SELECT asset_id, COUNT(*) AS unplanned_events
    FROM {{DB}}.{{SCHEMA}}.SYNTH_DOWNTIME_EVENTS
    WHERE NOT is_planned
    GROUP BY asset_id
)
SELECT t.asset_id, t.precursor_texts, COALESCE(e.unplanned_events, 0) AS unplanned_events
FROM texts t
LEFT JOIN events e ON e.asset_id = t.asset_id
WHERE t.precursor_texts <> 3 OR COALESCE(e.unplanned_events, 0) <> 1;

-- 8. Leakage traps are where they should be: every canary record is
--    timestamped after its failure (hindsight, as-found) or is the failure
--    WO note itself. Must return zero rows.
SELECT c.*
FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_LEAKAGE_CANARY c
JOIN {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_PRECURSORS p ON p.event_id = c.event_id
WHERE c.reason IN ('LEAK_HINDSIGHT', 'LEAK_AS_FOUND') AND c.source_ts <= p.failure_ts;

-- 9. The hindsight trap is reachable through a WO created BEFORE the
--    failure -- which is exactly why a WO-created filter leaks. Expect one
--    row per planted asset.
SELECT c.asset_id, w.created_at AS wo_created, c.source_ts AS note_ts, p.failure_ts
FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_LEAKAGE_CANARY c
JOIN {{DB}}.{{SCHEMA}}.SYNTH_WORK_ORDERS w ON w.wo_id = c.wo_id
JOIN {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_PRECURSORS p ON p.event_id = c.event_id
WHERE c.reason = 'LEAK_HINDSIGHT' AND w.created_at < p.failure_ts
ORDER BY 1 LIMIT 10;

-- 10. Sensor drift is visible for planted assets and absent for controls
--     outside their one-day spike.
SELECT p.scenario,
       ROUND(AVG(CASE WHEN DATEDIFF(day, s.reading_date, p.failure_ts::DATE) BETWEEN 1 AND 10
                      THEN s.vibration_mm_s END), 2) AS vib_last_10d_before_event,
       ROUND(AVG(CASE WHEN DATEDIFF(day, s.reading_date, p.failure_ts::DATE) BETWEEN 100 AND 200
                      THEN s.vibration_mm_s END), 2) AS vib_baseline
FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_PRECURSORS p
JOIN {{DB}}.{{SCHEMA}}.SYNTH_SENSOR_DAILY s ON s.asset_id = p.asset_id
WHERE p.scenario = 'PLANTED_FAILURE'
GROUP BY 1;

-- 11. Missing sensor readings are NULL, never zero. Expect a few percent
--     NULL and zero exact-zero readings.
SELECT ROUND(100.0 * COUNT_IF(vibration_mm_s IS NULL) / COUNT(*), 2) AS pct_null_vib,
       COUNT_IF(vibration_mm_s = 0) AS zero_vib
FROM {{DB}}.{{SCHEMA}}.SYNTH_SENSOR_DAILY;

-- 12. Event dates straddle any reasonable time split (needed for a
--     train/test evaluation with events on both sides).
SELECT MIN(failure_ts) AS first_event, MAX(failure_ts) AS last_event,
       DATEADD(day, ROUND(MEDIAN(DATEDIFF(day, '2000-01-01'::DATE, failure_ts::DATE)))::INT, '2000-01-01'::DATE) AS median_event,
       COUNT(*) AS planted_events
FROM {{DB}}.{{EVAL_SCHEMA}}.ANSWER_KEY_PRECURSORS
WHERE scenario = 'PLANTED_FAILURE';

-- 13. CMMS failure-code baseline on corrective WOs (the field this play
--     replaces). Expect OTHER to dominate.
SELECT COALESCE(failure_code, '<null>') AS failure_code, COUNT(*) AS wos
FROM {{DB}}.{{SCHEMA}}.SYNTH_WORK_ORDERS
WHERE wo_type IN ('CM', 'EMERGENCY')
GROUP BY 1 ORDER BY 2 DESC;
