-- =====================================================================
-- Phase 5: accepted edges -> clusters -> guards -> stable golden ids ->
-- survivorship -> golden records, crosswalk, relationships.
-- No AI calls. Substitute {{SCHEMA}}, {{RUN_ID}}, {{EXPERIMENT_ID}},
-- {{PRIOR_RUN_ID}} (the last published run, or a value that matches no run
-- on the first build), {{MAX_CLUSTER_SIZE}}, {{MIN_COHESION}}.
-- =====================================================================

USE SCHEMA {{SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Accepted edges for this run. Three sources, one table.
--    Edge confidence: RULE = 1.0, SCORE = composite score, MODEL = model
--    confidence. A model match whose swapped-order probe disagreed is NOT
--    accepted (rule 22) — it goes to steward review instead.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ER_ACCEPTED_EDGES (
    run_id          VARCHAR,
    experiment_id   VARCHAR,
    pair_id         VARCHAR,
    entity_type     VARCHAR,
    record_uid_a    VARCHAR,
    record_uid_b    VARCHAR,
    decision_source VARCHAR,     -- RULE | SCORE | MODEL | STEWARD
    edge_confidence FLOAT,
    composite_score FLOAT,
    detail          VARIANT
);

DELETE FROM ER_ACCEPTED_EDGES WHERE run_id = '{{RUN_ID}}';

INSERT INTO ER_ACCEPTED_EDGES
WITH probe_flips AS (
    SELECT p.pair_id
    FROM ER_MATCH_DECISIONS p
    JOIN ER_MATCH_DECISIONS s
      ON s.pair_id = p.pair_id AND s.run_id = p.run_id AND s.is_swap_probe
    WHERE p.run_id = '{{RUN_ID}}' AND NOT p.is_swap_probe AND p.outcome <> s.outcome
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', sp.pair_id, sp.entity_type, sp.record_uid_a, sp.record_uid_b,
       sp.band_source,
       IFF(sp.band_source = 'RULE', 1.0, sp.composite_score),
       sp.composite_score,
       OBJECT_CONSTRUCT('rule', sp.rule_match_reason, 'block_rules', sp.block_rules)
FROM ER_SCORED_PAIRS sp
WHERE sp.run_id = '{{RUN_ID}}' AND sp.band = 'AUTO_MATCH'
UNION ALL
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', sp.pair_id, sp.entity_type, sp.record_uid_a, sp.record_uid_b,
       'MODEL', d.confidence, sp.composite_score,
       OBJECT_CONSTRUCT('summary', d.summary, 'reasons', d.reasons, 'prompt_hash', d.prompt_hash, 'model', d.model)
FROM ER_MATCH_DECISIONS d
JOIN ER_SCORED_PAIRS sp ON sp.pair_id = d.pair_id AND sp.run_id = d.run_id
WHERE d.run_id = '{{RUN_ID}}' AND NOT d.is_swap_probe
  AND d.outcome = 'MODEL_MATCH'
  AND d.pair_id NOT IN (SELECT pair_id FROM probe_flips);

-- Steward decisions, when a review workflow exists, enter here as
-- decision_source = 'STEWARD' and take precedence over every other source
-- for the same pair (including steward NO_MATCH removing an automatic edge).

-- ---------------------------------------------------------------------
-- 2. Connected components by iterative min-label propagation. Each record
--    starts with its own uid as label; each pass takes the minimum label
--    among itself and its neighbours; stops when nothing changes. Passes
--    are bounded by the longest chain, which the guards below inspect.
--    A regular (not TEMPORARY) work table is used so the block also runs as
--    a task body (rule 38).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ER_CC_LABELS AS
SELECT r.record_uid, r.entity_type, r.record_uid AS label
FROM ER_RECORDS r;

EXECUTE IMMEDIATE $$
DECLARE
    changed INTEGER DEFAULT 1;
    passes  INTEGER DEFAULT 0;
BEGIN
    WHILE (changed > 0 AND passes < 100) DO
        CREATE OR REPLACE TABLE ER_CC_NEXT AS
        WITH nbr AS (
            SELECT e.record_uid_a AS uid, l.label AS nlabel
            FROM ER_ACCEPTED_EDGES e JOIN ER_CC_LABELS l ON l.record_uid = e.record_uid_b
            WHERE e.run_id = '{{RUN_ID}}'
            UNION ALL
            SELECT e.record_uid_b, l.label
            FROM ER_ACCEPTED_EDGES e JOIN ER_CC_LABELS l ON l.record_uid = e.record_uid_a
            WHERE e.run_id = '{{RUN_ID}}'
        )
        SELECT c.record_uid, c.entity_type,
               LEAST(c.label, COALESCE(MIN(n.nlabel), c.label)) AS label
        FROM ER_CC_LABELS c
        LEFT JOIN nbr n ON n.uid = c.record_uid
        GROUP BY c.record_uid, c.entity_type, c.label;

        SELECT COUNT(*) INTO :changed
        FROM ER_CC_NEXT n JOIN ER_CC_LABELS c ON c.record_uid = n.record_uid
        WHERE n.label <> c.label;

        ALTER TABLE ER_CC_LABELS SWAP WITH ER_CC_NEXT;
        passes := passes + 1;
    END WHILE;
    DROP TABLE IF EXISTS ER_CC_NEXT;
    INSERT INTO ER_PIPELINE_QUALITY_LOG (run_id, phase, check_name, check_value, detail)
        SELECT '{{RUN_ID}}', 'golden', 'cc_passes', :passes, OBJECT_CONSTRUCT('converged', :changed = 0);
    RETURN 'passes=' || passes || ' converged=' || IFF(changed = 0, 'true', 'false');
END;
$$;
-- If converged is false after 100 passes, a chain is pathologically long:
-- stop and inspect the largest clusters before continuing.

-- ---------------------------------------------------------------------
-- 3. Clusters with guards (rule 24): size cap, cannot-link inside cluster
--    (checked on member attributes, not only on scored pairs, because two
--    cannot-link records may never have been a candidate pair), cohesion,
--    and the weakest accepted edge as the cut candidate.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ER_CLUSTERS (
    run_id             VARCHAR,
    cluster_key        VARCHAR,     -- min member uid; run-local, NOT the golden id
    entity_type        VARCHAR,
    cluster_size       INT,
    distinct_tax_ids   INT,
    distinct_gtins     INT,
    distinct_sizes     INT,
    min_edge_confidence FLOAT,
    min_pair_composite FLOAT,
    weakest_edge_pair  VARCHAR,
    cluster_status     VARCHAR,     -- PUBLISHABLE | HELD
    hold_reasons       ARRAY
);

DELETE FROM ER_CLUSTERS WHERE run_id = '{{RUN_ID}}';

INSERT INTO ER_CLUSTERS
WITH m AS (
    SELECT l.label AS cluster_key, r.*
    FROM ER_CC_LABELS l JOIN ER_RECORDS r ON r.record_uid = l.record_uid
),
attrs AS (
    SELECT cluster_key, entity_type,
           COUNT(*)                                AS cluster_size,
           COUNT(DISTINCT tax_id_norm)             AS distinct_tax_ids,
           COUNT(DISTINCT gtin_norm)               AS distinct_gtins,
           COUNT(DISTINCT ROUND(size_oz, 0))       AS distinct_sizes
    FROM m GROUP BY 1, 2
),
edges AS (
    SELECT l.label AS cluster_key, e.pair_id, e.edge_confidence
    FROM ER_ACCEPTED_EDGES e JOIN ER_CC_LABELS l ON l.record_uid = e.record_uid_a
    WHERE e.run_id = '{{RUN_ID}}'
),
edge_stats AS (
    SELECT cluster_key, MIN(edge_confidence) AS min_edge_confidence,
           MIN_BY(pair_id, edge_confidence)  AS weakest_edge_pair
    FROM edges GROUP BY 1
),
cohesion AS (
    -- Every scored pair whose two records ended up in the same cluster,
    -- whether or not it was accepted.
    SELECT la.label AS cluster_key, MIN(sp.composite_score) AS min_pair_composite
    FROM ER_SCORED_PAIRS sp
    JOIN ER_CC_LABELS la ON la.record_uid = sp.record_uid_a
    JOIN ER_CC_LABELS lb ON lb.record_uid = sp.record_uid_b AND lb.label = la.label
    WHERE sp.run_id = '{{RUN_ID}}'
    GROUP BY 1
),
flagged AS (
    SELECT a.*, es.min_edge_confidence, es.weakest_edge_pair, c.min_pair_composite,
        ARRAY_CONSTRUCT_COMPACT(
            IFF(a.cluster_size > {{MAX_CLUSTER_SIZE}}, 'SIZE_CAP', NULL),
            IFF(a.entity_type <> 'PRODUCT' AND a.distinct_tax_ids > 1, 'CANNOT_LINK_TAX_ID', NULL),
            IFF(a.entity_type =  'PRODUCT' AND a.distinct_gtins > 1,   'CANNOT_LINK_GTIN', NULL),
            IFF(a.entity_type =  'PRODUCT' AND a.distinct_sizes > 1,   'CANNOT_LINK_SIZE', NULL),
            IFF(c.min_pair_composite < {{MIN_COHESION}}, 'LOW_COHESION', NULL)
        ) AS hold_reasons
    FROM attrs a
    LEFT JOIN edge_stats es ON es.cluster_key = a.cluster_key
    LEFT JOIN cohesion c    ON c.cluster_key  = a.cluster_key
)
SELECT '{{RUN_ID}}', cluster_key, entity_type, cluster_size,
       distinct_tax_ids, distinct_gtins, distinct_sizes,
       min_edge_confidence, min_pair_composite, weakest_edge_pair,
       IFF(ARRAY_SIZE(hold_reasons) > 0, 'HELD', 'PUBLISHABLE'),
       hold_reasons
FROM flagged;

-- ---------------------------------------------------------------------
-- 4. Stable golden ids (rule 26). A cluster inherits the prior run's golden
--    id with which it shares the most members, provided that prior id is not
--    claimed by a cluster with a larger overlap. Everything else mints.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ER_GOLDEN_ID_REGISTRY (
    golden_id     VARCHAR,
    entity_type   VARCHAR,
    minted_run_id VARCHAR,
    minted_at     TIMESTAMP_NTZ,
    status        VARCHAR       -- ACTIVE | RETIRED
);

CREATE TABLE IF NOT EXISTS ER_CROSSWALK (
    run_id                VARCHAR,
    experiment_id         VARCHAR,
    golden_id             VARCHAR,
    entity_type           VARCHAR,
    record_uid            VARCHAR,
    source_system         VARCHAR,
    source_record_id      VARCHAR,
    membership_confidence FLOAT,
    cluster_size          INT,
    cluster_status        VARCHAR,
    id_lineage            VARCHAR,  -- INHERITED | MINTED
    review_status         VARCHAR DEFAULT 'UNREVIEWED',
    reviewed_by           VARCHAR,
    reviewed_at           TIMESTAMP_NTZ
);

CREATE OR REPLACE TABLE ER_GOLDEN_ID_ASSIGNMENT AS
WITH overlap AS (
    SELECT l.label AS cluster_key, x.golden_id AS prior_golden_id, COUNT(*) AS shared
    FROM ER_CC_LABELS l
    JOIN ER_CROSSWALK x ON x.record_uid = l.record_uid AND x.run_id = '{{PRIOR_RUN_ID}}'
    GROUP BY 1, 2
),
best_for_cluster AS (
    SELECT * FROM overlap
    QUALIFY ROW_NUMBER() OVER (PARTITION BY cluster_key ORDER BY shared DESC, prior_golden_id) = 1
),
claimed AS (
    -- Each prior golden id goes to at most one new cluster: the one with the
    -- largest overlap. Losers of a split mint new ids.
    SELECT * FROM best_for_cluster
    QUALIFY ROW_NUMBER() OVER (PARTITION BY prior_golden_id ORDER BY shared DESC, cluster_key) = 1
)
SELECT c.cluster_key, c.entity_type,
       COALESCE(cl.prior_golden_id,
                'G-' || LEFT(c.entity_type, 1) || '-' || UPPER(LEFT(SHA2(c.cluster_key || '|' || '{{RUN_ID}}', 256), 16))) AS golden_id,
       IFF(cl.prior_golden_id IS NULL, 'MINTED', 'INHERITED') AS id_lineage
FROM ER_CLUSTERS c
LEFT JOIN claimed cl ON cl.cluster_key = c.cluster_key
WHERE c.run_id = '{{RUN_ID}}';

INSERT INTO ER_GOLDEN_ID_REGISTRY
SELECT golden_id, entity_type, '{{RUN_ID}}', CURRENT_TIMESTAMP(), 'ACTIVE'
FROM ER_GOLDEN_ID_ASSIGNMENT a
WHERE a.id_lineage = 'MINTED'
  AND NOT EXISTS (SELECT 1 FROM ER_GOLDEN_ID_REGISTRY g WHERE g.golden_id = a.golden_id);

-- ---------------------------------------------------------------------
-- 5. Crosswalk: every in-scope record exactly once (rule 27).
--    Membership confidence = strongest accepted edge to another member;
--    singletons are 1.0 by construction (nothing was merged).
-- ---------------------------------------------------------------------
DELETE FROM ER_CROSSWALK WHERE run_id = '{{RUN_ID}}';

INSERT INTO ER_CROSSWALK
    (run_id, experiment_id, golden_id, entity_type, record_uid, source_system, source_record_id,
     membership_confidence, cluster_size, cluster_status, id_lineage)
WITH member_conf AS (
    SELECT uid, MAX(edge_confidence) AS conf FROM (
        SELECT record_uid_a AS uid, edge_confidence FROM ER_ACCEPTED_EDGES WHERE run_id = '{{RUN_ID}}'
        UNION ALL
        SELECT record_uid_b, edge_confidence FROM ER_ACCEPTED_EDGES WHERE run_id = '{{RUN_ID}}'
    ) GROUP BY 1
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', ga.golden_id, r.entity_type, r.record_uid,
       r.source_system, r.source_record_id,
       IFF(c.cluster_size = 1, 1.0, mc.conf),
       c.cluster_size, c.cluster_status, ga.id_lineage
FROM ER_CC_LABELS l
JOIN ER_RECORDS r               ON r.record_uid = l.record_uid
JOIN ER_CLUSTERS c              ON c.cluster_key = l.label AND c.run_id = '{{RUN_ID}}'
JOIN ER_GOLDEN_ID_ASSIGNMENT ga ON ga.cluster_key = l.label
LEFT JOIN member_conf mc        ON mc.uid = r.record_uid;

-- ---------------------------------------------------------------------
-- 6. Survivorship (rule 25). Deterministic, per attribute, values taken
--    only from member records. Rule order per attribute comes from
--    ER_SURVIVORSHIP_RULES; each rule is a numeric sort key so one window
--    function serves every attribute. The deciding rule is the first key on
--    which the winner strictly beats the runner-up.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ER_SURVIVORSHIP_RULES (attribute VARCHAR, rule_order ARRAY);
INSERT INTO ER_SURVIVORSHIP_RULES
SELECT column1, PARSE_JSON(column2)::ARRAY FROM VALUES
  ('display_name',  '["MOST_TRUSTED_SOURCE","MOST_RECENT","MOST_COMPLETE"]'),
  ('address',       '["MOST_RECENT","MOST_TRUSTED_SOURCE","MOST_COMPLETE"]'),
  ('city',          '["MOST_FREQUENT_NON_NULL","MOST_TRUSTED_SOURCE","MOST_RECENT"]'),
  ('region',        '["MOST_FREQUENT_NON_NULL","MOST_TRUSTED_SOURCE","MOST_RECENT"]'),
  ('postal',        '["MOST_RECENT","MOST_TRUSTED_SOURCE","MOST_COMPLETE"]'),
  ('country',       '["MOST_FREQUENT_NON_NULL","MOST_TRUSTED_SOURCE","MOST_RECENT"]'),
  ('phone',         '["MOST_RECENT","MOST_TRUSTED_SOURCE","MOST_FREQUENT_NON_NULL"]'),
  ('email_domain',  '["MOST_FREQUENT_NON_NULL","MOST_TRUSTED_SOURCE","MOST_RECENT"]'),
  ('website',       '["MOST_FREQUENT_NON_NULL","MOST_TRUSTED_SOURCE","MOST_RECENT"]'),
  ('tax_id',        '["MOST_FREQUENT_NON_NULL","MOST_TRUSTED_SOURCE","MOST_RECENT"]'),
  ('brand',         '["MOST_TRUSTED_SOURCE","MOST_FREQUENT_NON_NULL","MOST_RECENT"]'),
  ('mpn',           '["MOST_FREQUENT_NON_NULL","MOST_TRUSTED_SOURCE","MOST_RECENT"]'),
  ('gtin',          '["MOST_FREQUENT_NON_NULL","MOST_TRUSTED_SOURCE","MOST_RECENT"]'),
  ('size_oz',       '["MOST_FREQUENT_NON_NULL","MOST_TRUSTED_SOURCE","MOST_RECENT"]');

CREATE TABLE IF NOT EXISTS ER_GOLDEN_RECORDS (
    run_id                VARCHAR,
    experiment_id         VARCHAR,
    golden_id             VARCHAR,
    entity_type           VARCHAR,
    display_name          VARCHAR,
    address               VARCHAR,
    city                  VARCHAR,
    region                VARCHAR,
    postal                VARCHAR,
    country               VARCHAR,
    phone                 VARCHAR,
    email_domain          VARCHAR,
    website               VARCHAR,
    tax_id                VARCHAR,
    brand                 VARCHAR,
    mpn                   VARCHAR,
    gtin                  VARCHAR,
    size_oz               FLOAT,
    member_count          INT,
    source_systems        ARRAY,
    cluster_status        VARCHAR,
    cluster_confidence    FLOAT,
    attribute_provenance  VARIANT,
    built_at              TIMESTAMP_NTZ
);

DELETE FROM ER_GOLDEN_RECORDS WHERE run_id = '{{RUN_ID}}';

INSERT INTO ER_GOLDEN_RECORDS
WITH members AS (
    SELECT x.golden_id, r.record_uid, r.source_system, r.trust_rank, r.updated_at,
           r.name_raw, r.address_norm, r.city_norm, r.region_norm, r.postal_norm, r.country_norm,
           r.phone_norm, r.email_domain, r.website_domain, r.tax_id_norm, r.brand_norm,
           r.mpn_norm, r.gtin_norm, TO_VARCHAR(r.size_oz) AS size_txt
    FROM ER_CROSSWALK x JOIN ER_RECORDS r ON r.record_uid = x.record_uid
    WHERE x.run_id = '{{RUN_ID}}'
),
long AS (
    SELECT golden_id, record_uid, source_system, trust_rank, updated_at, attribute, value
    FROM members
    UNPIVOT INCLUDE NULLS (value FOR attribute IN (
        name_raw, address_norm, city_norm, region_norm, postal_norm, country_norm,
        phone_norm, email_domain, website_domain, tax_id_norm, brand_norm, mpn_norm, gtin_norm, size_txt))
    -- size_oz is FLOAT; carried as text through the unpivot and cast back.
),
named AS (
    SELECT golden_id, record_uid, source_system, trust_rank, updated_at, value,
           DECODE(attribute, 'NAME_RAW','display_name', 'ADDRESS_NORM','address', 'CITY_NORM','city',
                  'REGION_NORM','region', 'POSTAL_NORM','postal', 'COUNTRY_NORM','country',
                  'PHONE_NORM','phone', 'EMAIL_DOMAIN','email_domain', 'WEBSITE_DOMAIN','website',
                  'TAX_ID_NORM','tax_id', 'BRAND_NORM','brand', 'MPN_NORM','mpn', 'GTIN_NORM','gtin',
                  'SIZE_TXT','size_oz') AS attribute
    FROM long
    WHERE value IS NOT NULL AND value <> ''
),
keyed AS (
    SELECT n.*,
           COUNT(*) OVER (PARTITION BY n.golden_id, n.attribute, n.value) AS freq,
           sr.rule_order
    FROM named n JOIN ER_SURVIVORSHIP_RULES sr ON sr.attribute = n.attribute
),
sortable AS (
    SELECT k.*,
        DECODE(rule_order[0]::STRING, 'MOST_TRUSTED_SOURCE', trust_rank, 'MOST_RECENT', -DATE_PART(EPOCH_SECOND, updated_at),
               'MOST_COMPLETE', -LENGTH(value), 'MOST_FREQUENT_NON_NULL', -freq) AS k1,
        DECODE(rule_order[1]::STRING, 'MOST_TRUSTED_SOURCE', trust_rank, 'MOST_RECENT', -DATE_PART(EPOCH_SECOND, updated_at),
               'MOST_COMPLETE', -LENGTH(value), 'MOST_FREQUENT_NON_NULL', -freq) AS k2,
        DECODE(rule_order[2]::STRING, 'MOST_TRUSTED_SOURCE', trust_rank, 'MOST_RECENT', -DATE_PART(EPOCH_SECOND, updated_at),
               'MOST_COMPLETE', -LENGTH(value), 'MOST_FREQUENT_NON_NULL', -freq) AS k3
    FROM keyed k
),
ranked AS (
    SELECT s.*,
           ROW_NUMBER() OVER (PARTITION BY golden_id, attribute ORDER BY k1, k2, k3, record_uid) AS rn,
           LEAD(k1) OVER (PARTITION BY golden_id, attribute ORDER BY k1, k2, k3, record_uid) AS n_k1,
           LEAD(k2) OVER (PARTITION BY golden_id, attribute ORDER BY k1, k2, k3, record_uid) AS n_k2,
           LEAD(k3) OVER (PARTITION BY golden_id, attribute ORDER BY k1, k2, k3, record_uid) AS n_k3,
           COUNT(DISTINCT value) OVER (PARTITION BY golden_id, attribute) AS distinct_values
    FROM sortable s
),
winners AS (
    SELECT golden_id, attribute, value, record_uid, source_system,
           CASE
               WHEN distinct_values = 1 THEN 'UNANIMOUS'
               WHEN n_k1 IS NULL        THEN 'ONLY_VALUE'
               WHEN k1 < n_k1           THEN rule_order[0]::STRING
               WHEN k2 < n_k2           THEN rule_order[1]::STRING
               WHEN k3 < n_k3           THEN rule_order[2]::STRING
               ELSE 'TIE_BREAK_RECORD_UID'
           END AS deciding_rule,
           distinct_values
    FROM ranked
    WHERE rn = 1
),
pivoted AS (
    SELECT golden_id,
           MAX(IFF(attribute = 'display_name', value, NULL)) AS display_name,
           MAX(IFF(attribute = 'address',      value, NULL)) AS address,
           MAX(IFF(attribute = 'city',         value, NULL)) AS city,
           MAX(IFF(attribute = 'region',       value, NULL)) AS region,
           MAX(IFF(attribute = 'postal',       value, NULL)) AS postal,
           MAX(IFF(attribute = 'country',      value, NULL)) AS country,
           MAX(IFF(attribute = 'phone',        value, NULL)) AS phone,
           MAX(IFF(attribute = 'email_domain', value, NULL)) AS email_domain,
           MAX(IFF(attribute = 'website',      value, NULL)) AS website,
           MAX(IFF(attribute = 'tax_id',       value, NULL)) AS tax_id,
           MAX(IFF(attribute = 'brand',        value, NULL)) AS brand,
           MAX(IFF(attribute = 'mpn',          value, NULL)) AS mpn,
           MAX(IFF(attribute = 'gtin',         value, NULL)) AS gtin,
           TRY_TO_DOUBLE(MAX(IFF(attribute = 'size_oz', value, NULL))) AS size_oz,
           OBJECT_AGG(attribute, OBJECT_CONSTRUCT(
               'record_uid', record_uid, 'source_system', source_system,
               'rule', deciding_rule, 'distinct_values', distinct_values)::VARIANT) AS attribute_provenance
    FROM winners
    GROUP BY golden_id
),
cluster_level AS (
    SELECT x.golden_id, ANY_VALUE(x.entity_type) AS entity_type, COUNT(*) AS member_count,
           ARRAY_AGG(DISTINCT x.source_system) WITHIN GROUP (ORDER BY x.source_system) AS source_systems,
           ANY_VALUE(x.cluster_status) AS cluster_status,
           -- Weakest-link confidence: chains are only as strong as their weakest edge.
           IFF(COUNT(*) = 1, 1.0, MIN(x.membership_confidence)) AS cluster_confidence
    FROM ER_CROSSWALK x
    WHERE x.run_id = '{{RUN_ID}}'
    GROUP BY 1
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', c.golden_id, c.entity_type,
       p.display_name, p.address, p.city, p.region, p.postal, p.country, p.phone,
       p.email_domain, p.website, p.tax_id, p.brand, p.mpn, p.gtin, p.size_oz,
       c.member_count, c.source_systems, c.cluster_status, c.cluster_confidence,
       p.attribute_provenance, CURRENT_TIMESTAMP()
FROM cluster_level c
LEFT JOIN pivoted p ON p.golden_id = c.golden_id;

-- ---------------------------------------------------------------------
-- 7. Relationships that are not identity (rule 23): parent/subsidiary,
--    sibling location, product variant. Mapped to golden ids, so a single
--    customer view can roll up an account hierarchy without merging it.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ER_ENTITY_RELATIONSHIPS (
    run_id         VARCHAR,
    golden_id_a    VARCHAR,
    golden_id_b    VARCHAR,
    entity_type    VARCHAR,
    relationship   VARCHAR,
    confidence     FLOAT,
    evidence_pair  VARCHAR,
    summary        VARCHAR
);

DELETE FROM ER_ENTITY_RELATIONSHIPS WHERE run_id = '{{RUN_ID}}';

INSERT INTO ER_ENTITY_RELATIONSHIPS
SELECT '{{RUN_ID}}', LEAST(xa.golden_id, xb.golden_id), GREATEST(xa.golden_id, xb.golden_id),
       sp.entity_type, d.relationship, d.confidence, d.pair_id, d.summary
FROM ER_MATCH_DECISIONS d
JOIN ER_SCORED_PAIRS sp ON sp.pair_id = d.pair_id AND sp.run_id = d.run_id
JOIN ER_CROSSWALK xa ON xa.record_uid = sp.record_uid_a AND xa.run_id = d.run_id
JOIN ER_CROSSWALK xb ON xb.record_uid = sp.record_uid_b AND xb.run_id = d.run_id
WHERE d.run_id = '{{RUN_ID}}' AND NOT d.is_swap_probe
  AND d.relationship IN ('PARENT_SUBSIDIARY', 'SIBLING_LOCATION', 'PRODUCT_VARIANT')
  AND xa.golden_id <> xb.golden_id
QUALIFY ROW_NUMBER() OVER (PARTITION BY LEAST(xa.golden_id, xb.golden_id), GREATEST(xa.golden_id, xb.golden_id), d.relationship
                           ORDER BY d.confidence DESC) = 1;
