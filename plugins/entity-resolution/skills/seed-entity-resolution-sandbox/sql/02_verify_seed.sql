-- =====================================================================
-- Verification for the entity resolution sandbox. Read-only.
-- Substitute {{SCHEMA}} and {{EVAL_SCHEMA}}. Run each block and show the
-- result at the gate. Every block names the defect it catches.
-- =====================================================================

-- 1. Corpus shape: records per system and entity type. Every configured
--    system must have rows, or a column mapping step is untested.
SELECT entity_type, source_system, COUNT(*) AS records
FROM {{EVAL_SCHEMA}}.SYNTH_COPY_VALUES
GROUP BY 1, 2
UNION ALL
SELECT 'PRODUCT', source_system, COUNT(*)
FROM {{EVAL_SCHEMA}}.SYNTH_PRODUCT_COPIES
GROUP BY 1, 2
ORDER BY 1, 2;

-- 2. Cluster size distribution of the truth, within entity type. Expect a
--    majority of singletons and a tail of 2-5. If there are no clusters of
--    size >= 3, transitive clustering is untested.
SELECT entity_type, cluster_size, COUNT(*) AS true_entities
FROM (
    SELECT entity_type, true_entity_id, COUNT(*) AS cluster_size
    FROM {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE
    GROUP BY 1, 2
)
GROUP BY 1, 2
ORDER BY 1, 2;

-- 3. True duplicate pair count per entity type and difficulty. This is the
--    denominator of pairwise recall. Zero HARD pairs means the hard-positive
--    slice is untested.
WITH ak AS (
    SELECT *, DECODE(difficulty, 'EASY', 1, 'MEDIUM', 2, 'HARD', 3) AS diff_rank
    FROM {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE
)
SELECT a.entity_type,
       DECODE(GREATEST(a.diff_rank, b.diff_rank), 1, 'EASY', 2, 'MEDIUM', 3, 'HARD') AS pair_difficulty,
       COUNT(*) AS true_pairs
FROM ak a
JOIN ak b
  ON a.true_entity_id = b.true_entity_id
 AND a.record_uid < b.record_uid
GROUP BY 1, 2
ORDER BY 1, 2;
-- A pair is as hard as its harder member.

-- 4. Hard negatives exist. Siblings and franchises must share a name stem
--    with another true entity, or the over-merge slice is untested.
SELECT case_role, entity_type, COUNT(DISTINCT true_entity_id) AS entities
FROM {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY
GROUP BY 1, 2
ORDER BY 1, 2;

-- 5. Sibling stems collide by name and city with a different tax id.
--    Expect rows. Zero rows means the hard-negative construction failed.
SELECT s.core_name AS sibling_name, o.core_name AS other_name, s.city, s.tax_id, o.tax_id AS other_tax_id
FROM {{EVAL_SCHEMA}}.SYNTH_TRUE_ENTITIES s
JOIN {{EVAL_SCHEMA}}.SYNTH_TRUE_ENTITIES o
  ON o.w1 = s.w1 AND o.w2 = s.w2 AND o.city = s.city
 AND o.true_entity_id <> s.true_entity_id
WHERE s.entity_role = 'SIBLING'
LIMIT 10;

-- 6. Leakage guard: no source record id contains any part of a true entity
--    id. Expect zero.
SELECT COUNT(*) AS leaking_ids
FROM {{EVAL_SCHEMA}}.SYNTH_COPY_VALUES
WHERE CONTAINS(source_record_id, 'TE-')
   OR CONTAINS(source_record_id, SUBSTR(true_entity_id, 6));

-- 7. Every answer-key record_uid resolves to exactly one source row, using
--    the same uid construction the standardize phase will use. Expect zero
--    unmatched and zero duplicated.
WITH src AS (
    SELECT 'CRM:' || account_id AS record_uid FROM {{SCHEMA}}.SYNTH_CRM_ACCOUNTS
    UNION ALL SELECT 'BILLING:' || cust_no FROM {{SCHEMA}}.SYNTH_BILLING_CUSTOMERS
    UNION ALL SELECT 'ECOM:' || org_uuid FROM {{SCHEMA}}.SYNTH_ECOM_ACCOUNTS
    UNION ALL SELECT 'ERP_' || company_code || ':' || vendor_id FROM {{SCHEMA}}.SYNTH_ERP_VENDORS
    UNION ALL SELECT 'P2P:' || supplier_id FROM {{SCHEMA}}.SYNTH_P2P_SUPPLIERS
    UNION ALL SELECT 'PIM:' || product_code FROM {{SCHEMA}}.SYNTH_PIM_PRODUCTS
    UNION ALL SELECT 'ERP_ITEM:' || item_number FROM {{SCHEMA}}.SYNTH_ERP_ITEMS
    UNION ALL SELECT 'SUPPLIER_CAT:' || sku FROM {{SCHEMA}}.SYNTH_SUPPLIER_CATALOG
)
SELECT
    (SELECT COUNT(*) FROM {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY ak
      WHERE NOT EXISTS (SELECT 1 FROM src WHERE src.record_uid = ak.record_uid)) AS key_without_source,
    (SELECT COUNT(*) FROM src
      WHERE NOT EXISTS (SELECT 1 FROM {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY ak WHERE ak.record_uid = src.record_uid)) AS source_without_key,
    (SELECT COUNT(*) FROM (SELECT record_uid FROM src GROUP BY 1 HAVING COUNT(*) > 1)) AS duplicated_uids;

-- 8. Placeholder and free-mail traps are present, so blocking-key hygiene is
--    tested. Expect a non-trivial share of free-mail addresses.
SELECT COUNT_IF(email_value ILIKE '%@freemail.example') AS freemail_contacts,
       COUNT(*) AS total
FROM {{EVAL_SCHEMA}}.SYNTH_COPY_VALUES;

-- 9. Size-variant products share brand, line and type but differ in GTIN
--    and MPN. Expect 3 variants per base.
SELECT base_seq, COUNT(*) AS variants, COUNT(DISTINCT gtin) AS distinct_gtins
FROM {{EVAL_SCHEMA}}.SYNTH_TRUE_PRODUCTS
GROUP BY 1
HAVING COUNT(*) <> 3 OR COUNT(DISTINCT gtin) <> 3;
-- Expect zero rows.

-- 10. Blocked vendors exist in the ERP table, so the source-status filter is
--     testable. Expect a small non-zero count.
SELECT COUNT_IF(blocked_flag = 'X') AS blocked_vendor_records
FROM {{SCHEMA}}.SYNTH_ERP_VENDORS;
