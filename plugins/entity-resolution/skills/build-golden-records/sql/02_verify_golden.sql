-- =====================================================================
-- Phase 5 verification. Read-only. Substitute {{RUN_ID}}, {{PRIOR_RUN_ID}}.
-- =====================================================================

-- 1. Convergence of connected components.
SELECT check_value AS passes, detail:converged::BOOLEAN AS converged
FROM ER_PIPELINE_QUALITY_LOG
WHERE run_id = '{{RUN_ID}}' AND phase = 'golden' AND check_name = 'cc_passes'
ORDER BY logged_at DESC
LIMIT 1;

-- 2. Crosswalk completeness (rule 27). in_scope = crosswalk_records and
--    duplicated = 0, or the single view silently omits records.
SELECT
    (SELECT COUNT(*) FROM ER_RECORDS)                                              AS in_scope,
    (SELECT COUNT(*) FROM ER_CROSSWALK WHERE run_id = '{{RUN_ID}}')                AS crosswalk_records,
    (SELECT COUNT(*) FROM (SELECT record_uid FROM ER_CROSSWALK WHERE run_id = '{{RUN_ID}}'
                           GROUP BY 1 HAVING COUNT(*) > 1))                        AS duplicated,
    (SELECT COUNT(*) FROM ER_GOLDEN_RECORDS WHERE run_id = '{{RUN_ID}}')           AS golden_records;

-- 3. Cluster size distribution per entity type.
SELECT entity_type, cluster_size, COUNT(*) AS clusters, SUM(cluster_size) AS records
FROM ER_CLUSTERS
WHERE run_id = '{{RUN_ID}}'
GROUP BY 1, 2
ORDER BY 1, 2;

-- 4. Held clusters and why (rule 24). Cannot-link holds must be resolved
--    before publishing; they are chaining defects or real conflicts.
SELECT entity_type, f.value::STRING AS hold_reason, COUNT(*) AS clusters
FROM ER_CLUSTERS c, LATERAL FLATTEN(input => c.hold_reasons) f
WHERE c.run_id = '{{RUN_ID}}'
GROUP BY 1, 2
ORDER BY 3 DESC;

-- 5. The five largest clusters with member names. Read them. This catches
--    chaining and placeholder keys faster than any metric.
WITH top AS (
    SELECT cluster_key, entity_type, cluster_size, cluster_status, hold_reasons, weakest_edge_pair
    FROM ER_CLUSTERS
    WHERE run_id = '{{RUN_ID}}'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY entity_type ORDER BY cluster_size DESC) <= 5
)
SELECT t.entity_type, t.cluster_size, t.cluster_status, t.hold_reasons, x.golden_id,
       ARRAY_AGG(r.name_raw) WITHIN GROUP (ORDER BY r.name_raw) AS member_names,
       ARRAY_AGG(DISTINCT r.city_norm) AS cities,
       ARRAY_AGG(DISTINCT r.tax_id_norm) AS tax_ids
FROM top t
JOIN ER_CC_LABELS l ON l.label = t.cluster_key
JOIN ER_RECORDS r   ON r.record_uid = l.record_uid
JOIN ER_CROSSWALK x ON x.record_uid = l.record_uid AND x.run_id = '{{RUN_ID}}'
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1, 2 DESC;

-- 6. Weakest edge in each held cluster: the cut candidate. Show its
--    decision source and, for model edges, the reasons.
SELECT c.entity_type, c.cluster_size, c.hold_reasons, e.decision_source, e.edge_confidence,
       ra.name_raw AS name_a, rb.name_raw AS name_b, e.detail
FROM ER_CLUSTERS c
JOIN ER_ACCEPTED_EDGES e ON e.pair_id = c.weakest_edge_pair AND e.run_id = c.run_id
JOIN ER_RECORDS ra ON ra.record_uid = e.record_uid_a
JOIN ER_RECORDS rb ON rb.record_uid = e.record_uid_b
WHERE c.run_id = '{{RUN_ID}}' AND c.cluster_status = 'HELD'
ORDER BY c.cluster_size DESC
LIMIT 20;

-- 7. Edge sources: how much of the merging came from rules, scores, and the
--    model.
SELECT entity_type, decision_source, COUNT(*) AS edges, ROUND(AVG(edge_confidence), 3) AS avg_conf
FROM ER_ACCEPTED_EDGES
WHERE run_id = '{{RUN_ID}}'
GROUP BY 1, 2
ORDER BY 1, 2;

-- 8. Golden id stability against the prior run (rule 26).
SELECT id_lineage, COUNT(DISTINCT golden_id) AS golden_ids
FROM ER_CROSSWALK
WHERE run_id = '{{RUN_ID}}'
GROUP BY 1;

-- Prior golden ids that no longer appear (merged away or fully split).
SELECT COUNT(DISTINCT p.golden_id) AS prior_ids_not_carried
FROM ER_CROSSWALK p
WHERE p.run_id = '{{PRIOR_RUN_ID}}'
  AND p.golden_id NOT IN (SELECT golden_id FROM ER_CROSSWALK WHERE run_id = '{{RUN_ID}}');

-- 9. Survivorship provenance coverage: every non-null golden attribute must
--    cite a member record (rule 25). Expect zero.
SELECT COUNT(*) AS attributes_without_valid_provenance
FROM ER_GOLDEN_RECORDS g, LATERAL FLATTEN(input => g.attribute_provenance) f
WHERE g.run_id = '{{RUN_ID}}'
  AND NOT EXISTS (
      SELECT 1 FROM ER_CROSSWALK x
      WHERE x.run_id = g.run_id AND x.golden_id = g.golden_id
        AND x.record_uid = f.value:record_uid::STRING);

-- 10. Which rule decided each attribute. Many TIE_BREAK_RECORD_UID decisions
--     mean the configured rules do not discriminate on this data.
SELECT f.key AS attribute, f.value:rule::STRING AS deciding_rule, COUNT(*) AS golden_records
FROM ER_GOLDEN_RECORDS g, LATERAL FLATTEN(input => g.attribute_provenance) f
WHERE g.run_id = '{{RUN_ID}}' AND g.member_count > 1
GROUP BY 1, 2
ORDER BY 1, 3 DESC;

-- 11. Duplicate-reduction headline: source records versus golden records.
SELECT entity_type,
       SUM(member_count)                         AS source_records,
       COUNT(*)                                  AS golden_records,
       SUM(member_count) - COUNT(*)              AS records_merged_away,
       COUNT_IF(member_count > 1)                AS multi_record_golden,
       COUNT_IF(cluster_status = 'HELD')         AS held
FROM ER_GOLDEN_RECORDS
WHERE run_id = '{{RUN_ID}}'
GROUP BY 1;

-- 12. Relationships that were not merged.
SELECT entity_type, relationship, COUNT(*) AS links
FROM ER_ENTITY_RELATIONSHIPS
WHERE run_id = '{{RUN_ID}}'
GROUP BY 1, 2;
