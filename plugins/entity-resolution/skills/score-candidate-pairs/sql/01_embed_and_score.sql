-- =====================================================================
-- Phase 3: embeddings, semantic blocking pass, pair features, banding.
-- Substitute {{SCHEMA}}, {{EMBED_MODEL}}, {{EMBED_DIM}}, {{TEMPLATE_VERSION}},
-- {{KNN_K}}, {{RUN_ID}}, {{EXPERIMENT_ID}}, {{EXPERIMENT_NAME}},
-- {{AUTO_MATCH}}, {{AUTO_REJECT}}.
--
-- AI cost in this file: AI_EMBED once per new or changed record (section 2),
-- and AI_SIMILARITY on a 20-pair parity sample (section 4). Nothing else.
-- =====================================================================

USE SCHEMA {{SCHEMA}};

-- Tag every query in this phase so evaluate-match-accuracy can reconcile
-- billed tokens per run from ACCOUNT_USAGE (rule 32).
ALTER SESSION SET QUERY_TAG = 'er:{{RUN_ID}}:score';

-- 0. Embedding store. Created empty on first run; costs nothing.
CREATE TABLE IF NOT EXISTS ER_RECORD_EMBEDDINGS (
    record_uid             VARCHAR,
    entity_type            VARCHAR,
    embed_model            VARCHAR,
    embed_template_version VARCHAR,
    embed_text_hash        VARCHAR,
    embedding              VECTOR(FLOAT, {{EMBED_DIM}}),
    embedded_at            TIMESTAMP_NTZ
);

-- ---------------------------------------------------------------------
-- 1. Estimate before embedding (gate step 2). Input tokens only.
-- ---------------------------------------------------------------------
SELECT
    COUNT(*)                                                         AS records_to_embed,
    SUM(AI_COUNT_TOKENS('ai_embed', '{{EMBED_MODEL}}', r.embed_text)) AS est_input_tokens,
    MAX(AI_COUNT_TOKENS('ai_embed', '{{EMBED_MODEL}}', r.embed_text)) AS max_tokens_one_record
FROM ER_RECORDS r
WHERE NOT EXISTS (
    SELECT 1 FROM ER_RECORD_EMBEDDINGS e
    WHERE e.record_uid = r.record_uid
      AND e.embed_model = '{{EMBED_MODEL}}'
      AND e.embed_template_version = '{{TEMPLATE_VERSION}}'
      AND e.embed_text_hash = r.embed_text_hash
);
-- If max_tokens_one_record exceeds the model's documented input limit, the
-- template is too long for this model (rule 13) — fix the template.

-- ---------------------------------------------------------------------
-- 2. Embeddings: once per record per (model, template). Re-embed only rows
--    whose text hash changed (rule 12). The USING clause is restricted to
--    rows that need work, so AI_EMBED never runs on an up-to-date row.
-- ---------------------------------------------------------------------
MERGE INTO ER_RECORD_EMBEDDINGS t
USING (
    SELECT r.record_uid, r.entity_type, r.embed_text_hash,
           AI_EMBED('{{EMBED_MODEL}}', r.embed_text) AS embedding
    FROM ER_RECORDS r
    WHERE r.embed_text IS NOT NULL
      AND NOT EXISTS (
          SELECT 1 FROM ER_RECORD_EMBEDDINGS e
          WHERE e.record_uid = r.record_uid
            AND e.embed_model = '{{EMBED_MODEL}}'
            AND e.embed_template_version = '{{TEMPLATE_VERSION}}'
            AND e.embed_text_hash = r.embed_text_hash)
) s
ON  t.record_uid = s.record_uid
AND t.embed_model = '{{EMBED_MODEL}}'
AND t.embed_template_version = '{{TEMPLATE_VERSION}}'
WHEN MATCHED THEN UPDATE SET
    embed_text_hash = s.embed_text_hash,
    embedding       = s.embedding,
    embedded_at     = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (record_uid, entity_type, embed_model, embed_template_version, embed_text_hash, embedding, embedded_at)
VALUES
    (s.record_uid, s.entity_type, '{{EMBED_MODEL}}', '{{TEMPLATE_VERSION}}', s.embed_text_hash, s.embedding, CURRENT_TIMESTAMP());

-- ---------------------------------------------------------------------
-- 3. SEMANTIC_KNN blocking pass. Top-K cosine neighbours per record within
--    entity type and country (products: entity type only). This is a vector
--    function, not an AI call. It is quadratic within each partition: fine
--    for tens of thousands of records per partition; above that, partition
--    further (first letter of name_core, region) and say so at the gate.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ER_KNN_PAIRS AS
WITH v AS (
    SELECT e.record_uid, e.entity_type, e.embedding,
           IFF(e.entity_type = 'PRODUCT', 'ALL', COALESCE(r.country_norm, '?')) AS part_key
    FROM ER_RECORD_EMBEDDINGS e
    JOIN ER_RECORDS r ON r.record_uid = e.record_uid
    WHERE e.embed_model = '{{EMBED_MODEL}}'
      AND e.embed_template_version = '{{TEMPLATE_VERSION}}'
      AND e.embed_text_hash = r.embed_text_hash
),
nn AS (
    SELECT a.record_uid AS uid_1, b.record_uid AS uid_2, a.entity_type,
           VECTOR_COSINE_SIMILARITY(a.embedding, b.embedding) AS cos_sim
    FROM v a
    JOIN v b
      ON  a.entity_type = b.entity_type
      AND a.part_key    = b.part_key
      AND a.record_uid <> b.record_uid
    QUALIFY ROW_NUMBER() OVER (PARTITION BY a.record_uid ORDER BY cos_sim DESC) <= {{KNN_K}}
)
SELECT LEAST(uid_1, uid_2) AS record_uid_a, GREATEST(uid_1, uid_2) AS record_uid_b,
       entity_type, MAX(cos_sim) AS cos_sim
FROM nn
GROUP BY 1, 2, 3;

MERGE INTO ER_CANDIDATE_PAIRS t
USING ER_KNN_PAIRS s
ON t.record_uid_a = s.record_uid_a AND t.record_uid_b = s.record_uid_b
WHEN MATCHED AND NOT ARRAY_CONTAINS('SEMANTIC_KNN'::VARIANT, t.block_rules) THEN UPDATE SET
    block_rules = ARRAY_APPEND(t.block_rules, 'SEMANTIC_KNN')
WHEN NOT MATCHED THEN INSERT (pair_id, entity_type, record_uid_a, record_uid_b, block_rules, generated_at)
VALUES (SHA2(s.record_uid_a || '|' || s.record_uid_b, 256), s.entity_type, s.record_uid_a, s.record_uid_b,
        ARRAY_CONSTRUCT('SEMANTIC_KNN'), CURRENT_TIMESTAMP());

-- ---------------------------------------------------------------------
-- 4. Parity check (rule 11): stored-vector cosine versus AI_SIMILARITY on a
--    small sample, for the configured model. Expect differences near zero.
--    20 pairs = 40 embeddings billed under AI_EMBED.
-- ---------------------------------------------------------------------
WITH parity_sample AS (
    SELECT p.record_uid_a, p.record_uid_b
    FROM ER_CANDIDATE_PAIRS p
    SAMPLE (20 ROWS)
)
SELECT s.record_uid_a, s.record_uid_b,
       VECTOR_COSINE_SIMILARITY(ea.embedding, eb.embedding)                       AS stored_cosine,
       AI_SIMILARITY(ra.embed_text, rb.embed_text, {'model': '{{EMBED_MODEL}}'})  AS ai_similarity,
       ABS(stored_cosine - ai_similarity)                                         AS abs_diff
FROM parity_sample s
JOIN ER_RECORDS ra ON ra.record_uid = s.record_uid_a
JOIN ER_RECORDS rb ON rb.record_uid = s.record_uid_b
JOIN ER_RECORD_EMBEDDINGS ea ON ea.record_uid = s.record_uid_a
     AND ea.embed_model = '{{EMBED_MODEL}}' AND ea.embed_template_version = '{{TEMPLATE_VERSION}}'
JOIN ER_RECORD_EMBEDDINGS eb ON eb.record_uid = s.record_uid_b
     AND eb.embed_model = '{{EMBED_MODEL}}' AND eb.embed_template_version = '{{TEMPLATE_VERSION}}'
ORDER BY abs_diff DESC;
-- If abs_diff is materially above the documented 1e-4 vector margin, the
-- stored vectors were not produced from the same text or model as the probe.
-- Investigate before scoring; do not paper over it.

-- ---------------------------------------------------------------------
-- 5. Pair features, cannot-link rules, composite score, band.
--    Accumulates by run_id (rule 34): delete this run's rows, re-insert.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ER_SCORED_PAIRS (
    run_id                 VARCHAR,
    experiment_id          VARCHAR,
    experiment_name        VARCHAR,
    embed_model            VARCHAR,
    embed_template_version VARCHAR,
    pair_id                VARCHAR,
    entity_type            VARCHAR,
    record_uid_a           VARCHAR,
    record_uid_b           VARCHAR,
    block_rules            ARRAY,
    cos_sim                FLOAT,
    name_jw                FLOAT,
    core_jw                FLOAT,
    addr_jw                FLOAT,
    city_eq                BOOLEAN,
    postal_eq              BOOLEAN,
    phone_eq               BOOLEAN,
    domain_eq              BOOLEAN,
    tax_rel                VARCHAR,     -- SAME | DIFFERENT | MISSING
    gtin_rel               VARCHAR,
    mpn_rel                VARCHAR,
    size_rel               VARCHAR,
    brand_eq               BOOLEAN,
    token_substitution     BOOLEAN,     -- each side has a core token the other lacks
    composite_score        FLOAT,
    cannot_link            BOOLEAN,
    cannot_link_reason     VARCHAR,
    rule_match_reason      VARCHAR,
    band                   VARCHAR,     -- AUTO_MATCH | REVIEW | AUTO_REJECT
    band_source            VARCHAR,     -- RULE | SCORE | CANNOT_LINK
    thresholds             VARIANT,
    scored_at              TIMESTAMP_NTZ
);

DELETE FROM ER_SCORED_PAIRS WHERE run_id = '{{RUN_ID}}';

INSERT INTO ER_SCORED_PAIRS
WITH emb AS (
    SELECT e.record_uid, e.embedding
    FROM ER_RECORD_EMBEDDINGS e
    JOIN ER_RECORDS r ON r.record_uid = e.record_uid AND r.embed_text_hash = e.embed_text_hash
    WHERE e.embed_model = '{{EMBED_MODEL}}' AND e.embed_template_version = '{{TEMPLATE_VERSION}}'
),
f AS (
    SELECT
        p.pair_id, p.entity_type, p.record_uid_a, p.record_uid_b, p.block_rules,
        VECTOR_COSINE_SIMILARITY(ea.embedding, eb.embedding)                     AS cos_sim,
        -- JAROWINKLER_SIMILARITY is 0-100; scale to 0-1 (rule 17).
        JAROWINKLER_SIMILARITY(a.name_norm, b.name_norm) / 100.0                 AS name_jw,
        JAROWINKLER_SIMILARITY(a.name_core, b.name_core) / 100.0                 AS core_jw,
        IFF(a.address_key IS NULL OR b.address_key IS NULL, NULL,
            JAROWINKLER_SIMILARITY(a.address_key, b.address_key) / 100.0)        AS addr_jw,
        IFF(a.city_norm   IS NULL OR b.city_norm   IS NULL, NULL, a.city_norm   = b.city_norm)   AS city_eq,
        IFF(a.postal_norm IS NULL OR b.postal_norm IS NULL, NULL, a.postal_norm = b.postal_norm) AS postal_eq,
        IFF(a.phone_norm  IS NULL OR b.phone_norm  IS NULL, NULL, a.phone_norm  = b.phone_norm)  AS phone_eq,
        CASE
            WHEN COALESCE(a.email_domain, a.website_domain) IS NULL
              OR COALESCE(b.email_domain, b.website_domain) IS NULL THEN NULL
            ELSE ARRAYS_OVERLAP(ARRAY_CONSTRUCT_COMPACT(a.email_domain, a.website_domain),
                                ARRAY_CONSTRUCT_COMPACT(b.email_domain, b.website_domain))
        END                                                                      AS domain_eq,
        CASE WHEN a.tax_id_norm IS NULL OR b.tax_id_norm IS NULL THEN 'MISSING'
             WHEN a.tax_id_norm = b.tax_id_norm THEN 'SAME' ELSE 'DIFFERENT' END AS tax_rel,
        CASE WHEN a.gtin_norm IS NULL OR b.gtin_norm IS NULL THEN 'MISSING'
             WHEN a.gtin_norm = b.gtin_norm THEN 'SAME' ELSE 'DIFFERENT' END     AS gtin_rel,
        CASE WHEN a.mpn_norm IS NULL OR b.mpn_norm IS NULL THEN 'MISSING'
             WHEN a.mpn_norm = b.mpn_norm THEN 'SAME' ELSE 'DIFFERENT' END       AS mpn_rel,
        -- Sizes within 0.6 oz are the same pack (355 ml = 12.0 oz after rounding).
        CASE WHEN a.size_oz IS NULL OR b.size_oz IS NULL THEN 'MISSING'
             WHEN ABS(a.size_oz - b.size_oz) <= 0.6 THEN 'SAME' ELSE 'DIFFERENT' END AS size_rel,
        IFF(a.brand_norm IS NULL OR b.brand_norm IS NULL, NULL, a.brand_norm = b.brand_norm) AS brand_eq,
        ARRAY_SIZE(ARRAY_EXCEPT(SPLIT(a.name_core, ' '), SPLIT(b.name_core, ' '))) > 0
          AND ARRAY_SIZE(ARRAY_EXCEPT(SPLIT(b.name_core, ' '), SPLIT(a.name_core, ' '))) > 0 AS token_substitution
    FROM ER_CANDIDATE_PAIRS p
    JOIN ER_RECORDS a ON a.record_uid = p.record_uid_a
    JOIN ER_RECORDS b ON b.record_uid = p.record_uid_b
    LEFT JOIN emb ea ON ea.record_uid = p.record_uid_a
    LEFT JOIN emb eb ON eb.record_uid = p.record_uid_b
),
scored AS (
    SELECT f.*,
        -- Weighted mean over the features that are present. A missing feature
        -- neither helps nor hurts; it shrinks the denominator.
        CASE WHEN entity_type = 'PRODUCT' THEN
            ( 0.45 * COALESCE(cos_sim, 0) + 0.30 * name_jw
              + 0.15 * IFF(brand_eq IS NULL, 0, IFF(brand_eq, 1, 0))
              + 0.10 * IFF(mpn_rel = 'SAME', 1, 0) )
            / NULLIF( 0.45 * IFF(cos_sim IS NULL, 0, 1) + 0.30
                      + 0.15 * IFF(brand_eq IS NULL, 0, 1)
                      + 0.10 * IFF(mpn_rel = 'MISSING', 0, 1), 0)
        ELSE
            ( 0.35 * COALESCE(cos_sim, 0) + 0.25 * core_jw
              + 0.15 * COALESCE(addr_jw, 0)
              + 0.10 * IFF(postal_eq IS NULL AND city_eq IS NULL, 0,
                           IFF(COALESCE(postal_eq, city_eq), 1, 0))
              + 0.15 * IFF(phone_eq IS NULL AND domain_eq IS NULL, 0,
                           IFF(COALESCE(phone_eq, FALSE) OR COALESCE(domain_eq, FALSE), 1, 0)) )
            / NULLIF( 0.35 * IFF(cos_sim IS NULL, 0, 1) + 0.25
                      + 0.15 * IFF(addr_jw IS NULL, 0, 1)
                      + 0.10 * IFF(postal_eq IS NULL AND city_eq IS NULL, 0, 1)
                      + 0.15 * IFF(phone_eq IS NULL AND domain_eq IS NULL, 0, 1), 0)
        END AS composite_score,
        -- Cannot-link (rule 16): deterministic conflicts override similarity.
        CASE
            WHEN entity_type <> 'PRODUCT' AND tax_rel = 'DIFFERENT' THEN 'TAX_ID_DIFFERENT'
            WHEN entity_type =  'PRODUCT' AND gtin_rel = 'DIFFERENT' THEN 'GTIN_DIFFERENT'
            WHEN entity_type =  'PRODUCT' AND size_rel = 'DIFFERENT' THEN 'SIZE_DIFFERENT'
            WHEN entity_type =  'PRODUCT' AND mpn_rel  = 'DIFFERENT' THEN 'MPN_DIFFERENT'
        END AS cannot_link_reason,
        -- Deterministic positive rules.
        CASE
            WHEN entity_type <> 'PRODUCT' AND tax_rel = 'SAME' THEN 'TAX_ID_SAME'
            WHEN entity_type =  'PRODUCT' AND gtin_rel = 'SAME' AND size_rel <> 'DIFFERENT' THEN 'GTIN_SAME'
        END AS rule_match_reason
    FROM f
)
SELECT
    '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{EXPERIMENT_NAME}}', '{{EMBED_MODEL}}', '{{TEMPLATE_VERSION}}',
    pair_id, entity_type, record_uid_a, record_uid_b, block_rules,
    cos_sim, name_jw, core_jw, addr_jw, city_eq, postal_eq, phone_eq, domain_eq,
    tax_rel, gtin_rel, mpn_rel, size_rel, brand_eq, token_substitution,
    composite_score,
    cannot_link_reason IS NOT NULL                                    AS cannot_link,
    cannot_link_reason,
    rule_match_reason,
    CASE
        WHEN cannot_link_reason IS NOT NULL THEN 'AUTO_REJECT'
        WHEN rule_match_reason  IS NOT NULL THEN 'AUTO_MATCH'
        -- Substitution guard: a high score with a swapped core token (sibling
        -- risk, rule 15) is never auto-matched on score alone.
        WHEN composite_score >= {{AUTO_MATCH}} AND (NOT token_substitution OR core_jw >= 0.97) THEN 'AUTO_MATCH'
        WHEN composite_score <  {{AUTO_REJECT}} THEN 'AUTO_REJECT'
        ELSE 'REVIEW'
    END                                                               AS band,
    CASE
        WHEN cannot_link_reason IS NOT NULL THEN 'CANNOT_LINK'
        WHEN rule_match_reason  IS NOT NULL THEN 'RULE'
        ELSE 'SCORE'
    END                                                               AS band_source,
    OBJECT_CONSTRUCT('auto_match', {{AUTO_MATCH}}, 'auto_reject', {{AUTO_REJECT}}) AS thresholds,
    CURRENT_TIMESTAMP()
FROM scored;

-- ---------------------------------------------------------------------
-- 6. Gate verification.
-- ---------------------------------------------------------------------

-- 6a. Records without a current embedding. Must be zero.
SELECT COUNT(*) AS records_without_embedding
FROM ER_RECORDS r
WHERE NOT EXISTS (
    SELECT 1 FROM ER_RECORD_EMBEDDINGS e
    WHERE e.record_uid = r.record_uid AND e.embed_text_hash = r.embed_text_hash
      AND e.embed_model = '{{EMBED_MODEL}}' AND e.embed_template_version = '{{TEMPLATE_VERSION}}');

-- 6b. Band distribution by entity type and source.
SELECT entity_type, band, band_source, COUNT(*) AS pairs,
       ROUND(100 * RATIO_TO_REPORT(COUNT(*)) OVER (PARTITION BY entity_type), 1) AS pct
FROM ER_SCORED_PAIRS
WHERE run_id = '{{RUN_ID}}'
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3;

-- 6c. Contract checks. All must be zero.
SELECT
    COUNT_IF(band IS NULL)                                  AS null_bands,
    COUNT_IF(composite_score IS NULL)                       AS null_scores,
    COUNT_IF(band = 'AUTO_MATCH' AND cannot_link)           AS auto_match_with_cannot_link,
    COUNT_IF(cos_sim IS NULL)                               AS pairs_missing_cosine
FROM ER_SCORED_PAIRS
WHERE run_id = '{{RUN_ID}}';

-- 6d. Excluded fields never reached embedding text (rule 36). Expect zero.
--     Extend the pattern list from excluded_from_ai.
SELECT COUNT(*) AS embed_text_with_excluded_content
FROM ER_RECORDS
WHERE REGEXP_LIKE(LOWER(embed_text), '.*(bank|iban|routing|swift|account|tax[ _]?id|tax[ _]?number)\\s*:.*');

-- 6e. Score distribution per band, to eyeball separation before calibration.
SELECT entity_type, WIDTH_BUCKET(composite_score, 0, 1, 20) AS bucket,
       MIN(composite_score) AS lo, MAX(composite_score) AS hi, COUNT(*) AS pairs
FROM ER_SCORED_PAIRS
WHERE run_id = '{{RUN_ID}}'
GROUP BY 1, 2
ORDER BY 1, 2;

-- 6f. Review-band size: this is the adjudication call count.
SELECT entity_type, COUNT(*) AS review_pairs
FROM ER_SCORED_PAIRS
WHERE run_id = '{{RUN_ID}}' AND band = 'REVIEW'
GROUP BY 1;

ALTER SESSION UNSET QUERY_TAG;
