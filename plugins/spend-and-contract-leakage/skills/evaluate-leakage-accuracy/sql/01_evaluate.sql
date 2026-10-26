-- =====================================================================
-- Phase 5. Evaluate the pipeline against the answer key.
--
-- This is the ONLY file in the plugin that reads {{EVAL_SCHEMA}}.
-- No AI functions. Results land in {{EVAL_SCHEMA}} alongside the keys and
-- accumulate by experiment, so runs compare side by side.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}} {{SCHEMA}} {{EVAL_SCHEMA}} {{RUN_ID}} {{EXPERIMENT_ID}}
--   {{EXPERIMENT_NAME}} {{PROMPT_VERSION}} {{QUERY_TAG_PREFIX}}
--
-- Matching rules:
--   documents  by document_id
--   terms      by (contract_family_id, term_name), 11 scored terms
--   rates      by (contract_family_id, sku, tier_min_qty, effective_from)
--   findings   line grain     by (finding_type, invoice_line_id)
--              contract grain by (finding_type, contract_family_id)
--   A finding on the right line with the wrong type is a TYPE_CONFUSION:
--   it counts as one false positive AND one false negative, and is
--   reported separately because its fix is different.
-- =====================================================================

USE DATABASE {{DB}};
USE SCHEMA {{EVAL_SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Documents: class, family, duplicate.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS EVAL_DOC_RESULTS (
    run_id VARCHAR, experiment_id VARCHAR, document_id VARCHAR,
    expected_doc_class VARCHAR, actual_doc_class VARCHAR, class_correct BOOLEAN,
    expected_family VARCHAR, actual_family VARCHAR, family_correct BOOLEAN,
    expected_duplicate_of VARCHAR, actual_duplicate_of VARCHAR, duplicate_correct BOOLEAN,
    evaluated_at TIMESTAMP_NTZ
);
DELETE FROM EVAL_DOC_RESULTS WHERE run_id = '{{RUN_ID}}';
INSERT INTO EVAL_DOC_RESULTS
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', k.document_id,
       k.expected_doc_class, r.doc_class, k.expected_doc_class = r.doc_class,
       k.contract_family_id, r.contract_family_id,
       k.contract_family_id IS NOT DISTINCT FROM IFF(r.family_role IN ('GOVERNING','AMENDMENT','DUPLICATE'), r.contract_family_id, NULL),
       k.is_duplicate_of, r.is_duplicate_of, k.is_duplicate_of IS NOT DISTINCT FROM r.is_duplicate_of,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM SYNTH_DOCUMENT_KEY k
LEFT JOIN {{DB}}.{{SCHEMA}}.CONTRACT_REGISTRY r ON r.document_id = k.document_id;

-- ---------------------------------------------------------------------
-- 2. Header terms. Correct = usable status and exact normalized value.
--    NOT_STATED in the key must be answered NOT_STATED; a value invented
--    for an absent term is wrong, and so is NOT_STATED for a present one.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS EVAL_TERM_RESULTS (
    run_id VARCHAR, experiment_id VARCHAR, contract_family_id VARCHAR, term_name VARCHAR,
    expected_value VARCHAR, actual_value VARCHAR, actual_status VARCHAR,
    outcome VARCHAR,          -- CORRECT | WRONG_VALUE | MISSED (said NOT_STATED) | INVENTED (value for NOT_STATED) | FAILED | UNVERIFIED | ABSENT
    evaluated_at TIMESTAMP_NTZ
);
DELETE FROM EVAL_TERM_RESULTS WHERE run_id = '{{RUN_ID}}';
INSERT INTO EVAL_TERM_RESULTS
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', k.contract_family_id, k.term_name,
       k.expected_value, t.normalized_value, t.status,
       CASE
         WHEN t.status IS NULL                                   THEN 'ABSENT'
         WHEN t.status = 'FAILED'                                THEN 'FAILED'
         WHEN t.status = 'UNVERIFIED'                            THEN 'UNVERIFIED'
         WHEN t.normalized_value = k.expected_value              THEN 'CORRECT'
         WHEN k.expected_value = 'NOT_STATED'                    THEN 'INVENTED'
         WHEN t.status = 'NOT_STATED'                            THEN 'MISSED'
         ELSE 'WRONG_VALUE'
       END,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM SYNTH_TERM_KEY k
LEFT JOIN {{DB}}.{{SCHEMA}}.CONTRACT_HEADER_TERMS t
  ON t.contract_family_id = k.contract_family_id
 AND t.term_name = k.term_name
 AND t.experiment_id = '{{EXPERIMENT_ID}}';

-- ---------------------------------------------------------------------
-- 3. Effective rates. Scores price, unit, currency and window, and counts
--    pipeline rates the key does not have (spurious rates price lines that
--    should have been exceptions).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS EVAL_RATE_RESULTS (
    run_id VARCHAR, experiment_id VARCHAR, contract_family_id VARCHAR, sku VARCHAR,
    tier_min_qty NUMBER(18,4), expected_from DATE, actual_from DATE,
    expected_price NUMBER(18,4), actual_price NUMBER(18,4),
    expected_to DATE, actual_to DATE,
    outcome VARCHAR,          -- CORRECT | WRONG_PRICE | WRONG_WINDOW | WRONG_UNIT_OR_CCY | MISSING | SPURIOUS
    evaluated_at TIMESTAMP_NTZ
);
DELETE FROM EVAL_RATE_RESULTS WHERE run_id = '{{RUN_ID}}';
INSERT INTO EVAL_RATE_RESULTS
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}',
       COALESCE(k.contract_family_id, e.contract_family_id), COALESCE(k.sku, e.sku),
       COALESCE(k.tier_min_qty, e.tier_min_qty), k.effective_from, e.effective_from,
       k.unit_price, e.unit_price, k.effective_to, e.effective_to,
       CASE
         WHEN e.contract_family_id IS NULL THEN 'MISSING'
         WHEN k.contract_family_id IS NULL THEN 'SPURIOUS'
         WHEN ROUND(e.unit_price, 4) <> ROUND(k.unit_price, 4) THEN 'WRONG_PRICE'
         WHEN e.effective_to <> k.effective_to THEN 'WRONG_WINDOW'
         WHEN e.currency IS DISTINCT FROM k.currency OR e.unit_of_measure IS DISTINCT FROM k.unit_of_measure THEN 'WRONG_UNIT_OR_CCY'
         ELSE 'CORRECT'
       END,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM SYNTH_RATE_KEY k
FULL OUTER JOIN (SELECT * FROM {{DB}}.{{SCHEMA}}.CONTRACT_EFFECTIVE_RATES WHERE experiment_id = '{{EXPERIMENT_ID}}') e
  ON e.contract_family_id = k.contract_family_id
 AND e.sku = k.sku
 AND e.tier_min_qty IS NOT DISTINCT FROM k.tier_min_qty
 AND e.effective_from = k.effective_from;

-- ---------------------------------------------------------------------
-- 4. Findings: TP / FP / FN / TYPE_CONFUSION, with dollar error per TP.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS EVAL_FINDING_MATCHES (
    run_id VARCHAR, experiment_id VARCHAR,
    match_key VARCHAR, finding_type VARCHAR, key_finding_type VARCHAR, case_role VARCHAR,
    vendor_id VARCHAR, contract_family_id VARCHAR, invoice_line_id VARCHAR,
    impact_kind VARCHAR, impact_currency VARCHAR,
    expected_amount NUMBER(18,2), actual_amount NUMBER(18,2), amount_abs_error NUMBER(18,2),
    outcome VARCHAR,          -- TP | FP | FN | TYPE_CONFUSION_FP | TYPE_CONFUSION_FN | DISTRACTOR_HIT
    evaluated_at TIMESTAMP_NTZ
);
DELETE FROM EVAL_FINDING_MATCHES WHERE run_id = '{{RUN_ID}}';
INSERT INTO EVAL_FINDING_MATCHES
WITH f AS (
    SELECT finding_type, vendor_id, contract_family_id, invoice_line_id, impact_kind, impact_currency, impact_amount,
           COALESCE(invoice_line_id, 'FAMILY:' || contract_family_id) AS grain_key
    FROM {{DB}}.{{SCHEMA}}.LEAKAGE_FINDINGS WHERE run_id = '{{RUN_ID}}'
),
k AS (
    SELECT finding_type, case_role, vendor_id, contract_family_id, invoice_line_id, impact_kind, impact_currency,
           expected_impact_amount,
           COALESCE(invoice_line_id, 'FAMILY:' || contract_family_id) AS grain_key
    FROM SYNTH_LEAKAGE_KEY
),
planted AS (SELECT * FROM k WHERE case_role = 'PLANTED'),
distractor AS (SELECT * FROM k WHERE case_role = 'DISTRACTOR'),
-- Exact matches: same grain, same type.
tp AS (
    SELECT f.*, p.expected_impact_amount
    FROM f JOIN planted p ON p.grain_key = f.grain_key AND p.finding_type = f.finding_type
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', grain_key, finding_type, key_finding_type, case_role,
       vendor_id, contract_family_id, invoice_line_id, impact_kind, impact_currency,
       expected_amount, actual_amount, ABS(COALESCE(actual_amount, 0) - COALESCE(expected_amount, 0)),
       outcome, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM (
    SELECT grain_key, finding_type, finding_type AS key_finding_type, 'PLANTED' AS case_role, vendor_id,
           contract_family_id, invoice_line_id, impact_kind, impact_currency,
           expected_impact_amount AS expected_amount, impact_amount AS actual_amount, 'TP' AS outcome
    FROM tp
    UNION ALL
    -- Pipeline findings with no exact planted match.
    SELECT f.grain_key, f.finding_type, COALESCE(p.finding_type, d.finding_type),
           COALESCE(p.case_role, d.case_role, 'NONE'), f.vendor_id, f.contract_family_id, f.invoice_line_id,
           f.impact_kind, f.impact_currency, 0, f.impact_amount,
           CASE WHEN p.grain_key IS NOT NULL THEN 'TYPE_CONFUSION_FP'
                WHEN d.grain_key IS NOT NULL THEN 'DISTRACTOR_HIT'
                ELSE 'FP' END
    FROM f
    LEFT JOIN tp ON tp.grain_key = f.grain_key AND tp.finding_type = f.finding_type
    LEFT JOIN planted p ON p.grain_key = f.grain_key
    LEFT JOIN distractor d ON d.grain_key = f.grain_key AND p.grain_key IS NULL
    WHERE tp.grain_key IS NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY f.grain_key, f.finding_type ORDER BY d.finding_type) = 1
    UNION ALL
    -- Planted findings the pipeline did not raise with the right type.
    SELECT p.grain_key, p.finding_type, p.finding_type, 'PLANTED', p.vendor_id, p.contract_family_id,
           p.invoice_line_id, p.impact_kind, p.impact_currency, p.expected_impact_amount, NULL,
           IFF(fk.grain_key IS NOT NULL, 'TYPE_CONFUSION_FN', 'FN')
    FROM planted p
    LEFT JOIN tp ON tp.grain_key = p.grain_key AND tp.finding_type = p.finding_type
    LEFT JOIN (SELECT DISTINCT grain_key FROM f) fk ON fk.grain_key = p.grain_key
    WHERE tp.grain_key IS NULL
) x;

-- ---------------------------------------------------------------------
-- 5. Dollar reconciliation per impact kind and currency. The pipeline's
--    total includes false positives, because that is the number a reader
--    would see. Never summed across kinds or currencies.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS EVAL_DOLLAR_RECONCILIATION (
    run_id VARCHAR, experiment_id VARCHAR, impact_kind VARCHAR, impact_currency VARCHAR,
    expected_total NUMBER(18,2), pipeline_total NUMBER(18,2), tp_total NUMBER(18,2),
    fp_total NUMBER(18,2), fn_total NUMBER(18,2), tp_abs_error NUMBER(18,2),
    total_error NUMBER(18,2), total_error_pct NUMBER(9,2),
    evaluated_at TIMESTAMP_NTZ
);
DELETE FROM EVAL_DOLLAR_RECONCILIATION WHERE run_id = '{{RUN_ID}}';
INSERT INTO EVAL_DOLLAR_RECONCILIATION
WITH m AS (SELECT * FROM EVAL_FINDING_MATCHES WHERE run_id = '{{RUN_ID}}'),
agg AS (
    SELECT impact_kind, impact_currency,
           SUM(IFF(outcome IN ('TP','FP','DISTRACTOR_HIT','TYPE_CONFUSION_FP'), actual_amount, 0)) AS pipeline_total,
           SUM(IFF(outcome = 'TP', actual_amount, 0))                                              AS tp_total,
           SUM(IFF(outcome IN ('FP','DISTRACTOR_HIT','TYPE_CONFUSION_FP'), actual_amount, 0))      AS fp_total,
           SUM(IFF(outcome IN ('FN','TYPE_CONFUSION_FN'), expected_amount, 0))                     AS fn_total,
           SUM(IFF(outcome = 'TP', amount_abs_error, 0))                                           AS tp_abs_error
    FROM m GROUP BY 1, 2
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}',
       COALESCE(e.impact_kind, a.impact_kind), COALESCE(e.impact_currency, a.impact_currency),
       COALESCE(e.expected_total, 0), COALESCE(a.pipeline_total, 0), COALESCE(a.tp_total, 0),
       COALESCE(a.fp_total, 0), COALESCE(a.fn_total, 0), COALESCE(a.tp_abs_error, 0),
       COALESCE(a.pipeline_total, 0) - COALESCE(e.expected_total, 0),
       ROUND(100 * (COALESCE(a.pipeline_total, 0) - COALESCE(e.expected_total, 0)) / NULLIF(e.expected_total, 0), 2),
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM SYNTH_EXPECTED_TOTALS e
FULL OUTER JOIN agg a ON a.impact_kind = e.impact_kind AND a.impact_currency = e.impact_currency;

-- ---------------------------------------------------------------------
-- 6. Cost, from the usage view, by query tag. Do NOT use
--    CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY: it has no timestamp column and
--    is no longer updated. CORTEX_AI_FUNCTIONS_USAGE_HISTORY can lag by up
--    to 24 hours; rerun this block later if it returns nothing.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS EVAL_COST (
    run_id VARCHAR, experiment_id VARCHAR, phase VARCHAR, function_name VARCHAR, model_name VARCHAR,
    queries INT, credits NUMBER(18,6), input_tokens NUMBER, output_tokens NUMBER, total_tokens NUMBER, pages NUMBER,
    measured_at TIMESTAMP_NTZ
);
DELETE FROM EVAL_COST WHERE run_id = '{{RUN_ID}}';
INSERT INTO EVAL_COST
WITH u AS (
    SELECT SPLIT_PART(query_tag, ':', 2) AS phase, function_name, model_name, query_id, credits, metrics
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
    WHERE query_tag LIKE '{{QUERY_TAG_PREFIX}}:%:{{RUN_ID}}'
),
m AS (
    SELECT u.phase, u.function_name, u.model_name, u.query_id, u.credits,
           SUM(IFF(x.value:key:metric::VARCHAR = 'input'  AND x.value:key:unit::VARCHAR = 'tokens', x.value:value::NUMBER, 0)) AS input_tokens,
           SUM(IFF(x.value:key:metric::VARCHAR = 'output' AND x.value:key:unit::VARCHAR = 'tokens', x.value:value::NUMBER, 0)) AS output_tokens,
           SUM(IFF(x.value:key:metric::VARCHAR = 'total'  AND x.value:key:unit::VARCHAR = 'tokens', x.value:value::NUMBER, 0)) AS total_tokens,
           SUM(IFF(x.value:key:unit::VARCHAR = 'pages', x.value:value::NUMBER, 0)) AS pages
    FROM u, LATERAL FLATTEN(input => u.metrics, OUTER => TRUE) x
    GROUP BY 1, 2, 3, 4, 5
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', phase, function_name, model_name,
       COUNT(DISTINCT query_id), SUM(credits), SUM(input_tokens), SUM(output_tokens), SUM(total_tokens), SUM(pages),
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM m GROUP BY phase, function_name, model_name;

-- ---------------------------------------------------------------------
-- 7. Summary, one row per (run, scope). Accumulates across experiments.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS EVAL_SUMMARY (
    run_id VARCHAR, experiment_id VARCHAR, experiment_name VARCHAR, prompt_version VARCHAR,
    scope VARCHAR,            -- ALL | finding type | DOCUMENTS | TERMS | RATES
    tp INT, fp INT, fn INT, type_confusions INT, distractor_hits INT,
    precision NUMBER(6,4), recall NUMBER(6,4), f1 NUMBER(6,4),
    items_scored INT, items_correct INT, accuracy NUMBER(6,4),
    evaluated_at TIMESTAMP_NTZ
);
DELETE FROM EVAL_SUMMARY WHERE run_id = '{{RUN_ID}}';
INSERT INTO EVAL_SUMMARY
WITH m AS (SELECT * FROM EVAL_FINDING_MATCHES WHERE run_id = '{{RUN_ID}}'),
by_type AS (
    SELECT COALESCE(finding_type, key_finding_type) AS scope,
           COUNT_IF(outcome = 'TP') AS tp,
           COUNT_IF(outcome IN ('FP','DISTRACTOR_HIT','TYPE_CONFUSION_FP')) AS fp,
           COUNT_IF(outcome IN ('FN','TYPE_CONFUSION_FN')) AS fn,
           COUNT_IF(outcome = 'TYPE_CONFUSION_FN') AS type_confusions,
           COUNT_IF(outcome = 'DISTRACTOR_HIT') AS distractor_hits
    FROM m GROUP BY 1
    UNION ALL
    SELECT 'ALL', COUNT_IF(outcome = 'TP'),
           COUNT_IF(outcome IN ('FP','DISTRACTOR_HIT','TYPE_CONFUSION_FP')),
           COUNT_IF(outcome IN ('FN','TYPE_CONFUSION_FN')),
           COUNT_IF(outcome = 'TYPE_CONFUSION_FN'), COUNT_IF(outcome = 'DISTRACTOR_HIT')
    FROM m
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{EXPERIMENT_NAME}}', '{{PROMPT_VERSION}}', scope,
       tp, fp, fn, type_confusions, distractor_hits,
       ROUND(tp / NULLIF(tp + fp, 0), 4), ROUND(tp / NULLIF(tp + fn, 0), 4),
       ROUND(2 * tp / NULLIF(2 * tp + fp + fn, 0), 4),
       NULL, NULL, NULL, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM by_type
UNION ALL
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{EXPERIMENT_NAME}}', '{{PROMPT_VERSION}}', 'DOCUMENTS',
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       COUNT(*), COUNT_IF(class_correct AND family_correct AND duplicate_correct),
       ROUND(COUNT_IF(class_correct AND family_correct AND duplicate_correct) / NULLIF(COUNT(*), 0), 4),
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM EVAL_DOC_RESULTS WHERE run_id = '{{RUN_ID}}'
UNION ALL
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{EXPERIMENT_NAME}}', '{{PROMPT_VERSION}}', 'TERMS',
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       COUNT(*), COUNT_IF(outcome = 'CORRECT'), ROUND(COUNT_IF(outcome = 'CORRECT') / NULLIF(COUNT(*), 0), 4),
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM EVAL_TERM_RESULTS WHERE run_id = '{{RUN_ID}}'
UNION ALL
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{EXPERIMENT_NAME}}', '{{PROMPT_VERSION}}', 'RATES',
       NULL, COUNT_IF(outcome = 'SPURIOUS'), COUNT_IF(outcome = 'MISSING'), NULL, NULL, NULL, NULL, NULL,
       COUNT_IF(outcome <> 'SPURIOUS'), COUNT_IF(outcome = 'CORRECT'),
       ROUND(COUNT_IF(outcome = 'CORRECT') / NULLIF(COUNT_IF(outcome <> 'SPURIOUS'), 0), 4),
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM EVAL_RATE_RESULTS WHERE run_id = '{{RUN_ID}}';

-- =====================================================================
-- Report queries. Show these to the user.
-- =====================================================================

-- R1. Headline: finding precision / recall overall and per type.
SELECT scope, tp, fp, fn, type_confusions, distractor_hits, precision, recall, f1
FROM EVAL_SUMMARY WHERE run_id = '{{RUN_ID}}' AND tp IS NOT NULL ORDER BY scope = 'ALL' DESC, scope;

-- R2. Extraction accuracy: documents, terms, rates.
SELECT scope, items_scored, items_correct, accuracy, fp AS spurious, fn AS missing
FROM EVAL_SUMMARY WHERE run_id = '{{RUN_ID}}' AND scope IN ('DOCUMENTS','TERMS','RATES');

-- R3. Term accuracy per term, with the failure mode.
SELECT term_name, COUNT_IF(outcome = 'CORRECT') AS correct, COUNT(*) AS scored,
       ARRAY_AGG(DISTINCT IFF(outcome <> 'CORRECT', outcome || ':' || contract_family_id, NULL)) AS errors
FROM EVAL_TERM_RESULTS WHERE run_id = '{{RUN_ID}}' GROUP BY 1 ORDER BY correct / scored, 1;

-- R4. Dollar reconciliation. Every row stands alone.
SELECT impact_kind, impact_currency, expected_total, pipeline_total, total_error, total_error_pct,
       tp_total, fp_total, fn_total, tp_abs_error
FROM EVAL_DOLLAR_RECONCILIATION WHERE run_id = '{{RUN_ID}}' ORDER BY 1, 2;

-- R5. Every error, for diagnosis. Map each to a best-practices rule.
SELECT outcome, finding_type, key_finding_type, grain_key AS match_key, vendor_id, expected_amount, actual_amount
FROM EVAL_FINDING_MATCHES
WHERE run_id = '{{RUN_ID}}' AND outcome <> 'TP'
ORDER BY outcome, vendor_id, match_key;

-- R6. Parse and extraction failure accounting.
SELECT 'documents_parse_failed' AS metric, COUNT_IF(parse_status <> 'OK') AS n FROM {{DB}}.{{SCHEMA}}.CONTRACT_REGISTRY
UNION ALL SELECT 'pages_low_text', COUNT_IF(parse_error = 'LOW_TEXT_PAGE') FROM {{DB}}.{{SCHEMA}}.CONTRACT_PAGES
UNION ALL SELECT 'header_terms_failed', COUNT_IF(status = 'FAILED') FROM {{DB}}.{{SCHEMA}}.CONTRACT_HEADER_TERMS WHERE experiment_id = '{{EXPERIMENT_ID}}'
UNION ALL SELECT 'header_terms_unverified', COUNT_IF(status = 'UNVERIFIED') FROM {{DB}}.{{SCHEMA}}.CONTRACT_HEADER_TERMS WHERE experiment_id = '{{EXPERIMENT_ID}}'
UNION ALL SELECT 'rate_lines_unverified', COUNT_IF(status = 'UNVERIFIED') FROM {{DB}}.{{SCHEMA}}.CONTRACT_RATE_LINES WHERE experiment_id = '{{EXPERIMENT_ID}}'
UNION ALL SELECT 'rate_lines_failed_or_non_numeric', COUNT_IF(status IN ('FAILED','NON_NUMERIC')) FROM {{DB}}.{{SCHEMA}}.CONTRACT_RATE_LINES WHERE experiment_id = '{{EXPERIMENT_ID}}'
UNION ALL SELECT 'clause_rules_failed', COUNT_IF(response_status <> 'OK') FROM {{DB}}.{{SCHEMA}}.CONTRACT_CLAUSE_RULES WHERE experiment_id = '{{EXPERIMENT_ID}}'
UNION ALL SELECT 'reconcile_exceptions', COUNT(*) FROM {{DB}}.{{SCHEMA}}.RECONCILE_EXCEPTIONS WHERE run_id = '{{RUN_ID}}';

-- R7. Cost per 1K documents and per 1K invoice lines, by phase and function.
--     Report credits as measured; do not convert to currency.
WITH c AS (SELECT * FROM EVAL_COST WHERE run_id = '{{RUN_ID}}'),
n AS (SELECT (SELECT COUNT(*) FROM {{DB}}.{{SCHEMA}}.CONTRACT_REGISTRY) AS docs,
             (SELECT COUNT(*) FROM {{DB}}.{{SCHEMA}}.INVOICE_CONTRACT_MATCH) AS lines)
SELECT c.phase, c.function_name, c.model_name, c.queries, c.credits, c.pages,
       c.input_tokens, c.output_tokens, c.total_tokens,
       ROUND(1000 * c.credits / NULLIF(n.docs, 0), 4)  AS credits_per_1k_docs,
       ROUND(1000 * c.pages / NULLIF(n.docs, 0), 1)    AS pages_per_1k_docs,
       ROUND(1000 * (c.input_tokens + c.output_tokens + c.total_tokens) / NULLIF(n.docs, 0), 0) AS tokens_per_1k_docs
FROM c CROSS JOIN n ORDER BY c.credits DESC;

-- R8. Experiment comparison (COMPARE intent).
SELECT experiment_id, experiment_name, prompt_version, scope, precision, recall, f1, accuracy, evaluated_at
FROM EVAL_SUMMARY
WHERE scope IN ('ALL', 'TERMS', 'RATES', 'DOCUMENTS')
QUALIFY ROW_NUMBER() OVER (PARTITION BY experiment_id, scope ORDER BY evaluated_at DESC) = 1
ORDER BY scope, evaluated_at;
