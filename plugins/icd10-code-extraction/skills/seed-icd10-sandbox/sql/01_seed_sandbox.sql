-- =====================================================================
-- Synthetic clinical corpus with ground truth, for ICD-10 / HCC
-- suspecting pipeline development and accuracy measurement.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}            target database
--   {{SCHEMA}}        target schema for sandbox data
--   {{EVAL_SCHEMA}}   separate schema for the answer key (quarantine)
--   {{PANEL_SIZE}}    number of patients, e.g. 500
--   {{MODEL_YEAR}}    CMS model year, e.g. v28
--
-- All identifiers are prefixed SYN- so a synthetic row can never be
-- mistaken for a real one. All names, providers and sites are fabricated.
--
-- The answer key lands in {{EVAL_SCHEMA}}, NOT {{SCHEMA}}. Nothing in the
-- pipeline may read it. Only the accuracy harness reads it.
-- =====================================================================

USE DATABASE {{DB}};
CREATE SCHEMA IF NOT EXISTS {{SCHEMA}};
CREATE SCHEMA IF NOT EXISTS {{EVAL_SCHEMA}};
USE SCHEMA {{DB}}.{{SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Condition reference. RAF weights are illustrative placeholders for
--    sandbox arithmetic only -- replace with the published factors for
--    the pinned model year before any revenue figure is shown to a
--    customer. model_year is a column, not an assumption, so a stale
--    build is visible rather than silent.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_CONDITION_REFERENCE (
    hcc_code            VARCHAR(10),
    hcc_category        VARCHAR(100),
    primary_icd10_codes VARCHAR(2000),
    raf_factor          FLOAT,
    model_year          VARCHAR(10)
);

INSERT INTO SYNTH_CONDITION_REFERENCE
    (hcc_code, hcc_category, primary_icd10_codes, raf_factor, model_year)
VALUES
    ('HCC85',  'Congestive Heart Failure',
     'I50.20, I50.22, I50.32, I50.42, I50.9', 0.331, '{{MODEL_YEAR}}'),
    ('HCC111', 'Chronic Obstructive Pulmonary Disease',
     'J44.0, J44.1, J44.9', 0.315, '{{MODEL_YEAR}}'),
    ('HCC18',  'Diabetes with Chronic Complications',
     'E11.21, E11.22, E11.40, E11.42, E11.51', 0.302, '{{MODEL_YEAR}}'),
    ('HCC96',  'Specified Heart Arrhythmias',
     'I48.0, I48.1, I48.2, I48.91', 0.258, '{{MODEL_YEAR}}'),
    ('HCC82',  'Peripheral Vascular Disease',
     'I70.213, I70.221, I73.9', 0.276, '{{MODEL_YEAR}}');

-- ---------------------------------------------------------------------
-- 2. Patient panel. Fabricated name pools, skewed to a senior
--    population so age-related condition prevalence is plausible.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_PATIENTS (
    patient_id            VARCHAR(20),
    patient_name          VARCHAR(100),
    age                   INT,
    gender                VARCHAR(10),
    site_code             VARCHAR(10),
    pcp_name              VARCHAR(100),
    panel_status          VARCHAR(20),
    next_appointment_date DATE
);

INSERT INTO SYNTH_PATIENTS
SELECT
    'SYN-' || LPAD(SEQ4(), 6, '0') AS patient_id,
    ARRAY_CONSTRUCT('Alder','Brentwood','Calloway','Danforth','Ellsworth',
                    'Fairbank','Gladstone','Harrowgate','Inglewood','Jessup',
                    'Kingsley','Larkspur','Merriweather','Northrup','Oakhurst',
                    'Pemberton','Quincey','Ravenwood','Stanhope','Thornbury')
        [UNIFORM(0, 19, RANDOM())]::STRING
      || ', ' ||
    ARRAY_CONSTRUCT('Adela','Bernard','Clementine','Desmond','Eunice',
                    'Fitzgerald','Genevieve','Horace','Imogene','Jasper',
                    'Katherine','Leonard','Mabel','Norbert','Ophelia',
                    'Percival','Rosalind','Sylvester','Theodora','Ulysses')
        [UNIFORM(0, 19, RANDOM())]::STRING AS patient_name,
    UNIFORM(66, 94, RANDOM())             AS age,
    CASE WHEN UNIFORM(0, 1, RANDOM()) = 0 THEN 'F' ELSE 'M' END AS gender,
    ARRAY_CONSTRUCT('SITE-01','SITE-02','SITE-03','SITE-04','SITE-05')
        [UNIFORM(0, 4, RANDOM())]::STRING AS site_code,
    'Dr. ' || ARRAY_CONSTRUCT('Abernathy','Blackwood','Cortland','Delacroix',
                              'Everhart','Fenwick','Grimsby','Holloway')
        [UNIFORM(0, 7, RANDOM())]::STRING AS pcp_name,
    'ACTIVE'                              AS panel_status,
    DATEADD(DAY, UNIFORM(1, 90, RANDOM()), CURRENT_DATE()) AS next_appointment_date
FROM TABLE(GENERATOR(ROWCOUNT => {{PANEL_SIZE}}));

-- ---------------------------------------------------------------------
-- 3. Claims history -- what is ALREADY coded. The pipeline suppresses
--    against this so output is gaps, not restatement.
--
--    Deliberately excludes the planted conditions for the labeled
--    patients (verified by check 1 in SKILL.md). Code format here is
--    'HCC85' style; note the format, because a mismatch against the
--    pipeline side silently empties the output.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_CLAIMS_HISTORY (
    claim_id      VARCHAR(20),
    patient_id    VARCHAR(20),
    service_date  DATE,
    icd10_code    VARCHAR(10),
    hcc_mapped    VARCHAR(10),
    model_year    VARCHAR(10)
);

-- Background coded conditions for the unlabeled population.
INSERT INTO SYNTH_CLAIMS_HISTORY
SELECT
    'SYN-CLM-' || LPAD(SEQ4(), 8, '0'),
    p.patient_id,
    DATEADD(DAY, -UNIFORM(30, 330, RANDOM()), CURRENT_DATE()),
    'E11.9',
    'HCC19',
    '{{MODEL_YEAR}}'
FROM SYNTH_PATIENTS p, TABLE(GENERATOR(ROWCOUNT => 1))
WHERE UNIFORM(0, 100, RANDOM()) < 45
  AND p.patient_id NOT IN (
      'SYN-000001','SYN-000002','SYN-000003','SYN-000004','SYN-000005',
      'SYN-000006','SYN-000007','SYN-000008','SYN-000009','SYN-000010'
  );

-- Patient 11 is the suppression control: correctly coded AND has
-- supporting evidence in the notes. The pipeline must NOT re-surface it.
INSERT INTO SYNTH_CLAIMS_HISTORY
    (claim_id, patient_id, service_date, icd10_code, hcc_mapped, model_year)
VALUES
    ('SYN-CLM-90000011', 'SYN-000011',
     DATEADD(DAY, -60, CURRENT_DATE()), 'J44.1', 'HCC111', '{{MODEL_YEAR}}');

-- ---------------------------------------------------------------------
-- 4. Documents. Mixed text-native and scanned, with administrative
--    noise and duplicates so the routing tiers have something to route.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_DOCUMENTS (
    document_id     VARCHAR(20),
    patient_id      VARCHAR(20),
    document_date   DATE,
    document_type   VARCHAR(50),
    source_system   VARCHAR(50),
    file_format     VARCHAR(10),
    page_count      INT,
    file_path       VARCHAR(500),   -- populated when document_text IS NULL
    document_text   VARCHAR(16777216)
);

-- 4a. PLANTED SIGNALS -- the labeled set. Evidence is spread across
--     multiple documents and dates so the pipeline must assemble it
--     rather than pattern-match a single sentence.

-- SYN-000001 | HCC85 CHF | strong, trending. Expect SUSPECT.
INSERT INTO SYNTH_DOCUMENTS
    (document_id, patient_id, document_date, document_type, source_system,
     file_format, page_count, file_path, document_text)
VALUES
('SYN-DOC-00000101','SYN-000001',DATEADD(DAY,-150,CURRENT_DATE()),
 'OFFICE_VISIT_NOTE','EHR_NOTES','text',2,NULL,
 'SUBJECTIVE: 79yo presents with three months of progressive exertional dyspnea, now at one flight of stairs. Reports two-pillow orthopnea, new since last visit. Denies chest pain. OBJECTIVE: BP 138/84, HR 88, weight up 4.1 kg from prior visit. JVD present at 45 degrees. Bibasilar crackles. 2+ pitting edema to mid-shin bilaterally. S3 gallop appreciated at apex. ASSESSMENT: Volume overload, etiology under evaluation. PLAN: BNP, echocardiogram, initiate furosemide 20mg daily.'),
('SYN-DOC-00000102','SYN-000001',DATEADD(DAY,-148,CURRENT_DATE()),
 'LABORATORY_REPORT','LAB_INTERFACE','text',1,NULL,
 'BRAIN NATRIURETIC PEPTIDE. Result: 620 pg/mL. Reference range: less than 100 pg/mL. FLAG: HIGH. Prior results for comparison: 340 pg/mL collected 90 days prior; 180 pg/mL collected 210 days prior.'),
('SYN-DOC-00000103','SYN-000001',DATEADD(DAY,-140,CURRENT_DATE()),
 'ECHOCARDIOGRAM_REPORT','CARDIOLOGY_LAB','text',3,NULL,
 'TRANSTHORACIC ECHOCARDIOGRAM. FINDINGS: Left ventricular ejection fraction estimated at 35 percent by biplane method, moderately reduced. Global hypokinesis. Left ventricular end-diastolic dimension 58 mm, mildly dilated. Grade II diastolic dysfunction. Mild mitral regurgitation. IMPRESSION: Moderately reduced systolic function with chamber dilation. Findings consistent with systolic dysfunction. Correlate clinically.'),

-- SYN-000002 | HCC18 Diabetes with chronic complications | multi-system.
('SYN-DOC-00000201','SYN-000002',DATEADD(DAY,-120,CURRENT_DATE()),
 'OFFICE_VISIT_NOTE','EHR_NOTES','text',2,NULL,
 'SUBJECTIVE: 74yo with 16-year history of type 2 diabetes. Reports bilateral burning and numbness in feet, progressive over 8 months, now interfering with sleep. OBJECTIVE: Diminished vibratory sensation to mid-calf bilaterally. Absent ankle reflexes. Monofilament testing insensate at 6 of 10 plantar sites bilaterally. No ulceration. ASSESSMENT: Diabetes with peripheral neuropathy. Renal function declining, see labs. PLAN: Gabapentin initiated. Continue empagliflozin, added specifically for renal protection. Nephrology referral.'),
('SYN-DOC-00000202','SYN-000002',DATEADD(DAY,-118,CURRENT_DATE()),
 'LABORATORY_REPORT','LAB_INTERFACE','text',1,NULL,
 'COMPREHENSIVE METABOLIC PANEL AND URINE STUDIES. Creatinine 1.82 mg/dL, HIGH. Estimated GFR 38 mL/min/1.73m2, LOW. Urine albumin-to-creatinine ratio 380 mg/g, HIGH, consistent with macroalbuminuria. Hemoglobin A1c 8.4 percent. eGFR trend: 62 at 24 months, 49 at 12 months, 38 current.'),

-- SYN-000003 | HCC82 PVD | objective vascular study.
('SYN-DOC-00000301','SYN-000003',DATEADD(DAY,-95,CURRENT_DATE()),
 'VASCULAR_STUDY_REPORT','VASCULAR_LAB','text',2,NULL,
 'LOWER EXTREMITY ARTERIAL DUPLEX WITH SEGMENTAL PRESSURES. Ankle-brachial index: right 0.68, left 0.52. Both abnormal; left in the moderate-to-severe range. Monophasic waveforms below the popliteal bilaterally. Significant stenosis of the left superficial femoral artery estimated at 70 to 80 percent. IMPRESSION: Bilateral lower extremity arterial insufficiency, more severe on the left.'),
('SYN-DOC-00000302','SYN-000003',DATEADD(DAY,-93,CURRENT_DATE()),
 'OFFICE_VISIT_NOTE','EHR_NOTES','text',1,NULL,
 'SUBJECTIVE: 81yo reports left calf cramping after approximately one block of walking, relieved by rest, worsening over 6 months. OBJECTIVE: Diminished left dorsalis pedis and posterior tibial pulses. Femoral bruit audible on the left. Dependent rubor of the left foot. A 1.5 cm ulcer over the left lateral malleolus, present 7 weeks, no granulation tissue. ASSESSMENT: Claudication with non-healing ulcer. PLAN: Cilostazol started. Vascular surgery referral.'),

-- SYN-000004 | HCC96 Arrhythmia | ambulatory monitor.
('SYN-DOC-00000401','SYN-000004',DATEADD(DAY,-70,CURRENT_DATE()),
 'CARDIAC_MONITOR_REPORT','CARDIOLOGY_LAB','text',4,NULL,
 'FOURTEEN-DAY AMBULATORY CARDIAC MONITOR. Total wear time 13.6 days, analyzable 98 percent. FINDINGS: Sixteen discrete episodes of atrial fibrillation, longest 6 hours 42 minutes, total burden 11 percent of monitored time. Ventricular rates during episodes 96 to 168 bpm. Patient-triggered events correlate with two documented episodes. IMPRESSION: Paroxysmal atrial fibrillation with moderate burden.'),
('SYN-DOC-00000402','SYN-000004',DATEADD(DAY,-66,CURRENT_DATE()),
 'OFFICE_VISIT_NOTE','EHR_NOTES','text',1,NULL,
 'SUBJECTIVE: 77yo describes intermittent palpitations with associated lightheadedness, several episodes weekly. OBJECTIVE: Irregularly irregular rhythm on examination today, rate approximately 104. ASSESSMENT: Reviewed monitor findings with patient. PLAN: Anticoagulation initiated after CHA2DS2-VASc discussion, score 4. Rate control with metoprolol. Cardiology follow-up.'),

-- SYN-000005 | HCC111 COPD | spirometry with post-bronchodilator values.
('SYN-DOC-00000501','SYN-000005',DATEADD(DAY,-200,CURRENT_DATE()),
 'PULMONARY_FUNCTION_REPORT','PULMONARY_LAB','text',3,NULL,
 'SPIROMETRY WITH BRONCHODILATOR RESPONSE. Pre-bronchodilator FEV1 1.24 L, 46 percent predicted. FVC 2.85 L, 74 percent predicted. FEV1/FVC ratio 0.44. Post-bronchodilator FEV1 1.31 L, 48 percent predicted, change of 5.6 percent, not significant. IMPRESSION: Severe irreversible airflow obstruction. Pattern consistent with chronic obstructive disease. No significant bronchodilator reversibility.'),
('SYN-DOC-00000502','SYN-000005',DATEADD(DAY,-195,CURRENT_DATE()),
 'OFFICE_VISIT_NOTE','EHR_NOTES','text',2,NULL,
 'SUBJECTIVE: 83yo with 48 pack-year smoking history, quit 6 years ago. Chronic productive cough most mornings. Dyspnea on minimal exertion, mMRC grade 3. Two courses of prednisone in the past 12 months for exacerbations. OBJECTIVE: Barrel chest. Prolonged expiratory phase. Diffusely diminished breath sounds with scattered expiratory wheeze. Room air saturation 89 percent. ASSESSMENT: Severe obstructive lung disease with frequent exacerbations. PLAN: Continue tiotropium and budesonide-formoterol. Pulmonary rehabilitation referral.'),

-- 4b. BORDERLINE cases -- correct answer is EVAL, not SUSPECT. These
--     test whether the pipeline distinguishes "warrants a look" from
--     "the evidence supports this diagnosis".
('SYN-DOC-00000601','SYN-000006',DATEADD(DAY,-80,CURRENT_DATE()),
 'OFFICE_VISIT_NOTE','EHR_NOTES','text',2,NULL,
 'SUBJECTIVE: 72yo reports mild exertional dyspnea over the past two months, tolerating usual activity with some limitation. OBJECTIVE: Trace bilateral ankle edema. Lungs clear. No JVD. No gallop. BNP 168 pg/mL, mildly elevated. ASSESSMENT: Exertional dyspnea with minimal findings. Cardiac versus deconditioning, not yet distinguished. No echocardiogram on file. PLAN: Order echocardiogram. Reassess after results.'),
('SYN-DOC-00000701','SYN-000007',DATEADD(DAY,-75,CURRENT_DATE()),
 'OFFICE_VISIT_NOTE','EHR_NOTES','text',1,NULL,
 'SUBJECTIVE: 69yo with 12-year diabetes history, reports occasional tingling in toes, intermittent, not affecting sleep or function. OBJECTIVE: Monofilament intact at all 10 plantar sites. Vibratory sensation preserved. Ankle reflexes present but reduced. eGFR 68, stable. Urine albumin-to-creatinine ratio 42 mg/g, mildly elevated. A1c 7.6 percent. ASSESSMENT: Diabetes, well controlled. Early sensory symptoms without objective deficit. Mild albuminuria, monitor. PLAN: Repeat urine studies in 3 months.'),

-- 4c. DISTRACTOR cases -- findings that superficially suggest a
--     condition but have a documented alternative explanation. A
--     pipeline that flags these is over-calling. This is how precision
--     gets measured.
('SYN-DOC-00000801','SYN-000008',DATEADD(DAY,-60,CURRENT_DATE()),
 'OFFICE_VISIT_NOTE','EHR_NOTES','text',2,NULL,
 'SUBJECTIVE: 76yo with bilateral lower extremity swelling, worse at end of day, improves overnight with elevation. No dyspnea, no orthopnea, no exertional limitation. OBJECTIVE: 2+ bilateral pitting edema. Prominent varicosities bilaterally with hemosiderin staining. Lungs clear throughout. No JVD. No gallop. BNP 44 pg/mL, normal. Echocardiogram 4 months ago: ejection fraction 60 percent, normal chamber sizes, normal diastolic function. Venous duplex: bilateral superficial venous reflux, no deep venous thrombosis. ASSESSMENT: Edema secondary to chronic venous insufficiency. Cardiac etiology excluded by normal BNP and normal recent echocardiogram. PLAN: Compression stockings, elevation.'),
('SYN-DOC-00000901','SYN-000009',DATEADD(DAY,-55,CURRENT_DATE()),
 'OFFICE_VISIT_NOTE','EHR_NOTES','text',2,NULL,
 'SUBJECTIVE: 71yo former smoker, quit 18 years ago, presents for follow-up of prior dyspnea. Symptoms fully resolved following treatment of anemia. Currently walks 2 miles daily without limitation. OBJECTIVE: Lungs clear to auscultation, no wheeze, normal expiratory phase. Saturation 97 percent on room air. Spirometry today: FEV1 2.38 L, 88 percent predicted. FEV1/FVC ratio 0.76, normal. ASSESSMENT: Normal spirometry. No evidence of obstructive lung disease. Prior dyspnea attributable to anemia, now corrected. PLAN: No pulmonary follow-up indicated.'),
('SYN-DOC-00001001','SYN-000010',DATEADD(DAY,-50,CURRENT_DATE()),
 'OFFICE_VISIT_NOTE','EHR_NOTES','text',1,NULL,
 'SUBJECTIVE: 78yo seen for medication review. Reports feeling well. OBJECTIVE: Regular rate and rhythm. No murmur or gallop. No edema. Current medications include metoprolol, prescribed for hypertension, and furosemide, prescribed for lower extremity edema of venous origin. ASSESSMENT: Hypertension, controlled. Venous insufficiency, stable. No cardiac symptoms. Note for the record: medication list may superficially suggest heart failure, but there is no supporting clinical or imaging evidence and no such diagnosis has been made. PLAN: Continue current regimen.'),

-- 4d. SUPPRESSION CONTROL -- SYN-000011 has COPD evidence AND it is
--     already coded in claims. Correct behaviour is to emit nothing.
('SYN-DOC-00001101','SYN-000011',DATEADD(DAY,-65,CURRENT_DATE()),
 'PULMONARY_FUNCTION_REPORT','PULMONARY_LAB','text',3,NULL,
 'SPIROMETRY. Post-bronchodilator FEV1 1.18 L, 43 percent predicted. FEV1/FVC ratio 0.41. IMPRESSION: Severe fixed airflow obstruction, consistent with known chronic obstructive pulmonary disease. Stable compared with study 12 months prior.');

-- 4e. Background clinical documents for the unlabeled population, so the
--     labeled patients are not the only ones with content.
INSERT INTO SYNTH_DOCUMENTS
    (document_id, patient_id, document_date, document_type, source_system,
     file_format, page_count, file_path, document_text)
SELECT
    'SYN-DOC-1' || LPAD(SEQ4(), 7, '0'),
    p.patient_id,
    DATEADD(DAY, -UNIFORM(10, 340, RANDOM()), CURRENT_DATE()),
    'OFFICE_VISIT_NOTE',
    'EHR_NOTES',
    'text', 1, NULL,
    -- The first ~300 characters are deliberately IDENTICAL across patients.
    -- Real corpora share note templates, and this is what traps an unscoped
    -- MD5(LEFT(text, N)) dedup key. The tail varies so the documents are not
    -- wholly identical, which is both more realistic and keeps legitimate
    -- patient-scoped dedup from collapsing them.
    'SUBJECTIVE: Routine follow-up. Patient reports stable status without new complaints. '
      || 'Medication adherence reported as good. OBJECTIVE: Vital signs within patient baseline. '
      || 'Cardiopulmonary examination unremarkable. No peripheral edema. '
      || 'ASSESSMENT: Chronic conditions stable. PLAN: Continue current regimen, '
      || 'routine follow-up in 3 months. '
      || 'Recorded weight ' || UNIFORM(58, 104, RANDOM())::VARCHAR || ' kg. '
      || 'Blood pressure ' || UNIFORM(108, 148, RANDOM())::VARCHAR
      || '/' || UNIFORM(62, 88, RANDOM())::VARCHAR || '. '
      || 'Reviewed by ' || p.pcp_name || '.'
FROM SYNTH_PATIENTS p, TABLE(GENERATOR(ROWCOUNT => 2))
WHERE p.patient_id NOT IN (
    'SYN-000001','SYN-000002','SYN-000003','SYN-000004','SYN-000005',
    'SYN-000006','SYN-000007','SYN-000008','SYN-000009','SYN-000010','SYN-000011'
);

-- 4f. ADMINISTRATIVE NOISE -- should route to the skip tier.
INSERT INTO SYNTH_DOCUMENTS
    (document_id, patient_id, document_date, document_type, source_system,
     file_format, page_count, file_path, document_text)
SELECT
    'SYN-DOC-2' || LPAD(SEQ4(), 7, '0'),
    p.patient_id,
    DATEADD(DAY, -UNIFORM(10, 340, RANDOM()), CURRENT_DATE()),
    n.doc_type,
    'DOCUMENT_MANAGEMENT',
    'pdf', 1, NULL,
    n.body
FROM SYNTH_PATIENTS p
CROSS JOIN (
    SELECT 'CONSENT_FORM' AS doc_type,
           'PATIENT CONSENT FOR TREATMENT. I hereby consent to receive medical treatment '
             || 'from the providers of this practice. I understand that no guarantee has been '
             || 'made regarding the outcome of treatment or examination.' AS body
    UNION ALL SELECT 'PRIVACY_NOTICE',
           'NOTICE OF PRIVACY PRACTICES. This notice describes how medical information about '
             || 'you may be used and disclosed and how you can get access to this information. '
             || 'Please review it carefully.'
    UNION ALL SELECT 'BILLING_FORM',
           'ASSIGNMENT OF BENEFITS AND FINANCIAL RESPONSIBILITY AGREEMENT. I authorize payment '
             || 'of medical benefits directly to the provider and accept financial '
             || 'responsibility for charges not covered.'
    UNION ALL SELECT 'RECORDS_AUTHORIZATION',
           'AUTHORIZATION FOR RELEASE OF INFORMATION. I authorize the release of my medical '
             || 'records to the party designated below for the purpose indicated.'
) n
WHERE UNIFORM(0, 100, RANDOM()) < 35;

-- 4g. DUPLICATES. Two kinds, both deliberate:
--     (i)  same patient, same content, different document_id -- normal dedup
--     (ii) DIFFERENT patients sharing identical text -- traps an unscoped
--          MD5(LEFT(text,N)) dedup key, which would wrongly delete the
--          second patient's document entirely.
INSERT INTO SYNTH_DOCUMENTS
    (document_id, patient_id, document_date, document_type, source_system,
     file_format, page_count, file_path, document_text)
SELECT
    'SYN-DOC-3' || LPAD(SEQ4(), 7, '0'),
    d.patient_id,
    d.document_date,
    'OFFICE_VISIT_NOTE_COPY',
    'DOCUMENT_MANAGEMENT',
    'text', 1, NULL,
    d.document_text
FROM SYNTH_DOCUMENTS d
WHERE d.document_type = 'OFFICE_VISIT_NOTE'
  AND d.document_text IS NOT NULL
  AND UNIFORM(0, 100, RANDOM()) < 20;

-- 4h. SCANNED documents -- no text, forcing the OCR path so the routing
--     tiers are actually exercised. file_path is a placeholder; the
--     routing skill decides whether OCR runs against real staged files
--     or whether these are excluded from the sandbox run.
INSERT INTO SYNTH_DOCUMENTS
    (document_id, patient_id, document_date, document_type, source_system,
     file_format, page_count, file_path, document_text)
SELECT
    'SYN-DOC-4' || LPAD(SEQ4(), 7, '0'),
    p.patient_id,
    DATEADD(DAY, -UNIFORM(10, 340, RANDOM()), CURRENT_DATE()),
    'SCANNED_OUTSIDE_RECORDS',
    'FAX_INTAKE',
    'pdf',
    UNIFORM(2, 18, RANDOM()),
    'scanned/' || p.patient_id || '/' || UUID_STRING() || '.pdf',
    NULL
FROM SYNTH_PATIENTS p
WHERE UNIFORM(0, 100, RANDOM()) < 20;

-- 4i. Thin documents. Real corpora are full of these; they are not
--     extraction failures and should not be reported as such.
INSERT INTO SYNTH_DOCUMENTS
    (document_id, patient_id, document_date, document_type, source_system,
     file_format, page_count, file_path, document_text)
SELECT
    'SYN-DOC-5' || LPAD(SEQ4(), 7, '0'),
    p.patient_id,
    DATEADD(DAY, -UNIFORM(10, 340, RANDOM()), CURRENT_DATE()),
    'ADDENDUM',
    'EHR_NOTES',
    'text', 1, NULL,
    'Addendum: prior note reviewed and signed.'
FROM SYNTH_PATIENTS p
WHERE UNIFORM(0, 100, RANDOM()) < 12;

-- ---------------------------------------------------------------------
-- 5. ANSWER KEY -- ground truth. Lands in {{EVAL_SCHEMA}}.
--
--    QUARANTINE RULES:
--      * No pipeline query may reference this table.
--      * It must never appear in a prompt, in retrieved context, or in
--        the knowledge store.
--      * Only evaluate-icd10-accuracy reads it.
--
--    expected_classification is as important as expected_hcc: without
--    it the harness cannot distinguish a correct EVAL from a missed
--    SUSPECT, and cannot measure over-calling on the distractors.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{DB}}.{{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY (
    patient_id              VARCHAR(20),
    expected_hcc            VARCHAR(10),
    expected_icd10          VARCHAR(10),
    expected_classification VARCHAR(10),  -- SUSPECT | EVAL | NONE
    -- expected_icd10 is populated ONLY where expected_classification is
    -- SUSPECT. EVAL and NONE cases assert no code, so specificity is not
    -- scoreable for them.
    expected_confidence_min INT,          -- lower bound for a correct call
    case_role               VARCHAR(20),  -- PLANTED | BORDERLINE | DISTRACTOR | SUPPRESSED
    evidence_summary        VARCHAR(1000),
    model_year              VARCHAR(10)
);

INSERT INTO {{DB}}.{{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY VALUES
('SYN-000001','HCC85','I50.22','SUSPECT',8,'PLANTED',
 'EF 35 percent with global hypokinesis; BNP trending 180 to 340 to 620; JVD, S3 gallop, bibasilar crackles, bilateral edema; furosemide initiated','{{MODEL_YEAR}}'),
('SYN-000002','HCC18','E11.22','SUSPECT',8,'PLANTED',
 'Diabetes 16 years; eGFR trending 62 to 49 to 38; macroalbuminuria 380 mg/g; objective peripheral neuropathy on monofilament and vibratory testing; empagliflozin for renal protection','{{MODEL_YEAR}}'),
('SYN-000003','HCC82','I70.213','SUSPECT',8,'PLANTED',
 'ABI 0.52 left and 0.68 right; 70-80 percent left SFA stenosis; claudication at one block; non-healing lateral malleolar ulcer at 7 weeks; cilostazol started','{{MODEL_YEAR}}'),
('SYN-000004','HCC96','I48.0','SUSPECT',8,'PLANTED',
 'Sixteen atrial fibrillation episodes on 14-day monitor, 11 percent burden, longest 6h42m; irregularly irregular rhythm on exam; anticoagulation initiated','{{MODEL_YEAR}}'),
-- NOTE: J44.9, not J44.1. J44.1 is COPD WITH ACUTE EXACERBATION and requires a
-- CURRENT exacerbation at the encounter; this note documents a HISTORY of two
-- prednisone courses, which is not the same thing. This distinction was caught
-- by the judge stage disagreeing with an earlier version of this answer key --
-- see the note on ground-truth review in SKILL.md.
('SYN-000005','HCC111','J44.9','SUSPECT',8,'PLANTED',
 'Post-bronchodilator FEV1 48 percent predicted with ratio 0.44, irreversible; 48 pack-years; mMRC 3; history of two exacerbations requiring prednisone in 12 months but NO current acute exacerbation documented','{{MODEL_YEAR}}'),
-- expected_icd10 is NULL for EVAL cases. An EVAL classification means the
-- evidence does NOT support asserting a diagnosis, so there is no code to get
-- right. Carrying a code here contradicts the classification and wrongly
-- inflates the specificity denominator.
('SYN-000006','HCC85',NULL,'EVAL',4,'BORDERLINE',
 'Mild exertional dyspnea, trace edema, BNP 168 mildly elevated, no echocardiogram on file. Warrants evaluation; evidence insufficient to assert a diagnosis','{{MODEL_YEAR}}'),
('SYN-000007','HCC18',NULL,'EVAL',4,'BORDERLINE',
 'Diabetes with subjective tingling but intact monofilament and vibratory testing; eGFR 68 stable; mild albuminuria 42 mg/g. Monitor rather than assert','{{MODEL_YEAR}}'),
('SYN-000008',NULL,NULL,'NONE',NULL,'DISTRACTOR',
 'Edema is venous in origin: normal BNP 44, recent EF 60 percent, duplex confirms superficial reflux. Cardiac etiology explicitly excluded. Flagging CHF here is over-calling','{{MODEL_YEAR}}'),
('SYN-000009',NULL,NULL,'NONE',NULL,'DISTRACTOR',
 'Spirometry normal, FEV1 88 percent predicted with ratio 0.76; prior dyspnea attributed to corrected anemia. Flagging COPD here is over-calling','{{MODEL_YEAR}}'),
('SYN-000010',NULL,NULL,'NONE',NULL,'DISTRACTOR',
 'Metoprolol and furosemide present but prescribed for hypertension and venous edema; no cardiac symptoms or imaging support. Medication-only inference is a known coding error','{{MODEL_YEAR}}'),
('SYN-000011','HCC111',NULL,'NONE',NULL,'SUPPRESSED',
 'COPD evidence present AND already coded in claims history. Correct behaviour is to emit nothing, because output must be gaps rather than restatement','{{MODEL_YEAR}}');

-- ---------------------------------------------------------------------
-- 6. Verification. Run these and show the results before marking the
--    phase done. Each catches a specific seed bug that would otherwise
--    surface later as a false pipeline failure.
-- ---------------------------------------------------------------------

-- 6.1 No labeled patient may already have their planted condition coded
--     (except the deliberate suppression control).
SELECT ak.patient_id, ak.expected_hcc, ak.case_role
FROM {{DB}}.{{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY ak
JOIN SYNTH_CLAIMS_HISTORY ch
  ON ch.patient_id = ak.patient_id AND ch.hcc_mapped = ak.expected_hcc
WHERE ak.case_role <> 'SUPPRESSED';
-- Expect zero rows.

-- 6.2 Every labeled patient must have documents to reason over.
SELECT ak.patient_id, COUNT(d.document_id) AS docs
FROM {{DB}}.{{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY ak
LEFT JOIN SYNTH_DOCUMENTS d ON d.patient_id = ak.patient_id
GROUP BY 1 HAVING COUNT(d.document_id) = 0;
-- Expect zero rows.

-- 6.3 Every expected condition must exist in the reference table.
SELECT DISTINCT ak.expected_hcc
FROM {{DB}}.{{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY ak
LEFT JOIN SYNTH_CONDITION_REFERENCE cr ON cr.hcc_code = ak.expected_hcc
WHERE ak.expected_hcc IS NOT NULL AND cr.hcc_code IS NULL;
-- Expect zero rows.

-- 6.4 Corpus shape: is there noise to skip and are there scans to OCR?
SELECT document_type,
       COUNT(*) AS docs,
       COUNT_IF(document_text IS NULL) AS scanned,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct_of_corpus
FROM SYNTH_DOCUMENTS
GROUP BY 1 ORDER BY docs DESC;

-- 6.5 Cross-patient identical text must exist, so the unscoped-dedup
--     trap is actually testable.
SELECT MD5(LEFT(document_text, 500)) AS text_hash,
       COUNT(DISTINCT patient_id)    AS distinct_patients,
       COUNT(*)                      AS docs
FROM SYNTH_DOCUMENTS
WHERE document_text IS NOT NULL
GROUP BY 1 HAVING COUNT(DISTINCT patient_id) > 1
ORDER BY distinct_patients DESC LIMIT 5;
-- Expect at least one row.

-- 6.6 Answer key composition -- confirm the harness has all four case
--     roles, or precision and over-calling cannot both be measured.
SELECT case_role, expected_classification, COUNT(*) AS patients
FROM {{DB}}.{{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY
GROUP BY 1, 2 ORDER BY 1, 2;
