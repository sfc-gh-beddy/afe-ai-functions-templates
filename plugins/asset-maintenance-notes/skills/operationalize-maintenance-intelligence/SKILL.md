---
name: operationalize-maintenance-intelligence
description: "Phase 7 of the asset-maintenance-notes build. Turns an evaluated configuration into a continuously refreshed production path and a CoWork-ready interface: incremental dynamic tables for source text, triage, taxonomy-constrained extraction and signals (REFRESH_MODE = INCREMENTAL explicitly, never AUTO, because AI functions re-bill on full refresh), scheduled tasks for embeddings, re-clustering and weekly precursor scoring, an optional AI_REDACT pass and Cortex Search service over evidence spans, a semantic view over assets, observed failures, recurring issues, repeat visits and asset risk, and a Cortex Agent with instructions that keep it decision support (cite evidence, never recommend deferring safety-mandated work). Use when asked to productionize, schedule, build a semantic view, or create an agent for maintenance planners or reliability engineers."
parent_skill: asset-maintenance-notes
---

# Operationalize maintenance intelligence

Run only after `phases.eval: done` and the user has accepted the evaluated configuration
(`experiment_id`, `prompt_hash`, `taxonomy_version`, model pins, threshold, window, alert budget).
Operationalizing an unevaluated configuration ships unknown accuracy to planners.

Everything here creates long-lived, credit-consuming objects. Each block is its own gate: show the
DDL, state the refresh cadence and what it will call, confirm, create, verify.

## 1. Freeze the configuration

Dynamic tables cannot read session variables. Every value the interactive scripts took from `$...`
becomes a literal in the DDL, taken from `maintenance-project.yml`:

| Literal | From |
|---|---|
| extraction model | `models.extract` |
| embedding model | `models.embed` |
| taxonomy version | `taxonomy.version` |
| prompt text | the evaluated prompt; its `SHA2` must equal the evaluated `prompt_hash` |
| similarity threshold, repeat window | `recurring.*` |
| alert threshold | from `EV_THRESHOLD` of the accepted evaluation |

Verify the prompt hash after creating the extraction dynamic table by comparing one row's
`prompt_hash` to the evaluated one. A mismatch means production is running an unevaluated prompt.

## 2. Incremental dynamic tables

### Refresh mode is not negotiable

Cortex AI functions are supported in the `SELECT` of dynamic tables that use **incremental** refresh.
Set `REFRESH_MODE = INCREMENTAL` explicitly on every dynamic table that calls a model, and on every
upstream one. With `AUTO`, Snowflake may choose full refresh -- and a full refresh re-sends every note
in history through the model on every refresh. If a definition cannot be refreshed incrementally,
creation with `REFRESH_MODE = INCREMENTAL` fails, which is the outcome you want.

Taxonomy and prompt tables joined into an AI dynamic table must not be edited in place: a change to a
joined dimension reprocesses every dependent row. A taxonomy change is a new dynamic table version
(new name), evaluated first, then switched.

### DDL

Replace `<DB>.<SCHEMA>`, the warehouse, the source tables (from `sources.*`), and the frozen literals.

```sql
CREATE OR REPLACE DYNAMIC TABLE <DB>.<SCHEMA>.MAINT_DT_SOURCE_TEXT
  TARGET_LAG = '6 hours'
  WAREHOUSE = <WH>
  REFRESH_MODE = INCREMENTAL
AS
SELECT 'WO_NOTE' AS source_type, n.note_id AS source_id, n.wo_id, w.asset_id, a.asset_class, w.wo_type,
       n.note_ts AS source_ts, n.note_text AS source_text,
       LOWER(REGEXP_REPLACE(TRIM(n.note_text), '\\s+', ' ')) AS normalized_text,
       MD5(w.asset_id || '::' || LOWER(REGEXP_REPLACE(TRIM(n.note_text), '\\s+', ' '))) AS text_hash
FROM <notes_table> n
JOIN <work_orders_table> w ON w.wo_id = n.wo_id
JOIN <asset_registry> a ON a.asset_id = w.asset_id
WHERE n.note_text IS NOT NULL AND LENGTH(TRIM(n.note_text)) > 0
UNION ALL
SELECT 'INSPECTION', r.report_id, NULL, r.asset_id, a.asset_class, 'INSPECTION',
       r.inspection_ts, r.report_text,
       LOWER(REGEXP_REPLACE(TRIM(r.report_text), '\\s+', ' ')),
       MD5(r.asset_id || '::' || LOWER(REGEXP_REPLACE(TRIM(r.report_text), '\\s+', ' ')))
FROM <inspections_table> r
JOIN <asset_registry> a ON a.asset_id = r.asset_id
WHERE r.report_text IS NOT NULL AND LENGTH(TRIM(r.report_text)) > 0;

-- One row per (asset, normalized text): the unit that is billed.
CREATE OR REPLACE DYNAMIC TABLE <DB>.<SCHEMA>.MAINT_DT_DISTINCT_TEXT
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = <WH>
  REFRESH_MODE = INCREMENTAL
AS
SELECT text_hash, asset_class,
       MIN(source_text) AS source_text,
       MIN(source_type) AS source_type,
       MIN(wo_type)     AS wo_type
FROM <DB>.<SCHEMA>.MAINT_DT_SOURCE_TEXT
GROUP BY text_hash, asset_class;

CREATE OR REPLACE DYNAMIC TABLE <DB>.<SCHEMA>.MAINT_DT_TRIAGE
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = <WH>
  REFRESH_MODE = INCREMENTAL
AS
SELECT text_hash, asset_class, source_text, source_type, wo_type,
       AI_CLASSIFY(
           source_text,
           [ {'label': 'MAINTENANCE_FINDING', 'description': 'Mentions equipment condition, a measurement, a defect, a check result, or work done on a component'},
             {'label': 'ADMIN_ONLY',          'description': 'Only scheduling, access, permits, parts ordering or travel, with no equipment condition'},
             {'label': 'CLOSEOUT_BOILERPLATE','description': 'Only standard completion text such as job complete, area clean, permit closed'} ],
           {'task_description': 'Triage maintenance work order notes and inspection text before detailed extraction. If any equipment condition or component work is mentioned, choose MAINTENANCE_FINDING.'}
       ):labels[0]::STRING AS triage_label
FROM <DB>.<SCHEMA>.MAINT_DT_DISTINCT_TEXT;

CREATE OR REPLACE DYNAMIC TABLE <DB>.<SCHEMA>.MAINT_DT_SIGNAL_RAW
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = <WH>
  REFRESH_MODE = INCREMENTAL
AS
WITH p AS (
    SELECT t.text_hash, t.asset_class, x.taxonomy_hash, x.component_enum, x.mode_enum,
           <FROZEN PROMPT EXPRESSION, identical to the evaluated one, built from t.* and x.*> AS prompt
    FROM <DB>.<SCHEMA>.MAINT_DT_TRIAGE t
    JOIN <DB>.<SCHEMA>.TAX_CLASS_CONTEXT x
      ON x.asset_class = t.asset_class AND x.taxonomy_version = '<taxonomy_version>'
    WHERE COALESCE(t.triage_label, 'MAINTENANCE_FINDING') = 'MAINTENANCE_FINDING'
)
SELECT text_hash, asset_class, taxonomy_hash, SHA2(prompt, 256) AS prompt_hash,
       '<extract_model>' AS extract_model, '<taxonomy_version>' AS taxonomy_version,
       AI_COMPLETE(
           model => '<extract_model>',
           prompt => prompt,
           model_parameters => {'temperature': 0, 'max_tokens': 2048},
           response_format => <the evaluated OBJECT_CONSTRUCT schema, using component_enum and mode_enum>,
           show_details => TRUE,
           return_error_details => TRUE
       ) AS response
FROM p;
```

`MAINT_DT_SIGNALS` follows the flatten-validate-fan-out query of
`extract-failure-signals/sql/10_triage_and_extract.sql` step 6, reading `MAINT_DT_SIGNAL_RAW` and
`MAINT_DT_SOURCE_TEXT` instead of the run tables, with `run_id` replaced by a constant production
label. Then:

```sql
CREATE OR REPLACE VIEW <DB>.<SCHEMA>.MAINT_DT_SIGNALS_OBSERVED AS
SELECT * FROM <DB>.<SCHEMA>.MAINT_DT_SIGNALS
WHERE polarity = 'OBSERVED' AND evidence_found_in_source AND component_in_taxonomy AND mode_in_taxonomy;
```

### Verify refresh mode and first refresh

```sql
SHOW DYNAMIC TABLES LIKE 'MAINT_DT_%' IN SCHEMA <DB>.<SCHEMA>;

SELECT "name", "refresh_mode", "target_lag", "scheduling_state"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- Refresh history: confirm INCREMENTAL actions and row counts that track new notes, not the corpus.
SELECT name, refresh_action, state, refresh_start_time, refresh_end_time,
       statistics:numInsertedRows::INT AS inserted
FROM TABLE(INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(NAME_PREFIX => '<DB>.<SCHEMA>.MAINT_DT_'))
ORDER BY refresh_start_time DESC
LIMIT 20;
```

Every AI dynamic table must show `refresh_mode = INCREMENTAL`. After the initial load, `inserted` on
`MAINT_DT_SIGNAL_RAW` per refresh should be of the order of new distinct notes in the lag window. A
number near the full corpus means something upstream is forcing reprocessing -- suspend and
investigate before the next refresh.

Parse-failure monitoring continues in production: schedule the quality-log query from best-practices
rule 10 against `MAINT_DT_SIGNAL_RAW` and alert on a non-zero error or unparseable share (the
`alert` skill covers Snowflake alerts).

## 3. Scheduled tasks for the non-incremental steps

Clustering (graph and label propagation) and precursor scoring are batch computations, not
incremental ones. Schedule them as tasks with fully qualified names and no temporary tables shared
between tasks (best-practices rule 38). Delegate task mechanics to the `snowflake-tasks` skill.

| Task | Cadence | Does |
|---|---|---|
| `MAINT_TASK_EMBED` | daily | embeds new `OBSERVED` signal strings with the pinned model (incremental insert) |
| `MAINT_TASK_ASSIGN_CLUSTERS` | daily | assigns new signals to trained clusters (no refit); rebuilds repeat visits |
| `MAINT_TASK_REFIT_CLUSTERS` | quarterly, manual approval | refits clusters as a new `experiment_id`; evaluated before switching |
| `MAINT_TASK_SCORE_RISK` | weekly | builds the current week's feature row per asset (same SQL as Phase 5, cutoff = this week), asserts `max_source_ts < cutoff_ts`, calls `PREDICT`, applies the frozen threshold |

The weekly scoring task must fail -- not log and continue -- if the leakage assertion returns rows.

## 4. Sensitive text: optional redaction and search

Evidence spans are verbatim technician text. Before exposing them to a broad CoWork audience, decide
with the customer (preflight section 11) whether to redact:

```sql
CREATE OR REPLACE DYNAMIC TABLE <DB>.<SCHEMA>.MAINT_DT_EVIDENCE_REDACTED
  TARGET_LAG = '1 day'
  WAREHOUSE = <WH>
  REFRESH_MODE = INCREMENTAL
AS
SELECT source_type, source_id, signal_no, asset_id, asset_class, source_ts, component_code,
       failure_mode_code, AI_REDACT(evidence_span) AS evidence_span_redacted
FROM <DB>.<SCHEMA>.MAINT_DT_SIGNALS
WHERE polarity IN ('OBSERVED', 'UNCLEAR');
```

Confirm `AI_REDACT` availability in the region at preflight and review a sample of its output with
the customer before relying on it; it is a mitigation, not a guarantee.

For "find notes about X" questions, a Cortex Search service over evidence spans gives the agent a
retrieval tool that returns exact citations:

```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE <DB>.<SCHEMA>.MAINT_EVIDENCE_SEARCH
  ON evidence_span_redacted
  ATTRIBUTES asset_id, asset_class, component_code, failure_mode_code
  WAREHOUSE = <WH>
  TARGET_LAG = '1 day'
AS
SELECT source_id, asset_id, asset_class, component_code, failure_mode_code,
       source_ts, evidence_span_redacted
FROM <DB>.<SCHEMA>.MAINT_DT_EVIDENCE_REDACTED;
```

## 5. Semantic view

Over production tables only. **Never** include anything from the eval schema.

```sql
CREATE OR REPLACE SEMANTIC VIEW <DB>.<SCHEMA>.MAINT_INTEL_SV
  TABLES (
    assets AS <DB>.<SCHEMA>.<asset_registry_table>
      PRIMARY KEY (asset_id)
      WITH SYNONYMS ('equipment', 'machine', 'unit')
      COMMENT = 'Asset registry: one row per asset (equipment)',
    signals AS <DB>.<SCHEMA>.MAINT_DT_SIGNALS_OBSERVED
      PRIMARY KEY (source_type, source_id, signal_no)
      WITH SYNONYMS ('failures', 'findings', 'faults')
      COMMENT = 'Observed failure findings extracted from work order notes and inspection reports. Ruled-out checks and PM actions are excluded.',
    repeats AS <DB>.<SCHEMA>.MAINT_REPEAT_VISITS
      PRIMARY KEY (repeat_wo_id, cluster_id)
      WITH SYNONYMS ('repeat truck rolls', 'callbacks', 'return visits')
      COMMENT = 'A corrective work order for the same issue on the same asset within the first-time-fix window after the previous one closed',
    issues AS <DB>.<SCHEMA>.MAINT_CLUSTER_NAMES
      PRIMARY KEY (cluster_id)
      WITH SYNONYMS ('recurring issues', 'failure patterns')
      COMMENT = 'Named recurring issue clusters',
    risk AS <DB>.<SCHEMA>.MAINT_ASSET_RISK_CURRENT
      PRIMARY KEY (asset_id)
      WITH SYNONYMS ('at risk assets', 'early warnings', 'alerts')
      COMMENT = 'Latest weekly precursor score per asset with alert flag at the evaluated threshold'
  )
  RELATIONSHIPS (
    signals_to_assets AS signals (asset_id) REFERENCES assets,
    repeats_to_assets AS repeats (asset_id) REFERENCES assets,
    repeats_to_issues AS repeats (cluster_id) REFERENCES issues,
    risk_to_assets    AS risk (asset_id) REFERENCES assets
  )
  FACTS (
    repeats.days_after_close AS repeats.days_after_close,
    risk.risk_score AS risk.risk_score
  )
  DIMENSIONS (
    assets.asset_class AS assets.asset_class WITH SYNONYMS ('equipment type'),
    assets.site_code AS assets.site_code WITH SYNONYMS ('site', 'plant'),
    assets.criticality AS assets.criticality,
    signals.component AS signals.component_code WITH SYNONYMS ('part', 'item'),
    signals.assembly AS signals.assembly_code,
    signals.failure_mode AS signals.failure_mode_code WITH SYNONYMS ('how it failed', 'symptom'),
    signals.severity AS signals.severity,
    signals.source_type AS signals.source_type,
    signals.finding_date AS DATE(signals.source_ts),
    signals.finding_month AS DATE_TRUNC('month', signals.source_ts),
    repeats.repeat_date AS DATE(repeats.repeat_created_at),
    issues.issue_name AS issues.cluster_name,
    risk.is_alert AS risk.is_alert,
    risk.scored_week AS DATE(risk.cutoff_ts)
  )
  METRICS (
    signals.observed_failures AS COUNT(signals.source_id)
      COMMENT = 'Count of observed failure findings',
    signals.assets_with_failures AS COUNT(DISTINCT signals.asset_id),
    repeats.repeat_visits AS COUNT(repeats.repeat_wo_id)
      WITH SYNONYMS ('repeat truck rolls'),
    repeats.assets_with_repeats AS COUNT(DISTINCT repeats.asset_id),
    risk.assets_on_alert AS COUNT_IF(risk.is_alert)
  )
  COMMENT = 'Maintenance intelligence from work orders, technician notes and inspections. Decision support only.'
  AI_SQL_GENERATION 'Failures always means observed findings from the signals table; never count ruled-out checks or PM actions. Repeat visits use the first-time-fix window stated in the window_days column; mention the window when reporting repeats. Risk scores are decision support for planners, not failure predictions with certainty.';
```

`MAINT_ASSET_RISK_CURRENT` is a view over `MAINT_ASSET_RISK` returning the latest scored week per
asset, the frozen-threshold `is_alert` flag, and the model variant -- create it with the scoring task.

Verify with two canned questions through Cortex Analyst (or the agent) and show the generated SQL:
"Which five assets had the most repeat visits in the last 90 days, and for what issue?" and "How many
observed seal leaks were there per site last quarter?". Check the SQL filters what it should
(observed only; window stated) before handing the view to users. Add both as verified queries
(`AI_VERIFIED_QUERIES`) once they are right.

## 6. Cortex Agent

```sql
CREATE OR REPLACE AGENT <DB>.<SCHEMA>.MAINT_INTEL_AGENT
  COMMENT = 'Maintenance intelligence assistant for planners and reliability engineers'
  FROM SPECIFICATION
  $$
  instructions:
    response: >
      You support maintenance planners and reliability engineers. Answer from the tools only.
      When you name an asset as at risk or as a bad actor, cite the evidence: dates, component,
      failure mode and the technician's words from the evidence search. State that risk scores are
      decision support. Never recommend deferring, skipping or extending a replacement or inspection
      that is required by regulation, insurance, or a safety case; if asked, say that this is outside
      what the analysis can decide. When reporting repeat visits, state the first-time-fix window used.
      If a question needs data the tools do not have (costs, parts prices, labour rates), say so
      rather than estimating.
    orchestration: >
      Use the analyst tool for counts, trends, rankings and risk lists. Use the evidence search to
      quote what technicians wrote about a specific asset, component or issue. For "why is this asset
      flagged", run the analyst for the asset's risk row and then search evidence for that asset.
    sample_questions:
      - question: "Which assets had the most repeat visits for the same issue in the last 90 days?"
      - question: "Show the pumps currently on alert and what the notes said before they were flagged."
      - question: "What are the top recurring issues on gearboxes at SITE-02?"
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "maintenance_analyst"
        description: "Counts and trends of observed failures, recurring issues, repeat visits and current asset risk, by asset class, site, component and failure mode"
    - tool_spec:
        type: "cortex_search"
        name: "evidence_search"
        description: "Finds technician and inspector findings (redacted evidence text) by asset, component or failure mode, with dates"
  tool_resources:
    maintenance_analyst:
      semantic_view: "<DB>.<SCHEMA>.MAINT_INTEL_SV"
    evidence_search:
      search_service: "<DB>.<SCHEMA>.MAINT_EVIDENCE_SEARCH"
      max_results: "10"
  $$;
```

Grant usage on the agent, semantic view, search service and underlying tables to the planner role
only after the governance decision from preflight is recorded. Verify by asking one sample question
and showing the answer and its tool calls.

## Gate verification

- `SHOW DYNAMIC TABLES`: every `MAINT_DT_*` with `refresh_mode = INCREMENTAL`;
- first incremental refresh inserted rows proportional to new notes;
- production `prompt_hash` equals the evaluated one;
- tasks created and their first run succeeded (leakage assertion passed in the scoring task);
- semantic view answers both canned questions with correct SQL;
- the agent answers one sample question with citations.

Record every object in `created_objects` (dynamic tables, tasks, search service, semantic view,
agent) and set `phases.operationalize: done`.
