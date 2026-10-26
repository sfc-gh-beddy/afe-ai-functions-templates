---
name: operationalize-intake-pipeline
description: "Phase 6 of the document-intake build: turn the validated batch pipeline into an incremental, scheduled service with a business-facing interface. Creates a stream on the stage directory table, a serverless task graph (classify -> extract -> validate -> queue) triggered by SYSTEM$STREAM_HAS_DATA and keyed on run_id for idempotency, a monitoring view for daily STP / false-STP sample audit / exception aging / credits per 1K pages, a semantic view over decisions, approvals and the exceptions queue, and a Cortex Agent for the AP, claims or contracts team in Snowflake CoWork that answers queue and throughput questions without exposing sensitive fields. Use for scheduling, incremental processing, stream and task, semantic view, Cortex Agent, CoWork, or 'make it run every day'."
parent_skill: document-intake
---

# Operationalize: incremental pipeline, semantic view, agent

Precondition: Phase 5 is `done`, the false-STP rate at the chosen thresholds is recorded, the
business owner accepted it in writing, and missed exceptions on the hard cases are zero. Scheduling a
pipeline before that automates an unmeasured error stream. If any precondition is missing, say which
and stop.

For dbt builds, the task graph below becomes `EXECUTE DBT PROJECT` on a schedule — delegate to the
`dbt-projects-on-snowflake` skill. For scheduling mechanics in general, load the `snowflake-tasks`
skill; this file covers what this pipeline specifically needs.

## 1. Detect new files

A stream on the stage's directory table records added files. The directory must be refreshed — by
auto-refresh on an external stage with event notifications, or explicitly for internal stages.

```sql
CREATE STREAM IF NOT EXISTS {{DB}}.{{SCHEMA}}.INBOUND_DOCS_STREAM
    ON STAGE {{STAGE_FQN}}
    COMMENT = 'New files for document intake';
```

The stream is a trigger, not the source of truth for "already processed". The incremental predicates
in Phases 2 and 3 (`NOT EXISTS ... document_id` and `(document_id, schema_hash)`) are what make a run
safe to repeat. Two consequences:

- A task retry, a manual re-run, or a stream that replays does not double-extract or double-bill.
- A schema version change re-extracts deliberately, even for files the stream consumed long ago.

## 2. The task graph

Serverless tasks; each step is a stored procedure wrapping the phase SQL from Phases 2–4, taking
`run_id` as an argument. Do not share `TEMPORARY` tables between tasks — each task runs in its own
session. The temporary tables used interactively in the phase skills (`CLASSIFY_CANDIDATES`,
`DOC_FIELDS`, ...) become either transient tables keyed on `run_id` or CTEs inside one procedure.

```sql
-- Root: refresh the directory, mint a run_id, and consume the stream into the
-- inbound file register. Runs only when there is something new.
CREATE OR REPLACE TASK {{DB}}.{{SCHEMA}}.INTAKE_ROOT
    SCHEDULE = '15 MINUTE'
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'SMALL'
    WHEN SYSTEM$STREAM_HAS_DATA('{{DB}}.{{SCHEMA}}.INBOUND_DOCS_STREAM')
AS
    CALL {{DB}}.{{SCHEMA}}.INTAKE_START_RUN();      -- sets the run_id as the task return value

CREATE OR REPLACE TASK {{DB}}.{{SCHEMA}}.INTAKE_CLASSIFY
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'SMALL'
    AFTER {{DB}}.{{SCHEMA}}.INTAKE_ROOT
AS
    CALL {{DB}}.{{SCHEMA}}.INTAKE_CLASSIFY(SYSTEM$GET_PREDECESSOR_RETURN_VALUE());

CREATE OR REPLACE TASK {{DB}}.{{SCHEMA}}.INTAKE_EXTRACT
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'SMALL'
    AFTER {{DB}}.{{SCHEMA}}.INTAKE_CLASSIFY
AS
    CALL {{DB}}.{{SCHEMA}}.INTAKE_EXTRACT(SYSTEM$GET_PREDECESSOR_RETURN_VALUE());

CREATE OR REPLACE TASK {{DB}}.{{SCHEMA}}.INTAKE_VALIDATE
    USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = 'SMALL'
    AFTER {{DB}}.{{SCHEMA}}.INTAKE_EXTRACT
AS
    CALL {{DB}}.{{SCHEMA}}.INTAKE_VALIDATE_AND_QUEUE(SYSTEM$GET_PREDECESSOR_RETURN_VALUE());
```

Each procedure returns the `run_id` it received (`SYSTEM$SET_RETURN_VALUE`) so the next step gets it.
Load `snowflake-tasks` to confirm return-value passing and serverless parameters on the account before
deploying — they are newer features and the exact parameter names should be checked, not assumed.

Requirements for the procedures:

- Set `QUERY_TAG = 'doc_intake:<experiment_id>:<phase>'` at the start of each, so cost attribution in
  Phase 5 keeps working in production.
- Fully qualify every object and the stage in `TO_FILE`.
- Read thresholds, rules and schemas from the configuration tables (`FIELD_THRESHOLDS`,
  `VALIDATION_RULES`) and from a `EXTRACTION_SCHEMAS` table holding `(document_type, schema_version,
  schema_json)` — not from session variables, which do not exist inside a task.
- Cap the batch size per run (for example `LIMIT 500` documents in the classify step) so a backlog
  drains over several runs instead of one very long, expensive one, and so a bad file cannot hold the
  whole backlog hostage.
- Enable a failure notification on the root task (see the `alert` / `notification` skills). A failed
  intake run means invoices are not being keyed by anyone.

Resume the graph only after the user confirms, child tasks first:

```sql
ALTER TASK {{DB}}.{{SCHEMA}}.INTAKE_VALIDATE RESUME;
ALTER TASK {{DB}}.{{SCHEMA}}.INTAKE_EXTRACT  RESUME;
ALTER TASK {{DB}}.{{SCHEMA}}.INTAKE_CLASSIFY RESUME;
ALTER TASK {{DB}}.{{SCHEMA}}.INTAKE_ROOT     RESUME;
```

### Why not dynamic tables for the AI steps

Dynamic tables are attractive for the downstream reporting layer (exception aging, daily throughput)
and fine there. For the AI-calling steps they are a poor fit: a definition change or a full refresh
re-runs `AI_EXTRACT` over every document and re-bills every page, and the "process each file once per
schema version" guarantee is harder to see and to test. Keep the AI steps in tasks with explicit
incremental predicates; build reporting on dynamic tables if wanted (load the `dynamic-tables` skill).

## 3. Production monitoring

The sandbox measured accuracy once. Production needs it measured continuously, without an answer key:

```sql
CREATE OR REPLACE VIEW {{DB}}.{{SCHEMA}}.INTAKE_DAILY_HEALTH AS
SELECT
    DATE_TRUNC('DAY', d.decided_at)                                       AS day,
    d.document_type,
    COUNT(*)                                                              AS documents,
    COUNT_IF(d.decision = 'AUTO_APPROVED')                                AS auto_approved,
    ROUND(COUNT_IF(d.decision = 'AUTO_APPROVED') / NULLIF(COUNT_IF(d.decision <> 'REJECTED'), 0), 4) AS stp_rate,
    COUNT_IF(d.decision = 'EXCEPTION')                                    AS exceptions,
    COUNT_IF(d.decision = 'REJECTED')                                     AS rejected,
    COUNT_IF(ARRAY_CONTAINS('VENDOR_BANK_MATCH'::VARIANT, d.blocking_failures)) AS bank_change_flags,
    COUNT_IF(ARRAY_CONTAINS('DUP_VENDOR_INVOICE'::VARIANT, d.blocking_failures)) AS duplicate_flags
FROM {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION d
GROUP BY 1, 2;

CREATE OR REPLACE VIEW {{DB}}.{{SCHEMA}}.EXCEPTION_AGING AS
SELECT document_type, primary_reason, status,
       COUNT(*)                                               AS open_items,
       SUM(total_amount)                                      AS amount_open,
       MAX(DATEDIFF(HOUR, created_at, CURRENT_TIMESTAMP()))   AS oldest_hours,
       COUNT_IF(days_to_due <= 5)                             AS due_within_5_days
FROM {{DB}}.{{SCHEMA}}.EXCEPTIONS_QUEUE
WHERE status IN ('OPEN', 'IN_REVIEW')
GROUP BY 1, 2, 3;
```

And a **sample audit of auto-approved documents** — the only production check on false STP, because
reviewer corrections never see approved documents:

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.STP_AUDIT_SAMPLE (
    document_id VARCHAR, sampled_at TIMESTAMP_LTZ, auditor VARCHAR,
    audit_result VARCHAR,      -- CORRECT | WRONG_FIELD | SHOULD_HAVE_BEEN_EXCEPTION
    wrong_fields ARRAY, note VARCHAR, audited_at TIMESTAMP_LTZ
);

-- Weekly: a random sample of auto-approved documents for human verification.
INSERT INTO {{DB}}.{{SCHEMA}}.STP_AUDIT_SAMPLE (document_id, sampled_at)
SELECT document_id, CURRENT_TIMESTAMP()
FROM {{DB}}.{{SCHEMA}}.INTAKE_APPROVED
WHERE approved_at >= DATEADD(DAY, -7, CURRENT_TIMESTAMP())
SAMPLE (:audit_sample_size ROWS);
```

The sample size is a customer decision; the Wilson interval in `evaluate-intake-accuracy` shows what a
given sample can and cannot rule out. Drift signals worth an alert: STP rate dropping on one vendor or
channel (a new invoice template), a jump in `LOW_SCORE` on one field, `bank_change_flags` above zero
(always worth a human look the same day).

## 4. Semantic view

For questions the AP, claims, or contracts team actually asks: how much is in the queue, what is
blocking it, what is due soon, how much went straight through. It deliberately excludes
`EXTRACTED_FIELDS.raw_value` and anything holding bank details or tax IDs.

```sql
CREATE OR REPLACE SEMANTIC VIEW {{DB}}.{{SCHEMA}}.DOCUMENT_INTAKE_SV
  TABLES (
    decisions AS {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION
      PRIMARY KEY (document_id, run_id)
      WITH SYNONYMS ('documents', 'intake decisions')
      COMMENT = 'One decision per document per run: AUTO_APPROVED, EXCEPTION, or REJECTED',
    approved AS {{DB}}.{{SCHEMA}}.INTAKE_APPROVED
      PRIMARY KEY (document_id)
      WITH SYNONYMS ('posted documents', 'straight through')
      COMMENT = 'Documents that passed every blocking rule and were released downstream',
    exceptions AS {{DB}}.{{SCHEMA}}.EXCEPTIONS_QUEUE
      PRIMARY KEY (exception_id)
      WITH SYNONYMS ('review queue', 'exceptions', 'work queue')
      COMMENT = 'Documents waiting for human review, with the reason they were stopped'
  )
  RELATIONSHIPS (
    approved_to_decision AS approved (document_id, run_id) REFERENCES decisions,
    exception_to_decision AS exceptions (document_id, run_id) REFERENCES decisions
  )
  FACTS (
    approved.approved_amount AS approved.total_amount
      COMMENT = 'Document total in its own currency; never sum across currencies',
    exceptions.queued_amount AS exceptions.total_amount
      COMMENT = 'Document total in its own currency; never sum across currencies',
    exceptions.age_hours AS DATEDIFF(HOUR, exceptions.created_at, CURRENT_TIMESTAMP())
  )
  DIMENSIONS (
    decisions.document_type AS decisions.document_type
      WITH SYNONYMS = ('doc type', 'type'),
    decisions.decision AS decisions.decision
      COMMENT = 'AUTO_APPROVED, EXCEPTION, or REJECTED',
    decisions.decision_date AS DATE(decisions.decided_at),
    approved.currency AS approved.currency,
    approved.vendor_id AS approved.vendor_id,
    approved.due_date AS approved.due_date,
    exceptions.primary_reason AS exceptions.primary_reason
      WITH SYNONYMS = ('blocking reason', 'why it stopped'),
    exceptions.status AS exceptions.status,
    exceptions.priority AS exceptions.priority,
    exceptions.days_to_due AS exceptions.days_to_due
  )
  METRICS (
    decisions.document_count AS COUNT(decisions.document_id),
    decisions.auto_approved_count AS COUNT_IF(decisions.decision = 'AUTO_APPROVED'),
    decisions.stp_rate AS COUNT_IF(decisions.decision = 'AUTO_APPROVED')
                          / NULLIF(COUNT_IF(decisions.decision <> 'REJECTED'), 0)
      COMMENT = 'Straight-through-processing rate: auto-approved over documents that should be processed',
    exceptions.open_exception_count AS COUNT_IF(exceptions.status IN ('OPEN', 'IN_REVIEW')),
    exceptions.open_exception_amount AS SUM(IFF(exceptions.status IN ('OPEN', 'IN_REVIEW'), exceptions.queued_amount, 0))
      COMMENT = 'Sum within one currency only; group by currency',
    exceptions.avg_age_hours AS AVG(exceptions.age_hours)
  )
  COMMENT = 'Document intake throughput, straight-through processing, and the human review queue'
  AI_SQL_GENERATION 'Amounts are in each document''s own currency. Never sum amounts without grouping by currency. The false-STP rate is NOT in this view; it comes from evaluation and audit, and must not be inferred from STP.';
```

The `EXCEPTIONS_QUEUE` table needs a `currency` column for the currency guidance to be followable —
add it in Phase 4 from `DOC_FIELDS.currency` (or the vendor default) if it is not already there. Load the
`agent-studio` skill to validate the semantic view and to add verified queries for the questions the
team asks most.

## 5. Cortex Agent for the team, in CoWork

```sql
CREATE OR REPLACE AGENT {{DB}}.{{SCHEMA}}.DOCUMENT_INTAKE_AGENT
  COMMENT = 'Answers questions about document intake throughput and the review queue'
  PROFILE = '{"display_name": "Document Intake Assistant"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  instructions:
    response: "Be concise. Give counts and amounts with their currency. Never sum amounts across currencies. If asked whether a specific document is correct, say that only a reviewer can confirm it and point to its exception reason."
    orchestration: "Use the intake analyst tool for all questions about volumes, STP rate, exceptions, reasons, aging and due dates. Do not answer accuracy or false-STP questions from this data; say those come from the evaluation report."
    sample_questions:
      - question: "How many invoices are waiting for review and what is blocking most of them?"
      - question: "Which exceptions are due in the next five days?"
      - question: "What was our straight-through rate for invoices last week?"
      - question: "How many bank-change flags did we get this month?"

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "intake_analyst"
        description: "Document intake decisions, straight-through processing, approved documents and the exceptions review queue"

  tool_resources:
    intake_analyst:
      semantic_view: "{{DB}}.{{SCHEMA}}.DOCUMENT_INTAKE_SV"
  $$;
```

Grant usage to the team role only after the governance decision from preflight: the agent can read
whatever the semantic view exposes, and nothing else. For contracts, a Cortex Search service over parsed
contract text is a natural second tool ("which contracts auto-renew in Q1 with 90-day notice?") — that
requires the full-parse path from `extract-document-fields` and its page cost; scope it as a follow-on.

Load `agent-studio` to test the agent against the sample questions before handing it over.

## Verification at the gate

```sql
SHOW TASKS LIKE 'INTAKE_%' IN SCHEMA {{DB}}.{{SCHEMA}};

-- After the first scheduled run: did it run, end to end, and was it idempotent?
SELECT name, state, scheduled_time, completed_time, error_message
FROM TABLE({{DB}}.INFORMATION_SCHEMA.TASK_HISTORY(
    SCHEDULED_TIME_RANGE_START => DATEADD(HOUR, -6, CURRENT_TIMESTAMP())))
WHERE name LIKE 'INTAKE_%'
ORDER BY scheduled_time DESC;

-- Re-running the same run_id must add nothing.
SELECT run_id, COUNT(*) AS extract_rows, COUNT(DISTINCT document_id) AS documents
FROM {{DB}}.{{SCHEMA}}.EXTRACT_RAW
GROUP BY 1 HAVING COUNT(*) <> COUNT(DISTINCT document_id);
-- Zero rows.

SELECT * FROM {{DB}}.{{SCHEMA}}.INTAKE_DAILY_HEALTH ORDER BY day DESC LIMIT 14;
```

Record tasks, stream, views, semantic view, and agent in `created_objects`; set
`phases.operationalize: done`.
