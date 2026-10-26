-- =====================================================================
-- Phase 4: adjudicate the REVIEW band with AI_COMPLETE structured output.
-- Substitute {{SCHEMA}}, {{RUN_ID}}, {{EXPERIMENT_ID}}, {{PROMPT_VERSION}},
-- {{ADJ_MODEL}}, {{MAX_PAIRS}}, {{SWAP_SAMPLE}}, {{MODEL_ACCEPT_CONF}}.
--
-- AI cost: one AI_COMPLETE call per row in ER_ADJ_PROMPTS for this run —
-- the capped review band plus the position-swap probe sample. Section 2
-- reports the exact call count and an input-token floor before anything runs.
-- =====================================================================

USE SCHEMA {{SCHEMA}};

-- Tag every query in this phase so evaluate-match-accuracy can reconcile
-- billed tokens per run from ACCOUNT_USAGE (rule 32).
ALTER SESSION SET QUERY_TAG = 'er:{{RUN_ID}}:adjudicate';

-- ---------------------------------------------------------------------
-- 1. Prompts. Built once, stored, hashed, and the SAME stored text is bound
--    into the call (rule 35). Record order is chosen by hash of the pair so
--    record_uid_a is not always first (rule 22). Record ids are never shown.
--    Raw tax ids are never shown: only the SQL comparison result (rule 36).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ER_ADJ_PROMPTS (
    run_id          VARCHAR,
    experiment_id   VARCHAR,
    prompt_version  VARCHAR,
    pair_id         VARCHAR,
    entity_type     VARCHAR,
    presented_order VARCHAR,       -- AB | BA
    is_swap_probe   BOOLEAN,
    prompt_text     VARCHAR,
    prompt_hash     VARCHAR,
    built_at        TIMESTAMP_NTZ
);

DELETE FROM ER_ADJ_PROMPTS WHERE run_id = '{{RUN_ID}}';

INSERT INTO ER_ADJ_PROMPTS
WITH review AS (
    SELECT sp.*
    FROM ER_SCORED_PAIRS sp
    WHERE sp.run_id = '{{RUN_ID}}' AND sp.band = 'REVIEW'
    -- Hard cap. Highest composite first is NOT used: a cap that keeps only the
    -- easy end of the band biases every downstream metric. Deterministic hash
    -- order gives a uniform sample when the cap binds.
    QUALIFY ROW_NUMBER() OVER (ORDER BY HASH(sp.pair_id)) <= {{MAX_PAIRS}}
),
described AS (
    SELECT
        r.*,
        -- Display text per record. Labeled, NULL-safe, no identifiers.
        CASE WHEN r.entity_type = 'PRODUCT' THEN
            ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
                'description: ' || a.name_raw,
                'brand: '       || a.brand_norm,
                'size: '        || TO_VARCHAR(a.size_oz) || ' oz'), '\n')
        ELSE
            ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
                'name: '    || a.name_raw,
                'address: ' || a.address_norm,
                'city: '    || a.city_norm,
                'region: '  || a.region_norm,
                'postal: '  || a.postal_norm,
                'country: ' || a.country_norm,
                'source system: ' || a.source_system), '\n')
        END AS desc_a,
        CASE WHEN r.entity_type = 'PRODUCT' THEN
            ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
                'description: ' || b.name_raw,
                'brand: '       || b.brand_norm,
                'size: '        || TO_VARCHAR(b.size_oz) || ' oz'), '\n')
        ELSE
            ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
                'name: '    || b.name_raw,
                'address: ' || b.address_norm,
                'city: '    || b.city_norm,
                'region: '  || b.region_norm,
                'postal: '  || b.postal_norm,
                'country: ' || b.country_norm,
                'source system: ' || b.source_system), '\n')
        END AS desc_b,
        -- System comparisons: authoritative, identifier-free.
        CASE WHEN r.entity_type = 'PRODUCT' THEN
            'GTIN: '  || DECODE(r.gtin_rel, 'SAME','identical', 'DIFFERENT','different', 'not available on both') || '\n' ||
            'manufacturer part number: ' || DECODE(r.mpn_rel, 'SAME','identical', 'DIFFERENT','different', 'not available on both') || '\n' ||
            'size: '  || DECODE(r.size_rel, 'SAME','same within tolerance', 'DIFFERENT','different', 'not available on both')
        ELSE
            'tax id: ' || DECODE(r.tax_rel, 'SAME','identical', 'DIFFERENT','different', 'not available on both') || '\n' ||
            'phone: '  || IFF(r.phone_eq IS NULL, 'not available on both', IFF(r.phone_eq, 'identical', 'different')) || '\n' ||
            'web or email domain: ' || IFF(r.domain_eq IS NULL, 'not available on both', IFF(r.domain_eq, 'shared', 'different'))
        END AS comparisons,
        IFF(MOD(ABS(HASH(r.pair_id, 'order')), 2) = 0, 'AB', 'BA') AS primary_order
    FROM review r
    JOIN ER_RECORDS a ON a.record_uid = r.record_uid_a
    JOIN ER_RECORDS b ON b.record_uid = r.record_uid_b
),
orders AS (
    SELECT d.*, d.primary_order AS presented_order, FALSE AS is_swap_probe FROM described d
    UNION ALL
    -- Position-bias probe: the same pair in the opposite order.
    SELECT d.*, IFF(d.primary_order = 'AB', 'BA', 'AB'), TRUE
    FROM described d
    QUALIFY ROW_NUMBER() OVER (ORDER BY HASH(d.pair_id, 'probe')) <= {{SWAP_SAMPLE}}
),
assembled AS (
    SELECT o.*,
        'You are a master data steward. Decide whether the two records below describe the same real-world '
        || DECODE(o.entity_type, 'CUSTOMER','customer organization', 'VENDOR','supplier organization', 'PRODUCT','product (exact sellable item)')
        || '.\n\nRules:\n'
        || '- MATCH only if they are the same legal entity (or, for products, the identical item).\n'
        || '- A parent, subsidiary, sister company, franchisee, or separately registered branch is NOT the same entity. '
        || 'Use decision NO_MATCH and set relationship to PARENT_SUBSIDIARY or SIBLING_LOCATION.\n'
        || '- For products, a different size, pack, or color is a PRODUCT_VARIANT, not the same item: decision NO_MATCH.\n'
        || '- An attribute missing from one record is not evidence that the records differ.\n'
        || '- The system comparisons are computed exactly and are authoritative. A different tax id or a different GTIN means different entities.\n'
        || '- Abbreviations, legal-suffix spellings, typos, casing, and address formatting differences are normal for duplicates.\n'
        || '- If the evidence does not support a confident decision, use UNSURE.\n'
        || '- Every reason must name one attribute that appears in the records or the system comparisons.\n\n'
        || 'Record 1:\n' || IFF(o.presented_order = 'AB', o.desc_a, o.desc_b) || '\n\n'
        || 'Record 2:\n' || IFF(o.presented_order = 'AB', o.desc_b, o.desc_a) || '\n\n'
        || 'System comparisons:\n' || o.comparisons || '\n\n'
        || 'Respond in JSON.' AS prompt_text
    FROM orders o
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{PROMPT_VERSION}}',
       pair_id, entity_type, presented_order, is_swap_probe,
       prompt_text, SHA2(prompt_text, 256), CURRENT_TIMESTAMP()
FROM assembled;

-- ---------------------------------------------------------------------
-- 2. Estimate (gate step 2). Call count and input-token floor. Output tokens
--    bill on top, and response_format schema overhead may not be counted by
--    AI_COUNT_TOKENS (rule 32) — say both when presenting this.
-- ---------------------------------------------------------------------
SELECT entity_type,
       COUNT(*)                                                     AS calls,
       COUNT_IF(is_swap_probe)                                      AS probe_calls,
       SUM(AI_COUNT_TOKENS('ai_complete', '{{ADJ_MODEL}}', prompt_text)) AS est_input_tokens_floor
FROM ER_ADJ_PROMPTS
WHERE run_id = '{{RUN_ID}}'
GROUP BY 1;

-- ---------------------------------------------------------------------
-- 3. The calls. Idempotent on (run_id, pair_id, presented_order): a retry
--    does not re-bill rows that already have a response (rule 38).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ER_MATCH_DECISIONS_RAW (
    run_id          VARCHAR,
    experiment_id   VARCHAR,
    prompt_version  VARCHAR,
    prompt_hash     VARCHAR,
    model           VARCHAR,
    pair_id         VARCHAR,
    presented_order VARCHAR,
    is_swap_probe   BOOLEAN,
    response        VARIANT,
    called_at       TIMESTAMP_NTZ
);

-- 3a. Reuse prior responses for byte-identical prompts on the same model.
--     The prompt contains every input the model sees, so an identical
--     prompt_hash means an identical question. This is the main incremental
--     cost lever: unchanged pairs are never re-billed across runs. Skip this
--     statement when the point of the run is to re-ask (e.g. a model or
--     temperature experiment with the same prompt).
INSERT INTO ER_MATCH_DECISIONS_RAW
SELECT p.run_id, p.experiment_id, p.prompt_version, p.prompt_hash, prior.model,
       p.pair_id, p.presented_order, p.is_swap_probe,
       prior.response, prior.called_at
FROM ER_ADJ_PROMPTS p
JOIN (
    SELECT * FROM ER_MATCH_DECISIONS_RAW
    WHERE model = '{{ADJ_MODEL}}' AND response:value IS NOT NULL AND run_id <> '{{RUN_ID}}'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY prompt_hash ORDER BY called_at DESC) = 1
) prior ON prior.prompt_hash = p.prompt_hash
WHERE p.run_id = '{{RUN_ID}}'
  AND NOT EXISTS (
      SELECT 1 FROM ER_MATCH_DECISIONS_RAW d
      WHERE d.run_id = p.run_id AND d.pair_id = p.pair_id AND d.presented_order = p.presented_order);

INSERT INTO ER_MATCH_DECISIONS_RAW
SELECT
    p.run_id, p.experiment_id, p.prompt_version, p.prompt_hash, '{{ADJ_MODEL}}',
    p.pair_id, p.presented_order, p.is_swap_probe,
    AI_COMPLETE(
        model => '{{ADJ_MODEL}}',
        prompt => p.prompt_text,
        model_parameters => {'temperature': 0, 'max_tokens': 1024},
        response_format => {
            'type': 'json',
            'schema': {
                'type': 'object',
                'properties': {
                    'decision':     {'type': 'string', 'enum': ['MATCH', 'NO_MATCH', 'UNSURE']},
                    'relationship': {'type': 'string',
                                     'enum': ['SAME_ENTITY', 'PARENT_SUBSIDIARY', 'SIBLING_LOCATION',
                                              'PRODUCT_VARIANT', 'UNRELATED', 'UNSURE']},
                    'confidence':   {'type': 'number',
                                     'description': 'Probability from 0 to 1 that the decision is correct.'},
                    'reasons': {
                        'type': 'array',
                        'items': {
                            'type': 'object',
                            'properties': {
                                'attribute':   {'type': 'string',
                                                'enum': ['name', 'address', 'city', 'region', 'postal', 'country',
                                                         'source_system', 'tax_id', 'phone', 'domain',
                                                         'description', 'brand', 'size', 'gtin', 'mpn']},
                                'observation': {'type': 'string'},
                                'effect':      {'type': 'string',
                                                'enum': ['SUPPORTS_MATCH', 'OPPOSES_MATCH', 'NEUTRAL']}
                            },
                            'required': ['attribute', 'observation', 'effect']
                        }
                    },
                    'summary': {'type': 'string', 'description': 'One sentence a data steward can read.'}
                },
                'required': ['decision', 'relationship', 'confidence', 'reasons', 'summary']
            }
        },
        show_details => TRUE,
        return_error_details => TRUE
    )::VARIANT,   -- returns OBJECT(value VARIANT, error VARCHAR); stored as VARIANT
    CURRENT_TIMESTAMP()
FROM ER_ADJ_PROMPTS p
WHERE p.run_id = '{{RUN_ID}}'
  AND NOT EXISTS (
      SELECT 1 FROM ER_MATCH_DECISIONS_RAW d
      WHERE d.run_id = p.run_id AND d.pair_id = p.pair_id
        AND d.presented_order = p.presented_order
        AND d.response:value IS NOT NULL);

-- ---------------------------------------------------------------------
-- 4. Parse with one defensive accessor (rule 20), validate reasons (rule
--    21), and decide acceptance. NULL is a failure, never a NO_MATCH (19).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ER_MATCH_DECISIONS (
    run_id              VARCHAR,
    experiment_id       VARCHAR,
    prompt_version      VARCHAR,
    prompt_hash         VARCHAR,
    model               VARCHAR,
    pair_id             VARCHAR,
    presented_order     VARCHAR,
    is_swap_probe       BOOLEAN,
    decision            VARCHAR,
    relationship        VARCHAR,
    confidence          FLOAT,
    reasons             ARRAY,
    summary             VARCHAR,
    reason_count        INT,
    invalid_reason_count INT,
    error_message       VARCHAR,
    prompt_tokens       INT,
    completion_tokens   INT,
    outcome             VARCHAR,     -- MODEL_MATCH | MODEL_NO_MATCH | STEWARD_REVIEW | MODEL_FAILED
    parsed_at           TIMESTAMP_NTZ
);

DELETE FROM ER_MATCH_DECISIONS WHERE run_id = '{{RUN_ID}}';

INSERT INTO ER_MATCH_DECISIONS
WITH latest AS (
    SELECT *
    FROM ER_MATCH_DECISIONS_RAW
    WHERE run_id = '{{RUN_ID}}'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY pair_id, presented_order ORDER BY called_at DESC) = 1
),
parsed AS (
    SELECT l.*,
        COALESCE(
            l.response:value:structured_output[0]:raw_message,
            l.response:value:structured_output,
            l.response:structured_output[0]:raw_message,
            l.response:structured_output)                       AS obj,
        l.response:error::STRING                                AS error_message,
        COALESCE(l.response:value:usage:prompt_tokens, l.response:usage:prompt_tokens)::INT         AS prompt_tokens,
        COALESCE(l.response:value:usage:completion_tokens, l.response:usage:completion_tokens)::INT AS completion_tokens
    FROM latest l
),
reason_check AS (
    -- A reason naming an attribute that is not part of this entity type's
    -- prompt is a fabricated reason.
    SELECT p.pair_id, p.presented_order,
           COUNT_IF(f.value IS NOT NULL AND (
               (s.entity_type =  'PRODUCT' AND f.value:attribute::STRING NOT IN ('description','brand','size','gtin','mpn'))
            OR (s.entity_type <> 'PRODUCT' AND f.value:attribute::STRING IN ('description','brand','size','gtin','mpn'))
           )) AS invalid_reason_count
    FROM parsed p
    JOIN ER_SCORED_PAIRS s ON s.pair_id = p.pair_id AND s.run_id = p.run_id,
    LATERAL FLATTEN(input => p.obj:reasons, OUTER => TRUE) f
    GROUP BY 1, 2
),
checked AS (
    SELECT p.*,
        p.obj:decision::STRING                                  AS decision,
        p.obj:relationship::STRING                              AS relationship,
        TRY_TO_DOUBLE(p.obj:confidence::STRING)                 AS confidence,
        p.obj:reasons::ARRAY                                    AS reasons,
        p.obj:summary::STRING                                   AS summary,
        COALESCE(ARRAY_SIZE(p.obj:reasons), 0)                  AS reason_count,
        COALESCE(rc.invalid_reason_count, 0)                    AS invalid_reason_count
    FROM parsed p
    LEFT JOIN reason_check rc
      ON rc.pair_id = p.pair_id AND rc.presented_order = p.presented_order
)
SELECT
    run_id, experiment_id, prompt_version, prompt_hash, model,
    pair_id, presented_order, is_swap_probe,
    decision, relationship, confidence, reasons, summary, reason_count, invalid_reason_count,
    error_message, prompt_tokens, completion_tokens,
    CASE
        WHEN obj IS NULL OR decision IS NULL                         THEN 'MODEL_FAILED'
        WHEN reason_count = 0 OR invalid_reason_count > 0            THEN 'STEWARD_REVIEW'
        WHEN decision = 'MATCH' AND relationship = 'SAME_ENTITY'
             AND confidence >= {{MODEL_ACCEPT_CONF}}                 THEN 'MODEL_MATCH'
        WHEN decision = 'NO_MATCH' AND confidence >= {{MODEL_ACCEPT_CONF}} THEN 'MODEL_NO_MATCH'
        ELSE 'STEWARD_REVIEW'   -- UNSURE, low confidence, or MATCH with a non-identity relationship
    END,
    CURRENT_TIMESTAMP()
FROM checked;

-- Quality log (rule 19).
INSERT INTO ER_PIPELINE_QUALITY_LOG (run_id, phase, check_name, check_value, detail)
SELECT '{{RUN_ID}}', 'adjudicate', 'model_failed', COUNT_IF(outcome = 'MODEL_FAILED'),
       OBJECT_CONSTRUCT('calls', COUNT(*),
                        'no_reasons', COUNT_IF(reason_count = 0),
                        'invalid_reasons', COUNT_IF(invalid_reason_count > 0),
                        'sample_errors', ARRAY_AGG(DISTINCT LEFT(error_message, 200)))
FROM ER_MATCH_DECISIONS
WHERE run_id = '{{RUN_ID}}';

-- ---------------------------------------------------------------------
-- 5. Gate verification.
-- ---------------------------------------------------------------------

-- 5a. Accessor sanity: rows with no error but no parsed decision mean the
--     accessor is wrong for this account, not that the model failed.
SELECT COUNT(*) AS accessor_mismatch
FROM ER_MATCH_DECISIONS
WHERE run_id = '{{RUN_ID}}' AND error_message IS NULL AND decision IS NULL;

-- 5b. Outcome distribution (primary order only).
SELECT outcome, decision, relationship, COUNT(*) AS pairs,
       ROUND(AVG(confidence), 3) AS avg_confidence
FROM ER_MATCH_DECISIONS
WHERE run_id = '{{RUN_ID}}' AND NOT is_swap_probe
GROUP BY 1, 2, 3
ORDER BY 4 DESC;

-- 5c. Position bias (rule 22): primary versus swapped decision on probe pairs.
SELECT COUNT(*)                                            AS probe_pairs,
       COUNT_IF(p.decision <> s.decision)                  AS decision_flips,
       ROUND(COUNT_IF(p.decision <> s.decision) / NULLIF(COUNT(*), 0), 3) AS flip_rate,
       COUNT_IF(p.outcome <> s.outcome)                    AS outcome_flips
FROM ER_MATCH_DECISIONS p
JOIN ER_MATCH_DECISIONS s
  ON s.pair_id = p.pair_id AND s.run_id = p.run_id AND s.is_swap_probe
WHERE p.run_id = '{{RUN_ID}}' AND NOT p.is_swap_probe;

-- 5d. Real usage from show_details (rule 32). Reconcile with account usage
--     after the run; ACCOUNT_USAGE views have ingestion latency.
SELECT COUNT(*) AS calls, SUM(prompt_tokens) AS prompt_tokens, SUM(completion_tokens) AS completion_tokens
FROM ER_MATCH_DECISIONS
WHERE run_id = '{{RUN_ID}}';

-- 5e. Read ten decisions with their reasons. Reading them is part of the gate.
SELECT d.pair_id, d.decision, d.relationship, d.confidence, d.summary, d.reasons
FROM ER_MATCH_DECISIONS d
WHERE d.run_id = '{{RUN_ID}}' AND NOT d.is_swap_probe
ORDER BY HASH(d.pair_id)
LIMIT 10;

ALTER SESSION UNSET QUERY_TAG;
