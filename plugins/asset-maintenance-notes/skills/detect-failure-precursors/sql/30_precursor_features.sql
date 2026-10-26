-- =====================================================================
-- Phase 5: failure labels, point-in-time precursor features, scoring.
--
-- SET BEFORE RUNNING (all settled in maintenance-project.yml first):
--   SET run_id             = '<extraction run_id>';
--   SET horizon_days       = <customer: how far ahead a warning must look>;
--   SET min_lead_days      = <customer: below this an alert cannot change a decision>;
--   SET lookback_days      = 60;      -- text and maintenance-history window
--   SET cutoff_step_days   = 7;       -- one feature row per asset per week
--   SET recovery_days      = 14;      -- cutoffs this soon after a failure are excluded
--   SET grace_hours        = 24;      -- emergency WOs this close before a failure ARE the failure
--   SET train_end          = '<YYYY-MM-DD>';
--   SET test_start         = '<YYYY-MM-DD>';  -- >= train_end + lookback_days + horizon_days
--   SET history_start      = '<YYYY-MM-DD>';
--   SET history_end        = '<YYYY-MM-DD>';
--
-- cutoff_policy = note_ts (default). Every input must be strictly before
-- cutoff_ts. max_source_ts is carried on every row and asserted.
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};

-- Guard: the split must leave a gap at least as long as lookback + horizon,
-- so no test-period record is visible in a training window and no training
-- label window reaches into the test period. Must return gap_ok = TRUE.
SELECT DATEDIFF(day, $train_end::DATE, $test_start::DATE) AS gap_days,
       DATEDIFF(day, $train_end::DATE, $test_start::DATE) >= $lookback_days + $horizon_days AS gap_ok;

-- ---------------------------------------------------------------------
-- 1. Labels: unplanned downtime events (precursor.label_source = downtime).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_FAILURE_LABELS AS
SELECT d.event_id, d.asset_id, d.start_ts AS failure_ts, d.end_ts AS failure_end_ts, 'downtime' AS label_source
FROM SYNTH_DOWNTIME_EVENTS d
WHERE NOT d.is_planned;

-- Work orders that ARE a failure (raised for it), to be excluded from
-- features even when created slightly before the logged start.
CREATE OR REPLACE TABLE MAINT_LABEL_WORK_ORDERS AS
SELECT DISTINCT w.wo_id, l.event_id, l.asset_id
FROM SYNTH_WORK_ORDERS w
JOIN MAINT_FAILURE_LABELS l
  ON l.asset_id = w.asset_id
 AND w.wo_type IN ('EMERGENCY', 'CM')
 AND w.created_at BETWEEN TIMESTAMPADD(hour, -$grace_hours, l.failure_ts) AND l.failure_end_ts;

-- ---------------------------------------------------------------------
-- 2. Cutoff grid: one row per asset per week, with the label.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_PRECURSOR_GRID AS
WITH weeks AS (
    SELECT DATEADD(day, $cutoff_step_days * (ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1), $history_start::DATE) AS cutoff_date
    FROM TABLE(GENERATOR(ROWCOUNT => 200))
), grid AS (
    SELECT a.asset_id, a.asset_class, a.install_date, w.cutoff_date::TIMESTAMP_NTZ AS cutoff_ts
    FROM SYNTH_ASSETS a
    CROSS JOIN weeks w
    WHERE w.cutoff_date >= DATEADD(day, $lookback_days, $history_start::DATE)
      AND w.cutoff_date <= DATEADD(day, -$horizon_days, $history_end::DATE)  -- label window must be observable
), labelled AS (
    -- Label: an unplanned failure starts within (cutoff, cutoff + horizon].
    -- Down/recovering flag: the cutoff falls inside [failure, failure_end + recovery).
    SELECT g.asset_id, g.asset_class, g.install_date, g.cutoff_ts,
           MIN(IFF(l.failure_ts > g.cutoff_ts
                   AND l.failure_ts <= TIMESTAMPADD(day, $horizon_days, g.cutoff_ts), l.failure_ts, NULL)) AS next_failure_ts,
           MAX(IFF(g.cutoff_ts >= l.failure_ts
                   AND g.cutoff_ts < TIMESTAMPADD(day, $recovery_days, l.failure_end_ts), 1, 0))        AS in_recovery
    FROM grid g
    LEFT JOIN MAINT_FAILURE_LABELS l ON l.asset_id = g.asset_id
    GROUP BY 1, 2, 3, 4
)
SELECT asset_id, asset_class, install_date, cutoff_ts,
       next_failure_ts IS NOT NULL AS label,
       next_failure_ts,
       CASE WHEN cutoff_ts < $train_end::TIMESTAMP_NTZ
             AND TIMESTAMPADD(day, $horizon_days, cutoff_ts) < $train_end::TIMESTAMP_NTZ THEN 'TRAIN'
            WHEN cutoff_ts >= $test_start::TIMESTAMP_NTZ                                  THEN 'TEST'
            ELSE 'GAP' END AS split
FROM labelled
-- Exclude cutoffs while the asset is down or recovering: the state is known, not predicted.
WHERE in_recovery = 0;

-- ---------------------------------------------------------------------
-- 3. Text features from OBSERVED / UNCLEAR signals, note timestamp < cutoff.
--    Sources are filtered FIRST (valid, run-scoped, not a label WO), then
--    joined by time window.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_FEAT_TEXT AS
WITH sig AS (
    SELECT s.*
    FROM MAINT_SIGNALS s
    LEFT JOIN MAINT_LABEL_WORK_ORDERS lw ON lw.wo_id = s.wo_id
    WHERE s.run_id = $run_id
      AND s.polarity IN ('OBSERVED', 'UNCLEAR')
      AND s.evidence_found_in_source AND s.component_in_taxonomy AND s.mode_in_taxonomy
      AND lw.wo_id IS NULL
)
SELECT g.asset_id, g.cutoff_ts,
       COUNT_IF(s.polarity = 'OBSERVED' AND s.source_ts >= TIMESTAMPADD(day, -30, g.cutoff_ts))  AS observed_30d,
       COUNT_IF(s.polarity = 'OBSERVED')                                                       AS observed_60d,
       COUNT_IF(s.polarity = 'UNCLEAR')                                                        AS unclear_60d,
       COUNT_IF(s.polarity = 'OBSERVED' AND s.severity IN ('MEDIUM', 'HIGH'))                  AS observed_med_high_60d,
       COUNT(DISTINCT IFF(s.polarity = 'OBSERVED', s.component_code, NULL))                    AS distinct_components_60d,
       COUNT_IF(s.polarity = 'OBSERVED' AND s.failure_mode_code IN ('EXTERNAL_LEAK', 'HIGH_VIBRATION',
                'OVERHEATING', 'ABNORMAL_NOISE', 'CONTAMINATION', 'WEAR'))                     AS degradation_mode_60d,
       DATEDIFF(day, MAX(IFF(s.polarity = 'OBSERVED', s.source_ts, NULL)), g.cutoff_ts)        AS days_since_last_observed,
       MAX(s.source_ts)                                                                        AS max_text_ts
FROM MAINT_PRECURSOR_GRID g
LEFT JOIN sig s
  ON s.asset_id = g.asset_id
 AND s.source_ts <  g.cutoff_ts                                   -- note timestamp, strictly before
 AND s.source_ts >= TIMESTAMPADD(day, -$lookback_days, g.cutoff_ts)
GROUP BY g.asset_id, g.cutoff_ts;

-- ---------------------------------------------------------------------
-- 4. Maintenance-history features. Only WOs created before the cutoff;
--    label WOs excluded. No feature is derived from the label source.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_FEAT_HISTORY AS
WITH wo AS (
    SELECT w.*
    FROM SYNTH_WORK_ORDERS w
    LEFT JOIN MAINT_LABEL_WORK_ORDERS lw ON lw.wo_id = w.wo_id
    WHERE lw.wo_id IS NULL
)
SELECT g.asset_id, g.cutoff_ts,
       COUNT_IF(w.wo_type = 'CM') AS cm_wos_180d,
       COUNT_IF(w.wo_type = 'PM') AS pm_wos_180d,
       DATEDIFF(day, MAX(IFF(w.wo_type = 'PM', w.created_at, NULL)), g.cutoff_ts) AS days_since_pm,
       MAX(w.created_at)          AS max_wo_ts
FROM MAINT_PRECURSOR_GRID g
LEFT JOIN wo w
  ON w.asset_id = g.asset_id
 AND w.created_at <  g.cutoff_ts
 AND w.created_at >= TIMESTAMPADD(day, -180, g.cutoff_ts)
GROUP BY g.asset_id, g.cutoff_ts;

-- Repeat visits seen so far (point in time).
CREATE OR REPLACE TABLE MAINT_FEAT_REPEATS AS
WITH rv AS (
    SELECT r.*
    FROM MAINT_REPEAT_VISITS r
    LEFT JOIN MAINT_LABEL_WORK_ORDERS lw ON lw.wo_id = r.repeat_wo_id
    WHERE lw.wo_id IS NULL
)
SELECT g.asset_id, g.cutoff_ts,
       COUNT(r.repeat_wo_id)    AS repeat_visits_180d,
       MAX(r.repeat_created_at) AS max_repeat_ts
FROM MAINT_PRECURSOR_GRID g
LEFT JOIN rv r
  ON r.asset_id = g.asset_id
 AND r.repeat_created_at <  g.cutoff_ts
 AND r.repeat_created_at >= TIMESTAMPADD(day, -180, g.cutoff_ts)
GROUP BY g.asset_id, g.cutoff_ts;

-- ---------------------------------------------------------------------
-- 5. Sensor features. NULLs kept; coverage carried; baseline is a rolling
--    window that ENDS before the recent window (point in time, no future).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_FEAT_SENSOR AS
SELECT g.asset_id, g.cutoff_ts,
       AVG(IFF(s.reading_date >= DATEADD(day, -7, g.cutoff_ts::DATE), s.vibration_mm_s, NULL))      AS vib_avg_7d,
       AVG(IFF(s.reading_date <  DATEADD(day, -60, g.cutoff_ts::DATE), s.vibration_mm_s, NULL))     AS vib_baseline,
       AVG(IFF(s.reading_date >= DATEADD(day, -7, g.cutoff_ts::DATE), s.bearing_temp_c, NULL))      AS temp_avg_7d,
       AVG(IFF(s.reading_date <  DATEADD(day, -60, g.cutoff_ts::DATE), s.bearing_temp_c, NULL))     AS temp_baseline,
       REGR_SLOPE(IFF(s.reading_date >= DATEADD(day, -21, g.cutoff_ts::DATE), s.vibration_mm_s, NULL),
                  IFF(s.reading_date >= DATEADD(day, -21, g.cutoff_ts::DATE),
                      DATEDIFF(day, g.cutoff_ts::DATE, s.reading_date), NULL))                       AS vib_slope_21d,
       COUNT_IF(s.reading_date >= DATEADD(day, -14, g.cutoff_ts::DATE) AND s.vibration_mm_s IS NOT NULL) / 14.0
                                                                                                    AS sensor_coverage_14d,
       MAX(s.reading_date)::TIMESTAMP_NTZ                                                           AS max_sensor_ts
FROM MAINT_PRECURSOR_GRID g
LEFT JOIN SYNTH_SENSOR_DAILY s
  ON s.asset_id = g.asset_id
 AND s.reading_date <  g.cutoff_ts::DATE                            -- the cutoff day itself is not yet complete
 AND s.reading_date >= DATEADD(day, -180, g.cutoff_ts::DATE)
GROUP BY g.asset_id, g.cutoff_ts;

-- ---------------------------------------------------------------------
-- 6. Assembled feature table with max_source_ts for the leakage assertion.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_PRECURSOR_FEATURES AS
SELECT g.asset_id, g.asset_class, g.cutoff_ts, g.split, g.label, g.next_failure_ts,
       DATEDIFF(day, g.install_date, g.cutoff_ts)                    AS asset_age_days,
       COALESCE(t.observed_30d, 0)            AS observed_30d,
       COALESCE(t.observed_60d, 0)            AS observed_60d,
       COALESCE(t.unclear_60d, 0)             AS unclear_60d,
       COALESCE(t.observed_med_high_60d, 0)   AS observed_med_high_60d,
       COALESCE(t.distinct_components_60d, 0) AS distinct_components_60d,
       COALESCE(t.degradation_mode_60d, 0)    AS degradation_mode_60d,
       t.days_since_last_observed,                                   -- NULL = never observed in window; keep NULL
       COALESCE(h.cm_wos_180d, 0)             AS cm_wos_180d,
       COALESCE(h.pm_wos_180d, 0)             AS pm_wos_180d,
       h.days_since_pm,
       COALESCE(r.repeat_visits_180d, 0)      AS repeat_visits_180d,
       s.vib_avg_7d, s.vib_baseline, s.vib_avg_7d - s.vib_baseline   AS vib_delta,
       s.temp_avg_7d, s.temp_baseline, s.temp_avg_7d - s.temp_baseline AS temp_delta,
       s.vib_slope_21d, s.sensor_coverage_14d,
       GREATEST(COALESCE(t.max_text_ts,   '1900-01-01'::TIMESTAMP_NTZ),
                COALESCE(h.max_wo_ts,     '1900-01-01'::TIMESTAMP_NTZ),
                COALESCE(r.max_repeat_ts, '1900-01-01'::TIMESTAMP_NTZ),
                COALESCE(s.max_sensor_ts, '1900-01-01'::TIMESTAMP_NTZ))     AS max_source_ts
FROM MAINT_PRECURSOR_GRID g
LEFT JOIN MAINT_FEAT_TEXT    t ON t.asset_id = g.asset_id AND t.cutoff_ts = g.cutoff_ts
LEFT JOIN MAINT_FEAT_HISTORY h ON h.asset_id = g.asset_id AND h.cutoff_ts = g.cutoff_ts
LEFT JOIN MAINT_FEAT_REPEATS r ON r.asset_id = g.asset_id AND r.cutoff_ts = g.cutoff_ts
LEFT JOIN MAINT_FEAT_SENSOR  s ON s.asset_id = g.asset_id AND s.cutoff_ts = g.cutoff_ts;

-- LEAKAGE ASSERTION. Must return zero rows. Fail the phase otherwise.
SELECT asset_id, cutoff_ts, max_source_ts
FROM MAINT_PRECURSOR_FEATURES
WHERE max_source_ts >= cutoff_ts;

-- Base rate per split (report next to every precision figure).
SELECT split, COUNT(*) AS rows_total, COUNT_IF(label) AS positives,
       ROUND(100.0 * COUNT_IF(label) / NULLIF(COUNT(*), 0), 2) AS base_rate_pct,
       COUNT(DISTINCT IFF(label, next_failure_ts::STRING || asset_id, NULL)) AS distinct_events
FROM MAINT_PRECURSOR_FEATURES
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 7. Training views. Identifiers, timestamps and the label-derived
--    next_failure_ts are NOT features -- asset_id as a categorical feature
--    memorizes which assets failed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW MAINT_TRAIN_COMBINED AS
SELECT asset_class, asset_age_days, observed_30d, observed_60d, unclear_60d, observed_med_high_60d,
       distinct_components_60d, degradation_mode_60d, days_since_last_observed, cm_wos_180d, pm_wos_180d,
       days_since_pm, repeat_visits_180d, vib_avg_7d, vib_delta, temp_avg_7d, temp_delta, vib_slope_21d,
       sensor_coverage_14d, label
FROM MAINT_PRECURSOR_FEATURES WHERE split = 'TRAIN';

CREATE OR REPLACE VIEW MAINT_TRAIN_SENSOR_ONLY AS
SELECT asset_class, asset_age_days, vib_avg_7d, vib_delta, temp_avg_7d, temp_delta, vib_slope_21d,
       sensor_coverage_14d, label
FROM MAINT_PRECURSOR_FEATURES WHERE split = 'TRAIN';

CREATE OR REPLACE VIEW MAINT_TRAIN_TEXT_ONLY AS
SELECT asset_class, asset_age_days, observed_30d, observed_60d, unclear_60d, observed_med_high_60d,
       distinct_components_60d, degradation_mode_60d, days_since_last_observed, cm_wos_180d, pm_wos_180d,
       days_since_pm, repeat_visits_180d, label
FROM MAINT_PRECURSOR_FEATURES WHERE split = 'TRAIN';

-- ---------------------------------------------------------------------
-- 8. Train (three variants for the ablation). Built-in evaluation uses a
--    random holdout of TRAIN rows -- ignore it; Phase 6 evaluates on TEST.
-- ---------------------------------------------------------------------
CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION MAINT_PRECURSOR_MODEL_COMBINED(
    INPUT_DATA     => SYSTEM$REFERENCE('VIEW', 'MAINT_TRAIN_COMBINED'),
    TARGET_COLNAME => 'LABEL'
);
CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION MAINT_PRECURSOR_MODEL_SENSOR(
    INPUT_DATA     => SYSTEM$REFERENCE('VIEW', 'MAINT_TRAIN_SENSOR_ONLY'),
    TARGET_COLNAME => 'LABEL'
);
CREATE OR REPLACE SNOWFLAKE.ML.CLASSIFICATION MAINT_PRECURSOR_MODEL_TEXT(
    INPUT_DATA     => SYSTEM$REFERENCE('VIEW', 'MAINT_TRAIN_TEXT_ONLY'),
    TARGET_COLNAME => 'LABEL'
);

-- ---------------------------------------------------------------------
-- 9. Score every cutoff (train and test). Probability keys follow the
--    label values; inspect one row's output before trusting the path.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS MAINT_ASSET_RISK (
    run_id         VARCHAR,
    model_variant  VARCHAR,
    asset_id       VARCHAR,
    asset_class    VARCHAR,
    cutoff_ts      TIMESTAMP_NTZ,
    split          VARCHAR,
    risk_score     FLOAT,
    prediction     VARIANT,
    scored_at      TIMESTAMP_NTZ
);

INSERT INTO MAINT_ASSET_RISK
SELECT $run_id, 'COMBINED', f.asset_id, f.asset_class, f.cutoff_ts, f.split,
       pred:probability:"True"::FLOAT, pred, CURRENT_TIMESTAMP()
FROM (
  SELECT f.*, MAINT_PRECURSOR_MODEL_COMBINED!PREDICT(INPUT_DATA => OBJECT_CONSTRUCT(
        'ASSET_CLASS', f.asset_class, 'ASSET_AGE_DAYS', f.asset_age_days, 'OBSERVED_30D', f.observed_30d,
        'OBSERVED_60D', f.observed_60d, 'UNCLEAR_60D', f.unclear_60d, 'OBSERVED_MED_HIGH_60D', f.observed_med_high_60d,
        'DISTINCT_COMPONENTS_60D', f.distinct_components_60d, 'DEGRADATION_MODE_60D', f.degradation_mode_60d,
        'DAYS_SINCE_LAST_OBSERVED', f.days_since_last_observed, 'CM_WOS_180D', f.cm_wos_180d,
        'PM_WOS_180D', f.pm_wos_180d, 'DAYS_SINCE_PM', f.days_since_pm, 'REPEAT_VISITS_180D', f.repeat_visits_180d,
        'VIB_AVG_7D', f.vib_avg_7d, 'VIB_DELTA', f.vib_delta, 'TEMP_AVG_7D', f.temp_avg_7d,
        'TEMP_DELTA', f.temp_delta, 'VIB_SLOPE_21D', f.vib_slope_21d, 'SENSOR_COVERAGE_14D', f.sensor_coverage_14d
  )) AS pred
  FROM MAINT_PRECURSOR_FEATURES f
  WHERE f.split IN ('TRAIN', 'TEST')
) f;
-- Repeat the INSERT for 'SENSOR' and 'TEXT' variants with their feature subsets.

-- Inspect the probability path once. If the key is "true"/"1" rather than
-- "True", fix the extraction above before Phase 6.
SELECT prediction FROM MAINT_ASSET_RISK WHERE run_id = $run_id LIMIT 3;
