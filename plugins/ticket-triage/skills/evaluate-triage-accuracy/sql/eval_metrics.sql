-- =====================================================================
-- Ticket triage evaluation harness.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}            database
--   {{SCHEMA}}        pipeline schema (TICKET_TRIAGE_OUTPUT etc.)
--   {{EVAL_SCHEMA}}   eval schema (answer key / holdout; results land here)
--   {{TRUTH_TABLE}}   SYNTH_ANSWER_KEY in the sandbox, HOLDOUT_LABELS on real data
--   {{RUN_ID}}        the run being scored
--
-- Every view is built FROM GROUND TRUTH OUTWARD. A ticket with no
-- prediction, or with UNCLASSIFIED, is a false negative for its true label.
-- Tickets in the EXAMPLE split (few-shot pool) are excluded everywhere.
-- Results tables accumulate by run_id so experiments can be compared.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. Scored population: truth LEFT JOIN predictions for one run.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE AS
SELECT
    a.ticket_id,
    a.case_role,
    a.true_category, a.true_impact, a.true_urgency, a.true_priority, a.true_queue,
    a.true_product, a.true_error_code, a.true_asset_id,
    a.is_multi_intent AS true_multi_intent, a.secondary_category,
    a.dup_cluster_id, a.dup_parent_ticket_id, a.true_known_issue_id,
    a.is_deflectable, a.acceptable_article_ids,
    o.run_id, o.experiment_id, o.experiment_name, o.prompt_version, o.prompt_hash, o.taxonomy_version,
    COALESCE(o.pred_category, 'UNCLASSIFIED') AS pred_category,
    COALESCE(o.pred_queue,    'UNCLASSIFIED') AS pred_queue,
    COALESCE(o.pred_priority, 'UNCLASSIFIED') AS pred_priority,
    COALESCE(o.pred_impact,   'UNCLASSIFIED') AS pred_impact,
    COALESCE(o.pred_urgency,  'UNCLASSIFIED') AS pred_urgency,
    o.queue_source, o.category_source, o.priority_source,
    o.confidence_band, o.fallback_confidence, o.is_multi_intent AS pred_multi_intent,
    o.product, o.error_code, o.asset_id,
    o.cluster_id, o.parent_ticket_id,
    o.known_issue_id,
    COALESCE(o.is_deflection_candidate, FALSE) AS pred_deflect,
    o.citations,
    o.suggestion_reject_reason,
    o.ticket_id IS NULL AS missing_prediction
FROM {{DB}}.{{EVAL_SCHEMA}}.{{TRUTH_TABLE}} a
LEFT JOIN {{DB}}.{{SCHEMA}}.TICKET_TRIAGE_OUTPUT o
  ON o.ticket_id = a.ticket_id
 AND o.run_id = '{{RUN_ID}}'
WHERE COALESCE(a.split, 'EVAL') = 'EVAL';

-- ---------------------------------------------------------------------
-- 1. Per-label precision / recall / F1 with support, for queue and
--    category. Labels = union of true and predicted labels, so a label
--    that is predicted but never true still shows its false positives.
--    UNCLASSIFIED is never a "label" in macro averages; it only ever
--    adds false negatives to the true label.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_LABEL_METRICS AS
WITH pairs AS (
    SELECT 'queue' AS dimension, true_queue AS t, pred_queue AS p FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
    UNION ALL
    SELECT 'category', true_category, pred_category FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
    UNION ALL
    SELECT 'priority', true_priority, pred_priority FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
),
labels AS (
    SELECT DISTINCT dimension, t AS label FROM pairs
    UNION
    SELECT DISTINCT dimension, p FROM pairs WHERE p <> 'UNCLASSIFIED'
)
SELECT
    l.dimension, l.label,
    COUNT_IF(p.t = l.label)                     AS support,
    COUNT_IF(p.p = l.label)                     AS predicted,
    COUNT_IF(p.t = l.label AND p.p = l.label)   AS tp,
    COUNT_IF(p.t <> l.label AND p.p = l.label)  AS fp,
    COUNT_IF(p.t = l.label AND p.p <> l.label)  AS fn,
    DIV0(COUNT_IF(p.t = l.label AND p.p = l.label), COUNT_IF(p.p = l.label)) AS precision_l,
    DIV0(COUNT_IF(p.t = l.label AND p.p = l.label), COUNT_IF(p.t = l.label)) AS recall_l,
    DIV0(2 * COUNT_IF(p.t = l.label AND p.p = l.label),
         COUNT_IF(p.p = l.label) + COUNT_IF(p.t = l.label))                  AS f1_l,
    COUNT_IF(p.t = l.label) < 30                AS low_support
FROM labels l
JOIN pairs p ON p.dimension = l.dimension
GROUP BY 1, 2;

-- Headline: macro-F1 (unweighted over labels), micro-F1 / accuracy, and the
-- UNCLASSIFIED count, per dimension.
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_DIMENSION_SUMMARY AS
SELECT
    m.dimension,
    COUNT(*)                                        AS labels,
    COUNT_IF(m.low_support)                         AS low_support_labels,
    ROUND(AVG(m.f1_l), 3)                           AS macro_f1,
    ROUND(AVG(m.precision_l), 3)                    AS macro_precision,
    ROUND(AVG(m.recall_l), 3)                       AS macro_recall,
    ROUND(MIN(m.f1_l), 3)                           AS worst_label_f1,
    MIN_BY(m.label, m.f1_l)                         AS worst_label,
    ROUND(DIV0(SUM(m.tp), SUM(m.support)), 3)       AS accuracy_micro_f1,   -- single-label: micro-F1 = accuracy
    MAX(u.unclassified)                             AS unclassified,
    MAX(u.scored)                                   AS scored_tickets
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_LABEL_METRICS m
JOIN (
    SELECT 'queue' AS dimension, COUNT_IF(pred_queue = 'UNCLASSIFIED') AS unclassified, COUNT(*) AS scored
    FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
    UNION ALL
    SELECT 'category', COUNT_IF(pred_category = 'UNCLASSIFIED'), COUNT(*) FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
    UNION ALL
    SELECT 'priority', COUNT_IF(pred_priority = 'UNCLASSIFIED'), COUNT(*) FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
) u ON u.dimension = m.dimension
GROUP BY m.dimension;

-- ---------------------------------------------------------------------
-- 2. Confusion matrices with every cell, zero or not (best-practices
--    rule 19). Rows = true, columns = predicted (incl. UNCLASSIFIED).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_CONFUSION AS
WITH pairs AS (
    SELECT 'priority' AS dimension, true_priority AS t, pred_priority AS p FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
    UNION ALL SELECT 'impact',   true_impact,   pred_impact   FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
    UNION ALL SELECT 'urgency',  true_urgency,  pred_urgency  FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
    UNION ALL SELECT 'queue',    true_queue,    pred_queue    FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
),
true_labels AS (SELECT DISTINCT dimension, t AS label FROM pairs),
pred_labels AS (
    SELECT dimension, label FROM true_labels
    UNION SELECT DISTINCT dimension, p FROM pairs
    UNION SELECT DISTINCT dimension, 'UNCLASSIFIED' FROM pairs
),
grid AS (
    SELECT t.dimension, t.label AS true_label, p.label AS pred_label
    FROM true_labels t JOIN pred_labels p ON p.dimension = t.dimension
)
SELECT g.dimension, g.true_label, g.pred_label,
       COUNT(x.t) AS tickets,
       ROUND(DIV0(COUNT(x.t), SUM(COUNT(x.t)) OVER (PARTITION BY g.dimension, g.true_label)), 3) AS row_share
FROM grid g
LEFT JOIN pairs x
  ON x.dimension = g.dimension AND x.t = g.true_label AND x.p = g.pred_label
GROUP BY 1, 2, 3;

-- Priority direction: under-prioritization (predicted less urgent than true)
-- is the costly direction for P1/P2; over-prioritization burns on-call.
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_PRIORITY_DIRECTION AS
SELECT
    true_priority,
    COUNT(*)                                                                    AS support,
    COUNT_IF(pred_priority = true_priority)                                     AS exact,
    COUNT_IF(pred_priority <> 'UNCLASSIFIED' AND pred_priority > true_priority) AS under_prioritized,  -- 'P3' > 'P1'
    COUNT_IF(pred_priority <> 'UNCLASSIFIED' AND pred_priority < true_priority) AS over_prioritized,
    COUNT_IF(pred_priority = 'UNCLASSIFIED')                                    AS unclassified
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
GROUP BY 1 ORDER BY 1;
-- String comparison works only because labels are 'P1'..'P4'. If the
-- customer's scheme differs, join a rank table instead.

-- ---------------------------------------------------------------------
-- 3. Reliability: does confidence_band separate right from wrong?
--    Only if precision differs by band may anything rely on the band.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_RELIABILITY AS
SELECT 'band' AS signal, COALESCE(confidence_band, 'NONE') AS bucket,
       COUNT(*) AS tickets,
       ROUND(AVG(IFF(pred_queue = true_queue, 1, 0)), 3)        AS queue_precision,
       ROUND(AVG(IFF(pred_priority = true_priority, 1, 0)), 3)  AS priority_accuracy
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE GROUP BY 1, 2
UNION ALL
SELECT 'fallback_self_reported', 'conf_' || COALESCE(TO_VARCHAR(FLOOR(fallback_confidence / 2) * 2), 'none'),
       COUNT(*),
       ROUND(AVG(IFF(pred_queue = true_queue, 1, 0)), 3),
       ROUND(AVG(IFF(pred_priority = true_priority, 1, 0)), 3)
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE WHERE queue_source = 'AI_COMPLETE' GROUP BY 1, 2
UNION ALL
SELECT 'queue_source', COALESCE(queue_source, 'NONE'), COUNT(*),
       ROUND(AVG(IFF(pred_queue = true_queue, 1, 0)), 3),
       ROUND(AVG(IFF(pred_priority = true_priority, 1, 0)), 3)
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE GROUP BY 1, 2;

-- ---------------------------------------------------------------------
-- 4. Trap scenarios: each case_role answers one question.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_CASE_ROLES AS
SELECT
    case_role,
    COUNT(*)                                                            AS tickets,
    ROUND(AVG(IFF(pred_queue = true_queue, 1, 0)), 3)                   AS queue_correct,
    ROUND(AVG(IFF(pred_category = true_category, 1, 0)), 3)             AS category_correct,
    ROUND(AVG(IFF(pred_priority = true_priority, 1, 0)), 3)             AS priority_correct,
    ROUND(AVG(IFF(pred_deflect, 1, 0)), 3)                              AS flagged_deflectable,
    ROUND(AVG(IFF(is_deflectable, 1, 0)), 3)                            AS truly_deflectable,
    ROUND(AVG(IFF(true_multi_intent, IFF(pred_multi_intent, 1, 0), NULL)), 3) AS multi_intent_flag_recall,
    ROUND(AVG(IFF(true_multi_intent AND pred_category = secondary_category, 1, 0)), 3) AS predicted_secondary_instead
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
GROUP BY 1 ORDER BY 1;

-- ---------------------------------------------------------------------
-- 5. Entities: exact match after the same normalization on both sides.
--    Only tickets whose truth HAS a value are scored for recall; tickets
--    with no true value but a predicted one are invented values.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_ENTITIES AS
SELECT 'error_code' AS entity,
       COUNT_IF(true_error_code IS NOT NULL) AS with_truth,
       COUNT_IF(true_error_code IS NOT NULL AND UPPER(TRIM(error_code)) = UPPER(TRIM(true_error_code))) AS exact,
       COUNT_IF(true_error_code IS NULL AND error_code IS NOT NULL) AS invented
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
UNION ALL
SELECT 'asset_id',
       COUNT_IF(true_asset_id IS NOT NULL),
       COUNT_IF(true_asset_id IS NOT NULL AND UPPER(TRIM(asset_id)) = UPPER(TRIM(true_asset_id))),
       COUNT_IF(true_asset_id IS NULL AND asset_id IS NOT NULL)
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
UNION ALL
SELECT 'product',
       COUNT_IF(true_product IS NOT NULL),
       COUNT_IF(true_product IS NOT NULL AND UPPER(TRIM(product)) = UPPER(TRIM(true_product))),
       COUNT_IF(true_product IS NULL AND product IS NOT NULL)
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE;

-- ---------------------------------------------------------------------
-- 6. Duplicates, scored PAIRWISE (best-practices rule 20). A pair is
--    positive when both tickets share a cluster. Singletons contribute no
--    pairs. Truth pairs come from dup_cluster_id; predicted pairs from
--    cluster_id. Restricted to scored tickets.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_DUPLICATE_PAIRS AS
WITH t_pairs AS (
    SELECT a.ticket_id AS t1, b.ticket_id AS t2
    FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE a
    JOIN {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE b
      ON a.dup_cluster_id = b.dup_cluster_id AND a.ticket_id < b.ticket_id
),
p_pairs AS (
    SELECT a.ticket_id AS t1, b.ticket_id AS t2
    FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE a
    JOIN {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE b
      ON a.cluster_id = b.cluster_id AND a.ticket_id < b.ticket_id
)
SELECT
    (SELECT COUNT(*) FROM t_pairs)                                              AS true_pairs,
    (SELECT COUNT(*) FROM p_pairs)                                              AS predicted_pairs,
    (SELECT COUNT(*) FROM t_pairs t JOIN p_pairs p ON p.t1 = t.t1 AND p.t2 = t.t2) AS tp_pairs,
    ROUND(DIV0((SELECT COUNT(*) FROM t_pairs t JOIN p_pairs p ON p.t1 = t.t1 AND p.t2 = t.t2),
               (SELECT COUNT(*) FROM p_pairs)), 3)                              AS pair_precision,
    ROUND(DIV0((SELECT COUNT(*) FROM t_pairs t JOIN p_pairs p ON p.t1 = t.t1 AND p.t2 = t.t2),
               (SELECT COUNT(*) FROM t_pairs)), 3)                              AS pair_recall;

-- Per planted cluster: how it was recovered, and whether the parent matched.
-- Two true clusters mapping to one predicted cluster is over-merging
-- (the S07 / S27 time-window test in the sandbox).
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_CLUSTERS AS
WITH spread AS (
    SELECT dup_cluster_id, cluster_id, COUNT(*) AS members
    FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
    WHERE dup_cluster_id IS NOT NULL
    GROUP BY 1, 2
),
main AS (
    SELECT dup_cluster_id,
           SUM(members)                     AS true_size,
           COUNT(DISTINCT cluster_id)       AS predicted_clusters_spanned,
           MAX_BY(cluster_id, members)      AS main_predicted_cluster,
           MAX(members)                     AS in_main_cluster
    FROM spread
    GROUP BY 1
)
SELECT m.*,
       ROUND(DIV0(m.in_main_cluster, m.true_size), 3)              AS recovered_share,
       -- did the predicted root of the main cluster equal the true parent?
       EQUAL_NULL(m.main_predicted_cluster, p.dup_parent_ticket_id) AS parent_matches_root
FROM main m
LEFT JOIN (SELECT DISTINCT dup_cluster_id, dup_parent_ticket_id
           FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE WHERE dup_cluster_id IS NOT NULL) p
  ON p.dup_cluster_id = m.dup_cluster_id;

CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_CLUSTER_MERGES AS
SELECT cluster_id AS predicted_cluster,
       COUNT(DISTINCT dup_cluster_id)                      AS true_clusters_merged,
       COUNT_IF(dup_cluster_id IS NULL)                    AS non_duplicate_members,
       COUNT(*)                                            AS size
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE
WHERE cluster_id IS NOT NULL
GROUP BY 1
HAVING COUNT(*) > 1 AND (COUNT(DISTINCT dup_cluster_id) > 1 OR COUNT_IF(dup_cluster_id IS NULL) > 0);

-- ---------------------------------------------------------------------
-- 7. Known-issue links.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_KNOWN_ISSUES AS
SELECT
    COUNT_IF(true_known_issue_id IS NOT NULL)                                       AS true_links,
    COUNT_IF(known_issue_id IS NOT NULL)                                            AS predicted_links,
    COUNT_IF(known_issue_id IS NOT NULL AND known_issue_id = true_known_issue_id)   AS tp,
    ROUND(DIV0(COUNT_IF(known_issue_id IS NOT NULL AND known_issue_id = true_known_issue_id),
               COUNT_IF(known_issue_id IS NOT NULL)), 3)                            AS precision_ki,
    ROUND(DIV0(COUNT_IF(known_issue_id IS NOT NULL AND known_issue_id = true_known_issue_id),
               COUNT_IF(true_known_issue_id IS NOT NULL)), 3)                       AS recall_ki
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE;

-- ---------------------------------------------------------------------
-- 8. Deflection (best-practices rule 21). TP = flagged AND truly
--    deflectable AND at least one cited chunk belongs to an acceptable
--    article. Flagged-and-deflectable citing the wrong article is a FP.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_DEFLECTION_ROWS AS
WITH cited AS (
    SELECT b.ticket_id,
           ARRAY_AGG(DISTINCT k.article_id) AS cited_articles
    FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE b,
         LATERAL FLATTEN(input => b.citations) f,
         {{DB}}.{{SCHEMA}}.KB_CHUNKS k
    WHERE k.chunk_id = f.value:chunk_id::STRING
    GROUP BY 1
)
SELECT b.ticket_id, b.case_role, b.is_deflectable, b.pred_deflect,
       b.acceptable_article_ids, c.cited_articles,
       ARRAYS_OVERLAP(COALESCE(c.cited_articles, ARRAY_CONSTRUCT()),
                      COALESCE(b.acceptable_article_ids, ARRAY_CONSTRUCT()))      AS cites_acceptable,
       CASE
         WHEN b.pred_deflect AND b.is_deflectable
              AND ARRAYS_OVERLAP(COALESCE(c.cited_articles, ARRAY_CONSTRUCT()),
                                 COALESCE(b.acceptable_article_ids, ARRAY_CONSTRUCT())) THEN 'TP'
         WHEN b.pred_deflect AND b.is_deflectable                                  THEN 'FP_WRONG_ARTICLE'
         WHEN b.pred_deflect                                                        THEN 'FP_NOT_DEFLECTABLE'
         WHEN b.is_deflectable                                                      THEN 'FN'
         ELSE 'TN'
       END AS outcome,
       b.suggestion_reject_reason
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE b
LEFT JOIN cited c ON c.ticket_id = b.ticket_id;

CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_DEFLECTION AS
SELECT
    COUNT_IF(is_deflectable)                                   AS truly_deflectable,
    COUNT_IF(pred_deflect)                                     AS flagged,
    COUNT_IF(outcome = 'TP')                                   AS tp,
    COUNT_IF(outcome = 'FP_WRONG_ARTICLE')                     AS fp_wrong_article,
    COUNT_IF(outcome = 'FP_NOT_DEFLECTABLE')                   AS fp_not_deflectable,
    COUNT_IF(outcome = 'FN')                                   AS fn,
    ROUND(DIV0(COUNT_IF(outcome = 'TP'), COUNT_IF(pred_deflect)), 3)   AS deflection_precision,
    ROUND(DIV0(COUNT_IF(outcome = 'TP'), COUNT_IF(is_deflectable)), 3) AS deflection_recall,
    COUNT_IF(pred_deflect AND case_role = 'DEFLECT_DISTRACTOR')        AS distractors_flagged,
    COUNT_IF(pred_deflect AND case_role = 'ACCESS_REQUEST')            AS access_requests_flagged
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_DEFLECTION_ROWS;

-- ---------------------------------------------------------------------
-- 9. Current-state baseline: how often the EXISTING process got the
--    queue right at first assignment, and how often the final group was
--    right. In the sandbox this is computable against truth; on real data
--    use first-vs-final agreement and label it as such.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASELINE AS
SELECT
    COUNT(*)                                                            AS tickets,
    ROUND(AVG(IFF(t.first_assignment_group = b.true_queue, 1, 0)), 3)   AS current_first_touch_accuracy,
    ROUND(AVG(IFF(t.assignment_group = b.true_queue, 1, 0)), 3)         AS current_final_accuracy,
    ROUND(AVG(IFF(b.pred_queue = b.true_queue, 1, 0)), 3)               AS pipeline_queue_accuracy,
    ROUND(AVG(IFF(t.category = b.true_category, 1, 0)), 3)              AS current_category_accuracy,
    ROUND(AVG(IFF(b.pred_category = b.true_category, 1, 0)), 3)         AS pipeline_category_accuracy,
    ROUND(AVG(t.reassignment_count), 3)                                 AS current_avg_reassignments
FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE b
JOIN {{DB}}.{{SCHEMA}}.SYNTH_TICKETS t ON t.ticket_id = b.ticket_id;   -- source ticket table on real data

-- ---------------------------------------------------------------------
-- 10. Parse failures and silent nulls for the run (best-practices rule 4).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_PARSE_FAILURES AS
SELECT 'classification' AS stage,
       COUNT(*) AS calls,
       COUNT_IF(raw_category:error IS NOT NULL OR raw_impact:error IS NOT NULL
                OR raw_urgency:error IS NOT NULL) AS function_errors,
       COUNT_IF(fallback_used AND NOT parse_ok)   AS unparsed,
       COUNT_IF(pred_queue = 'UNCLASSIFIED')      AS unclassified
FROM {{DB}}.{{SCHEMA}}.TICKET_CLASSIFICATION WHERE run_id = '{{RUN_ID}}'
UNION ALL
SELECT 'entities', COUNT(*), COUNT_IF(NOT extract_ok), 0, 0
FROM {{DB}}.{{SCHEMA}}.TICKET_ENTITIES WHERE run_id = '{{RUN_ID}}'
UNION ALL
SELECT 'deflection_gate', COUNT_IF(excluded_reason IS NULL), COUNT_IF(gate_error IS NOT NULL),
       COUNT_IF(excluded_reason IS NULL AND answerable IS NULL), 0
FROM {{DB}}.{{SCHEMA}}.DEFLECTION_GATE WHERE run_id = '{{RUN_ID}}'
UNION ALL
SELECT 'suggestion', COUNT(*), 0,
       COUNT_IF(raw_response:structured_output IS NULL),
       COUNT_IF(reject_reason IN ('no_citation', 'cites_unretrieved_chunk'))
FROM {{DB}}.{{SCHEMA}}.RESOLUTION_SUGGESTIONS WHERE run_id = '{{RUN_ID}}';

-- ---------------------------------------------------------------------
-- 11. Cost per 1K tickets, from the system of record. Credits and the
--     function/model split, attributed by QUERY_TAG = run_id. Never
--     convert to currency. CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY is no
--     longer updated; use CORTEX_AI_FUNCTIONS_USAGE_HISTORY.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_COST AS
WITH n AS (
    SELECT COUNT(*) AS tickets FROM {{DB}}.{{SCHEMA}}.TICKET_CLASSIFICATION WHERE run_id = '{{RUN_ID}}'
)
SELECT u.function_name, u.model_name,
       COUNT(DISTINCT u.query_id)                         AS queries,
       SUM(u.credits)                                     AS credits,
       ROUND(1000 * DIV0(SUM(u.credits), MAX(n.tickets)), 6) AS credits_per_1k_tickets,
       MAX(n.tickets)                                     AS tickets_in_run
FROM snowflake.account_usage.cortex_ai_functions_usage_history u
CROSS JOIN n
WHERE u.query_tag = '{{RUN_ID}}'
GROUP BY 1, 2;

-- Token view for AI_COMPLETE stages, from show_details usage on the rows.
CREATE OR REPLACE VIEW {{DB}}.{{EVAL_SCHEMA}}.EVAL_TOKENS AS
SELECT 'classification_fallback' AS stage,
       COUNT_IF(fallback_used) AS calls,
       SUM(raw_fallback:usage:prompt_tokens::NUMBER)     AS prompt_tokens,
       SUM(raw_fallback:usage:completion_tokens::NUMBER) AS completion_tokens
FROM {{DB}}.{{SCHEMA}}.TICKET_CLASSIFICATION WHERE run_id = '{{RUN_ID}}'
UNION ALL
SELECT 'suggestion', COUNT(*),
       SUM(raw_response:usage:prompt_tokens::NUMBER),
       SUM(raw_response:usage:completion_tokens::NUMBER)
FROM {{DB}}.{{SCHEMA}}.RESOLUTION_SUGGESTIONS WHERE run_id = '{{RUN_ID}}'
UNION ALL
SELECT 'normalization_saving', COUNT(*), SUM(raw_tokens) - SUM(clean_tokens), NULL
FROM {{DB}}.{{SCHEMA}}.TICKETS_NORMALIZED;

-- ---------------------------------------------------------------------
-- 12. Accumulating experiment summary. INSERT, never replace.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS {{DB}}.{{EVAL_SCHEMA}}.EVAL_EXPERIMENT_SUMMARY (
    run_id VARCHAR, experiment_id VARCHAR, experiment_name VARCHAR,
    prompt_version VARCHAR, prompt_hash VARCHAR, taxonomy_version VARCHAR,
    truth_table VARCHAR, self_retrieval_guard VARCHAR,
    scored_tickets NUMBER,
    macro_f1_queue FLOAT, accuracy_queue FLOAT, worst_queue VARCHAR, worst_queue_f1 FLOAT,
    macro_f1_category FLOAT, macro_f1_priority FLOAT, accuracy_priority FLOAT,
    unclassified_queue NUMBER,
    dup_pair_precision FLOAT, dup_pair_recall FLOAT,
    ki_precision FLOAT, ki_recall FLOAT,
    deflection_precision FLOAT, deflection_recall FLOAT, deflection_flagged NUMBER,
    credits_total FLOAT, credits_per_1k_tickets FLOAT,
    evaluated_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO {{DB}}.{{EVAL_SCHEMA}}.EVAL_EXPERIMENT_SUMMARY
    (run_id, experiment_id, experiment_name, prompt_version, prompt_hash, taxonomy_version,
     truth_table, self_retrieval_guard, scored_tickets,
     macro_f1_queue, accuracy_queue, worst_queue, worst_queue_f1,
     macro_f1_category, macro_f1_priority, accuracy_priority, unclassified_queue,
     dup_pair_precision, dup_pair_recall, ki_precision, ki_recall,
     deflection_precision, deflection_recall, deflection_flagged,
     credits_total, credits_per_1k_tickets)
SELECT
    '{{RUN_ID}}', b.experiment_id, b.experiment_name, b.prompt_version, b.prompt_hash, b.taxonomy_version,
    '{{TRUTH_TABLE}}', '{{SELF_RETRIEVAL_GUARD}}', q.scored_tickets,
    q.macro_f1, q.accuracy_micro_f1, q.worst_label, q.worst_label_f1,
    c.macro_f1, p.macro_f1, p.accuracy_micro_f1, q.unclassified,
    d.pair_precision, d.pair_recall, k.precision_ki, k.recall_ki,
    f.deflection_precision, f.deflection_recall, f.flagged,
    cost.credits, cost.per_1k
FROM (SELECT ANY_VALUE(experiment_id) AS experiment_id, ANY_VALUE(experiment_name) AS experiment_name,
             ANY_VALUE(prompt_version) AS prompt_version, ANY_VALUE(prompt_hash) AS prompt_hash,
             ANY_VALUE(taxonomy_version) AS taxonomy_version
      FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_BASE WHERE run_id IS NOT NULL) b
CROSS JOIN (SELECT * FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_DIMENSION_SUMMARY WHERE dimension = 'queue')    q
CROSS JOIN (SELECT * FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_DIMENSION_SUMMARY WHERE dimension = 'category') c
CROSS JOIN (SELECT * FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_DIMENSION_SUMMARY WHERE dimension = 'priority') p
CROSS JOIN {{DB}}.{{EVAL_SCHEMA}}.EVAL_DUPLICATE_PAIRS d
CROSS JOIN {{DB}}.{{EVAL_SCHEMA}}.EVAL_KNOWN_ISSUES k
CROSS JOIN {{DB}}.{{EVAL_SCHEMA}}.EVAL_DEFLECTION f
CROSS JOIN (SELECT SUM(credits) AS credits, SUM(credits_per_1k_tickets) AS per_1k
            FROM {{DB}}.{{EVAL_SCHEMA}}.EVAL_COST) cost;
