-- =====================================================================
-- Phase 2 verification. Read-only. Show every result at the gate.
-- =====================================================================

-- 1. Row conservation: staging rows per source equal canonical rows per
--    source, and canonical record_uids are unique.
SELECT s.source_system, s.staged, r.canonical,
       r.canonical - r.distinct_uids AS duplicate_uids
FROM (SELECT source_system, COUNT(*) AS staged FROM ER_SOURCE_STAGING GROUP BY 1) s
JOIN (SELECT source_system, COUNT(*) AS canonical, COUNT(DISTINCT record_uid) AS distinct_uids
      FROM ER_RECORDS GROUP BY 1) r USING (source_system)
ORDER BY 1;

-- 2. Normalization failures. Investigate any non-zero count; an empty
--    name_norm or embed_text record is invisible to every later phase.
SELECT entity_type,
       COUNT(*)                                     AS records,
       COUNT_IF(name_norm IS NULL OR name_norm = '') AS empty_name_norm,
       COUNT_IF(name_core IS NULL)                  AS empty_name_core,
       COUNT_IF(embed_text IS NULL OR embed_text = '') AS empty_embed_text,
       COUNT_IF(entity_type <> 'PRODUCT' AND postal_norm IS NULL) AS missing_postal,
       COUNT_IF(entity_type <> 'PRODUCT' AND city_norm IS NULL)   AS missing_city,
       COUNT_IF(entity_type = 'PRODUCT' AND size_oz IS NULL)      AS product_missing_size
FROM ER_RECORDS
GROUP BY 1
ORDER BY 1;

-- 3. Attribute fill rates by source. A blocking rule is only as good as the
--    fill rate of its inputs; a rule on a 5 percent-filled field contributes
--    little and should not be relied on.
SELECT source_system,
       ROUND(100 * COUNT(postal_norm)    / COUNT(*), 1) AS pct_postal,
       ROUND(100 * COUNT(phone_norm)     / COUNT(*), 1) AS pct_phone,
       ROUND(100 * COUNT(tax_id_norm)    / COUNT(*), 1) AS pct_tax_id,
       ROUND(100 * COUNT(email_domain)   / COUNT(*), 1) AS pct_email_domain,
       ROUND(100 * COUNT(website_domain) / COUNT(*), 1) AS pct_website,
       ROUND(100 * COUNT(gtin_norm)      / COUNT(*), 1) AS pct_gtin,
       ROUND(100 * COUNT(mpn_norm)       / COUNT(*), 1) AS pct_mpn
FROM ER_RECORDS
GROUP BY 1
ORDER BY 1;

-- 4. Top values of every exact-match key. Placeholder values (a switchboard
--    phone on every record, a dummy tax id) show up here as a value shared by
--    many records. Each one must be added to the placeholder exclusions.
SELECT block_rule, block_key, block_size
FROM ER_BLOCK_STATS
WHERE block_rule IN ('TAX_ID','PHONE','EMAIL_DOMAIN','WEBSITE_DOMAIN','PRODUCT_MPN','PRODUCT_GTIN')
QUALIFY ROW_NUMBER() OVER (PARTITION BY block_rule ORDER BY block_size DESC) <= 5
ORDER BY block_rule, block_size DESC;

-- 5. Capped blocks: what was NOT compared. Never silent.
SELECT entity_type, block_rule, block_key, block_size, potential_pairs
FROM ER_BLOCK_STATS
WHERE is_capped
ORDER BY block_size DESC;

-- 6. Pair defects. All three must be zero.
SELECT
    COUNT_IF(record_uid_a = record_uid_b)                AS self_pairs,
    COUNT_IF(record_uid_a > record_uid_b)                AS non_canonical_order,
    (SELECT COUNT(*) FROM (
        SELECT record_uid_a, record_uid_b FROM ER_CANDIDATE_PAIRS
        GROUP BY 1, 2 HAVING COUNT(*) > 1))              AS duplicate_pairs
FROM ER_CANDIDATE_PAIRS;

-- 7. Cross-type pairs. Must be zero unless scope.cross_type_party is true,
--    and even then cross-type linking runs as a separate pass.
SELECT COUNT(*) AS cross_type_pairs
FROM ER_CANDIDATE_PAIRS p
JOIN ER_RECORDS a ON a.record_uid = p.record_uid_a
JOIN ER_RECORDS b ON b.record_uid = p.record_uid_b
WHERE a.entity_type <> b.entity_type;

-- 8. Reduction ratio per entity type: 1 - candidates / all possible pairs.
--    Report with pair completeness (evaluate-match-accuracy), never alone.
SELECT r.entity_type,
       r.n                                    AS records,
       r.n * (r.n - 1) / 2                    AS all_pairs,
       COALESCE(c.candidates, 0)              AS candidate_pairs,
       ROUND(1 - COALESCE(c.candidates, 0) / NULLIF(r.n * (r.n - 1) / 2, 0), 5) AS reduction_ratio,
       ROUND(COALESCE(c.candidates, 0) / NULLIF(r.n, 0), 2) AS candidates_per_record
FROM (SELECT entity_type, COUNT(*) AS n FROM ER_RECORDS GROUP BY 1) r
LEFT JOIN (SELECT entity_type, COUNT(*) AS candidates FROM ER_CANDIDATE_PAIRS GROUP BY 1) c
  USING (entity_type)
ORDER BY 1;

-- 9. Rule contribution: how many pairs each rule produced, and how many
--    pairs were produced by that rule ALONE. A rule with near-zero unique
--    contribution can be dropped; a rule that is the sole source of many pairs
--    is load-bearing, and its fill rate matters.
SELECT f.value::STRING AS block_rule,
       COUNT(*)                                AS pairs_with_rule,
       COUNT_IF(ARRAY_SIZE(p.block_rules) = 1) AS pairs_only_from_rule
FROM ER_CANDIDATE_PAIRS p, LATERAL FLATTEN(input => p.block_rules) f
GROUP BY 1
ORDER BY 2 DESC;

-- 10. Records with no candidate pair at all. Expected for true singletons; a
--     large share of records with no keys at all means the blocking inputs are
--     too sparse in this data.
SELECT r.entity_type,
       COUNT(*) AS records_without_pairs,
       COUNT_IF(k.record_uid IS NULL) AS records_without_any_block_key
FROM ER_RECORDS r
LEFT JOIN (SELECT DISTINCT record_uid FROM ER_BLOCK_KEYS) k ON k.record_uid = r.record_uid
WHERE NOT EXISTS (SELECT 1 FROM ER_CANDIDATE_PAIRS p
                  WHERE p.record_uid_a = r.record_uid OR p.record_uid_b = r.record_uid)
GROUP BY 1;
