-- =====================================================================
-- Synthetic maintenance corpus with ground truth, for failure-mode and
-- component extraction, recurring-issue clustering, and failure-precursor
-- lead-time evaluation.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}                 target database
--   {{SCHEMA}}             sandbox data schema (what the pipeline reads)
--   {{EVAL_SCHEMA}}        answer key + generator staging (quarantine)
--   {{ASSETS_PER_CLASS}}   assets per asset class, e.g. 80 (3 classes)
--   {{HISTORY_DAYS}}       history length in days, e.g. 600
--   {{ANCHOR_DATE}}        fixed "today" for the corpus, e.g. 2026-06-30
--   {{WOS_PER_ASSET}}      background work orders per asset, e.g. 6
--   {{INSPECTIONS_PER_ASSET}} background inspection reports per asset, e.g. 5
--
-- Determinism: every "random" choice is UNIFORM(lo, hi, HASH(...)) on a
-- stable key, so the same parameters produce the same corpus on any
-- account. Do not replace with RANDOM() -- a regenerated corpus would then
-- invalidate every stored evaluation result.
--
-- All identifiers are prefixed SYN- and all tags, sites and roles are
-- fabricated. Scenario assignment, templates and labels live ONLY in
-- {{EVAL_SCHEMA}}. No table in {{SCHEMA}} carries a template id, a label,
-- or a scenario flag. Only the accuracy harness may read {{EVAL_SCHEMA}}.
-- =====================================================================

USE DATABASE {{DB}};
CREATE SCHEMA IF NOT EXISTS {{SCHEMA}};
CREATE SCHEMA IF NOT EXISTS {{EVAL_SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Reference taxonomy (customer-owned reference data in a real build,
--    so it lives in the pipeline schema; it carries no labels).
--    Failure mode = the observed effect. Cause is free text elsewhere.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_TAXONOMY_COMPONENT (
    asset_class     VARCHAR,
    component_code  VARCHAR,
    assembly_code   VARCHAR,
    component_name  VARCHAR,
    synonyms        VARCHAR
);

INSERT INTO {{SCHEMA}}.SYNTH_TAXONOMY_COMPONENT VALUES
  ('PUMP_CENTRIFUGAL','MECH_SEAL',     'SEALING',     'Mechanical seal',              'seal, mech seal, seal cartridge, gland'),
  ('PUMP_CENTRIFUGAL','BEARING_DE',    'BEARINGS',    'Drive-end bearing',            'DE brg, drive end bearing, pump side bearing'),
  ('PUMP_CENTRIFUGAL','BEARING_NDE',   'BEARINGS',    'Non-drive-end bearing',        'NDE brg, non drive end bearing'),
  ('PUMP_CENTRIFUGAL','IMPELLER',      'HYDRAULIC',   'Impeller',                     'impeller, vanes'),
  ('PUMP_CENTRIFUGAL','CASING',        'HYDRAULIC',   'Pump casing',                  'casing, volute'),
  ('PUMP_CENTRIFUGAL','COUPLING',      'DRIVE',       'Coupling',                     'coupling, insert, spider, alignment'),
  ('PUMP_CENTRIFUGAL','MOTOR',         'DRIVE',       'Electric motor',               'motor, VFD, drive'),
  ('GEARBOX',         'GEAR_SET',      'GEARING',     'Gear set',                     'gears, pinion, teeth, gear mesh'),
  ('GEARBOX',         'BEARING_INPUT', 'BEARINGS',    'Input shaft bearing',          'input brg, HS bearing'),
  ('GEARBOX',         'BEARING_OUTPUT','BEARINGS',    'Output shaft bearing',         'output brg, LS bearing'),
  ('GEARBOX',         'OIL_SEAL',      'SEALING',     'Shaft oil seal',               'oil seal, lip seal, shaft seal'),
  ('GEARBOX',         'LUBE_SYSTEM',   'LUBRICATION', 'Lubrication system',           'oil, lube pump, filter, mag plug, oil sample'),
  ('GEARBOX',         'COUPLING',      'DRIVE',       'Coupling',                     'coupling'),
  ('AIR_COMPRESSOR',  'AIR_END',       'COMPRESSION', 'Air end / compression element','air end, element, screw'),
  ('AIR_COMPRESSOR',  'INLET_VALVE',   'CONTROL',     'Inlet / unloader valve',       'inlet valve, unloader, not loading'),
  ('AIR_COMPRESSOR',  'COOLER',        'COOLING',     'Oil / after cooler',           'cooler, fins, radiator'),
  ('AIR_COMPRESSOR',  'DRIVE_BELT',    'DRIVE',       'Drive belts',                  'belt, belts, belt set'),
  ('AIR_COMPRESSOR',  'MOTOR',         'DRIVE',       'Electric motor',               'motor'),
  ('AIR_COMPRESSOR',  'OIL_SEPARATOR', 'LUBRICATION', 'Oil separator',                'separator, sep element, carryover');

CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_TAXONOMY_FAILURE_MODE (
    failure_mode_code VARCHAR,
    failure_mode_name VARCHAR,
    definition        VARCHAR
);

INSERT INTO {{SCHEMA}}.SYNTH_TAXONOMY_FAILURE_MODE VALUES
  ('EXTERNAL_LEAK',       'External leakage',        'Process fluid, oil or air escaping to the outside'),
  ('HIGH_VIBRATION',      'High vibration',          'Vibration above normal, measured or felt'),
  ('OVERHEATING',         'Overheating',             'Temperature above normal for the component'),
  ('ABNORMAL_NOISE',      'Abnormal noise',          'Knocking, whine, squeal, grinding or roughness heard'),
  ('FAIL_TO_START',       'Fail to start',           'Does not start or trips on start'),
  ('LOW_OUTPUT',          'Low output',              'Delivers less flow, pressure or load than required'),
  ('BREAKDOWN',           'Breakdown',               'Component broken, seized, collapsed or disintegrated'),
  ('WEAR',                'Wear',                    'Material loss, scoring, glazing, erosion without breakage'),
  ('CONTAMINATION',       'Contamination',           'Debris, metal particles, water or oil where it should not be'),
  ('PARAMETER_DEVIATION', 'Parameter deviation',     'Pressure, level or flow outside limits, not otherwise covered'),
  ('NONE',                'No failure mode',         'Used with RULED_OUT and ACTION_ONLY polarity');

-- ---------------------------------------------------------------------
-- 2. Note templates and their labels. EVAL SCHEMA ONLY.
--    kind drives where a template is used; labels are per template.
--    Placeholders: {TAG} asset tag, {V1} vibration mm/s, {T1} temp C.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_NOTE_TEMPLATES (
    template_id   VARCHAR,
    asset_class   VARCHAR,     -- or ANY
    kind          VARCHAR,     -- FAILURE ACTION NEGATIVE PRECURSOR CONTROL SCEN_FAILURE AS_FOUND HINDSIGHT NFF BOILERPLATE ADMIN
    template_text VARCHAR
);

INSERT INTO {{EVAL_SCHEMA}}.SYNTH_NOTE_TEMPLATES VALUES
  -- Pump: corrective
  ('PU_F1','PUMP_CENTRIFUGAL','FAILURE','Called out to {TAG}. Found mech seal leaking approx 1 L/min at gland. Isolated, replaced seal cartridge. Tested OK.'),
  ('PU_F2','PUMP_CENTRIFUGAL','FAILURE','{TAG} tripped on high vib. DE brg running rough, vib {V1} mm/s DE horiz. Replaced DE brg. Checked alignment - within tolerance.'),
  ('PU_F3','PUMP_CENTRIFUGAL','FAILURE','Pump {TAG} not delivering, disch press low. Pulled pump, impeller eroded at vane tips. Fitted new impeller.'),
  ('PU_F4','PUMP_CENTRIFUGAL','FAILURE','Coupling insert on {TAG} disintegrated, rubber debris in guard. Replaced insert. NDE brg sounding noisy - monitor.'),
  ('PU_F5','PUMP_CENTRIFUGAL','FAILURE','o/c {TAG} - motor wont start, VFD fault OC. reset, ran 10 min ok. motor IR test pass.'),
  -- Pump: PM / action only
  ('PU_A1','PUMP_CENTRIFUGAL','ACTION','PM 6M {TAG}: greased DE and NDE brgs, cleaned motor fan cowl, checked hold-down bolts. No issues.'),
  ('PU_A2','PUMP_CENTRIFUGAL','ACTION','PM {TAG} - replaced mech seal per 24 month interval. Old seal in good condition.'),
  -- Pump: inspection negatives
  ('PU_N1','PUMP_CENTRIFUGAL','NEGATIVE','Monthly route {TAG}: Seal - no leaks. DE brg temp {T1}C normal. Vib normal. Guard secure. Nil defects.'),
  ('PU_N2','PUMP_CENTRIFUGAL','NEGATIVE','Inspection checklist {TAG}\nCasing leaks: N\nCoupling condition: Good\nComments: none'),
  -- Pump: precursors (scenario order = rank)
  ('PU_P1','PUMP_CENTRIFUGAL','PRECURSOR','Route check {TAG}: slight weep at seal faces, few drops per min. Not urgent, monitor.'),
  ('PU_P2','PUMP_CENTRIFUGAL','PRECURSOR','{TAG} DE brg temp {T1}C, up from usual. Vib {V1} mm/s trending up. Re-greased, recheck next route.'),
  ('PU_P3','PUMP_CENTRIFUGAL','PRECURSOR','Operator thinks DE brg on {TAG} may be running warm, not confirmed on site today.'),
  ('PU_C1','PUMP_CENTRIFUGAL','CONTROL','{TAG} DE brg vib spike {V1} mm/s after restart, settled to normal within 5 min. No action.'),
  ('PU_S1','PUMP_CENTRIFUGAL','SCEN_FAILURE','Emergency callout {TAG}: pump tripped, heavy leak from mech seal, DE brg collapsed and shaft scored. Pump u/s, change-out required.'),
  ('PU_X1','PUMP_CENTRIFUGAL','AS_FOUND','As found after trip on {TAG}: seal faces destroyed, DE brg cage broken. Note: weep had been reported on earlier routes.'),
  ('PU_H1','PUMP_CENTRIFUGAL','HINDSIGHT','Update: in hindsight the weep noted on this route was the start of the seal failure on {TAG} - see emergency WO.'),
  -- Gearbox
  ('GB_F1','GEARBOX','FAILURE','Gearbox {TAG} oil leaking from output shaft seal, puddle under unit. Replaced oil seal, topped up oil.'),
  ('GB_F2','GEARBOX','FAILURE','Loud knocking from {TAG}. Inspection port: chipped teeth on 2nd stage pinion. Unit u/s, tagged out pending o/h.'),
  ('GB_F3','GEARBOX','FAILURE','Input brg on {TAG} overheating {T1}C, oil discoloured, metal particles on mag plug.'),
  ('GB_F4','GEARBOX','FAILURE','Lube pump on {TAG} not building pressure, low oil press alarm. Replaced lube pump.'),
  ('GB_A1','GEARBOX','ACTION','PM {TAG}: oil change, filter replaced, oil sample sent to lab.'),
  ('GB_A2','GEARBOX','ACTION','PM {TAG}: re-torqued coupling bolts, checked guard, greased output brg.'),
  ('GB_N1','GEARBOX','NEGATIVE','Quarterly insp {TAG}: oil level OK, no leaks at seals, mag plug clean, gear mesh noise normal.'),
  ('GB_N2','GEARBOX','NEGATIVE','Route {TAG}: input brg temp {T1}C ok, output brg nil abnormal noise.'),
  ('GB_P1','GEARBOX','PRECURSOR','Oil sample results {TAG}: iron ppm elevated vs last sample. Recommend resample in 4 weeks.'),
  ('GB_P2','GEARBOX','PRECURSOR','Slight whine from {TAG} at full load, not present at low speed. Monitor.'),
  ('GB_P3','GEARBOX','PRECURSOR','Operator mentioned {TAG} may have a small oil drip at output seal, could not find on inspection.'),
  ('GB_C1','GEARBOX','CONTROL','Mag plug {TAG} light fuzz, normal for run-in after o/h. No action.'),
  ('GB_S1','GEARBOX','SCEN_FAILURE','Emergency {TAG}: gearbox seized under load, output brg collapsed, teeth stripped on 2nd stage. Unit u/s.'),
  ('GB_X1','GEARBOX','AS_FOUND','As found on {TAG}: output brg cage broken, gear teeth heavily scored. Earlier oil samples had shown rising iron.'),
  ('GB_H1','GEARBOX','HINDSIGHT','Update: whine reported on this route was the gear set failing on {TAG} - see emergency WO.'),
  -- Air compressor
  ('AC_F1','AIR_COMPRESSOR','FAILURE','{TAG} tripped high disch temp {T1}C. Cooler fins blocked with dust, cleaned cooler, restarted.'),
  ('AC_F2','AIR_COMPRESSOR','FAILURE','Comp {TAG} not loading, inlet valve stuck closed. Replaced inlet valve kit.'),
  ('AC_F3','AIR_COMPRESSOR','FAILURE','Drive belt snapped on {TAG}, replaced belt set and retensioned.'),
  ('AC_F4','AIR_COMPRESSOR','FAILURE','Oil carryover into air lines from {TAG}, sep element saturated. Replaced oil separator element.'),
  ('AC_A1','AIR_COMPRESSOR','ACTION','PM 4000h {TAG}: changed air filter, oil filter and separator element. Tested OK.'),
  ('AC_A2','AIR_COMPRESSOR','ACTION','PM {TAG}: retensioned belts, blew out cooler, checked condensate drain.'),
  ('AC_N1','AIR_COMPRESSOR','NEGATIVE','Weekly check {TAG}: disch temp {T1}C within range, belt tension OK, no oil carryover.'),
  ('AC_N2','AIR_COMPRESSOR','NEGATIVE','Inspection {TAG}\nAir leaks at cooler: none\nMotor noise: normal\nComments: nil'),
  ('AC_P1','AIR_COMPRESSOR','PRECURSOR','Belt squeal on start-up {TAG}, slight glazing on belts. Retension next visit.'),
  ('AC_P2','AIR_COMPRESSOR','PRECURSOR','{TAG} disch temp running {T1}C, higher than last month. Cooler looks dusty.'),
  ('AC_P3','AIR_COMPRESSOR','PRECURSOR','Site says {TAG} cycling more often, possibly not loading fully. Not seen on visit.'),
  ('AC_C1','AIR_COMPRESSOR','CONTROL','High temp alarm {TAG} during heatwave, ambient 41C, cleared when ambient dropped. No fault found on cooler.'),
  ('AC_S1','AIR_COMPRESSOR','SCEN_FAILURE','Emergency {TAG}: compressor tripped and will not restart, air end seized. Unit u/s.'),
  ('AC_X1','AIR_COMPRESSOR','AS_FOUND','As found on {TAG}: air end bearings failed, rotors scored. Previous visits noted rising disch temps.'),
  ('AC_H1','AIR_COMPRESSOR','HINDSIGHT','Update: temps noted on this route were the start of the air end failure on {TAG} - see emergency WO.'),
  -- Any class: no signals by design
  ('ANY_B1','ANY','BOILERPLATE','Job completed. Area left clean and tidy. LOTO removed and permit closed.'),
  ('ANY_B2','ANY','BOILERPLATE','Work complete as per job plan. Handed back to operations.'),
  ('ANY_D1','ANY','ADMIN','Parts on order, ETA Thursday. Need scaffold access before return visit. Contact site supervisor on arrival.'),
  ('ANY_D2','ANY','ADMIN','Rescheduled - no access, gate locked. Rebooked for next week.'),
  ('ANY_Z1','ANY','NFF','Attended {TAG}, nff, unit running normally on departure.');

CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_TEMPLATE_LABELS (
    template_id        VARCHAR,
    component_code     VARCHAR,
    failure_mode_code  VARCHAR,
    polarity           VARCHAR
);

INSERT INTO {{EVAL_SCHEMA}}.SYNTH_TEMPLATE_LABELS VALUES
  ('PU_F1','MECH_SEAL','EXTERNAL_LEAK','OBSERVED'),
  ('PU_F2','BEARING_DE','HIGH_VIBRATION','OBSERVED'),
  ('PU_F2','COUPLING','NONE','RULED_OUT'),
  ('PU_F3','IMPELLER','LOW_OUTPUT','OBSERVED'),
  ('PU_F4','COUPLING','BREAKDOWN','OBSERVED'),
  ('PU_F4','BEARING_NDE','ABNORMAL_NOISE','OBSERVED'),
  ('PU_F5','MOTOR','FAIL_TO_START','OBSERVED'),
  ('PU_A1','BEARING_DE','NONE','ACTION_ONLY'),
  ('PU_A1','BEARING_NDE','NONE','ACTION_ONLY'),
  ('PU_A1','MOTOR','NONE','ACTION_ONLY'),
  ('PU_A2','MECH_SEAL','NONE','ACTION_ONLY'),
  ('PU_N1','MECH_SEAL','NONE','RULED_OUT'),
  ('PU_N1','BEARING_DE','NONE','RULED_OUT'),
  ('PU_N2','CASING','NONE','RULED_OUT'),
  ('PU_N2','COUPLING','NONE','RULED_OUT'),
  ('PU_P1','MECH_SEAL','EXTERNAL_LEAK','OBSERVED'),
  ('PU_P2','BEARING_DE','OVERHEATING','OBSERVED'),
  ('PU_P2','BEARING_DE','HIGH_VIBRATION','OBSERVED'),
  ('PU_P3','BEARING_DE','OVERHEATING','UNCLEAR'),
  ('PU_C1','BEARING_DE','HIGH_VIBRATION','OBSERVED'),
  ('PU_S1','MECH_SEAL','EXTERNAL_LEAK','OBSERVED'),
  ('PU_S1','BEARING_DE','BREAKDOWN','OBSERVED'),
  ('PU_X1','MECH_SEAL','BREAKDOWN','OBSERVED'),
  ('PU_X1','BEARING_DE','BREAKDOWN','OBSERVED'),
  ('PU_H1','MECH_SEAL','EXTERNAL_LEAK','OBSERVED'),
  ('GB_F1','OIL_SEAL','EXTERNAL_LEAK','OBSERVED'),
  ('GB_F2','GEAR_SET','ABNORMAL_NOISE','OBSERVED'),
  ('GB_F3','BEARING_INPUT','OVERHEATING','OBSERVED'),
  ('GB_F3','LUBE_SYSTEM','CONTAMINATION','OBSERVED'),
  ('GB_F4','LUBE_SYSTEM','PARAMETER_DEVIATION','OBSERVED'),
  ('GB_A1','LUBE_SYSTEM','NONE','ACTION_ONLY'),
  ('GB_A2','COUPLING','NONE','ACTION_ONLY'),
  ('GB_A2','BEARING_OUTPUT','NONE','ACTION_ONLY'),
  ('GB_N1','LUBE_SYSTEM','NONE','RULED_OUT'),
  ('GB_N1','OIL_SEAL','NONE','RULED_OUT'),
  ('GB_N1','GEAR_SET','NONE','RULED_OUT'),
  ('GB_N2','BEARING_INPUT','NONE','RULED_OUT'),
  ('GB_N2','BEARING_OUTPUT','NONE','RULED_OUT'),
  ('GB_P1','LUBE_SYSTEM','CONTAMINATION','OBSERVED'),
  ('GB_P2','GEAR_SET','ABNORMAL_NOISE','OBSERVED'),
  ('GB_P3','OIL_SEAL','EXTERNAL_LEAK','UNCLEAR'),
  ('GB_C1','LUBE_SYSTEM','CONTAMINATION','RULED_OUT'),
  ('GB_S1','GEAR_SET','BREAKDOWN','OBSERVED'),
  ('GB_S1','BEARING_OUTPUT','BREAKDOWN','OBSERVED'),
  ('GB_X1','BEARING_OUTPUT','BREAKDOWN','OBSERVED'),
  ('GB_X1','GEAR_SET','WEAR','OBSERVED'),
  ('GB_H1','GEAR_SET','ABNORMAL_NOISE','OBSERVED'),
  ('AC_F1','COOLER','OVERHEATING','OBSERVED'),
  ('AC_F2','INLET_VALVE','LOW_OUTPUT','OBSERVED'),
  ('AC_F3','DRIVE_BELT','BREAKDOWN','OBSERVED'),
  ('AC_F4','OIL_SEPARATOR','CONTAMINATION','OBSERVED'),
  ('AC_A1','OIL_SEPARATOR','NONE','ACTION_ONLY'),
  ('AC_A2','DRIVE_BELT','NONE','ACTION_ONLY'),
  ('AC_A2','COOLER','NONE','ACTION_ONLY'),
  ('AC_N1','AIR_END','NONE','RULED_OUT'),
  ('AC_N1','DRIVE_BELT','NONE','RULED_OUT'),
  ('AC_N1','OIL_SEPARATOR','NONE','RULED_OUT'),
  ('AC_N2','COOLER','NONE','RULED_OUT'),
  ('AC_N2','MOTOR','NONE','RULED_OUT'),
  ('AC_P1','DRIVE_BELT','WEAR','OBSERVED'),
  ('AC_P2','COOLER','OVERHEATING','OBSERVED'),
  ('AC_P3','INLET_VALVE','LOW_OUTPUT','UNCLEAR'),
  ('AC_C1','COOLER','OVERHEATING','RULED_OUT'),
  ('AC_S1','AIR_END','BREAKDOWN','OBSERVED'),
  ('AC_X1','AIR_END','BREAKDOWN','OBSERVED'),
  ('AC_H1','AIR_END','OVERHEATING','OBSERVED');
-- BOILERPLATE, ADMIN and NFF templates intentionally have no labels:
-- a correct extractor returns an empty signal array for them.

-- ---------------------------------------------------------------------
-- 3. Asset registry (pipeline schema) and scenario assignment (eval).
--    Scenario by MOD(n, 10) so every class gets an equal share:
--      0 PLANTED_FAILURE   precursor notes + sensor drift + failure
--      1 FALSE_ALARM       benign anomaly notes + transient spike, no failure
--      2 RECURRING         three repeat corrective WOs for one issue
--      else BACKGROUND
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO AS
WITH g AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS n
    FROM TABLE(GENERATOR(ROWCOUNT => 3 * {{ASSETS_PER_CLASS}}))
)
SELECT
    n,
    'SYN-A-' || LPAD(n::STRING, 5, '0') AS asset_id,
    CASE MOD(n, 3) WHEN 0 THEN 'PUMP_CENTRIFUGAL' WHEN 1 THEN 'GEARBOX' ELSE 'AIR_COMPRESSOR' END AS asset_class,
    CASE MOD(n, 3) WHEN 0 THEN 'P-' WHEN 1 THEN 'GB-' ELSE 'AC-' END || (1000 + n)::STRING AS asset_tag,
    CASE MOD(n, 10) WHEN 0 THEN 'PLANTED_FAILURE' WHEN 1 THEN 'FALSE_ALARM' WHEN 2 THEN 'RECURRING'
                    ELSE 'BACKGROUND' END AS scenario,
    -- Event dates spread across history so some fall in a train window and some in test.
    DATEADD(day, -(60 + MOD(n * 37, 440)), '{{ANCHOR_DATE}}'::DATE) AS event_date
FROM g;

CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_ASSETS AS
SELECT
    s.asset_id,
    s.asset_tag,
    s.asset_class,
    'SITE-0' || (1 + MOD(FLOOR(s.n / 3), 4))::STRING                          AS site_code,
    'FL-' || (1 + MOD(FLOOR(s.n / 3), 4))::STRING || '-' || LPAD(s.n::STRING, 4, '0') AS functional_location,
    DATEADD(day, -UNIFORM(900, 6000, HASH(s.n, 'install')), '{{ANCHOR_DATE}}'::DATE) AS install_date,
    ARRAY_CONSTRUCT('A', 'B', 'C')[UNIFORM(0, 2, HASH(s.n, 'crit'))]::STRING   AS criticality,
    ARRAY_CONSTRUCT('Northfield Works', 'Ostrander Hydraulics', 'Kelvane Industrial')
        [UNIFORM(0, 2, HASH(s.n, 'mfr'))]::STRING                              AS manufacturer,
    -- Deliberately NULL. Replacement cost is a customer input to the value
    -- model and is never synthesized.
    NULL::NUMBER(18, 2)                                                        AS replacement_unit_capex
FROM {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s;

-- ---------------------------------------------------------------------
-- 4. Template catalogue expanded per class, ranked within (class, kind),
--    used by every generator below.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_TEMPLATE_CATALOGUE AS
WITH classes AS (
    SELECT DISTINCT asset_class FROM {{SCHEMA}}.SYNTH_TAXONOMY_COMPONENT
), expanded AS (
    SELECT t.template_id, t.asset_class, t.kind, t.template_text
    FROM {{EVAL_SCHEMA}}.SYNTH_NOTE_TEMPLATES t WHERE t.asset_class <> 'ANY'
    UNION ALL
    SELECT t.template_id, c.asset_class, t.kind, t.template_text
    FROM {{EVAL_SCHEMA}}.SYNTH_NOTE_TEMPLATES t CROSS JOIN classes c WHERE t.asset_class = 'ANY'
)
SELECT e.*,
       ROW_NUMBER() OVER (PARTITION BY asset_class, kind ORDER BY template_id) AS kind_rank,
       COUNT(*)     OVER (PARTITION BY asset_class, kind)                      AS kind_count
FROM expanded e;

-- ---------------------------------------------------------------------
-- 5. Work order generator (eval staging, carries scenario + intent).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_GEN_WORK_ORDERS (
    wo_id            VARCHAR,
    asset_id         VARCHAR,
    wo_type          VARCHAR,
    priority         INT,
    created_at       TIMESTAMP_NTZ,
    closed_at        TIMESTAMP_NTZ,
    last_modified_at TIMESTAMP_NTZ,
    description      VARCHAR,
    failure_code     VARCHAR,
    main_kind        VARCHAR,
    main_rank        INT,
    gen_role         VARCHAR      -- BACKGROUND, SCEN_ROUTE, SCEN_EMERGENCY, RECURRING
);

-- 5a. Background work orders.
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_GEN_WORK_ORDERS
WITH k AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS k
    FROM TABLE(GENERATOR(ROWCOUNT => {{WOS_PER_ASSET}}))
), base AS (
    SELECT s.n, s.asset_id, s.asset_class, s.scenario, s.event_date, k.k,
           UNIFORM(0, 19, HASH(s.n, k.k, 'type'))                  AS type_roll,
           DATEADD(day, MOD(ABS(HASH(s.n, k.k, 'day')), {{HISTORY_DAYS}} - 5),
                   DATEADD(day, -{{HISTORY_DAYS}}, '{{ANCHOR_DATE}}'::DATE)) AS wo_date
    FROM {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s CROSS JOIN k
)
SELECT
    'SYN-WO-' || LPAD(b.n::STRING, 5, '0') || '-' || LPAD(b.k::STRING, 2, '0')             AS wo_id,
    b.asset_id,
    CASE WHEN b.type_roll < 8 THEN 'PM' ELSE 'CM' END                                      AS wo_type,
    CASE WHEN b.type_roll < 8 THEN 4 ELSE 2 + UNIFORM(0, 1, HASH(b.n, b.k, 'prio')) END    AS priority,
    TIMESTAMPADD(hour, 7 + UNIFORM(0, 9, HASH(b.n, b.k, 'hr')), b.wo_date::TIMESTAMP_NTZ)  AS created_at,
    TIMESTAMPADD(hour, 8 + UNIFORM(4, 72, HASH(b.n, b.k, 'dur')), b.wo_date::TIMESTAMP_NTZ) AS closed_at,
    -- Most WOs are not edited after close; a minority are, by up to 20 days.
    TIMESTAMPADD(hour, 8 + UNIFORM(4, 72, HASH(b.n, b.k, 'dur'))
                 + CASE WHEN UNIFORM(0, 9, HASH(b.n, b.k, 'edit')) = 0
                        THEN 24 * UNIFORM(1, 20, HASH(b.n, b.k, 'editd')) ELSE 0 END,
                 b.wo_date::TIMESTAMP_NTZ)                                                 AS last_modified_at,
    CASE WHEN b.type_roll < 8 THEN 'PM service' ELSE 'Corrective - callout' END            AS description,
    -- Noisy structured code: mostly OTHER on corrective, null on PM.
    CASE WHEN b.type_roll < 8 THEN NULL
         WHEN UNIFORM(0, 9, HASH(b.n, b.k, 'fc')) < 7 THEN 'OTHER'
         ELSE ARRAY_CONSTRUCT('MECH', 'ELEC', 'LEAK')[UNIFORM(0, 2, HASH(b.n, b.k, 'fcv'))]::STRING
    END                                                                                    AS failure_code,
    CASE WHEN b.type_roll < 8  THEN 'ACTION'
         WHEN b.type_roll < 17 THEN 'FAILURE'
         ELSE 'NFF' END                                                                    AS main_kind,
    NULL                                                                                   AS main_rank,
    'BACKGROUND'                                                                           AS gen_role
FROM base b
-- Keep background noise out of the planted window so the planted label is clean.
WHERE NOT (b.scenario = 'PLANTED_FAILURE'
           AND b.wo_date BETWEEN DATEADD(day, -60, b.event_date) AND DATEADD(day, 5, b.event_date));

-- 5b. Planted failure: a route WO at event-30 (later edited with hindsight)
--     and the emergency WO for the failure itself.
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_GEN_WORK_ORDERS
SELECT 'SYN-WO-' || LPAD(n::STRING, 5, '0') || '-R1', asset_id, 'ROUTE', 4,
       TIMESTAMPADD(hour, 9,  DATEADD(day, -30, event_date)::TIMESTAMP_NTZ),
       TIMESTAMPADD(hour, 11, DATEADD(day, -30, event_date)::TIMESTAMP_NTZ),
       TIMESTAMPADD(hour, 15, DATEADD(day,   5, event_date)::TIMESTAMP_NTZ),   -- edited after the failure
       'Condition monitoring route', NULL, 'PRECURSOR', 2, 'SCEN_ROUTE'
FROM {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO WHERE scenario = 'PLANTED_FAILURE'
UNION ALL
SELECT 'SYN-WO-' || LPAD(n::STRING, 5, '0') || '-E1', asset_id, 'EMERGENCY', 1,
       TIMESTAMPADD(hour, 3,  event_date::TIMESTAMP_NTZ),
       TIMESTAMPADD(hour, 50, event_date::TIMESTAMP_NTZ),
       TIMESTAMPADD(hour, 10, DATEADD(day, 10, event_date)::TIMESTAMP_NTZ),
       'Breakdown - unit tripped', 'OTHER', 'SCEN_FAILURE', 1, 'SCEN_EMERGENCY'
FROM {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO WHERE scenario = 'PLANTED_FAILURE';

-- 5c. Recurring issue: three corrective WOs for the same issue, each opened
--     12 days after the previous one closed.
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_GEN_WORK_ORDERS
WITH r AS (
    SELECT n, asset_id, event_date, v.i
    FROM {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO,
         (SELECT 0 AS i UNION ALL SELECT 1 UNION ALL SELECT 2) v
    WHERE scenario = 'RECURRING'
)
SELECT 'SYN-WO-' || LPAD(n::STRING, 5, '0') || '-Q' || i::STRING, asset_id, 'CM', 2,
       TIMESTAMPADD(hour, 8,  DATEADD(day, i * 14,     event_date)::TIMESTAMP_NTZ),
       TIMESTAMPADD(hour, 8,  DATEADD(day, i * 14 + 2, event_date)::TIMESTAMP_NTZ),
       TIMESTAMPADD(hour, 9,  DATEADD(day, i * 14 + 2, event_date)::TIMESTAMP_NTZ),
       'Corrective - callout', 'OTHER', 'FAILURE', 1, 'RECURRING'
FROM r;

-- ---------------------------------------------------------------------
-- 6. Text generator: every note and inspection report, with the template
--    that produced it. EVAL staging; the pipeline copy drops template_id.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT (
    source_type   VARCHAR,     -- WO_NOTE | INSPECTION
    source_id     VARCHAR,
    wo_id         VARCHAR,
    asset_id      VARCHAR,
    source_ts     TIMESTAMP_NTZ,
    author_role   VARCHAR,
    template_id   VARCHAR,
    kind          VARCHAR,
    gen_role      VARCHAR,
    source_text   VARCHAR
);

-- 6a. Main note on every work order.
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT
SELECT 'WO_NOTE', w.wo_id || '-N1', w.wo_id, w.asset_id,
       TIMESTAMPADD(hour, 2, w.created_at),
       'TECHNICIAN', c.template_id, c.kind, w.gen_role, c.template_text
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_WORK_ORDERS w
JOIN {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s ON s.asset_id = w.asset_id
JOIN {{EVAL_SCHEMA}}.SYNTH_TEMPLATE_CATALOGUE c
  ON c.asset_class = s.asset_class
 AND c.kind = w.main_kind
 AND c.kind_rank = COALESCE(w.main_rank, 1 + MOD(ABS(HASH(w.wo_id, 'tpl')), c.kind_count));

-- 6b. Second note (boilerplate or admin) on about half of background WOs.
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT
SELECT 'WO_NOTE', w.wo_id || '-N2', w.wo_id, w.asset_id, w.closed_at,
       'TECHNICIAN', c.template_id, c.kind, w.gen_role, c.template_text
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_WORK_ORDERS w
JOIN {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s ON s.asset_id = w.asset_id
JOIN {{EVAL_SCHEMA}}.SYNTH_TEMPLATE_CATALOGUE c
  ON c.asset_class = s.asset_class
 AND c.kind = CASE WHEN UNIFORM(0, 1, HASH(w.wo_id, 'n2k')) = 0 THEN 'BOILERPLATE' ELSE 'ADMIN' END
 AND c.kind_rank = 1 + MOD(ABS(HASH(w.wo_id, 'n2t')), c.kind_count)
WHERE w.gen_role IN ('BACKGROUND', 'RECURRING')
  AND UNIFORM(0, 1, HASH(w.wo_id, 'n2')) = 0;

-- 6c. Leakage traps on planted failures:
--     - hindsight note appended to the route WO five days AFTER the failure;
--     - as-found note on the emergency WO three days after the failure.
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT
SELECT 'WO_NOTE', w.wo_id || '-N9', w.wo_id, w.asset_id,
       TIMESTAMPADD(hour, 14, DATEADD(day, 5, s.event_date)::TIMESTAMP_NTZ),
       'RELIABILITY_ENGINEER', c.template_id, c.kind, 'LEAK_HINDSIGHT', c.template_text
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_WORK_ORDERS w
JOIN {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s ON s.asset_id = w.asset_id
JOIN {{EVAL_SCHEMA}}.SYNTH_TEMPLATE_CATALOGUE c ON c.asset_class = s.asset_class AND c.kind = 'HINDSIGHT'
WHERE w.gen_role = 'SCEN_ROUTE'
UNION ALL
SELECT 'WO_NOTE', w.wo_id || '-N2', w.wo_id, w.asset_id,
       TIMESTAMPADD(hour, 10, DATEADD(day, 3, s.event_date)::TIMESTAMP_NTZ),
       'TECHNICIAN', c.template_id, c.kind, 'LEAK_AS_FOUND', c.template_text
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_WORK_ORDERS w
JOIN {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s ON s.asset_id = w.asset_id
JOIN {{EVAL_SCHEMA}}.SYNTH_TEMPLATE_CATALOGUE c ON c.asset_class = s.asset_class AND c.kind = 'AS_FOUND'
WHERE w.gen_role = 'SCEN_EMERGENCY';

-- 6d. Background inspection reports: negatives.
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT
WITH k AS (
    SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS k
    FROM TABLE(GENERATOR(ROWCOUNT => {{INSPECTIONS_PER_ASSET}}))
)
SELECT 'INSPECTION', 'SYN-IR-' || LPAD(s.n::STRING, 5, '0') || '-' || LPAD(k.k::STRING, 2, '0'),
       NULL, s.asset_id,
       TIMESTAMPADD(hour, 10, DATEADD(day, MOD(ABS(HASH(s.n, k.k, 'ird')), {{HISTORY_DAYS}} - 5),
                                      DATEADD(day, -{{HISTORY_DAYS}}, '{{ANCHOR_DATE}}'::DATE))::TIMESTAMP_NTZ),
       'INSPECTOR', c.template_id, c.kind, 'BACKGROUND', c.template_text
FROM {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s
CROSS JOIN k
JOIN {{EVAL_SCHEMA}}.SYNTH_TEMPLATE_CATALOGUE c
  ON c.asset_class = s.asset_class AND c.kind = 'NEGATIVE'
 AND c.kind_rank = 1 + MOD(ABS(HASH(s.n, k.k, 'irt')), c.kind_count);

-- 6e. Planted precursor inspections (rank 1 at event-50, rank 3 at event-12;
--     rank 2 is the route WO note at event-30 from 6a).
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT
SELECT 'INSPECTION', 'SYN-IR-' || LPAD(s.n::STRING, 5, '0') || '-P' || c.kind_rank::STRING,
       NULL, s.asset_id,
       TIMESTAMPADD(hour, 10, DATEADD(day, CASE c.kind_rank WHEN 1 THEN -50 ELSE -12 END, s.event_date)::TIMESTAMP_NTZ),
       'INSPECTOR', c.template_id, c.kind, 'SCEN_PRECURSOR', c.template_text
FROM {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s
JOIN {{EVAL_SCHEMA}}.SYNTH_TEMPLATE_CATALOGUE c
  ON c.asset_class = s.asset_class AND c.kind = 'PRECURSOR' AND c.kind_rank IN (1, 3)
WHERE s.scenario = 'PLANTED_FAILURE';

-- 6f. False-alarm controls: one benign anomaly inspection on the event date.
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT
SELECT 'INSPECTION', 'SYN-IR-' || LPAD(s.n::STRING, 5, '0') || '-C1', NULL, s.asset_id,
       TIMESTAMPADD(hour, 10, s.event_date::TIMESTAMP_NTZ),
       'INSPECTOR', c.template_id, c.kind, 'SCEN_CONTROL', c.template_text
FROM {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s
JOIN {{EVAL_SCHEMA}}.SYNTH_TEMPLATE_CATALOGUE c ON c.asset_class = s.asset_class AND c.kind = 'CONTROL'
WHERE s.scenario = 'FALSE_ALARM';

-- 6g. Fill placeholders. Values are kind-dependent so text and sensors agree.
UPDATE {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT t
SET source_text = REPLACE(REPLACE(REPLACE(t.source_text,
        '{TAG}', a.asset_tag),
        '{V1}', TO_VARCHAR(ROUND(
            CASE WHEN t.kind IN ('FAILURE', 'SCEN_FAILURE', 'AS_FOUND') THEN 6.0 + UNIFORM(0, 39, HASH(t.source_id, 'v')) / 10
                 WHEN t.kind IN ('PRECURSOR', 'CONTROL')                THEN 3.6 + UNIFORM(0, 19, HASH(t.source_id, 'v')) / 10
                 ELSE 1.5 + UNIFORM(0, 12, HASH(t.source_id, 'v')) / 10 END, 1))),
        '{T1}', TO_VARCHAR(
            CASE WHEN a.asset_class = 'AIR_COMPRESSOR' THEN 24 ELSE 0 END +
            CASE WHEN t.kind IN ('FAILURE', 'SCEN_FAILURE', 'AS_FOUND') THEN 88 + UNIFORM(0, 8, HASH(t.source_id, 't'))
                 WHEN t.kind = 'PRECURSOR'                              THEN 74 + UNIFORM(0, 8, HASH(t.source_id, 't'))
                 ELSE 56 + UNIFORM(0, 8, HASH(t.source_id, 't')) END))
FROM {{SCHEMA}}.SYNTH_ASSETS a
WHERE a.asset_id = t.asset_id;

-- ---------------------------------------------------------------------
-- 7. Pipeline-visible tables. No template_id, kind, gen_role or scenario.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_WORK_ORDERS AS
SELECT w.wo_id, w.asset_id, a.functional_location, w.wo_type, w.priority,
       w.created_at, w.closed_at, w.last_modified_at, w.description, w.failure_code
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_WORK_ORDERS w
JOIN {{SCHEMA}}.SYNTH_ASSETS a ON a.asset_id = w.asset_id;

CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_WO_NOTES AS
SELECT source_id AS note_id, wo_id, asset_id, source_ts AS note_ts, author_role, source_text AS note_text
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT
WHERE source_type = 'WO_NOTE';

CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_INSPECTION_REPORTS AS
SELECT source_id AS report_id, asset_id, source_ts AS inspection_ts, author_role AS inspector_role,
       source_text AS report_text
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT
WHERE source_type = 'INSPECTION';

-- ---------------------------------------------------------------------
-- 8. Downtime events: planned (half of PM WOs) and unplanned (planted
--    failures). This is the precursor label source.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_DOWNTIME_EVENTS AS
SELECT 'SYN-DT-' || w.wo_id AS event_id, w.asset_id,
       w.created_at AS start_ts, TIMESTAMPADD(hour, 4, w.created_at) AS end_ts,
       TRUE AS is_planned, 'PLANNED_MAINTENANCE' AS cause_category
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_WORK_ORDERS w
WHERE w.wo_type = 'PM' AND UNIFORM(0, 1, HASH(w.wo_id, 'dt')) = 0
UNION ALL
SELECT 'SYN-DT-' || s.asset_id || '-F1', s.asset_id,
       TIMESTAMPADD(hour, 1, s.event_date::TIMESTAMP_NTZ),
       TIMESTAMPADD(hour, 49, s.event_date::TIMESTAMP_NTZ),
       FALSE, 'EQUIPMENT_FAILURE'
FROM {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s
WHERE s.scenario = 'PLANTED_FAILURE';

-- ---------------------------------------------------------------------
-- 9. Daily sensor history. Vibration in mm/s RMS, bearing / discharge
--    temperature in C, dates in UTC. About 3 percent of readings missing
--    (NULL, never zero). Planted failures drift over the 45 days before
--    the event and read NULL while down; controls get a one-day spike.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_SENSOR_DAILY AS
WITH days AS (
    SELECT DATEADD(day, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1,
                   DATEADD(day, -{{HISTORY_DAYS}}, '{{ANCHOR_DATE}}'::DATE)) AS reading_date
    FROM TABLE(GENERATOR(ROWCOUNT => {{HISTORY_DAYS}} + 1))
), grid AS (
    SELECT s.asset_id, s.asset_class, s.scenario, s.event_date, d.reading_date,
           DATEDIFF(day, d.reading_date, s.event_date) AS days_to_event
    FROM {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s CROSS JOIN days d
)
SELECT
    g.asset_id,
    g.reading_date,
    CASE
      WHEN UNIFORM(0, 99, HASH(g.asset_id, g.reading_date, 'gap')) < 3 THEN NULL
      WHEN g.scenario = 'PLANTED_FAILURE' AND g.days_to_event BETWEEN -2 AND 0 THEN NULL
      ELSE ROUND(1.6 + UNIFORM(0, 80, HASH(g.asset_id, g.reading_date, 'vb')) / 100
           + CASE WHEN g.scenario = 'PLANTED_FAILURE' AND g.days_to_event BETWEEN 1 AND 45
                  THEN 5.0 * (45 - g.days_to_event) / 45 ELSE 0 END
           + CASE WHEN g.scenario = 'FALSE_ALARM' AND g.days_to_event = 0 THEN 4.0 ELSE 0 END, 2)
    END AS vibration_mm_s,
    CASE
      WHEN UNIFORM(0, 99, HASH(g.asset_id, g.reading_date, 'gap')) < 3 THEN NULL
      WHEN g.scenario = 'PLANTED_FAILURE' AND g.days_to_event BETWEEN -2 AND 0 THEN NULL
      ELSE ROUND(CASE WHEN g.asset_class = 'AIR_COMPRESSOR' THEN 82 ELSE 58 END
           + UNIFORM(0, 60, HASH(g.asset_id, g.reading_date, 'tp')) / 10
           + CASE WHEN g.scenario = 'PLANTED_FAILURE' AND g.days_to_event BETWEEN 1 AND 45
                  THEN 22.0 * (45 - g.days_to_event) / 45 ELSE 0 END
           + CASE WHEN g.scenario = 'FALSE_ALARM' AND g.days_to_event = 0 THEN 12.0 ELSE 0 END, 1)
    END AS bearing_temp_c
FROM grid g;

-- ---------------------------------------------------------------------
-- 10. Answer keys (EVAL schema only).
-- ---------------------------------------------------------------------

-- Every generated source, labeled or not, so precision can count false
-- positives on sources whose correct answer is "no signals".
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.ANSWER_KEY_SOURCES AS
SELECT source_type, source_id, asset_id, source_ts, kind, gen_role
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT;

CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.ANSWER_KEY_SIGNALS AS
SELECT t.source_type, t.source_id, t.asset_id, s.asset_class,
       l.component_code, c.assembly_code, l.failure_mode_code, l.polarity
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT t
JOIN {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s ON s.asset_id = t.asset_id
JOIN {{EVAL_SCHEMA}}.SYNTH_TEMPLATE_LABELS l ON l.template_id = t.template_id
JOIN {{SCHEMA}}.SYNTH_TAXONOMY_COMPONENT c
  ON c.asset_class = s.asset_class AND c.component_code = l.component_code;

CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.ANSWER_KEY_PRECURSORS AS
SELECT s.asset_id, s.asset_class, s.scenario,
       CASE WHEN s.scenario = 'PLANTED_FAILURE' THEN 'SYN-DT-' || s.asset_id || '-F1' END AS event_id,
       CASE WHEN s.scenario = 'PLANTED_FAILURE'
            THEN TIMESTAMPADD(hour, 1, s.event_date::TIMESTAMP_NTZ) END                AS failure_ts,
       CASE WHEN s.scenario = 'PLANTED_FAILURE'
            THEN TIMESTAMPADD(hour, 10, DATEADD(day, -50, s.event_date)::TIMESTAMP_NTZ) END AS first_text_precursor_ts,
       CASE WHEN s.scenario = 'PLANTED_FAILURE'
            THEN DATEADD(day, -44, s.event_date) END                                   AS first_sensor_drift_date,
       CASE WHEN s.scenario = 'FALSE_ALARM' THEN s.event_date END                      AS control_anomaly_date
FROM {{EVAL_SCHEMA}}.SYNTH_ASSET_SCENARIO s
WHERE s.scenario IN ('PLANTED_FAILURE', 'FALSE_ALARM');

CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.ANSWER_KEY_RECURRING AS
SELECT w.asset_id, w.asset_id || '-RG1' AS issue_group_id, w.wo_id, w.created_at, w.closed_at
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_WORK_ORDERS w
WHERE w.gen_role = 'RECURRING';

-- Records that MUST NOT appear in any precursor feature for their event.
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.ANSWER_KEY_LEAKAGE_CANARY AS
SELECT t.source_type, t.source_id, t.wo_id, t.asset_id, t.source_ts,
       'SYN-DT-' || t.asset_id || '-F1' AS event_id,
       t.gen_role AS reason
FROM {{EVAL_SCHEMA}}.SYNTH_GEN_TEXT t
WHERE t.gen_role IN ('LEAK_HINDSIGHT', 'LEAK_AS_FOUND', 'SCEN_EMERGENCY');
