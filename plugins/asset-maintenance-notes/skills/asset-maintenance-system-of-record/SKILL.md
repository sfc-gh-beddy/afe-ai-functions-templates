---
name: asset-maintenance-system-of-record
description: "Preflight discovery for an asset maintenance notes build. Establishes what the account can run and what data exists before anything is created: Cortex AI function access via EXPLAIN_PRIVILEGES, per-stage model availability via SHOW CORTEX BASE MODELS, CORTEX_ENABLED_CROSS_REGION and data-residency approval, the work order / technician note / inspection report inventory and column mapping, note-level versus WO-level timestamps (the precursor leakage question), asset registry and equipment-versus-functional-location history, sensor coverage and grain, downtime or failure event history for labels, CMMS failure-code quality, existing objects, sensitive data in notes, and privileges. Always loaded first by the asset-maintenance-notes router."
parent_skill: asset-maintenance-notes
---

# Preflight -- what this account can run, and what is already here

Run before creating anything. It prevents four bad outcomes specific to this play:

1. building around a model the account cannot call in its region;
2. guessing column names in a CMMS export that has forty columns called `TEXT*`;
3. building precursor features on a timestamp that silently includes hindsight;
4. promising a value story that the available history (no downtime log, no sensors, two months
   of notes) cannot support.

Report a compact summary and write settled values into `maintenance-project.yml`. Create nothing.

---

## 1. Cortex AI function access

`EXPLAIN_PRIVILEGES` analyzes the statement without executing it: no credits, no model calls.

```sql
SELECT
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COMPLETE('llama3.1-8b','x')$$,                       missing_only => true) AS ai_complete,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_CLASSIFY('x',['a','b'])$$,                           missing_only => true) AS ai_classify,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_EXTRACT(text => 'x', responseFormat => {'k':'q'})$$, missing_only => true) AS ai_extract,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_EMBED('snowflake-arctic-embed-l-v2.0','x')$$,        missing_only => true) AS ai_embed,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_AGG('x','Summarize the notes')$$,                    missing_only => true) AS ai_agg,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COUNT_TOKENS('ai_complete','llama3.1-8b','x')$$,      missing_only => true) AS ai_count_tokens;
```

| Function | Needed for | If unavailable |
|---|---|---|
| `AI_COMPLETE` | signal extraction (structured output), cluster labels | **hard stop** -- this is the pipeline |
| `AI_CLASSIFY` | triage (is there a maintenance finding) | replace with a small-model `AI_COMPLETE` triage; note the cost change |
| `AI_EMBED` | recurring-issue clustering | Phase 4 cannot run; recurring issues fall back to exact component + failure-mode grouping |
| `AI_EXTRACT` | verbatim fields from inspection files (part numbers, readings) | degrade to `AI_PARSE_DOCUMENT` + `AI_COMPLETE` |
| `AI_PARSE_DOCUMENT` | inspection reports stored as files | only a blocker if inspections are file-only |
| `AI_AGG` / `AI_SUMMARIZE_AGG` | cluster and asset narratives | not a blocker |
| `AI_COUNT_TOKENS` | estimates before every gate | not a blocker; estimates unavailable |

Remediation -- surface the grant, do not work around it:

```sql
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <role>;
```

`AI_EMBED` alone can also be granted through `SNOWFLAKE.CORTEX_EMBED_USER`. If the check itself
errors, record that access was not verified and continue.

## 2. Region, cross-region inference, and models

Model availability varies by region and models move through `LEGACY` and `EOL`. Check what the
account can call **and** whether calls may leave the region.

```sql
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
SELECT CURRENT_REGION();
```

Record the value in `cross_region.setting`. `DISABLED` (the default for many accounts) restricts
inference to models hosted in-region. Any other value permits routing inference to other regions
within the stated boundary; customer data stays stored in the account's region, but the inference
request is processed elsewhere.

**Do not change this parameter, and do not recommend changing it as a casual fix.** It is an
ACCOUNTADMIN-level data-residency decision. Asset and maintenance data in regulated sectors
(critical infrastructure, utilities, defence supply chains) may have residency constraints the
account team does not know about. Ask explicitly and record `cross_region.residency_approved`. If
the preferred extraction model is only available cross-region and approval is not given, pick the
strongest in-region GA model and say what the tradeoff is.

```sql
SHOW CORTEX BASE MODELS;

SELECT "name", "lifecycle_status", "in_region_availability", "legacy_date", "eol_date"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "lifecycle_status" = 'GA'
ORDER BY "name";
```

Do not pin a model whose `lifecycle_status` is `LEGACY`, `EOL` or blank. Pin into `models` and set
`models.verified_on` to today's date.

| Stage | Wants | Why |
|---|---|---|
| `triage` (AI_CLASSIFY has no model choice) | -- | runs on every note; cheap by design |
| `extract` | strong, reliable structured output | polarity and component disambiguation are reasoning tasks; extraction accuracy sits here |
| `cluster_label` | small to mid | short summaries over already-grouped signals |
| `embed` | one model for the whole build | vectors from different models are not comparable |

Never substitute a model silently.

## 3. Find the maintenance text

If the user named tables, describe them. Otherwise look, using the shared discovery query as a
starting point (`shared/sql/discover_unstructured.sql` in the repo) plus CMMS-specific names:

```sql
SELECT table_catalog, table_schema, table_name, row_count,
       ROUND(bytes / POWER(1024, 3), 2) AS gb, last_altered
FROM information_schema.tables
WHERE table_type = 'BASE TABLE'
  AND (table_name ILIKE '%WORK%ORDER%' OR table_name ILIKE '%WO%'
    OR table_name ILIKE '%NOTE%'       OR table_name ILIKE '%LONG%TEXT%'
    OR table_name ILIKE '%WORKLOG%'    OR table_name ILIKE '%INSPECT%'
    OR table_name ILIKE '%NOTIFICATION%' OR table_name ILIKE '%MAINT%')
ORDER BY row_count DESC NULLS LAST
LIMIT 40;
```

SAP PM long texts usually arrive as a separate table keyed by object and line number (multi-row per
note); Maximo work logs as one row per log entry; many field-service tools as a single `NOTES`
column that is appended to. Identify which shape this is -- it determines whether note-level
timestamps exist (section 5).

Then map columns and write `sources` in `maintenance-project.yml`. Confirm with the user. A wrong
`asset_id_col` produces a pipeline that runs perfectly and attributes failures to the wrong
equipment.

Required: WO id, asset id, WO type, created timestamp, text. Strongly wanted: note-level timestamp,
last-modified timestamp, closed timestamp, structured failure code (for comparison only).

### Multi-line long text must be reassembled

```sql
-- If long text is stored one line per row, reassemble before anything else.
SELECT <object_key>,
       LISTAGG(<line_text>, '\n') WITHIN GROUP (ORDER BY <line_no>) AS note_text,
       COUNT(*) AS line_count
FROM <long_text_table>
GROUP BY 1
ORDER BY line_count DESC
LIMIT 20;
```

Extracting per line splits "brg temp high" from "on DE side" and loses the component.

## 4. Volume, length and duplication

```sql
SELECT COUNT(*)                                  AS notes,
       COUNT(DISTINCT <wo_id_col>)               AS work_orders,
       ROUND(AVG(LENGTH(<text_col>)))            AS avg_chars,
       APPROX_PERCENTILE(LENGTH(<text_col>), 0.95) AS p95_chars,
       COUNT_IF(<text_col> IS NULL OR LENGTH(TRIM(<text_col>)) < 15) AS empty_or_trivial,
       COUNT(DISTINCT MD5(LOWER(TRIM(<text_col>)))) AS distinct_texts,
       MIN(<ts_col>) AS earliest, MAX(<ts_col>) AS latest
FROM <notes_table>;
```

Report: share empty or trivial ("done", "ok", "see above"); share duplicated (templated close-out
text, copy-forward between WOs); the history span. Precursor work needs enough history to contain
failures **and** the notes before them -- say plainly if the span is too short.

Token estimate on a sample, for the extraction gate:

```sql
SELECT SUM(AI_COUNT_TOKENS('ai_complete', '<extract_model>', <text_col>)) AS sample_input_tokens,
       COUNT(*) AS sample_rows
FROM (SELECT <text_col> FROM <notes_table> SAMPLE (1000 ROWS));
```

Scale by row count, add the fixed prompt overhead (taxonomy and instructions are sent on every
call), and report as a floor in tokens.

## 5. The timestamp question -- decides whether precursors are possible

This is the most important check in preflight for this play.

```sql
SELECT
  COUNT(*)                                                   AS work_orders,
  COUNT_IF(<last_modified_col> > <closed_col>)                AS edited_after_close,
  ROUND(100.0 * COUNT_IF(<last_modified_col> > <closed_col>) / NULLIF(COUNT(*), 0), 1) AS pct_edited_after_close,
  ROUND(AVG(DATEDIFF('day', <closed_col>, <last_modified_col>)), 1) AS avg_days_edit_after_close
FROM <work_orders_table>
WHERE <closed_col> IS NOT NULL;
```

And, if notes are a separate table:

```sql
SELECT COUNT(*) AS notes,
       COUNT_IF(n.<ts_col> > w.<closed_col>) AS notes_after_wo_closed,
       COUNT_IF(n.<ts_col> < w.<created_col>) AS notes_before_wo_created
FROM <notes_table> n
JOIN <work_orders_table> w ON w.<id_col> = n.<wo_id_col>;
```

Interpretation:

- **Note-level timestamps exist and are trustworthy:** set `precursor.cutoff_policy: note_ts`.
- **Only a single WO long text, frequently edited after close:** the text as stored contains
  hindsight. Set `cutoff_policy: wo_last_modified` and exclude any WO whose `last_modified_at` is at
  or after the feature cutoff. Say what this costs: notes on long-running WOs drop out of precursor
  features entirely.
- **No last-modified column at all:** precursor lead time cannot be measured without leakage risk.
  Say so. Recurring-issue and failure-mode work is still fully valid.

## 6. Asset registry and point-in-time installation

```sql
SELECT <class_col> AS asset_class, COUNT(*) AS assets,
       COUNT(<install_date_col>) AS with_install_date,
       COUNT(<criticality_col>)  AS with_criticality
FROM <asset_registry>
GROUP BY 1 ORDER BY 2 DESC;
```

Low-cardinality, well-populated classes are what the taxonomy is built per. Hundreds of free-text
classes mean a class-normalization step is needed before Phase 2 -- raise it.

Check whether equipment moves between functional locations:

```sql
SELECT COUNT(*) AS equipment, COUNT_IF(position_count > 1) AS moved
FROM (SELECT <equipment_id>, COUNT(DISTINCT <functional_location>) AS position_count
      FROM <asset_moves_table> GROUP BY 1);
```

If equipment moves and there is no move history, record `sources.asset_moves: null` and state the
consequence: failure history follows whatever the work order recorded, which is usually the
functional location.

## 7. Sensor and condition-monitoring history

```sql
SELECT COUNT(DISTINCT <asset_id_col>) AS assets_with_sensors,
       MIN(<ts_col>) AS earliest, MAX(<ts_col>) AS latest,
       COUNT(*) AS readings
FROM <sensor_table>;

-- Per-measure coverage and unit sanity, by month.
SELECT DATE_TRUNC('month', <ts_col>) AS month,
       COUNT(<measure>) AS non_null, COUNT(*) AS rows_total,
       MIN(<measure>) AS min_v, MAX(<measure>) AS max_v
FROM <sensor_table>
GROUP BY 1 ORDER BY 1;
```

Record `grain` and `timezone`. A sudden change in `max_v` by an order of magnitude is usually a unit
change, not a fleet-wide fault. If there are no sensors, the precursor model runs on text and
maintenance history alone -- which is a legitimate configuration and is often where text adds the
most.

## 8. Failure events for labels

Precursors need a label: a functional failure with a timestamp.

```sql
-- Preferred: a downtime / outage log.
SELECT COUNT(*) AS events,
       COUNT_IF(NOT <planned_col>) AS unplanned,
       COUNT(DISTINCT <asset_id_col>) AS assets_affected,
       MIN(<start_col>) AS earliest, MAX(<start_col>) AS latest
FROM <downtime_table>;
```

If there is no downtime log, the fallback label is emergency or breakdown work orders. Say what that
costs: the label then comes from the same system as the features, and a WO raised days after the
failure moves the label later than the failure, inflating apparent lead time. Record
`precursor.label_source`.

Report the unplanned event count per asset class. Fewer than a few dozen events in a class means
precursor results for that class are anecdotes, not statistics -- say so in the readout.

## 9. CMMS failure-code quality

The structured code is compared against extraction, never used as ground truth.

```sql
SELECT <failure_code_col> AS failure_code, COUNT(*) AS wos,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM <work_orders_table>
WHERE <type_col> IN (<corrective_types>)
GROUP BY 1 ORDER BY 2 DESC
LIMIT 25;
```

A large `OTHER`, `NULL`, or single default code share is the problem this play solves; record the
share for the readout (it is a customer-measured baseline, which is exactly the kind of number the
value model accepts).

## 10. Existing objects

```sql
SELECT table_schema, table_name, row_count, created
FROM information_schema.tables
WHERE table_name ILIKE 'MAINT_%' OR table_name ILIKE 'TAX_%' OR table_name ILIKE 'EVAL_%'
   OR table_name ILIKE 'SYNTH_%'
ORDER BY created DESC;

SHOW DYNAMIC TABLES;
SHOW SEMANTIC VIEWS;
SHOW AGENTS;
```

Surface anything found with row count and creation date, and ask whether to reuse, rename or
replace.

## 11. Sensitive content and governance

Technician notes contain more personal data than expected: names of crew and site contacts, phone
numbers, gate codes, vehicle registrations, occasionally injury descriptions.

```sql
SELECT policy_name, policy_kind, ref_entity_name, ref_column_name
FROM TABLE(information_schema.policy_references(
    ref_entity_name => '<fully_qualified_notes_table>', ref_entity_domain => 'TABLE'));

SHOW GRANTS ON TABLE <fully_qualified_notes_table>;
```

Report existing masking and row access policies and who can read the source. Extracted signals
carry an `evidence_span` copied verbatim from the note, so they inherit its sensitivity. Offer, do
not impose, an `AI_REDACT` pass on evidence spans before they reach the CoWork-facing semantic view;
record the decision. Do not create policies in this phase.

## 12. Warehouse and privileges

```sql
SHOW WAREHOUSES LIKE '<candidate>';
SHOW GRANTS TO ROLE <role>;
```

AI function throughput is bounded by the inference service, not warehouse size; a small or medium
warehouse with short auto-suspend is usually right. The role needs `CREATE TABLE`, `CREATE DYNAMIC
TABLE`, `CREATE SEMANTIC VIEW` and `CREATE AGENT` on the target schema for Phase 7; report missing
privileges now rather than at Phase 7.

---

## Output of this phase

A short summary: functions available; cross-region setting and residency decision; models pinned;
source mapping; volume, history span, duplication; the timestamp verdict and chosen
`cutoff_policy`; registry quality and move history; sensor coverage; label source and event counts
per class; CMMS failure-code baseline; existing objects; sensitive-content posture. Then the settled
values written to `maintenance-project.yml` and `phases.preflight: done`.

Anything unresolved stays absent. In particular, never write a `value_inputs` entry here.
