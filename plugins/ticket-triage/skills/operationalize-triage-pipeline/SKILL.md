---
name: operationalize-triage-pipeline
description: "Turn a measured triage build into a running pipeline and a business-facing interface: a production run identity, an incremental stream-and-task graph (or dynamic tables, with the refresh-mode check that prevents silent full re-inference), incremental duplicate attachment to existing roots, interactive versus batch retrieval for small increments, a current-state view, a semantic view with routing, priority, deflection and linking metrics, a Cortex Agent for CoWork combining Cortex Analyst over the semantic view with Cortex Search over the knowledge store, and ongoing monitoring for silent nulls, drift and regression. Phase 8 of the ticket-triage build. Triggers: schedule triage, productionize, stream and task, dynamic table, semantic view for tickets, Cortex Agent for service desk, CoWork agent, monitor triage."
parent_skill: ticket-triage
---

# Operationalize the triage pipeline

Only after phase 7 has measured the build and the user has accepted the numbers. This phase makes the same
logic run on new tickets as they land, and puts a governed interface over the output for service-desk
managers and analysts.

Read best-practices rules 24 and 25 before creating anything. Every object here is listed at the gate and
recorded in `created_objects`.

## What gets created

| Object | Type | Purpose |
|---|---|---|
| `TICKETS_STREAM` | stream on the source ticket table | new and changed tickets |
| `TRIAGE_QUEUE` | table | ticket ids pending triage, consumed from the stream |
| `TRIAGE_PROCESS_BATCH` | stored procedure | runs phases 4-6 for queued tickets under the production run id |
| `TRIAGE_ROOT_TASK` and child tasks | tasks | schedule and orchestration |
| `TRIAGE_CURRENT` | view | the production run's output, one row per ticket |
| `TICKET_TRIAGE_SV` | semantic view | metrics and dimensions for Cortex Analyst and BI |
| `TICKET_TRIAGE_AGENT` | Cortex Agent | CoWork entry point |
| `TRIAGE_HEALTH_LOG` | table | per-batch silent-failure and drift counters |

## Step 1 — A production run identity

Experiments use a new `run_id` per invocation. Production is different: new tickets append under **one**
identity per production model version, so the current state is one `run_id`, and promoting a new prompt or
taxonomy is a deliberate change of that identity.

- Set `experiment.run_id: prod_<experiment_id>` for the accepted experiment, keep its `prompt_hash` and
  `taxonomy_version`, and record it in `operations`.
- Changing anything (prompt, labels, model, thresholds) means a new experiment, phase 7 on the holdout, and
  only then a new production run id. Never edit the production prompt in place.

## Step 2 — Choose the mechanism

| Option | Use when | Watch for |
|---|---|---|
| **Stream + tasks** (default) | multi-step logic with `UPDATE`s, fallback passes and retrieval, as built in phases 4-6 | idempotency, one stream per consumer |
| **Dynamic tables** | the logic can be expressed as declarative `SELECT`s and the team prefers declarative refresh | a definition that is not incremental-eligible silently becomes **full** refresh, re-running every AI call on every refresh (rule 24) |

Ask with `ask_user_question`; record `operations.mode`. Cortex AI functions in the `SELECT` list are supported
for incremental dynamic-table refresh (per the supported-queries docs), so normalization and first-pass
classification can be dynamic tables. The fallback, retrieval and suggestion steps are multi-pass and fit tasks
better.

### If dynamic tables: verify the refresh mode you actually got

```sql
CREATE DYNAMIC TABLE IF NOT EXISTS <db>.<schema>.TICKETS_NORMALIZED_DT
  TARGET_LAG = '15 minutes'
  WAREHOUSE = <warehouse>
  REFRESH_MODE = INCREMENTAL
AS
SELECT ...;   -- the phase-4 normalization SELECT, deterministic functions only

SHOW DYNAMIC TABLES LIKE 'TICKETS_NORMALIZED_DT' IN SCHEMA <db>.<schema>;
SELECT "name", "refresh_mode", "refresh_mode_reason"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));
```

Specifying `REFRESH_MODE = INCREMENTAL` makes creation fail rather than silently fall back when the definition
is not eligible — preferable to discovering a full refresh on the bill. Check the output columns of `SHOW
DYNAMIC TABLES` in this account before relying on the names above. Re-initializing (`CREATE OR REPLACE`)
reprocesses every row; gate it like any other full-table AI run.

## Step 3 — Stream, queue and the batch procedure

```sql
CREATE STREAM IF NOT EXISTS <db>.<schema>.TICKETS_STREAM
  ON TABLE <source_table>
  APPEND_ONLY = FALSE;   -- tickets are updated (comments, reassignment); see note below

CREATE TABLE IF NOT EXISTS <db>.<schema>.TRIAGE_QUEUE (
    ticket_id   VARCHAR,
    enqueued_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    processed_at TIMESTAMP_NTZ
);
```

**Which changes re-trigger triage?** Triage is a first-assignment decision. Re-classifying a ticket every time an
agent adds a work note would both waste credits and feed post-assignment text back into the classifier (rule 1).
Enqueue only **inserts**, plus updates that happen **before first assignment** (a requester adding detail):

```sql
-- Root task body: consume the stream into the queue in one committed DML.
INSERT INTO <db>.<schema>.TRIAGE_QUEUE (ticket_id)
SELECT DISTINCT s.<id_col>
FROM <db>.<schema>.TICKETS_STREAM s
WHERE s.METADATA$ACTION = 'INSERT'
  AND (NOT s.METADATA$ISUPDATE OR s.<first_assigned_at_col> IS NULL)
  AND NOT EXISTS (SELECT 1 FROM <db>.<schema>.TRIAGE_QUEUE q
                  WHERE q.ticket_id = s.<id_col> AND q.processed_at IS NULL);
```

The batch procedure runs the phase 4-6 statements restricted to queued tickets. Those statements are already
idempotent (`NOT EXISTS` on `run_id` + `ticket_id`), which is what makes task retry safe. Skeleton:

```sql
CREATE OR REPLACE PROCEDURE <db>.<schema>.TRIAGE_PROCESS_BATCH(P_RUN_ID VARCHAR)
RETURNS VARCHAR
LANGUAGE SQL
EXECUTE AS OWNER
AS
$$
DECLARE
    n_queued INTEGER;
BEGIN
    EXECUTE IMMEDIATE 'ALTER SESSION SET QUERY_TAG = ''' || :P_RUN_ID || '''';

    SELECT COUNT(*) INTO :n_queued FROM <db>.<schema>.TRIAGE_QUEUE WHERE processed_at IS NULL;
    IF (:n_queued = 0) THEN
        RETURN 'nothing queued';
    END IF;

    -- 1. Normalize queued tickets (phase 4, step 1), restricted with
    --    WHERE ticket_id IN (SELECT ticket_id FROM TRIAGE_QUEUE WHERE processed_at IS NULL)
    -- 2. Classify, unpack, priority (phase 4, steps 2-3), with run_id = :P_RUN_ID
    -- 3. Entities and canonical product (phase 4, step 4)
    -- 4. Confidence band, fallback on LOW, UNCLASSIFIED marking (phase 4, step 5)
    -- 5. Embed and attach to existing roots (Step 4 below)
    -- 6. Known-issue links, priority raises (phase 5, steps 4-5)
    -- 7. Gate, retrieval, suggestion, validation (phase 6, steps 1-4)
    -- 8. Append to TICKET_TRIAGE_OUTPUT (phase 6, step 5)
    -- 9. Health counters (Step 6 below)

    UPDATE <db>.<schema>.TRIAGE_QUEUE SET processed_at = CURRENT_TIMESTAMP()
    WHERE processed_at IS NULL;

    RETURN 'processed ' || :n_queued;
END;
$$;
```

Fill each numbered step with the statement from its phase skill, verbatim, with `:run_id` replaced by
`:P_RUN_ID` and the queue restriction added. Inside a SQL procedure, variables and parameters need the colon
prefix in SQL statements; without it they are read as column names.

```sql
CREATE TASK IF NOT EXISTS <db>.<schema>.TRIAGE_ROOT_TASK
  WAREHOUSE = <warehouse>
  SCHEDULE = '15 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('<db>.<schema>.TICKETS_STREAM')
AS
  INSERT INTO <db>.<schema>.TRIAGE_QUEUE (ticket_id)
  SELECT DISTINCT s.<id_col>
  FROM <db>.<schema>.TICKETS_STREAM s
  WHERE s.METADATA$ACTION = 'INSERT'
    AND (NOT s.METADATA$ISUPDATE OR s.<first_assigned_at_col> IS NULL);

CREATE TASK IF NOT EXISTS <db>.<schema>.TRIAGE_PROCESS_TASK
  WAREHOUSE = <warehouse>
  AFTER <db>.<schema>.TRIAGE_ROOT_TASK
AS
  CALL <db>.<schema>.TRIAGE_PROCESS_BATCH('<production_run_id>');

-- Children resume before the root.
ALTER TASK <db>.<schema>.TRIAGE_PROCESS_TASK RESUME;
ALTER TASK <db>.<schema>.TRIAGE_ROOT_TASK RESUME;
```

Load the **`snowflake-tasks`** skill for scheduling, failure handling (`SUSPEND_TASK_AFTER_NUM_FAILURES`),
serverless versus warehouse tasks and task history; do not reproduce it here. The schedule is a business choice
— how long may a new ticket wait for a routing suggestion? — and costs nothing extra when the stream is empty,
because of the `WHEN` clause.

### Retrieval for small increments

A 15-minute batch is usually far below the ~2,000-query level where `CORTEX_SEARCH_BATCH` beats the interactive
API (per its docs), and batch jobs carry startup latency. For production increments, either accept the latency
(it is a background job), or replace phase 6 step 2 in the procedure with a Python stored procedure that calls
the interactive Cortex Search API per ticket. Measure both on a day's volume; keep batch for backfills.

## Step 4 — Incremental duplicate attachment

In production, a new ticket attaches to an **existing root** from the current output, which is the exact
anchored algorithm the backfill approximated:

```sql
-- For each newly classified ticket: the earliest root in the window, same
-- predicted category, directly similar above threshold.
INSERT INTO <db>.<schema>.DUPLICATE_LINKS
    (run_id, ticket_id, parent_ticket_id, cluster_id, similarity_to_parent, is_root,
     threshold_used, window_hours_used)
WITH new_t AS (
    SELECT c.ticket_id, c.pred_category, n.created_at, e.embedding
    FROM <db>.<schema>.TICKET_CLASSIFICATION c
    JOIN <db>.<schema>.TICKETS_NORMALIZED n ON n.ticket_id = c.ticket_id
    JOIN <db>.<schema>.TICKET_EMBEDDINGS e ON e.ticket_id = c.ticket_id AND e.embed_model = '<embed_model>'
    WHERE c.run_id = :P_RUN_ID
      AND c.ticket_id IN (SELECT ticket_id FROM <db>.<schema>.TRIAGE_QUEUE WHERE processed_at IS NULL)
),
roots AS (
    SELECT d.ticket_id, c.pred_category, n.created_at, e.embedding
    FROM <db>.<schema>.DUPLICATE_LINKS d
    JOIN <db>.<schema>.TICKET_CLASSIFICATION c ON c.run_id = d.run_id AND c.ticket_id = d.ticket_id
    JOIN <db>.<schema>.TICKETS_NORMALIZED n ON n.ticket_id = d.ticket_id
    JOIN <db>.<schema>.TICKET_EMBEDDINGS e ON e.ticket_id = d.ticket_id AND e.embed_model = '<embed_model>'
    WHERE d.run_id = :P_RUN_ID AND d.is_root
      AND n.created_at >= DATEADD(HOUR, -:window_hours, CURRENT_TIMESTAMP())
),
best AS (
    SELECT t.ticket_id,
           MIN_BY(r.ticket_id, r.created_at) AS parent_ticket_id,
           MIN_BY(VECTOR_COSINE_SIMILARITY(t.embedding, r.embedding), r.created_at) AS sim
    FROM new_t t
    JOIN roots r
      ON r.pred_category = t.pred_category
     AND r.created_at < t.created_at
     AND r.created_at >= DATEADD(HOUR, -:window_hours, t.created_at)
     AND VECTOR_COSINE_SIMILARITY(t.embedding, r.embedding) >= :dup_threshold
    GROUP BY t.ticket_id
)
SELECT :P_RUN_ID, t.ticket_id, b.parent_ticket_id, COALESCE(b.parent_ticket_id, t.ticket_id),
       b.sim, b.parent_ticket_id IS NULL, :dup_threshold, :window_hours
FROM new_t t
LEFT JOIN best b ON b.ticket_id = t.ticket_id
WHERE NOT EXISTS (SELECT 1 FROM <db>.<schema>.DUPLICATE_LINKS d
                  WHERE d.run_id = :P_RUN_ID AND d.ticket_id = t.ticket_id);
```

Then recompute `cluster_size` for affected clusters and apply the priority-raise rule. A cluster that crosses
`raise_cluster_size` raises priority for **existing** members too; that is a change to tickets already shown
to agents — decide with the customer whether the raise applies retroactively, and record it.

## Step 5 — Current view, semantic view, agent

```sql
CREATE OR REPLACE VIEW <db>.<schema>.TRIAGE_CURRENT AS
SELECT o.*
FROM <db>.<schema>.TICKET_TRIAGE_OUTPUT o
WHERE o.run_id = '<production_run_id>';
```

A view over a **table** with no AI calls is safe to query repeatedly. Never point a semantic view or dashboard
at anything that calls an AI function at query time.

The semantic view gives Cortex Analyst governed definitions for the questions managers ask. Load the
**`agent-studio`** skill for semantic view authoring, validation and verified queries; the definition below is
the content it should start from.

```sql
CREATE OR REPLACE SEMANTIC VIEW <db>.<schema>.TICKET_TRIAGE_SV
  TABLES (
    triage AS <db>.<schema>.TRIAGE_CURRENT
      PRIMARY KEY (ticket_id)
      WITH SYNONYMS ('tickets', 'incidents', 'cases')
      COMMENT = 'AI triage output for support and IT tickets, production run only'
  )
  FACTS (
    triage.deflect_flag   AS IFF(is_deflection_candidate, 1, 0),
    triage.suggested_flag AS IFF(is_suggested, 1, 0),
    triage.ki_flag        AS IFF(known_issue_id IS NOT NULL, 1, 0),
    triage.dup_flag       AS IFF(parent_ticket_id IS NOT NULL, 1, 0),
    triage.unclass_flag   AS IFF(pred_queue = 'UNCLASSIFIED', 1, 0),
    triage.high_conf_flag AS IFF(confidence_band = 'HIGH', 1, 0)
  )
  DIMENSIONS (
    triage.queue          AS pred_queue          WITH SYNONYMS = ('assignment group', 'resolver group', 'team')
                                                 COMMENT = 'Predicted first resolver queue',
    triage.category       AS pred_category       COMMENT = 'Predicted category',
    triage.priority       AS pred_priority       COMMENT = 'Priority derived from impact x urgency matrix',
    triage.impact         AS pred_impact,
    triage.urgency        AS pred_urgency,
    triage.confidence     AS confidence_band     COMMENT = 'Derived band; see evaluation reliability table',
    triage.contact_channel AS channel,
    triage.product_name   AS product,
    triage.known_issue    AS known_issue_id,
    triage.incident_cluster AS cluster_id        COMMENT = 'Root ticket of the duplicate cluster',
    triage.created_date   AS DATE(created_at)    COMMENT = 'Date the ticket was created',
    triage.created_week   AS DATE_TRUNC('WEEK', created_at)
  )
  METRICS (
    triage.ticket_count         AS COUNT(ticket_id)            COMMENT = 'Number of tickets',
    triage.deflection_candidates AS SUM(triage.deflect_flag)   COMMENT = 'Tickets flagged as deflectable with a cited self-service source',
    triage.deflection_rate      AS DIV0(SUM(triage.deflect_flag), COUNT(ticket_id))
                                COMMENT = 'Share of tickets flagged deflectable. Precision is measured separately in evaluation.',
    triage.known_issue_tickets  AS SUM(triage.ki_flag),
    triage.duplicate_tickets    AS SUM(triage.dup_flag)        COMMENT = 'Tickets attached to an earlier root ticket',
    triage.unclassified_rate    AS DIV0(SUM(triage.unclass_flag), COUNT(ticket_id)),
    triage.high_confidence_rate AS DIV0(SUM(triage.high_conf_flag), COUNT(ticket_id)),
    triage.suggestion_coverage  AS DIV0(SUM(triage.suggested_flag), COUNT(ticket_id))
  )
  COMMENT = 'Ticket triage: routing, priority, linking and deflection signals'
  AI_SQL_GENERATION 'Always filter to the production run via the TRIAGE_CURRENT table. Deflection rate is a share of tickets flagged, not a measured success rate; never describe it as tickets deflected.';
```

Validate with the `agent-studio` skill before use, and add verified queries for the questions the customer
actually asks ("which queues get the most P1s this week", "top known issues by ticket count", "how many
deflection candidates did KB article X generate").

Then the agent. Two tools: Cortex Analyst over the semantic view for numbers, Cortex Search over the knowledge
store for "what is the fix for…". The instructions carry the evaluation caveats so the agent does not overstate.

```sql
CREATE OR REPLACE AGENT <db>.<schema>.TICKET_TRIAGE_AGENT
  COMMENT = 'Service desk triage insights: routing, priority, duplicates, known issues, deflection'
  PROFILE = '{"display_name": "Ticket Triage Insights", "color": "blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto
  orchestration:
    budget:
      seconds: 60
      tokens: 16000
  instructions:
    response: >
      Answer concisely with numbers from the triage semantic view. Always state the date range.
      Deflection figures are candidates flagged by the pipeline, not confirmed deflections; say so.
      Routing and deflection accuracy come from the evaluation report, not from these counts.
      Do not quote ticket text or requester details; refer to tickets by id.
    orchestration: >
      Use TriageAnalyst for any count, rate, trend or breakdown by queue, category, priority,
      product, known issue or cluster. Use ResolutionSearch only to find knowledge-base guidance
      for a described problem, and cite the article_id returned.
    sample_questions:
      - question: "Which queues received the most P1 and P2 tickets last week?"
      - question: "What are the top known issues by ticket volume this month?"
      - question: "How many deflection candidates came from each KB article?"
      - question: "Which incident clusters had more than ten tickets in the last 7 days?"
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "TriageAnalyst"
        description: "Counts, rates and trends over AI triage output for support and IT tickets"
    - tool_spec:
        type: "cortex_search"
        name: "ResolutionSearch"
        description: "Searches published knowledge-base articles and redacted resolution notes for fixes"
  tool_resources:
    TriageAnalyst:
      semantic_view: "<db>.<schema>.TICKET_TRIAGE_SV"
      execution_environment:
        type: "warehouse"
        warehouse: "<warehouse>"
    ResolutionSearch:
      search_service: "<db>.<schema>.TRIAGE_KB_SEARCH"
      max_results: "5"
      id_column: "chunk_id"
      title_column: "title"
      filter:
        "@eq":
          source_type: "KB"
  $$;
```

The `ResolutionSearch` filter restricts the agent to published KB chunks by default; resolved-ticket notes are
redacted but still derived from tickets, and whether a broad CoWork audience should search them is the
customer's decision from preflight. The `execution_environment` block follows the agent REST specification
for Analyst tools; confirm the exact key names with the **`agent-studio`** skill, which owns agent
configuration, testing and evaluation, before creating the agent.

Grant usage deliberately: the agent's audience (service-desk managers) is usually wider than the audience for
ticket text. The semantic view exposes no free text by design; keep it that way.

## Step 6 — Monitoring

Each batch appends health counters; alert on the ones that indicate silent failure or drift:

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.TRIAGE_HEALTH_LOG (
    batch_at            TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    run_id              VARCHAR,
    tickets             NUMBER,
    classify_errors     NUMBER,
    fallback_share      FLOAT,
    unclassified_share  FLOAT,
    gate_nulls          NUMBER,
    uncited_suggestions NUMBER,
    top_queue_share     FLOAT
);

INSERT INTO <db>.<schema>.TRIAGE_HEALTH_LOG
    (run_id, tickets, classify_errors, fallback_share, unclassified_share, gate_nulls,
     uncited_suggestions, top_queue_share)
SELECT :P_RUN_ID,
       COUNT(*),
       COUNT_IF(c.raw_category:error IS NOT NULL),
       DIV0(COUNT_IF(c.fallback_used), COUNT(*)),
       DIV0(COUNT_IF(c.pred_queue = 'UNCLASSIFIED'), COUNT(*)),
       (SELECT COUNT(*) FROM <db>.<schema>.DEFLECTION_GATE g
        WHERE g.run_id = :P_RUN_ID AND g.excluded_reason IS NULL AND g.answerable IS NULL
          AND g.ticket_id IN (SELECT ticket_id FROM <db>.<schema>.TRIAGE_QUEUE WHERE processed_at IS NULL)),
       (SELECT COUNT(*) FROM <db>.<schema>.RESOLUTION_SUGGESTIONS s
        WHERE s.run_id = :P_RUN_ID AND s.is_suggested AND (ARRAY_SIZE(s.citations) = 0 OR s.citation_invalid)),
       (SELECT MAX(share) FROM (SELECT DIV0(COUNT(*), SUM(COUNT(*)) OVER ()) AS share
                                FROM <db>.<schema>.TICKET_CLASSIFICATION
                                WHERE run_id = :P_RUN_ID
                                  AND ticket_id IN (SELECT ticket_id FROM <db>.<schema>.TRIAGE_QUEUE WHERE processed_at IS NULL)
                                GROUP BY pred_queue))
FROM <db>.<schema>.TICKET_CLASSIFICATION c
WHERE c.run_id = :P_RUN_ID
  AND c.ticket_id IN (SELECT ticket_id FROM <db>.<schema>.TRIAGE_QUEUE WHERE processed_at IS NULL);
```

Alert conditions, set with the customer and implemented with the **`alert`** skill:

- `classify_errors` or `gate_nulls` above zero for consecutive batches — silent loss (rule 4);
- `uncited_suggestions` above zero — a contract break; stop showing suggestions until fixed;
- `unclassified_share` or `fallback_share` rising week over week — the taxonomy or input changed;
- `top_queue_share` jumping — everything going to one queue (DIAGNOSING section 2);
- once agents' reassignments are visible in the source system, the share of AI-routed tickets later reassigned,
  per queue — the production analogue of per-queue precision, and the drift signal for a reorganization
  (rule 27).

Re-run phase 7 on the holdout on a fixed cadence (monthly is a reasonable default to propose) and whenever the
production run id changes.

## Verification before declaring the phase done

1. Insert one synthetic ticket into the source (sandbox only, or a designated test record with the customer's
   agreement), wait one schedule interval, and show its `TRIAGE_CURRENT` row with every field populated.
2. Show `TASK_HISTORY` for the root and child task: both succeeded.
3. If dynamic tables were used: `refresh_mode` is `INCREMENTAL`.
4. Ask the agent one sample question and show the answer and the SQL it generated against the semantic view.
5. `TRIAGE_HEALTH_LOG` has a row for the test batch with zero errors.

Then `phases.operationalize: done`, every object in `created_objects`, and `operations` filled in.

## Teardown order

Suspend tasks (root first), then drop the agent, semantic view, tasks, procedure, stream and queue, and only
then the tables the tasks wrote — reading names from `created_objects`. Dropping a table while a task still
targets it produces failing task runs rather than a clean stop.
