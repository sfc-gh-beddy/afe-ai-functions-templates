---
name: evaluate-triage-accuracy
description: "Measure whether the ticket triage pipeline is actually right, and what it costs. Per-queue and per-category precision, recall, F1 and support with macro-F1 as the headline; full priority, impact and urgency confusion matrices including zero cells and UNCLASSIFIED; under- versus over-prioritization; a reliability table showing whether confidence bands separate right from wrong; trap-scenario results by case_role; entity exact-match and invented-value counts; pairwise duplicate precision/recall, cluster recovery and over-merge detection; known-issue link precision/recall; deflection precision and recall with wrong-article false positives; the current-state routing baseline; parse-failure and silent-null accounting; credits per 1K tickets from CORTEX_AI_FUNCTIONS_USAGE_HISTORY by query tag; threshold sweeps; leakage checks; building a real-data SME holdout; and experiment comparison guarded by taxonomy_version. Joins from ground truth outward so dropped tickets count as misses. Phase 7 of the ticket-triage build. Triggers: routing accuracy, F1 per queue, macro F1, priority confusion matrix, deflection precision, cost per ticket, is it accurate, compare experiments."
parent_skill: ticket-triage
---

# Evaluate accuracy and cost

A triage pipeline nobody has measured per queue is a pipeline that may be sending an entire specialist
team's tickets somewhere else while the headline accuracy looks fine. This phase answers, with numbers:

1. **Routing** — per queue, how much of each team's work reaches it (recall), and how much of what reaches it
   belongs there (precision)?
2. **Priority** — where does it under-prioritize, which is the costly direction?
3. **Linking** — does it group the same incident and keep different incidents apart?
4. **Deflection** — of what it would show a requester, how much actually resolves their ask, from the right
   article?
5. **Loss** — how many tickets silently failed?
6. **Cost** — credits and tokens per 1K tickets, by stage.

Do not skip it. If the user wants to stop before it, say plainly what they will not know. The value readout
uses only figures from this phase.

## The distinction that matters most

**Per-row confidence** is what the pipeline thinks about one ticket. **Pipeline accuracy** is how often it is
right per queue against truth. They are separate measurements, and phase 4's `confidence_band` is a hypothesis
until the reliability table below says it separates correct from incorrect.

## Truth: the sandbox answer key, or an SME holdout

**Sandbox:** `SYNTH_ANSWER_KEY` in the eval schema. Exclude `split = 'EXAMPLE'` (the few-shot pool) — the
harness does this in `EVAL_BASE`.

**Real data:** historical labels are not truth (best-practices rule 2). Build `HOLDOUT_LABELS` in the eval
schema with the same columns as the answer key the harness reads (`ticket_id`, `true_category`,
`true_impact`, `true_urgency`, `true_priority`, `true_queue`, `true_product`, `true_error_code`,
`true_asset_id`, `is_multi_intent`, `secondary_category`, `dup_cluster_id`, `dup_parent_ticket_id`,
`true_known_issue_id`, `is_deflectable`, `acceptable_article_ids`, `case_role`, `split`):

- **Stratify by historical final queue**, not uniformly — otherwise the small queues, where routing value
  concentrates, get a handful of rows. Aim for at least 30 per queue that matters; say plainly which queues
  fell short.
- **Label blind to predictions.** Export ticket ids and text to the labelling surface the customer uses
  inside the account (a Streamlit app or a table the SME edits); do not show the model's answer.
- **Two labellers on an overlap** of 50 to 100 tickets, and report their agreement. Model accuracy above
  inter-annotator agreement is not meaningful.
- **Deflection labels need the article.** "Deflectable" is recorded together with the acceptable article ids.
- Store `split = 'EVAL'` and freeze the holdout; tickets used as few-shot examples are never in it.
- Never write holdout ticket text outside the account.

Set `knowledge.self_retrieval_guard` before scoring deflection on closed tickets — see
`build-resolution-knowledge-store`.

## Run the harness

`sql/eval_metrics.sql` in this directory builds every view below. Substitute `{{DB}}`, `{{SCHEMA}}`,
`{{EVAL_SCHEMA}}`, `{{TRUTH_TABLE}}`, `{{RUN_ID}}` and `{{SELF_RETRIEVAL_GUARD}}`. On real data, change the
source table in `EVAL_BASELINE` from `SYNTH_TICKETS` to the customer's ticket table. The views make no AI
calls. The final `INSERT` appends one row to `EVAL_EXPERIMENT_SUMMARY`; it never replaces.

Read best-practices rules 17-22 before interpreting anything.

## Built from ground truth outward

`EVAL_BASE` starts from the truth table and `LEFT JOIN`s predictions for the run. A ticket with no prediction —
dropped upstream, failed parse, filtered — appears with `pred_queue = 'UNCLASSIFIED'` and
`missing_prediction = TRUE`, and counts as a false negative for its true label. If `missing_prediction` is
non-zero, find out why before quoting any metric:

```sql
SELECT COUNT_IF(missing_prediction) AS missing, COUNT(*) AS scored
FROM <db>.<eval_schema>.EVAL_BASE;
```

## 1. Routing: per queue first, then the headline

```sql
SELECT label AS queue, support, predicted, tp, fp, fn,
       ROUND(precision_l, 3) AS precision_q, ROUND(recall_l, 3) AS recall_q, ROUND(f1_l, 3) AS f1_q,
       low_support
FROM <db>.<eval_schema>.EVAL_LABEL_METRICS
WHERE dimension = 'queue'
ORDER BY support ASC;

SELECT * FROM <db>.<eval_schema>.EVAL_DIMENSION_SUMMARY;
```

Report **macro-F1** as the headline, with the worst queue named, **accuracy alongside and labelled**, the
`UNCLASSIFIED` count, and the low-support flag. A queue with low recall is a team whose tickets are going
elsewhere — read its row of the confusion matrix to see where:

```sql
SELECT true_label AS true_queue, pred_label AS predicted_queue, tickets, row_share
FROM <db>.<eval_schema>.EVAL_CONFUSION
WHERE dimension = 'queue' AND true_label = '<weak queue>'
ORDER BY tickets DESC;
```

### Compare with the current process

```sql
SELECT * FROM <db>.<eval_schema>.EVAL_BASELINE;
```

`current_first_touch_accuracy` is how often today's process routed correctly at first assignment; it is the
comparison the value readout uses. On real data, if truth comes from an SME holdout this is computable
directly; if not, report first-assignment versus final-assignment agreement and label it as a proxy.

## 2. Priority

```sql
-- Full matrix, every cell present.
SELECT true_label AS true_priority, pred_label AS predicted, tickets, row_share
FROM <db>.<eval_schema>.EVAL_CONFUSION
WHERE dimension = 'priority'
ORDER BY true_label, pred_label;

SELECT * FROM <db>.<eval_schema>.EVAL_PRIORITY_DIRECTION;
```

Show the matrix as a grid with support per row. Lead with the P1 and P2 rows and the under-prioritized count:
an under-prioritized P1 is the expensive error. If priority is weak, look at the impact and urgency matrices
(same view, `dimension IN ('impact', 'urgency')`) — they tell you which half of the derivation is wrong, which a
direct priority classifier never could.

## 3. Does confidence mean anything?

```sql
SELECT * FROM <db>.<eval_schema>.EVAL_RELIABILITY ORDER BY signal, bucket;
```

If queue precision for `HIGH` is clearly above `MEDIUM`, and `MEDIUM` above `LOW`, the bands are usable — for
example for an auto-assign-above-`HIGH` policy, quoted with its measured precision. If they are flat, say so:
the bands are not yet a basis for automation. Treat the self-reported fallback confidence the same way; flat or
inverted is common and is a finding, not a bug to hide.

## 4. Trap scenarios

```sql
SELECT * FROM <db>.<eval_schema>.EVAL_CASE_ROLES;
```

Each `case_role` answers one question (see `seed-ticket-sandbox`). Read in particular:

- `TONE_TRAP` `priority_correct` — does shouting inflate priority?
- `QUIET_P1` `priority_correct` — does polite wording hide a major incident?
- `LEXICAL_TRAP` `queue_correct` — are printer-offline tickets kept out of networking?
- `MULTI_INTENT` `multi_intent_flag_recall` and `predicted_secondary_instead`;
- `NON_ENGLISH` — every column; a collapse here means translation is needed;
- `DEFLECT_DISTRACTOR` and `ACCESS_REQUEST` `flagged_deflectable` — should be zero.

## 5. Entities

```sql
SELECT entity, with_truth, exact, ROUND(DIV0(exact, with_truth), 3) AS recall, invented
FROM <db>.<eval_schema>.EVAL_ENTITIES;
```

`invented` counts values extracted where the ticket stated none. A non-trivial `invented` count on `asset_id`
or `error_code` means the extraction questions are inviting guesses; tighten the descriptions ("Empty if none").

## 6. Duplicates and known issues

```sql
SELECT * FROM <db>.<eval_schema>.EVAL_DUPLICATE_PAIRS;
SELECT * FROM <db>.<eval_schema>.EVAL_CLUSTERS ORDER BY true_size DESC;
SELECT * FROM <db>.<eval_schema>.EVAL_CLUSTER_MERGES ORDER BY size DESC;
SELECT * FROM <db>.<eval_schema>.EVAL_KNOWN_ISSUES;
```

Pairwise precision catches over-merging, pairwise recall catches fragmentation. `EVAL_CLUSTER_MERGES` lists
predicted clusters that swallowed more than one true incident or non-duplicates; in the sandbox, `CL-S07` and
`CL-S27` appearing in one predicted cluster means the time window is too wide.

### Threshold sweeps

Tune `duplicate_similarity` and `known_issue_similarity` on the candidate tables, which kept every blocked pair
before thresholding:

```sql
-- Duplicate threshold sweep: pairwise precision/recall at each threshold,
-- against the truth table. Only pairs inside the blocking window can ever be found.
WITH truth AS (
    SELECT a.ticket_id AS t1, b.ticket_id AS t2
    FROM <db>.<eval_schema>.<truth_table> a
    JOIN <db>.<eval_schema>.<truth_table> b
      ON a.dup_cluster_id = b.dup_cluster_id AND a.ticket_id <> b.ticket_id
),
cand AS (
    SELECT ticket_id, other_ticket_id, similarity
    FROM <db>.<schema>.DUPLICATE_CANDIDATES WHERE run_id = :run_id
),
grid AS (SELECT 0.70 + 0.02 * SEQ4() AS thr FROM TABLE(GENERATOR(ROWCOUNT => 14)))
SELECT g.thr,
       COUNT_IF(c.similarity >= g.thr)                                AS predicted_edges,
       COUNT_IF(c.similarity >= g.thr AND t.t1 IS NOT NULL)           AS true_edges_found,
       ROUND(DIV0(COUNT_IF(c.similarity >= g.thr AND t.t1 IS NOT NULL),
                  COUNT_IF(c.similarity >= g.thr)), 3)                AS edge_precision,
       ROUND(DIV0(COUNT_IF(c.similarity >= g.thr AND t.t1 IS NOT NULL),
                  (SELECT COUNT(*) FROM truth)), 3)                   AS edge_recall
FROM grid g
CROSS JOIN cand c
LEFT JOIN truth t ON t.t1 = c.ticket_id AND t.t2 = c.other_ticket_id
GROUP BY g.thr ORDER BY g.thr;
```

Edge-level figures are a guide; re-run phase 5's clustering at the chosen threshold and confirm with the
pairwise view, which scores clusters, not edges. Record the threshold and the experiment that chose it. A
threshold chosen on the sandbox is a starting point for real data, not a transfer.

## 7. Deflection

```sql
SELECT * FROM <db>.<eval_schema>.EVAL_DEFLECTION;

SELECT outcome, case_role, COUNT(*) AS tickets
FROM <db>.<eval_schema>.EVAL_DEFLECTION_ROWS
GROUP BY 1, 2 ORDER BY 1, 2;
```

Report **deflection precision first**, with the wrong-article false positives separated from the
not-deflectable ones, then recall. Then say what the precision supports, using the customer's own policy:

- as **agent assist** (an agent reads the suggestion before using it), moderate precision is useful;
- as a **self-service suggestion** the requester can ignore, precision needs to be high enough that requesters
  keep trusting it;
- as an **auto-reply or auto-close**, precision must be very high and the customer sets the bar. Do not set it
  for them, and do not recommend auto-close from sandbox numbers.

Read the false negatives with `suggestion_reject_reason`: `sources_do_not_resolve` on a truly deflectable
ticket usually means retrieval missed the article (fix the knowledge store or query), while
`cited_source_not_self_service` means the `is_self_service` flag is wrong for that article.

## 8. Silent loss

```sql
SELECT * FROM <db>.<eval_schema>.EVAL_PARSE_FAILURES;
```

Every non-zero `function_errors`, `unparsed` or gate-null count is lost recall that would otherwise look like a
correct negative. Report the counts beside the headline metrics, not in a footnote. A pipeline that cannot say
how many calls failed cannot make a recall claim.

## 9. Leakage check

If any metric is implausibly high, test for leakage before celebrating (DIAGNOSING section 3):

```sql
-- Classifier inputs containing post-assignment or resolution language.
SELECT COUNT(*) AS leaky_inputs
FROM <db>.<schema>.TICKETS_NORMALIZED
WHERE classify_text ILIKE '%reassign%' OR classify_text ILIKE '%workaround applied%'
   OR classify_text ILIKE '%resolved by%';

-- Few-shot examples that are also scored tickets (must be zero).
SELECT COUNT(*) AS example_overlap
FROM <db>.<schema>.TAXONOMY_EXAMPLES x
JOIN <db>.<eval_schema>.EVAL_BASE b ON b.ticket_id = x.example_id;

-- Deflection citing the ticket's OWN resolution (self-retrieval; must be zero).
SELECT COUNT(*) AS self_citations
FROM <db>.<schema>.RESOLUTION_SUGGESTIONS s,
     LATERAL FLATTEN(input => s.citations) f
WHERE s.run_id = :run_id AND f.value:chunk_id::STRING = 'RT#' || s.ticket_id;
```

## 10. Cost per 1K tickets

```sql
SELECT * FROM <db>.<eval_schema>.EVAL_COST ORDER BY credits DESC;
SELECT * FROM <db>.<eval_schema>.EVAL_TOKENS;
```

- Credits come from `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` filtered on `QUERY_TAG = run_id`
  (the older `CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY` is no longer updated). Usage can take minutes to appear; if
  the view is empty, check the query tag was set and re-check later rather than estimating.
- Cortex Search batch usage is separate:
  `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_BATCH_QUERY_USAGE_HISTORY`. Add it to the per-1K figure for the
  suggestion stage; inspect its columns with a `LIMIT 1` select before aggregating.
- Report credits and tokens per 1K tickets **per stage**: classification (rules plus `AI_CLASSIFY`),
  fallback, entities, embeddings, deflection gate, retrieval, suggestion. Report what the levers saved on this
  corpus: share settled by rules, share needing the fallback, the normalization token reduction, and the share
  of tickets the deflection gate kept out of the suggestion pass.
- Never convert credits to currency or look up a price.

## 11. Comparing experiments

```sql
SELECT experiment_id, experiment_name, prompt_version, taxonomy_version, truth_table, run_id,
       scored_tickets, macro_f1_queue, worst_queue, worst_queue_f1, accuracy_queue,
       macro_f1_priority, unclassified_queue,
       dup_pair_precision, dup_pair_recall, deflection_precision, deflection_recall,
       credits_per_1k_tickets, prompt_hash, evaluated_at
FROM <db>.<eval_schema>.EVAL_EXPERIMENT_SUMMARY
ORDER BY evaluated_at;
```

Rules for a fair comparison:

- **Same truth table, same scored tickets.** A change in `scored_tickets` means the population moved.
- **Same `taxonomy_version`**, or say plainly that the label space changed and the per-queue numbers are not
  comparable. A merged queue raises macro-F1 by removing a hard label, which is not an accuracy improvement.
- **Trust `prompt_hash` over `prompt_version`.** Same version, different hash: the prompt or label set changed
  without a version bump — say so.
- **Look at the worst queue and the deltas per queue**, not only macro-F1. A change that helps four queues and
  wrecks one shows a small macro gain and a real regression.
- Small sandbox support means small differences are noise. A difference of a few tickets on a 30-ticket queue
  is not a result.

## 12. Regression gates

After the first accepted run, set `thresholds.min_acceptable_macro_f1_queue` and
`thresholds.min_acceptable_deflection_precision` to just under the achieved figures. In dbt mode these are the
singular tests in `DBT_MATERIALIZATION.md`; in SQL mode, `operationalize-triage-pipeline` checks them after each
evaluation run and alerts.

## What to report

A short readout, in this order:

1. Truth source and size; self-retrieval guard; any queues below 30 support.
2. Routing: macro-F1, worst queue and its recall, accuracy (labelled), unclassified count, and the
   current-process first-touch baseline.
3. Priority: P1/P2 recall and under-prioritized count, with the matrix.
4. Reliability: whether bands separate.
5. Linking: pairwise precision/recall; any over-merges.
6. Deflection: precision (with wrong-article split), recall, and what that precision supports.
7. Silent loss counts.
8. Credits and tokens per 1K tickets per stage, and what each lever saved.

Then `phases.eval: done`. Accuracy figures from this phase are the only ones the value readout may use.
