-- =====================================================================
-- Phase 6: evaluation harness. Runs as the harness role; the ONLY code
-- that reads {{EVAL_SCHEMA}}.
--
-- SET BEFORE RUNNING:
--   SET run_id          = '<extraction run_id>';
--   SET experiment_id   = '<experiment_id>';
--   SET horizon_days    = <as in Phase 5>;
--   SET min_lead_days   = <as in Phase 5>;
--   SET alert_budget    = <alerts per month planners can act on>;
--   SET model_variant   = 'COMBINED';   -- repeat for SENSOR, TEXT
--
-- Every metric is built from GROUND TRUTH outward: a labeled source the
-- pipeline dropped, errored on, or triaged out counts as missed.
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};

CREATE TABLE IF NOT EXISTS {{EVAL_SCHEMA}}.EVAL_EXTRACTION_SUMMARY (
    run_id VARCHAR, experiment_id VARCHAR, taxonomy_version VARCHAR, prompt_hash VARCHAR,
    level VARCHAR, slice VARCHAR, truth_n INT, pred_n INT, tp INT,
    precision_ FLOAT, recall_ FLOAT, f1 FLOAT, evaluated_at TIMESTAMP_NTZ
);

-- ---------------------------------------------------------------------
-- 0. Coverage: labeled sources that never produced a parseable response.
-- ---------------------------------------------------------------------
SELECT COUNT(DISTINCT k.source_id)                                                          AS labeled_sources,
       COUNT(DISTINCT IFF(t.text_hash IS NULL, k.source_id, NULL))                          AS not_in_source_text,
       COUNT(DISTINCT IFF(tr.triage_label IS NOT NULL
                          AND tr.triage_label <> 'MAINTENANCE_FINDING', k.source_id, NULL)) AS triaged_out,
       COUNT(DISTINCT IFF(r.text_hash IS NULL AND COALESCE(tr.triage_label, 'MAINTENANCE_FINDING') = 'MAINTENANCE_FINDING',
                          k.source_id, NULL))                                               AS not_extracted,
       COUNT(DISTINCT IFF(r.response:error::STRING IS NOT NULL, k.source_id, NULL))         AS errored,
       COUNT(DISTINCT IFF(r.response:error::STRING IS NULL
                          AND r.response:value:structured_output[0]:raw_message:signals IS NULL,
                          k.source_id, NULL))                                               AS unparseable
FROM (SELECT DISTINCT source_type, source_id FROM {{EVAL_SCHEMA}}.ANSWER_KEY_SIGNALS) k
LEFT JOIN MAINT_SOURCE_TEXT t ON t.source_type = k.source_type AND t.source_id = k.source_id
LEFT JOIN MAINT_TRIAGE tr     ON tr.text_hash = t.text_hash AND tr.run_id = $run_id
LEFT JOIN MAINT_SIGNAL_RAW r  ON r.text_hash = t.text_hash AND r.run_id = $run_id;

-- ---------------------------------------------------------------------
-- 1. Failure signals (OBSERVED), hierarchical: exact / component-only /
--    assembly-only / miss. The headline extraction metric.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE EV_TRUTH_OBS AS
SELECT DISTINCT source_type, source_id, asset_class, component_code, assembly_code, failure_mode_code
FROM {{EVAL_SCHEMA}}.ANSWER_KEY_SIGNALS
WHERE polarity = 'OBSERVED';

CREATE OR REPLACE TEMPORARY TABLE EV_PRED_OBS AS
SELECT DISTINCT source_type, source_id, asset_class, component_code, assembly_code, failure_mode_code
FROM MAINT_SIGNALS_OBSERVED
WHERE run_id = $run_id
  -- restrict to sources that exist in the key (all generated sources are in ANSWER_KEY_SOURCES)
  AND (source_type, source_id) IN (SELECT source_type, source_id FROM {{EVAL_SCHEMA}}.ANSWER_KEY_SOURCES);

-- Refuse to pool across taxonomy versions or prompts. Must return 1, 1.
SELECT COUNT(DISTINCT taxonomy_version) AS taxonomy_versions, COUNT(DISTINCT prompt_hash) AS prompt_hashes
FROM MAINT_SIGNALS WHERE run_id = $run_id;

CREATE OR REPLACE TEMPORARY TABLE EV_TRUTH_OUTCOME AS
SELECT t.source_type, t.source_id, t.asset_class, t.component_code, t.assembly_code, t.failure_mode_code,
       CASE WHEN MAX(IFF(p.component_code = t.component_code AND p.failure_mode_code = t.failure_mode_code, 1, 0)) = 1 THEN 'EXACT'
            WHEN MAX(IFF(p.component_code = t.component_code, 1, 0)) = 1 THEN 'COMPONENT_ONLY'
            WHEN MAX(IFF(p.assembly_code = t.assembly_code, 1, 0)) = 1   THEN 'ASSEMBLY_ONLY'
            ELSE 'MISS' END AS outcome
FROM EV_TRUTH_OBS t
LEFT JOIN EV_PRED_OBS p ON p.source_type = t.source_type AND p.source_id = t.source_id
GROUP BY 1, 2, 3, 4, 5, 6;

CREATE OR REPLACE TEMPORARY TABLE EV_PRED_OUTCOME AS
SELECT p.source_type, p.source_id, p.asset_class, p.component_code, p.assembly_code, p.failure_mode_code,
       CASE WHEN MAX(IFF(t.component_code = p.component_code AND t.failure_mode_code = p.failure_mode_code, 1, 0)) = 1 THEN 'EXACT'
            WHEN MAX(IFF(t.component_code = p.component_code, 1, 0)) = 1 THEN 'WRONG_MODE'
            WHEN MAX(IFF(t.assembly_code = p.assembly_code, 1, 0)) = 1   THEN 'WRONG_COMPONENT_SAME_ASSEMBLY'
            WHEN MAX(IFF(k.source_id IS NOT NULL, 1, 0)) = 1              THEN 'POLARITY_ERROR'   -- truth has this component, not OBSERVED
            ELSE 'SPURIOUS' END AS outcome
FROM EV_PRED_OBS p
LEFT JOIN EV_TRUTH_OBS t ON t.source_type = p.source_type AND t.source_id = p.source_id
LEFT JOIN {{EVAL_SCHEMA}}.ANSWER_KEY_SIGNALS k
  ON k.source_type = p.source_type AND k.source_id = p.source_id
 AND k.component_code = p.component_code AND k.polarity <> 'OBSERVED'
GROUP BY 1, 2, 3, 4, 5, 6;

-- Outcome distributions (the actionable view).
SELECT 'truth' AS side, outcome, COUNT(*) AS n FROM EV_TRUTH_OUTCOME GROUP BY 1, 2
UNION ALL
SELECT 'pred', outcome, COUNT(*) FROM EV_PRED_OUTCOME GROUP BY 1, 2
ORDER BY 1, 3 DESC;

-- Micro P/R/F1 at three levels, overall and per asset class.
INSERT INTO {{EVAL_SCHEMA}}.EVAL_EXTRACTION_SUMMARY
WITH lv AS (
    SELECT 'OBS_EXACT' AS level, asset_class,
           COUNT_IF(outcome = 'EXACT') AS truth_hits, COUNT(*) AS truth_n, NULL::INT AS pred_hits, NULL::INT AS pred_n
    FROM EV_TRUTH_OUTCOME GROUP BY 2
    UNION ALL
    SELECT 'OBS_EXACT', asset_class, NULL, NULL, COUNT_IF(outcome = 'EXACT'), COUNT(*)
    FROM EV_PRED_OUTCOME GROUP BY 2
    UNION ALL
    SELECT 'OBS_COMPONENT', asset_class, COUNT_IF(outcome IN ('EXACT', 'COMPONENT_ONLY')), COUNT(*), NULL, NULL
    FROM EV_TRUTH_OUTCOME GROUP BY 2
    UNION ALL
    SELECT 'OBS_COMPONENT', asset_class, NULL, NULL, COUNT_IF(outcome IN ('EXACT', 'WRONG_MODE')), COUNT(*)
    FROM EV_PRED_OUTCOME GROUP BY 2
    UNION ALL
    SELECT 'OBS_ASSEMBLY', asset_class, COUNT_IF(outcome <> 'MISS'), COUNT(*), NULL, NULL
    FROM EV_TRUTH_OUTCOME GROUP BY 2
    UNION ALL
    SELECT 'OBS_ASSEMBLY', asset_class, NULL, NULL,
           COUNT_IF(outcome IN ('EXACT', 'WRONG_MODE', 'WRONG_COMPONENT_SAME_ASSEMBLY')), COUNT(*)
    FROM EV_PRED_OUTCOME GROUP BY 2
), agg AS (
    SELECT level, COALESCE(asset_class, 'ALL') AS slice,
           SUM(truth_n) AS truth_n, SUM(pred_n) AS pred_n,
           SUM(truth_hits) AS truth_hits, SUM(pred_hits) AS pred_hits
    FROM lv GROUP BY GROUPING SETS ((level, asset_class), (level))
)
SELECT $run_id, $experiment_id,
       (SELECT ANY_VALUE(taxonomy_version) FROM MAINT_SIGNALS WHERE run_id = $run_id),
       (SELECT ANY_VALUE(prompt_hash)      FROM MAINT_SIGNALS WHERE run_id = $run_id),
       level, slice, truth_n, pred_n, truth_hits,
       pred_hits / NULLIF(pred_n, 0)                                         AS precision_,
       truth_hits / NULLIF(truth_n, 0)                                       AS recall_,
       2 * (pred_hits / NULLIF(pred_n, 0)) * (truth_hits / NULLIF(truth_n, 0))
         / NULLIF((pred_hits / NULLIF(pred_n, 0)) + (truth_hits / NULLIF(truth_n, 0)), 0) AS f1,
       CURRENT_TIMESTAMP()
FROM agg;

SELECT level, slice, truth_n, pred_n, ROUND(precision_, 3) AS precision_, ROUND(recall_, 3) AS recall_, ROUND(f1, 3) AS f1
FROM {{EVAL_SCHEMA}}.EVAL_EXTRACTION_SUMMARY
WHERE run_id = $run_id
ORDER BY level, slice;

-- Macro: per-source F1 at the exact level, so simple one-finding notes count
-- as much as multi-finding ones. Sources with neither truth nor prediction
-- are correct empties and are reported separately, not averaged in.
WITH t AS (
    SELECT source_type, source_id, COUNT(*) AS t_n, COUNT_IF(outcome = 'EXACT') AS t_hit
    FROM EV_TRUTH_OUTCOME GROUP BY 1, 2
), p AS (
    SELECT source_type, source_id, COUNT(*) AS p_n, COUNT_IF(outcome = 'EXACT') AS p_hit
    FROM EV_PRED_OUTCOME GROUP BY 1, 2
), per_source AS (
    SELECT s.source_type, s.source_id,
           COALESCE(t.t_n, 0) AS t_n, COALESCE(t.t_hit, 0) AS t_hit,
           COALESCE(p.p_n, 0) AS p_n, COALESCE(p.p_hit, 0) AS p_hit
    FROM {{EVAL_SCHEMA}}.ANSWER_KEY_SOURCES s
    LEFT JOIN t ON t.source_type = s.source_type AND t.source_id = s.source_id
    LEFT JOIN p ON p.source_type = s.source_type AND p.source_id = s.source_id
), scored AS (
    SELECT *, CASE WHEN t_n = 0 AND p_n = 0 THEN NULL
                   ELSE 2.0 * p_hit / NULLIF(p_n + t_n, 0) END AS f1   -- 2TP / (pred + truth); TP equal on both sides for exact tuples
    FROM per_source
)
SELECT COUNT_IF(f1 IS NOT NULL)         AS sources_scored,
       COUNT_IF(t_n = 0 AND p_n = 0)    AS correct_empties,
       COUNT_IF(t_n = 0 AND p_n > 0)    AS false_positive_sources,
       ROUND(AVG(f1), 3)                AS macro_f1,
       ROUND(STDDEV(f1), 3)             AS macro_f1_stddev,
       ROUND(MIN(f1), 3)                AS min_f1
FROM scored;

-- ---------------------------------------------------------------------
-- 2. Polarity confusion on (source, component), all polarities.
-- ---------------------------------------------------------------------
WITH t AS (
    SELECT DISTINCT source_type, source_id, component_code, polarity
    FROM {{EVAL_SCHEMA}}.ANSWER_KEY_SIGNALS
), p AS (
    SELECT DISTINCT source_type, source_id, component_code, polarity
    FROM MAINT_SIGNALS
    WHERE run_id = $run_id AND evidence_found_in_source AND component_in_taxonomy
      AND (source_type, source_id) IN (SELECT source_type, source_id FROM {{EVAL_SCHEMA}}.ANSWER_KEY_SOURCES)
)
SELECT COALESCE(t.polarity, '(none)') AS true_polarity,
       COALESCE(p.polarity, '(none)') AS predicted_polarity,
       COUNT(*) AS n
FROM t
FULL OUTER JOIN p
  ON p.source_type = t.source_type AND p.source_id = t.source_id AND p.component_code = t.component_code
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

-- Breakdown by text kind: where do errors concentrate? (negatives, PM, hedged...)
WITH truth_by_kind AS (
    SELECT s.kind,
           COUNT_IF(o.outcome = 'EXACT') AS exact,
           COUNT_IF(o.outcome = 'MISS')  AS missed
    FROM {{EVAL_SCHEMA}}.ANSWER_KEY_SOURCES s
    LEFT JOIN EV_TRUTH_OUTCOME o ON o.source_type = s.source_type AND o.source_id = s.source_id
    GROUP BY s.kind
), pred_by_kind AS (
    SELECT s.kind, COUNT_IF(p.outcome IN ('SPURIOUS', 'POLARITY_ERROR')) AS false_failures
    FROM EV_PRED_OUTCOME p
    JOIN {{EVAL_SCHEMA}}.ANSWER_KEY_SOURCES s ON s.source_type = p.source_type AND s.source_id = p.source_id
    GROUP BY s.kind
)
SELECT t.kind, t.exact, t.missed, COALESCE(p.false_failures, 0) AS false_failures
FROM truth_by_kind t
LEFT JOIN pred_by_kind p ON p.kind = t.kind
ORDER BY false_failures DESC, missed DESC;

-- Agreement with the CMMS failure code (comparison only, never accuracy).
SELECT w.failure_code, COUNT(DISTINCT w.wo_id) AS corrective_wos,
       COUNT(DISTINCT IFF(t.source_id IS NOT NULL, w.wo_id, NULL)) AS wos_with_true_observed_failure
FROM SYNTH_WORK_ORDERS w
LEFT JOIN SYNTH_WO_NOTES n ON n.wo_id = w.wo_id
LEFT JOIN EV_TRUTH_OBS t ON t.source_type = 'WO_NOTE' AND t.source_id = n.note_id
WHERE w.wo_type IN ('CM', 'EMERGENCY')
GROUP BY 1 ORDER BY 2 DESC;

-- ---------------------------------------------------------------------
-- 3. Recurring issues: planted groups recovered as one cluster with repeats.
-- ---------------------------------------------------------------------
SELECT COUNT(*)                                        AS planted_groups,
       COUNT_IF(clusters = 1)                          AS recovered_as_one_cluster,
       COUNT_IF(clusters > 1)                          AS fragmented,
       COUNT_IF(clusters = 0)                          AS not_extracted,
       COUNT_IF(repeats = 2)                           AS repeats_exact,
       ROUND(AVG(repeats), 2)                          AS avg_repeats_found
FROM (
    SELECT g.asset_id, g.clusters, COALESCE(r.repeats, 0) AS repeats
    FROM (SELECT k.asset_id, COUNT(DISTINCT m.cluster_id) AS clusters
          FROM {{EVAL_SCHEMA}}.ANSWER_KEY_RECURRING k
          LEFT JOIN MAINT_SIGNAL_CLUSTER_MAP m ON m.wo_id = k.wo_id
          GROUP BY k.asset_id) g
    LEFT JOIN (SELECT asset_id, COUNT(*) AS repeats FROM MAINT_REPEAT_VISITS GROUP BY 1) r
      ON r.asset_id = g.asset_id
);

-- Spurious repeats on assets with no planted recurring group.
SELECT COUNT(*) AS repeats_on_non_recurring_assets
FROM MAINT_REPEAT_VISITS r
WHERE r.asset_id NOT IN (SELECT asset_id FROM {{EVAL_SCHEMA}}.ANSWER_KEY_RECURRING);

-- ---------------------------------------------------------------------
-- 4. Precursors: leakage canary, alert budget, precision, event recall,
--    lead-time distribution, false alarms on controls.
-- ---------------------------------------------------------------------

-- 4a. Canary. For each planted event's last pre-failure cutoff:
--     leaked = canary signals visible under the pipeline's note_ts rule (must be 0)
--     trap_live = canary signals that WOULD be visible under a WO-created rule (expect > 0)
WITH last_cut AS (
    SELECT f.asset_id, MAX(f.cutoff_ts) AS cutoff_ts, p.failure_ts, p.event_id
    FROM MAINT_PRECURSOR_FEATURES f
    JOIN {{EVAL_SCHEMA}}.ANSWER_KEY_PRECURSORS p ON p.asset_id = f.asset_id AND p.scenario = 'PLANTED_FAILURE'
    WHERE f.cutoff_ts < p.failure_ts
    GROUP BY f.asset_id, p.failure_ts, p.event_id
)
SELECT COUNT(DISTINCT lc.event_id) AS events_checked,
       COUNT_IF(s.source_ts < lc.cutoff_ts)  AS leaked_under_note_ts,
       COUNT_IF(w.created_at < lc.cutoff_ts) AS trap_live_under_wo_created
FROM last_cut lc
JOIN {{EVAL_SCHEMA}}.ANSWER_KEY_LEAKAGE_CANARY c ON c.event_id = lc.event_id
LEFT JOIN MAINT_SIGNALS s ON s.source_id = c.source_id AND s.run_id = $run_id
LEFT JOIN SYNTH_WORK_ORDERS w ON w.wo_id = c.wo_id;

-- 4b. Threshold from the TRAIN period at the alert budget, applied to TEST.
CREATE OR REPLACE TEMPORARY TABLE EV_THRESHOLD AS
WITH tr AS (
    SELECT risk_score, cutoff_ts FROM MAINT_ASSET_RISK
    WHERE run_id = $run_id AND model_variant = $model_variant AND split = 'TRAIN' AND risk_score IS NOT NULL
), months AS (
    SELECT GREATEST(1, DATEDIFF(month, MIN(cutoff_ts), MAX(cutoff_ts)) + 1) AS n_months FROM tr
), ranked AS (
    SELECT risk_score, ROW_NUMBER() OVER (ORDER BY risk_score DESC) AS rk FROM tr
)
SELECT MIN(r.risk_score) AS threshold, ANY_VALUE(m.n_months) AS train_months
FROM ranked r CROSS JOIN months m
WHERE r.rk <= $alert_budget * m.n_months;

CREATE OR REPLACE TEMPORARY TABLE EV_TEST_ALERTS AS
SELECT r.asset_id, r.cutoff_ts, r.risk_score, f.label, f.next_failure_ts
FROM MAINT_ASSET_RISK r
JOIN MAINT_PRECURSOR_FEATURES f ON f.asset_id = r.asset_id AND f.cutoff_ts = r.cutoff_ts
CROSS JOIN EV_THRESHOLD t
WHERE r.run_id = $run_id AND r.model_variant = $model_variant AND r.split = 'TEST'
  AND r.risk_score >= t.threshold;

-- Alert precision vs base rate, and alert volume vs budget.
SELECT $model_variant AS model_variant,
       (SELECT threshold FROM EV_THRESHOLD)                                        AS threshold,
       COUNT(*)                                                                    AS test_alerts,
       ROUND(COUNT(*) / NULLIF((SELECT GREATEST(1, DATEDIFF(month, MIN(cutoff_ts), MAX(cutoff_ts)) + 1)
                                FROM MAINT_PRECURSOR_FEATURES WHERE split = 'TEST'), 0), 1) AS alerts_per_month,
       $alert_budget                                                               AS budget_per_month,
       ROUND(COUNT_IF(label) / NULLIF(COUNT(*), 0), 3)                             AS alert_precision,
       (SELECT ROUND(COUNT_IF(label) / NULLIF(COUNT(*), 0), 3)
          FROM MAINT_PRECURSOR_FEATURES WHERE split = 'TEST')                      AS test_base_rate
FROM EV_TEST_ALERTS;

-- Event recall and lead time. An event is caught if an alert fired on the
-- asset within (failure - horizon, failure); lead = failure - first alert.
WITH events AS (
    SELECT l.event_id, l.asset_id, l.failure_ts
    FROM MAINT_FAILURE_LABELS l
    WHERE l.failure_ts >= $test_start::TIMESTAMP_NTZ
), first_alert AS (
    SELECT e.event_id, e.asset_id, e.failure_ts,
           MIN(a.cutoff_ts) AS first_alert_ts
    FROM events e
    LEFT JOIN EV_TEST_ALERTS a
      ON a.asset_id = e.asset_id
     AND a.cutoff_ts <  e.failure_ts
     AND a.cutoff_ts >= TIMESTAMPADD(day, -$horizon_days, e.failure_ts)
    GROUP BY 1, 2, 3
), leads AS (
    SELECT *, DATEDIFF(day, first_alert_ts, failure_ts) AS lead_days FROM first_alert
)
SELECT COUNT(*)                                                 AS test_events,
       COUNT(first_alert_ts)                                    AS caught_any,
       COUNT_IF(lead_days >= $min_lead_days)                    AS caught_actionable,
       COUNT_IF(lead_days <  $min_lead_days)                    AS caught_late,
       ROUND(COUNT_IF(lead_days >= $min_lead_days) / NULLIF(COUNT(*), 0), 3) AS actionable_event_recall,
       APPROX_PERCENTILE(lead_days, 0.25)                       AS lead_p25_days,
       MEDIAN(lead_days)                                        AS lead_median_days,
       APPROX_PERCENTILE(lead_days, 0.75)                       AS lead_p75_days
FROM leads;

-- False alarms on planted controls (sandbox): alerts within 30 days after the
-- benign anomaly, on assets that never failed.
SELECT COUNT(DISTINCT p.asset_id) AS control_assets,
       COUNT(DISTINCT a.asset_id) AS controls_alerted
FROM {{EVAL_SCHEMA}}.ANSWER_KEY_PRECURSORS p
LEFT JOIN EV_TEST_ALERTS a
  ON a.asset_id = p.asset_id
 AND a.cutoff_ts >  p.control_anomaly_date::TIMESTAMP_NTZ
 AND a.cutoff_ts <= TIMESTAMPADD(day, 30, p.control_anomaly_date::TIMESTAMP_NTZ)
WHERE p.scenario = 'FALSE_ALARM' AND p.control_anomaly_date >= $test_start::DATE;

-- ---------------------------------------------------------------------
-- 5. Cost per 1,000 source records, from measured usage on this run.
-- ---------------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM MAINT_SOURCE_TEXT)                                   AS source_records,
       (SELECT COUNT(*) FROM MAINT_SOURCE_DISTINCT)                               AS distinct_texts,
       COUNT(*)                                                                   AS extraction_calls,
       SUM(response:value:usage:prompt_tokens::INT)                               AS prompt_tokens,
       SUM(response:value:usage:completion_tokens::INT)                           AS completion_tokens,
       ROUND(1000 * SUM(response:value:usage:total_tokens::INT)
             / NULLIF((SELECT COUNT(*) FROM MAINT_SOURCE_TEXT), 0))               AS extraction_tokens_per_1k_records,
       ROUND(AVG(response:value:usage:prompt_tokens::INT))                        AS avg_prompt_tokens_per_call
FROM MAINT_SIGNAL_RAW
WHERE run_id = $run_id;
-- Billed totals for every function (triage, embeddings, AI_AGG included) come
-- from SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY for the run
-- window; that view has ingestion latency, so reconcile later, not at the gate.
