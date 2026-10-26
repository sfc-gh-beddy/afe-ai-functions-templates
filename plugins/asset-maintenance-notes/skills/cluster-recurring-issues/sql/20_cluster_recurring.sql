-- =====================================================================
-- Phase 4: recurring-issue clustering and repeat visits.
--
-- SET BEFORE RUNNING:
--   SET run_id               = '<extraction run_id to cluster>';
--   SET taxonomy_version     = 'tax_v1';
--   SET embed_model          = 'snowflake-arctic-embed-l-v2.0';   -- pinned; 1024 dimensions
--   SET similarity_threshold = <from the sweep; do not guess>;
--   SET repeat_window_days   = <customer first-time-fix window>;
--   SET train_end            = '<YYYY-MM-DD>';  -- clusters are FITTED on signals before this date
--
-- Reads MAINT_SIGNALS_OBSERVED only. Never raw note text.
-- =====================================================================

USE SCHEMA {{DB}}.{{SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Signal strings to embed: normalized fields + verbatim evidence.
--    One embedding per distinct string per class (billed once).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS MAINT_SIGNAL_EMBEDDINGS (
    taxonomy_version VARCHAR,
    embed_model      VARCHAR,
    asset_class      VARCHAR,
    assembly_code    VARCHAR,
    component_code   VARCHAR,
    failure_mode_code VARCHAR,
    signal_text      VARCHAR,
    signal_hash      VARCHAR,
    first_seen_ts    TIMESTAMP_NTZ,
    embedding        VECTOR(FLOAT, 1024),
    embedded_at      TIMESTAMP_NTZ
);

INSERT INTO MAINT_SIGNAL_EMBEDDINGS
WITH s AS (
    SELECT asset_class, assembly_code, component_code, failure_mode_code,
           asset_class || ' | ' || component_code || ' | ' || failure_mode_code || ' | '
             || LOWER(REGEXP_REPLACE(TRIM(evidence_span), '\\s+', ' ')) AS signal_text,
           MIN(source_ts) AS first_seen_ts
    FROM MAINT_SIGNALS_OBSERVED
    WHERE run_id = $run_id AND taxonomy_version = $taxonomy_version
    GROUP BY 1, 2, 3, 4, 5
)
SELECT $taxonomy_version, $embed_model, s.asset_class, s.assembly_code, s.component_code, s.failure_mode_code,
       s.signal_text, MD5(s.signal_text), s.first_seen_ts,
       AI_EMBED($embed_model, s.signal_text),
       CURRENT_TIMESTAMP()
FROM s
WHERE NOT EXISTS (
    SELECT 1 FROM MAINT_SIGNAL_EMBEDDINGS e
    WHERE e.signal_hash = MD5(s.signal_text) AND e.embed_model = $embed_model
      AND e.taxonomy_version = $taxonomy_version);

-- Guard: exactly one embedding model in the comparison set. Must return 1.
SELECT COUNT(DISTINCT embed_model) AS embed_models
FROM MAINT_SIGNAL_EMBEDDINGS WHERE taxonomy_version = $taxonomy_version;

-- ---------------------------------------------------------------------
-- 2. Similarity graph, fitted on TRAINING-period signals only.
--    Edges only within the same class and assembly (pruning that also
--    encodes a rule: a seal leak and a bearing noise are never one issue).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_CLUSTER_EDGES AS
SELECT a.signal_hash AS src, b.signal_hash AS dst,
       VECTOR_COSINE_SIMILARITY(a.embedding, b.embedding) AS similarity
FROM MAINT_SIGNAL_EMBEDDINGS a
JOIN MAINT_SIGNAL_EMBEDDINGS b
  ON a.asset_class = b.asset_class
 AND a.assembly_code = b.assembly_code
 AND a.signal_hash < b.signal_hash
 AND a.embed_model = b.embed_model
 AND a.taxonomy_version = b.taxonomy_version
WHERE a.taxonomy_version = $taxonomy_version
  AND a.embed_model = $embed_model
  AND a.first_seen_ts < $train_end::TIMESTAMP_NTZ
  AND b.first_seen_ts < $train_end::TIMESTAMP_NTZ
  AND VECTOR_COSINE_SIMILARITY(a.embedding, b.embedding) >= $similarity_threshold;

-- ---------------------------------------------------------------------
-- 3. Connected components by iterative min-label propagation.
--    A recursive CTE over a dense similarity graph enumerates paths and
--    explodes; label propagation converges in a few passes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_CLUSTER_LABELS AS
SELECT signal_hash AS node, signal_hash AS label
FROM MAINT_SIGNAL_EMBEDDINGS
WHERE taxonomy_version = $taxonomy_version AND embed_model = $embed_model
  AND first_seen_ts < $train_end::TIMESTAMP_NTZ;

EXECUTE IMMEDIATE $$
DECLARE
    changed INTEGER DEFAULT 1;
    passes  INTEGER DEFAULT 0;
BEGIN
    WHILE (changed > 0 AND passes < 50) DO
        CREATE OR REPLACE TEMPORARY TABLE MAINT_CLUSTER_LABELS_NEXT AS
        WITH nbr AS (
            SELECT e.src AS node, l.label FROM MAINT_CLUSTER_EDGES e JOIN MAINT_CLUSTER_LABELS l ON l.node = e.dst
            UNION ALL
            SELECT e.dst AS node, l.label FROM MAINT_CLUSTER_EDGES e JOIN MAINT_CLUSTER_LABELS l ON l.node = e.src
        )
        SELECT l.node, LEAST(l.label, COALESCE(MIN(n.label), l.label)) AS label
        FROM MAINT_CLUSTER_LABELS l
        LEFT JOIN nbr n ON n.node = l.node
        GROUP BY l.node, l.label;

        SELECT COUNT(*) INTO :changed
        FROM MAINT_CLUSTER_LABELS_NEXT x JOIN MAINT_CLUSTER_LABELS l ON l.node = x.node
        WHERE x.label <> l.label;

        CREATE OR REPLACE TABLE MAINT_CLUSTER_LABELS AS SELECT * FROM MAINT_CLUSTER_LABELS_NEXT;
        passes := passes + 1;
    END WHILE;
    RETURN 'passes=' || passes || ', last_changed=' || changed;
END;
$$;

-- ---------------------------------------------------------------------
-- 4. Assign every signal (train and later) to a cluster. Post-train
--    signals join the nearest trained cluster above threshold, or become
--    their own new cluster -- they never reshape trained clusters.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_ISSUE_CLUSTERS AS
WITH trained AS (
    SELECT e.*, l.label AS cluster_seed
    FROM MAINT_SIGNAL_EMBEDDINGS e
    JOIN MAINT_CLUSTER_LABELS l ON l.node = e.signal_hash
), later AS (
    SELECT e.*
    FROM MAINT_SIGNAL_EMBEDDINGS e
    WHERE e.taxonomy_version = $taxonomy_version AND e.embed_model = $embed_model
      AND e.first_seen_ts >= $train_end::TIMESTAMP_NTZ
), later_assigned AS (
    SELECT l.*, t.cluster_seed, VECTOR_COSINE_SIMILARITY(l.embedding, t.embedding) AS sim
    FROM later l
    LEFT JOIN trained t
      ON t.asset_class = l.asset_class AND t.assembly_code = l.assembly_code
     AND VECTOR_COSINE_SIMILARITY(l.embedding, t.embedding) >= $similarity_threshold
    QUALIFY ROW_NUMBER() OVER (PARTITION BY l.signal_hash ORDER BY sim DESC NULLS LAST) = 1
), all_assigned AS (
    SELECT signal_hash, asset_class, assembly_code, component_code, failure_mode_code, signal_text,
           cluster_seed, 'TRAIN' AS fit_period
    FROM trained
    UNION ALL
    SELECT signal_hash, asset_class, assembly_code, component_code, failure_mode_code, signal_text,
           COALESCE(cluster_seed, signal_hash), 'POST_TRAIN'
    FROM later_assigned
)
SELECT a.*,
       'CL-' || SUBSTR(MD5(a.asset_class || '::' || a.cluster_seed), 1, 10) AS cluster_id,
       COUNT(*) OVER (PARTITION BY a.asset_class, a.cluster_seed)          AS cluster_size,
       $taxonomy_version AS taxonomy_version, $embed_model AS embed_model,
       $similarity_threshold AS similarity_threshold
FROM all_assigned a;

-- Map signals (per source) to clusters. A table, not a view: the run_id
-- filter is a session variable, which must be bound at build time.
CREATE OR REPLACE TABLE MAINT_SIGNAL_CLUSTER_MAP AS
SELECT s.run_id, s.source_type, s.source_id, s.wo_id, s.asset_id, s.asset_class, s.wo_type, s.source_ts,
       s.component_code, s.failure_mode_code, s.evidence_span, c.cluster_id, c.fit_period
FROM MAINT_SIGNALS_OBSERVED s
JOIN MAINT_ISSUE_CLUSTERS c
  ON c.signal_hash = MD5(s.asset_class || ' | ' || s.component_code || ' | ' || s.failure_mode_code || ' | '
                         || LOWER(REGEXP_REPLACE(TRIM(s.evidence_span), '\\s+', ' ')))
WHERE s.run_id = $run_id;

-- ---------------------------------------------------------------------
-- 5. Cluster names, written over formed clusters (AI_AGG describes; it
--    does not decide membership). Only clusters with 3+ signals.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_CLUSTER_NAMES AS
SELECT asset_class, cluster_id,
       MAX(cluster_size) AS cluster_size,
       ANY_VALUE(component_code) AS example_component,
       ANY_VALUE(failure_mode_code) AS example_mode,
       AI_AGG(signal_text,
              'These are normalized technician findings that were grouped as one recurring maintenance issue '
              || 'on industrial equipment. Each line is: asset class | component | failure mode | technician words. '
              || 'Write a short name for the issue, at most eight words, naming the component and how it fails. '
              || 'Return only the name.') AS cluster_name
FROM MAINT_ISSUE_CLUSTERS
WHERE cluster_size >= 3
GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- 6. Repeat visits: same asset, same cluster, a non-excluded WO created
--    within the window after the previous one CLOSED.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE MAINT_REPEAT_VISITS AS
WITH v AS (
    SELECT DISTINCT m.asset_id, m.cluster_id, w.wo_id, w.wo_type, w.created_at, w.closed_at
    FROM MAINT_SIGNAL_CLUSTER_MAP m
    JOIN SYNTH_WORK_ORDERS w ON w.wo_id = m.wo_id
    WHERE w.wo_type NOT IN ('PM')            -- recurring.exclude_wo_types
      AND w.closed_at IS NOT NULL
)
SELECT a.asset_id, a.cluster_id,
       a.wo_id AS first_wo_id,  a.wo_type AS first_wo_type,  a.closed_at  AS first_closed_at,
       b.wo_id AS repeat_wo_id, b.wo_type AS repeat_wo_type, b.created_at AS repeat_created_at,
       DATEDIFF(day, a.closed_at, b.created_at) AS days_after_close,
       $repeat_window_days AS window_days
FROM v a
JOIN v b
  ON b.asset_id = a.asset_id AND b.cluster_id = a.cluster_id
 AND b.wo_id <> a.wo_id
 AND b.created_at > a.closed_at
 AND b.created_at <= DATEADD(day, $repeat_window_days, a.closed_at)
-- Each repeat WO is counted once, against the most recent prior close.
QUALIFY ROW_NUMBER() OVER (PARTITION BY b.wo_id, b.cluster_id ORDER BY a.closed_at DESC) = 1;

-- ---------------------------------------------------------------------
-- 7. Gate summaries.
-- ---------------------------------------------------------------------
SELECT asset_class, COUNT(DISTINCT cluster_id) AS clusters,
       MAX(cluster_size) AS largest, MEDIAN(cluster_size) AS median_size,
       COUNT_IF(cluster_size = 1) AS singletons
FROM MAINT_ISSUE_CLUSTERS GROUP BY 1 ORDER BY 1;

SELECT COUNT(*) AS repeat_visits, COUNT(DISTINCT asset_id) AS assets_with_repeats,
       MEDIAN(days_after_close) AS median_days_after_close
FROM MAINT_REPEAT_VISITS;

-- Bad actors: assets ranked by repeat visits, with the issue named.
SELECT r.asset_id, n.cluster_name, COUNT(*) AS repeats
FROM MAINT_REPEAT_VISITS r
LEFT JOIN MAINT_CLUSTER_NAMES n ON n.cluster_id = r.cluster_id
GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20;
