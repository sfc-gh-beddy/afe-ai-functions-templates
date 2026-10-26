---
name: cluster-recurring-issues
description: "Phase 4 of the asset-maintenance-notes build. Groups OBSERVED maintenance signals into recurring issues and counts repeat visits. Embeds normalized signal strings (class | component | failure mode | verbatim evidence) with one pinned AI_EMBED model, builds a cosine-similarity graph within asset class and assembly, finds connected components by label propagation, fits clusters on the training period only, names clusters with AI_AGG after they are formed, and computes repeat truck rolls as same asset + same issue within the customer's first-time-fix window after the previous work order closed. Includes the threshold sweep against the sandbox answer key and bad-actor ranking. Use for recurring issues, repeat failures, bad actors, repeat truck rolls, first-time fix rate."
parent_skill: asset-maintenance-notes
---

# Cluster recurring issues

Two outputs, both feeding the OpEx lever:

- **Issue clusters** -- fleet-level groups of findings that are the same problem ("mech seal leak at
  gland" across sixty pumps), with a name, size and the assets they occur on.
- **Repeat visits** -- the same issue on the same asset again within the customer's first-time-fix
  window. Each is a candidate avoidable truck roll.

`sql/20_cluster_recurring.sql` is the plain-SQL implementation.

## Prerequisites

- `phases.extract: done` for the `run_id` being clustered.
- `models.embed` pinned (one model for the whole build).
- `recurring.repeat_window_days` **supplied by the customer** -- their definition of first-time fix
  (commonly framed as "back within N days for the same thing"). Do not default it. If they have no
  definition, show the distribution of `days_after_close` for a generous window and let them choose.
- `precursor.split.train_end` settled, because clusters are fitted on training-period signals only
  (best-practices rule 28) -- the precursor phase consumes cluster ids as features.

## Why taxonomy alone is not enough, and why embeddings alone are wrong

The taxonomy already groups by component and failure mode. Embeddings add the distinctions the
taxonomy does not encode -- a seal leak at the flush port versus at the gland, a bearing running warm
after greasing versus warm under load -- which are often different root causes and different fixes.

Embedding raw note text instead is wrong: templates and boilerplate ("Job completed. LOTO removed.")
dominate the vector, and the clusters group by author or form. The signal string embeds what was
wrong, in normalized form, with the technician's words for the distinguishing detail:

```
PUMP_CENTRIFUGAL | MECH_SEAL | EXTERNAL_LEAK | found mech seal leaking approx 1 l/min at gland
```

## Steps

### 1. Embed

One embedding per distinct signal string per class, incremental. Gate estimate:

```sql
SELECT COUNT(DISTINCT signal_text) AS strings_to_embed,
       SUM(AI_COUNT_TOKENS('ai_embed', $embed_model, signal_text)) AS input_tokens
FROM (SELECT asset_class || ' | ' || component_code || ' | ' || failure_mode_code || ' | '
               || LOWER(REGEXP_REPLACE(TRIM(evidence_span), '\\s+', ' ')) AS signal_text
      FROM MAINT_SIGNALS_OBSERVED WHERE run_id = $run_id);
```

The guard query after insert must return `1` embedding model. If `models.embed` ever changes,
truncate the embeddings table and re-embed everything; never mix.

### 2. Calibrate the threshold on the sandbox (harness-side)

The threshold is measured, not guessed. This query reads the answer key, so it runs from the
evaluation role, not the pipeline. A pair of signals is a true "same issue" pair when the answer key
gives both the same component and failure mode, and their sources are both labeled `OBSERVED`.

```sql
WITH labeled AS (
    SELECT DISTINCT e.signal_hash, e.asset_class, e.assembly_code, k.component_code AS true_component,
           k.failure_mode_code AS true_mode
    FROM MAINT_SIGNAL_EMBEDDINGS e
    JOIN MAINT_SIGNALS_OBSERVED s
      ON MD5(s.asset_class || ' | ' || s.component_code || ' | ' || s.failure_mode_code || ' | '
             || LOWER(REGEXP_REPLACE(TRIM(s.evidence_span), '\\s+', ' '))) = e.signal_hash
    JOIN <EVAL_SCHEMA>.ANSWER_KEY_SIGNALS k
      ON k.source_type = s.source_type AND k.source_id = s.source_id
     AND k.component_code = s.component_code AND k.polarity = 'OBSERVED'
    WHERE s.run_id = $run_id
), pairs AS (
    SELECT VECTOR_COSINE_SIMILARITY(ea.embedding, eb.embedding) AS sim,
           (a.true_component = b.true_component AND a.true_mode = b.true_mode) AS same_issue
    FROM labeled a
    JOIN labeled b ON a.asset_class = b.asset_class AND a.assembly_code = b.assembly_code
                  AND a.signal_hash < b.signal_hash
    JOIN MAINT_SIGNAL_EMBEDDINGS ea ON ea.signal_hash = a.signal_hash
    JOIN MAINT_SIGNAL_EMBEDDINGS eb ON eb.signal_hash = b.signal_hash
), thresholds AS (
    SELECT 0.70 + 0.025 * (ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1) AS t
    FROM TABLE(GENERATOR(ROWCOUNT => 11))
)
SELECT t.t AS threshold,
       COUNT_IF(p.sim >= t.t AND p.same_issue)     AS tp_pairs,
       COUNT_IF(p.sim >= t.t AND NOT p.same_issue) AS fp_pairs,
       COUNT_IF(p.sim <  t.t AND p.same_issue)     AS fn_pairs,
       ROUND(tp_pairs / NULLIF(tp_pairs + fp_pairs, 0), 3) AS pair_precision,
       ROUND(tp_pairs / NULLIF(tp_pairs + fn_pairs, 0), 3) AS pair_recall
FROM thresholds t CROSS JOIN pairs p
GROUP BY t.t ORDER BY t.t;
```

Pick the threshold where pair precision is high enough that a cluster reads as one issue to a
reliability engineer, without fragmenting recall. Record it in `recurring.similarity_threshold` and
the evidence for the choice in the session.

Two caveats to state:

- the sandbox has few phrasings per issue, so the curve is optimistic; re-check on a customer-reviewed
  sample of 50-100 production pairs before go-live;
- connected components chain: A~B and B~C put A and C together even if A and C are far apart. If
  clusters look stretched, raise the threshold or switch the connected-components step to require
  similarity to the cluster's earliest member (a "leader" rule), and compare.

### 3. Build the graph and components

Edges only within the same class **and** assembly. This is pruning (pairwise similarity is quadratic)
and a rule: a seal leak and a bearing noise are never one issue, however similar the phrasing.

Connected components use iterative min-label propagation in a Snowflake Scripting block. Do not use
a recursive CTE: on a dense similarity graph it enumerates paths, and the row count explodes before
it converges. The block returns the number of passes; more than a handful suggests long chains (see
caveat above).

### 4. Assign post-train signals without refitting

Signals first seen after `train_end` are attached to the most similar trained cluster above
threshold, or become new singleton clusters. They never merge trained clusters. This keeps cluster
ids stable for the precursor model and prevents test-period language from reshaping training
features.

Re-fit periodically (for example quarterly) as a new `experiment_id`, never in place.

### 5. Name clusters

`AI_AGG` over the signal strings of each formed cluster (3+ members) writes a short name. It
describes membership that vectors and a threshold already decided. Never ask a model to form the
groups itself -- it is not reproducible and cannot be evaluated.

Names are display text for the semantic view and agent; they are not keys. Keep `cluster_id`
(a hash of class and seed) as the key.

### 6. Repeat visits

A repeat visit, per best-practices rule 22:

- same `asset_id` (or functional location, if the analysis follows position -- decide and record);
- same `cluster_id`;
- second WO type not in `recurring.exclude_wo_types` (PM by default; add inspection or route types
  if the customer does not count them as truck rolls);
- second WO **created** after the first WO **closed**, within `repeat_window_days`;
- each repeat counted once, against the most recent prior close.

`MAINT_REPEAT_VISITS` carries `window_days` on every row so a figure in the readout always states the
window it used.

## Gate verification

From the script's final section:

- clusters per class with largest, median size and singleton count;
- repeat-visit count, assets affected, median days after close;
- top 20 bad actors with cluster names.

On the sandbox, also run (harness-side) the recurring-group recovery check:

```sql
-- Each planted recurring group should be one cluster with two repeat visits.
SELECT g.asset_id, g.clusters_for_group, COALESCE(r.repeats_found, 0) AS repeats_found
FROM (SELECT k.asset_id, COUNT(DISTINCT m.cluster_id) AS clusters_for_group
      FROM <EVAL_SCHEMA>.ANSWER_KEY_RECURRING k
      LEFT JOIN MAINT_SIGNAL_CLUSTER_MAP m ON m.wo_id = k.wo_id
      GROUP BY k.asset_id) g
LEFT JOIN (SELECT asset_id, COUNT(*) AS repeats_found FROM MAINT_REPEAT_VISITS GROUP BY 1) r
  ON r.asset_id = g.asset_id
ORDER BY g.clusters_for_group DESC, repeats_found;
```

Expect one cluster per planted group and two repeats per asset when the window is at least 12 days.
`clusters_for_group = 0` means extraction missed the signal; greater than 1 means the threshold
fragments the issue. Detailed scoring is in `evaluate-maintenance-accuracy`.

Record objects, the threshold, the window, and `phases.recurring: done`.

## What this does not tell you

A repeat visit is a candidate avoidable truck roll, not a proven one. Some repeats are planned
follow-ups ("return with parts"), and some are a second, unrelated fault that happens to share a
cluster. In the production pilot, have a planner review a sample of repeat pairs and record the share
they agree were avoidable -- that share, not the raw count, is the input to the value readout.
