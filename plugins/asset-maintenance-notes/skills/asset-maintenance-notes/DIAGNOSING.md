# Diagnosing a pipeline that is not producing what you expect

Work these in order. The first four account for most reports, and they look identical from a
dashboard: too many failures, too few failures, or a precursor model that is suspiciously good.

Object names below are the defaults; read the real ones from `created_objects` in
`maintenance-project.yml`.

## 1. Silent parse failures -- check first

**Symptom:** fewer signals than expected; a note you know describes a failure produced nothing.

A response that fails to parse becomes `NULL`, and `NULL` is indistinguishable from "this note had
no finding".

```sql
-- response holds AI_COMPLETE(..., show_details => TRUE, return_error_details => TRUE),
-- i.e. {"value": {...structured_output...}, "error": ...}.
SELECT COUNT(*)                                                         AS calls,
       COUNT_IF(response:error::STRING IS NOT NULL)                     AS errored,
       COUNT_IF(response:error::STRING IS NULL
                AND response:value:structured_output[0]:raw_message:signals IS NULL) AS unparseable,
       ROUND(100.0 * COUNT_IF(response:value:structured_output[0]:raw_message:signals IS NULL)
             / NULLIF(COUNT(*), 0), 2)                                  AS pct_lost
FROM MAINT_SIGNAL_RAW
WHERE run_id = '<run_id>';
```

Anything above zero is lost recall. Fixes in order: confirm `response_format` is attached with
`required` on `signals` and on every field inside a signal; `temperature: 0`; call with
`return_error_details => TRUE` so a failed row carries its error message instead of a bare `NULL`
(by default `AI_COMPLETE` returns `NULL` per failed row and the statement still completes -- which is
exactly why the loss is silent); move very long notes to the segmentation path rather than letting
them hit the context limit.

## 2. Everything is a failure

**Symptom:** failure-mode counts far above what the reliability team believes; inspection reports
produce as many failures as corrective work orders.

Almost always polarity. Inspection checklists are mostly negatives ("no leaks observed", "brg temp
normal", "seal OK"), and PM notes are mostly actions ("replaced filter", "greased brgs").

```sql
SELECT source_type, polarity, COUNT(*) AS signals
FROM MAINT_SIGNALS
WHERE run_id = '<run_id>'
GROUP BY 1, 2
ORDER BY 1, 3 DESC;
```

Expected shape: inspections dominated by `RULED_OUT`, PM work orders dominated by `ACTION_ONLY`,
corrective and emergency work orders dominated by `OBSERVED`. If `OBSERVED` dominates everywhere:

- confirm downstream queries filter `polarity = 'OBSERVED'` -- the most common bug is a cluster or
  feature query that forgot;
- confirm the prompt states the polarity rules with examples from **this** customer's checklist
  wording, not generic ones;
- check a sample of `RULED_OUT` ground truth against predictions in the sandbox
  (`evaluate-maintenance-accuracy` reports polarity confusion).

## 3. Replacements counted as failures

**Symptom:** a component shows a high failure rate that the planners say is a PM interval.

"Replaced DE bearing" on a PM work order is a scheduled action, not a failure. Check:

```sql
SELECT w.wo_type, s.polarity, COUNT(*) AS signals
FROM MAINT_SIGNALS s
JOIN <work_orders> w ON w.wo_id = s.wo_id
WHERE s.component_code = '<component>'
GROUP BY 1, 2 ORDER BY 3 DESC;
```

`ACTION_ONLY` on `PM` should not appear in failure statistics. If it is `OBSERVED` on PM, the
prompt is reading the action as evidence of a failure; add the PM-specific counter-examples.

## 4. Precursor model is too good

**Symptom:** precision near 1, lead times long and uniform, or performance that collapses on the
next month of data.

Assume leakage until proven otherwise. Run the cutoff assertion:

```sql
-- Any feature built from a record at or after the cutoff is leakage. Must return zero rows.
SELECT f.asset_id, f.cutoff_ts, f.max_source_ts
FROM MAINT_PRECURSOR_FEATURES f
WHERE f.max_source_ts >= f.cutoff_ts;
```

Then check the classic sources, in order:

1. **Failure WO text in features.** The corrective work order raised for the failure, including
   "as found" notes written afterwards, must be excluded. Join on note timestamp, not WO creation
   date: notes are appended to old WOs.
2. **`last_modified` after the failure.** A WO long text edited after the event can contain
   hindsight ("weep was reported in March"). Use note-level timestamps; if the source only has a
   single long-text field, exclude WOs whose `last_modified_at >= cutoff_ts`.
3. **Random split.** Train and test must be split by time (and ideally by asset). A random split
   puts next week's notes for the same asset in training.
4. **Clusters or embeddings fitted on all data.** Cluster centroids computed over the test period
   leak test-period vocabulary into training features. Fit on train period only.
5. **Label-defined features.** "Days since last emergency WO" where the emergency WO **is** the
   label.

The sandbox plants one of each; `evaluate-maintenance-accuracy` reports a leakage canary result.

## 5. No clusters, or one giant cluster

```sql
SELECT asset_class, COUNT(DISTINCT cluster_id) AS clusters,
       MAX(cluster_size) AS largest, MEDIAN(cluster_size) AS median_size
FROM MAINT_ISSUE_CLUSTERS
GROUP BY 1;
```

- **One giant cluster per class:** you embedded raw note text and the template boilerplate
  dominates ("Job completed. Area left clean. LOTO removed."). Embed the normalized signal string
  (component + failure mode + evidence span), per best-practices.
- **Every signal its own cluster:** threshold too high, or embeddings mixed models. All vectors in
  one comparison must come from the same `models.embed`; mixing models compiles if dimensions match
  and produces meaningless similarities.
- **Threshold was guessed.** Re-run the sweep in `cluster-recurring-issues` against the sandbox key.

## 6. Repeat visits look wrong

```sql
SELECT COUNT(*) AS repeat_pairs,
       COUNT_IF(first_wo_type = 'PM' OR second_wo_type = 'PM') AS involving_pm
FROM MAINT_REPEAT_VISITS;
```

PM visits are scheduled, not repeats. The window must be the customer's definition, recorded in
`recurring.repeat_window_days`. A repeat is the same asset **and** the same issue cluster within the
window after the first WO was **closed**, not created -- otherwise a long-open WO looks like its own
repeat.

## 7. Signals attached to the wrong asset

**Symptom:** a pump's history shows a gearbox failure, or an asset's failures stop the day it was
moved.

- Signals take `asset_id` from the work order or inspection record, never from a tag mentioned in
  the text. Text tags are free-form ("P-101A", "pump 101 A", "the A pump").
- If the CMMS distinguishes equipment from functional location, decide per analysis which one
  history follows: failure-mode statistics follow equipment (serial), downtime impact follows the
  functional location. Use `sources.asset_moves` to resolve point-in-time installation. A join on
  the current registry row attributes every historical WO to wherever the equipment sits today.

## 8. Sensor features are all NULL or all zero

- Timestamps in different zones or grains: record `sensors.timezone` and `grain`, convert once.
- `COALESCE(reading, 0)` turns a sensor outage into "perfectly healthy". Keep NULLs and carry a
  coverage feature (share of days with readings in the window).
- Units changed mid-history (in/s to mm/s). Check `MIN`/`MAX` by month before trusting a trend.

## 9. Cost is higher than expected

```sql
SELECT triage_label, COUNT(*) AS notes,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM MAINT_TRIAGE WHERE run_id = '<run_id>'
GROUP BY 1 ORDER BY 2 DESC;

SELECT COUNT(*) AS rows_in, COUNT(DISTINCT text_hash) AS distinct_texts
FROM MAINT_SOURCE_TEXT;
```

If triage exits almost nothing, the categories are not matched to this customer's chatter; if
distinct texts are far below rows, deduplication was not applied before extraction. Both are fixed
upstream, not by switching to a weaker extraction model.
