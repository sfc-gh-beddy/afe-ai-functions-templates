---
name: operationalize-call-insights
description: "Phase 7 of the call-center-intelligence build. Turns the one-off build into a running system: an incremental, idempotent pipeline driven by a stream on the call metadata table and a task graph (transcribe, redact, roles, reasons, outcomes, sentiment, QA, signals) with the AI error-handling session parameter set on the tasks; a CALL_FACTS table that joins the latest run of every per-call output; SQL-only dynamic tables for daily reason, repeat, escalation and save-gap metrics and for agent QA rollups with minimum-call thresholds; weekly driver narratives with AI_AGG and AI_SUMMARIZE_AGG built from redacted, derived text; a semantic view over the facts; a Cortex Agent for Snowflake Intelligence / CoWork that answers counts from the semantic view and never quotes numbers from narrative text; and grants that keep raw tables away from the agent. Use for: schedule the pipeline, automate call analytics, daily call drivers, dashboard, semantic view, Cortex Agent, Snowflake Intelligence, ask questions about calls."
parent_skill: call-center-intelligence
---

# Operationalize

Precondition: Phase 6 has run and the user has seen the redaction leak table and QA agreement. Scheduling a
pipeline nobody measured puts unmeasured numbers in front of supervisors every morning. If `phases.eval` is not
`done`, say so and stop.

This phase creates long-lived, scheduled objects that spend tokens on every run. The gate states the expected
daily token load from Phase 6's measured tokens per 1,000 calls times expected daily volume, and gets explicit
confirmation of the schedule.

In dbt mode, the transformation layers become models (see `../call-center-intelligence/DBT_MATERIALIZATION.md`)
and the task graph executes the dbt project; delegate scheduling mechanics to `dbt-projects-on-snowflake`. The
semantic view and agent are the same in both modes.

---

## 1. Incremental intake

New calls arrive in the metadata table. A stream gives exactly-once intake:

```sql
CREATE STREAM IF NOT EXISTS CALLS_NEW_STREAM
  ON TABLE <metadata_table>
  APPEND_ONLY = TRUE;
```

If the metadata table is a view or is fully rewritten by the loader, a stream will not work as intended; use a
watermark on `call_start_ts` (with a lag for late-arriving recordings) recorded in a control table instead, and say
why.

Recordings can land after their metadata row. The transcription step selects calls whose file exists on the stage
(join to `DIRECTORY(@stage)`) and leaves the rest for the next run rather than recording a transcription error for
a file that has not arrived. Requires the directory table to be refreshed: auto-refresh on external stages, or an
`ALTER STAGE ... REFRESH` at the start of the run on internal stages.

## 2. Stage procedures

Wrap each phase's statements (as built in Phases 2–5) in one SQL stored procedure per stage. Each procedure
reads the current `run_id` from the intake table the root task writes (passing a subquery as a `CALL` argument
from a task body is not a pattern to rely on). Each procedure:

- processes only calls not yet processed for the current `prompt_version` / `taxonomy_version` /
  `rubric_version` (the `NOT EXISTS` guards already in each phase skill);
- records `LAST_QUERY_ID()` into `RUN_QUERY_LOG` after each model-calling statement, so cost is attributable;
- writes its counts to `PIPELINE_QUALITY_LOG`;
- uses fully qualified names, never an unqualified `USE SCHEMA` switch (best-practices O4).

Skeleton:

```sql
CREATE OR REPLACE PROCEDURE SP_CCI_REDACT()
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
  P_RUN_ID VARCHAR;
BEGIN
  -- The root task stamps the batch; every child reads the same run id.
  SELECT MAX(run_id) INTO :P_RUN_ID FROM CCI.PIPELINE.CCI_INTAKE;
  -- Steps 4b-4e of transcribe-and-redact-calls, with :P_RUN_ID wherever the skill shows :run_id.
  -- ...
  INSERT INTO CCI.PIPELINE.RUN_QUERY_LOG SELECT :P_RUN_ID, 'redact', LAST_QUERY_ID(), CURRENT_TIMESTAMP();
  RETURN 'ok';
END;
$$;
```

Variables inside the body are referenced with a colon prefix (`:P_RUN_ID`).

## 3. Task graph

Session parameters are set **on the task**, because an interactive `ALTER SESSION` does not carry into task
sessions (best-practices O5, R1). `CREATE TASK` accepts session parameters; confirm the parameter is accepted on
the task in this account by `SHOW PARAMETERS IN TASK` after creation.

```sql
CREATE OR REPLACE TASK T_CCI_ROOT
  WAREHOUSE = <warehouse>
  SCHEDULE = 'USING CRON 0 5 * * * <customer_time_zone>'
  AI_SQL_ERROR_HANDLING_USE_FAIL_ON_ERROR = FALSE
  WHEN SYSTEM$STREAM_HAS_DATA('CALLS_NEW_STREAM')
AS
  -- Consume the stream into a durable intake table so children see a stable batch,
  -- and stamp the run id children will use.
  INSERT INTO CCI_INTAKE (call_id, run_id, intake_at)
  SELECT <id_col>, 'run_' || TO_VARCHAR(CURRENT_TIMESTAMP(), 'YYYYMMDDHH24MISS'), CURRENT_TIMESTAMP()
  FROM CALLS_NEW_STREAM;

CREATE OR REPLACE TASK T_CCI_TRANSCRIBE  WAREHOUSE = <warehouse> AI_SQL_ERROR_HANDLING_USE_FAIL_ON_ERROR = FALSE
  AFTER T_CCI_ROOT        AS CALL SP_CCI_TRANSCRIBE();
CREATE OR REPLACE TASK T_CCI_REDACT      WAREHOUSE = <warehouse> AI_SQL_ERROR_HANDLING_USE_FAIL_ON_ERROR = FALSE
  AFTER T_CCI_TRANSCRIBE  AS CALL SP_CCI_REDACT();
CREATE OR REPLACE TASK T_CCI_ROLES       WAREHOUSE = <warehouse>
  AFTER T_CCI_REDACT      AS CALL SP_CCI_ROLES();
CREATE OR REPLACE TASK T_CCI_REASONS     WAREHOUSE = <warehouse>
  AFTER T_CCI_ROLES       AS CALL SP_CCI_REASONS();
CREATE OR REPLACE TASK T_CCI_QA          WAREHOUSE = <warehouse>
  AFTER T_CCI_ROLES       AS CALL SP_CCI_QA();
CREATE OR REPLACE TASK T_CCI_SIGNALS     WAREHOUSE = <warehouse>
  AFTER T_CCI_REASONS     AS CALL SP_CCI_SIGNALS();
CREATE OR REPLACE TASK T_CCI_FACTS       WAREHOUSE = <warehouse>
  AFTER T_CCI_QA, T_CCI_SIGNALS AS CALL SP_CCI_FACTS();
```

Notes:

- Whether a session parameter set on the task is in effect inside an owner's-rights procedure the task calls is
  something to **test, not assume**: run the redact procedure once from the task against a sandbox batch that
  contains one deliberately oversized chunk, and confirm the run completes with that chunk counted as `FAILED`
  rather than the whole statement erroring. If it errors, set the parameter at the start of a caller's-rights
  procedure body instead.
- QA and reasons run in parallel after roles; signals waits for reasons because it screens on them.
- Consider a finalizer task that writes a run summary (counts from `PIPELINE_QUALITY_LOG`) and alerts on any
  redaction failure or leak-check regression; load the `snowflake-tasks` skill for finalizer and failure-handling
  mechanics, and the `alert` / `notification` skills for alerting.
- Set `SUSPEND_TASK_AFTER_NUM_FAILURES` on the root so a broken stage does not retry and re-bill every day.
- Resume children before the root: `ALTER TASK ... RESUME` in reverse dependency order, root last.
- Load the `snowflake-tasks` skill before creating these if anything here is unfamiliar; it owns the details.

## 4. CALL_FACTS — one row per call, latest outputs

```sql
CREATE OR REPLACE TABLE CALL_FACTS AS
WITH r AS (SELECT * FROM CALL_REASONS   QUALIFY ROW_NUMBER() OVER (PARTITION BY call_id ORDER BY classified_at DESC) = 1),
     o AS (SELECT * FROM CALL_OUTCOMES  QUALIFY ROW_NUMBER() OVER (PARTITION BY call_id ORDER BY extracted_at DESC) = 1),
     s AS (SELECT * FROM CALL_SENTIMENT QUALIFY ROW_NUMBER() OVER (PARTITION BY call_id ORDER BY scored_at DESC) = 1),
     q AS (SELECT * FROM QA_CALL_SCORES WHERE rubric_version = :current_rubric_version
           QUALIFY ROW_NUMBER() OVER (PARTITION BY call_id ORDER BY run_id DESC) = 1),
     g AS (SELECT * FROM CALL_SIGNALS   QUALIFY ROW_NUMBER() OVER (PARTITION BY call_id ORDER BY run_id DESC) = 1)
SELECT c.call_id, c.customer_id, c.agent_id, c.queue_name, c.call_start_ts,
       DATE_TRUNC('day', c.call_start_ts)    AS call_date,
       c.handle_seconds, c.hold_seconds, c.was_transferred, c.disposition_code, c.source_route,
       r.primary_reason, r.secondary_reasons, r.disposition_agrees, r.taxonomy_version,
       rp.is_repeat, rp.generated_repeat, rp.repeat_window_days,
       o.resolution_status, o.references_prior_contact, o.supervisor_requested, o.retention_routing,
       s.opening_overall, s.closing_overall, s.sentiment_shift,
       q.qa_score_pct, q.criteria_scored, q.rubric_version,
       g.cancel_intent, g.cancel_reason, g.save_offer_made, g.save_offer_type, g.save_outcome, g.save_gap,
       g.buying_signal, g.upsell_offered, g.upsell_outcome, g.unworked_buying_signal, g.competitor,
       t.self_service_fit
FROM CALLS_IN_SCOPE c
LEFT JOIN r  ON r.call_id = c.call_id
LEFT JOIN CALL_REPEATS rp ON rp.call_id = c.call_id
LEFT JOIN o  ON o.call_id = c.call_id
LEFT JOIN s  ON s.call_id = c.call_id
LEFT JOIN q  ON q.call_id = c.call_id
LEFT JOIN g  ON g.call_id = c.call_id
LEFT JOIN CONTACT_TAXONOMY t ON t.label = r.primary_reason AND t.taxonomy_version = r.taxonomy_version
WHERE c.source_route NOT LIKE 'EXCLUDED%';
```

`SP_CCI_FACTS` maintains this with `MERGE` on `call_id` (or `INSERT OVERWRITE`), **not** `CREATE OR REPLACE`
once dynamic tables read it: replacing a dynamic table's base table breaks or reinitializes the dynamic table. The
`CREATE` above is for the first build only. It calls no model, so a full overwrite is cheap at moderate volumes; switch to
a `MERGE` of new and changed calls when volume grows. Every analytic object downstream reads
`CALL_FACTS`, never the per-stage tables.

`CALL_FACTS` contains no transcript text. That is deliberate: it is what the semantic view and the agent read.

## 5. Rollups — dynamic tables over SQL only

Dynamic tables are right for these: no AI functions, deterministic, incremental-friendly (best-practices O3).

```sql
CREATE OR REPLACE DYNAMIC TABLE DT_DAILY_CONTACT_METRICS
  TARGET_LAG = '1 hour'
  WAREHOUSE = <warehouse>
AS
SELECT call_date, queue_name, primary_reason,
       COUNT(*)                                     AS calls,
       SUM(handle_seconds)                          AS handle_seconds,
       COUNT_IF(generated_repeat)                   AS calls_followed_by_repeat,
       COUNT_IF(is_repeat)                          AS repeat_calls,
       COUNT_IF(was_transferred)                    AS transfers,
       COUNT_IF(supervisor_requested = 'YES')       AS supervisor_requests,
       COUNT_IF(resolution_status = 'UNRESOLVED')   AS unresolved,
       COUNT_IF(cancel_intent)                      AS cancel_intents,
       COUNT_IF(save_gap)                           AS save_gaps,
       COUNT_IF(save_outcome = 'ACCEPTED')          AS saves,
       COUNT_IF(unworked_buying_signal)             AS unworked_buying_signals,
       COUNT_IF(upsell_outcome = 'ACCEPTED')        AS upsells_accepted,
       COUNT_IF(sentiment_shift = 'DETERIORATED')   AS deteriorated_calls
FROM CALL_FACTS
GROUP BY 1, 2, 3;

CREATE OR REPLACE DYNAMIC TABLE DT_AGENT_QA_WEEKLY
  TARGET_LAG = '1 day'
  WAREHOUSE = <warehouse>
AS
SELECT DATE_TRUNC('week', call_date) AS week, agent_id, rubric_version,
       COUNT_IF(qa_score_pct IS NOT NULL)          AS scored_calls,
       ROUND(AVG(qa_score_pct), 1)                 AS avg_qa_score_pct,
       COUNT_IF(save_gap)                          AS save_gaps,
       COUNT_IF(generated_repeat)                  AS calls_followed_by_repeat,
       COUNT_IF(qa_score_pct IS NOT NULL) >= :min_calls_for_agent_score AS meets_min_calls
FROM CALL_FACTS
GROUP BY 1, 2, 3;
```

Load the `dynamic-tables` skill and confirm both refresh incrementally before relying on the lag.

Agent rollups carry `meets_min_calls`; any surface that shows an agent's average must filter on it. Ask the customer
for `min_calls_for_agent_score` and record it in `definitions`; do not invent one. Per-criterion agent rollups come
from `QA_CRITERION_SCORES` with the same threshold.

## 6. Driver narratives — weekly, from derived text

Counts come from SQL; narratives explain them (best-practices G1, G2, G3). Built by a weekly task, not a dynamic
table, because they call a model.

```sql
CREATE TABLE IF NOT EXISTS DRIVER_NARRATIVES (
    week DATE, scope VARCHAR, scope_value VARCHAR, calls_in_scope INT,
    narrative VARCHAR, input_kind VARCHAR, generated_at TIMESTAMP_LTZ, run_id VARCHAR
);

-- Why do calls in each reason generate repeat contacts?
INSERT INTO DRIVER_NARRATIVES
SELECT DATE_TRUNC('week', f.call_date), 'repeat_driver', f.primary_reason, COUNT(*),
       AI_AGG(
         'Resolution: ' || f.resolution_status || '. Agent coaching note: ' || q.coaching_note
         || '. Customer opening: ' || LEFT(ri.opening_text, 600),
         'These are redacted summaries of customer service calls that were followed by another call from the same '
         || 'customer within a few days. Identify the most common reasons these calls did not resolve the issue, '
         || 'in order of how often they appear, and what agents or processes could change. Write for a contact center '
         || 'operations manager. Do not include names, numbers, or any personal details. Do not state counts or percentages.'),
       'coaching_note+opening', CURRENT_TIMESTAMP(), :run_id
FROM CALL_FACTS f
JOIN (SELECT call_id, resp:structured_output[0]:raw_message:coaching_note::STRING AS coaching_note
      FROM QA_RAW QUALIFY ROW_NUMBER() OVER (PARTITION BY call_id ORDER BY scored_at DESC) = 1) q
  ON q.call_id = f.call_id
JOIN REASON_INPUT ri ON ri.call_id = f.call_id
WHERE f.generated_repeat
  AND f.call_date >= DATEADD(week, -1, DATE_TRUNC('week', CURRENT_DATE()))
  AND f.call_date <  DATE_TRUNC('week', CURRENT_DATE())
GROUP BY 1, 2, 3
HAVING COUNT(*) >= :min_calls_for_narrative;
```

Do the same for escalations (`supervisor_requested = 'YES'`), save gaps (`cancel_reason` plus opening), and
deteriorated sentiment. `AI_SUMMARIZE_AGG` is acceptable for a general "what happened in this queue this week"
summary; `AI_AGG` with an instruction is better for drivers.

The instruction forbids counts on purpose; `calls_in_scope` is stored next to the narrative from SQL. Phase 6's leak
check should be extended to `DRIVER_NARRATIVES.narrative` once these exist.

## 7. Semantic view

Delegate authoring, validation and verified queries to the **`agent-studio`** skill. The shape:

```sql
CREATE OR REPLACE SEMANTIC VIEW SV_CALL_CENTER
  TABLES (
    calls AS CCI.PIPELINE.CALL_FACTS PRIMARY KEY (call_id)
      WITH SYNONYMS ('contacts', 'interactions')
      COMMENT = 'One row per in-scope customer service call with AI-derived reason, outcome, QA and signals',
    taxonomy AS CCI.PIPELINE.CONTACT_TAXONOMY PRIMARY KEY (taxonomy_version, label)
      COMMENT = 'Contact reason labels and descriptions'
  )
  RELATIONSHIPS (
    calls_to_reason AS calls (taxonomy_version, primary_reason) REFERENCES taxonomy
  )
  DIMENSIONS (
    calls.call_date        AS call_date        COMMENT = 'Date the call started',
    calls.queue_name       AS queue_name       COMMENT = 'Queue the call was routed to',
    calls.agent_id         AS agent_id         COMMENT = 'Agent identifier',
    calls.primary_reason   AS primary_reason   WITH SYNONYMS ('contact reason', 'call reason', 'call driver')
                                               COMMENT = 'AI-classified primary contact reason from the call opening',
    calls.disposition_code AS disposition_code COMMENT = 'Agent-selected disposition code; may disagree with primary_reason',
    calls.resolution_status AS resolution_status COMMENT = 'RESOLVED, PARTIAL, UNRESOLVED, or UNPARSED',
    calls.sentiment_shift  AS sentiment_shift  COMMENT = 'RECOVERED, DETERIORATED, STABLE, or MIXED from opening to closing customer sentiment',
    calls.cancel_reason    AS cancel_reason    COMMENT = 'Customer-stated reason for wanting to cancel, where stated',
    calls.save_outcome     AS save_outcome     COMMENT = 'ACCEPTED, DECLINED, UNDECIDED, NOT_OFFERED, or NOT_APPLICABLE',
    calls.self_service_fit AS self_service_fit COMMENT = 'Customer-confirmed fit of the reason for self-service: HIGH, PARTIAL, LOW',
    taxonomy.description   AS reason_description COMMENT = 'Description of the contact reason'
  )
  METRICS (
    calls.call_count            AS COUNT(calls.call_id)                          COMMENT = 'Number of calls',
    calls.total_handle_hours    AS SUM(calls.handle_seconds) / 3600              COMMENT = 'Handle time in hours from the system of record',
    calls.avg_handle_seconds    AS AVG(calls.handle_seconds)                     COMMENT = 'Average handle time in seconds',
    calls.repeat_generating_calls AS COUNT_IF(calls.generated_repeat)            COMMENT = 'Calls followed by another call from the same customer within the repeat window',
    calls.repeat_rate           AS COUNT_IF(calls.generated_repeat) / NULLIF(COUNT(calls.call_id), 0) COMMENT = 'Share of calls followed by a repeat contact',
    calls.supervisor_requests   AS COUNT_IF(calls.supervisor_requested = 'YES')  COMMENT = 'Calls where the customer asked for a supervisor',
    calls.transfers             AS COUNT_IF(calls.was_transferred)               COMMENT = 'Calls transferred, from the system of record',
    calls.cancel_intents        AS COUNT_IF(calls.cancel_intent)                 COMMENT = 'Calls where the customer stated an intent to cancel or downgrade',
    calls.save_gaps             AS COUNT_IF(calls.save_gap)                      COMMENT = 'Cancel-intent calls where no save offer was made by the agent',
    calls.saves_accepted        AS COUNT_IF(calls.save_outcome = 'ACCEPTED')     COMMENT = 'Save offers accepted on the call',
    calls.unworked_buying_signals AS COUNT_IF(calls.unworked_buying_signal)      COMMENT = 'Calls with a customer buying signal and no agent offer',
    calls.avg_qa_score_pct      AS AVG(calls.qa_score_pct)                       COMMENT = 'Average automated QA score, percent of maximum over applicable criteria; coaching signal with measured agreement'
  )
  COMMENT = 'Call center intelligence: contact reasons, repeats, escalations, QA and retention signals'
  AI_SQL_GENERATION 'Counts and rates must come from metrics. QA averages by agent must only be shown when the agent has at least the configured minimum number of scored calls. State the repeat window when reporting repeats.';
```

Validate with `agent-studio`: two or three verified queries that match base-table results exactly (for example,
calls by reason last week, save gaps by cancel reason, repeat rate by queue).

## 8. Cortex Agent for CoWork

Also delegate to `agent-studio`. Specification essentials:

```sql
CREATE OR REPLACE AGENT CCI_CALL_INSIGHTS_AGENT
  COMMENT = 'Answers questions about why customers call, repeats, escalations, QA and retention signals'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto
  instructions:
    response: "Answer with numbers from the call center semantic view. Quote counts and rates only from tool results. When you use a driver narrative, present it as qualitative context and never take a number from it. When showing agent QA scores, say they are automated coaching signals with measured agreement against human reviewers, and only show agents meeting the minimum call threshold. State the repeat-contact window when discussing repeats. Never display transcript text."
    orchestration: "Use CallMetrics for any count, rate, trend, ranking or comparison. Use DriverNarratives only to explain why a metric moved."
    sample_questions:
      - question: "What were the top contact reasons last week and how did they change?"
      - question: "Which reasons generate the most repeat contacts?"
      - question: "How many customers said they wanted to cancel and were not offered a save?"
      - question: "Why are customers asking for supervisors in the Tech queue?"
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "CallMetrics"
        description: "Contact reasons, repeats, escalations, sentiment shift, QA scores and save/upsell signals per call"
    - tool_spec:
        type: "cortex_search"
        name: "DriverNarratives"
        description: "Weekly qualitative summaries of why calls repeat, escalate, deteriorate or end in cancellation"
  tool_resources:
    CallMetrics:
      semantic_view: "CCI.PIPELINE.SV_CALL_CENTER"
    DriverNarratives:
      search_service: "CCI.PIPELINE.CSS_DRIVER_NARRATIVES"
      max_results: "5"
  $$;
```

The narrative search service:

```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE CSS_DRIVER_NARRATIVES
  ON narrative
  ATTRIBUTES scope, scope_value, week
  WAREHOUSE = <warehouse>
  TARGET_LAG = '1 day'
  AS SELECT narrative, scope, scope_value, week, calls_in_scope FROM DRIVER_NARRATIVES;
```

Do not index transcripts for the agent. If the customer wants "find calls like this one", build a separate search
service over redacted segments with its own grant decision, reviewed against the preflight PII posture.

## 9. Grants

| Object | Who |
|---|---|
| `TRANSCRIBE_RAW`, `CALL_SEGMENTS_RAW`, `REDACT_CHUNKS` | pipeline role only |
| `CALL_SEGMENTS_REDACTED` | pipeline role; analysts by explicit decision |
| `QA_*`, `DT_AGENT_QA_WEEKLY` | QA team and supervisors per preflight decision; HR-sensitive |
| `CALL_FACTS`, `DT_DAILY_CONTACT_METRICS`, `SV_CALL_CENTER`, `DRIVER_NARRATIVES` | operations, product, CX |
| `CCI_CALL_INSIGHTS_AGENT` | the CoWork audience; the agent's role must not reach raw tables |

If agent-level QA should not be visible to the general CoWork audience, apply a row access policy on `CALL_FACTS`
for `qa_score_pct` and `agent_id`, or publish two semantic views. Load the `data-governance` skill for the policy.

## Verification at the gate

```sql
SHOW TASKS LIKE 'T_CCI%';
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'T_CCI_ROOT', RESULT_LIMIT => 5));

SELECT SYSTEM$STREAM_HAS_DATA('CALLS_NEW_STREAM');

SHOW DYNAMIC TABLES LIKE 'DT_%';

-- Semantic view answers a reference question that matches the base table exactly.
SELECT * FROM SEMANTIC_VIEW(SV_CALL_CENTER
    DIMENSIONS calls.primary_reason
    METRICS calls.call_count, calls.repeat_rate)
ORDER BY call_count DESC;

SELECT primary_reason, COUNT(*), COUNT_IF(generated_repeat) / NULLIF(COUNT(*), 0)
FROM CALL_FACTS GROUP BY 1 ORDER BY 2 DESC;
```

Then ask the agent two sample questions and show the answers next to the SQL results.

Record every task, stream, procedure, dynamic table, semantic view, search service and agent in `created_objects`,
and set `phases.operationalize: done`. Mention to the user that the weekly driver narratives and the evaluation
re-run on a refreshed labeled sample are natural candidates for a scheduled `cortex automation`.
