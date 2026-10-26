---
name: operationalize-leakage-pipeline
description: "Phase 6 of the spend-and-contract-leakage build. Turns an evaluated pipeline into a running one: current-run serving views, a semantic view with per-impact-kind metrics and a mandatory currency grouping, a Cortex Agent for Snowflake CoWork that answers with arithmetic and cited clause evidence, and a scheduled task that pins the as-of date once per run, parses and extracts only new or changed contracts (directory-table stream plus content-hash cache), and reconciles all spend daily, with a run log and failure handling. Covers dynamic tables as an alternative, dbt deployment, access control for findings, and monitoring cost and drift. Triggers: schedule the pipeline, make it incremental, semantic view, Cortex Agent, CoWork, put it in production, run it daily, ask questions about leakage."
parent_skill: spend-and-contract-leakage
---

# Operationalize

Only after Phase 5. Scheduling a pipeline whose precision has not been measured schedules an
unknown number of false supplier disputes, and an agent over unmeasured findings answers confidently
with them.

Prerequisites: `phases.eval: done` on an experiment the user has accepted, recorded as
`{{PROD_EXPERIMENT_ID}}`; confidentiality decisions from preflight (who may read findings, who may
use the agent).

## What gets created

| Object | Kind | Purpose |
|---|---|---|
| `V_CURRENT_RUN`, `V_LEAKAGE_FINDINGS_CURRENT`, `V_SPEND_COVERAGE_CURRENT`, `V_RENEWAL_CALENDAR` | views | latest run of the served experiment only |
| `SPEND_LEAKAGE_SV` | semantic view | findings, coverage and renewal calendar for Cortex Analyst |
| `{{AGENT_NAME}}` | Cortex Agent | natural-language access in CoWork, with response rules |
| `{{CODE_STAGE}}` | stage | the phase SQL files as Jinja templates |
| `PIPELINE_RUNS`, `CONTRACT_ARRIVALS` | tables | run log; consumed stream rows |
| `CONTRACT_FILES_STREAM` | stream | new or changed contract files on the contract stage |
| `RUN_LEAKAGE_PIPELINE` | procedure | one run: parse and extract if contracts changed, then reconcile |
| `LEAKAGE_PIPELINE_DAILY` | task | the schedule, created suspended |

SQL: `sql/01_semantic_view_and_agent.sql`, then `sql/02_schedule.sql`. Two gates: serving layer
first (no inference), schedule second (inference on every run with changed contracts).

## Serving layer

### Why current-run views

Findings, term periods and coverage accumulate by run and experiment. An agent pointed at the raw
tables would sum across runs, and across experiments that were never meant for production. The views
select the latest run of one named experiment, so promoting a new prompt version is a deliberate
change to `{{PROD_EXPERIMENT_ID}}`, made after its Phase 5 results are accepted.

### The semantic view encodes the two rules readers break

- **No metric sums across impact kinds** (rule 13). There are three monetary metrics —
  `recoverable_overcharge`, `spend_under_management`, `commitment_exposure` — and no "total leakage".
  If a stakeholder asks for one number, the right answer is three numbers and why.
- **Money is grouped by currency** (rule 12). `AI_SQL_GENERATION` instructs Analyst to group every
  monetary metric by currency and to report price-checked spend beside any finding total.

`evidence_text` flattens each finding's cited clauses to `document page section: "quote"`. The view
exposes the quotes that support findings and nothing else of the contracts. If the customer wants
document search over contract text, that is a separate decision with a separate access policy; do not
add a Cortex Search service over `CONTRACT_PAGES` to this agent by default.

### The agent's instructions are part of the control

The response instructions require currency and impact kind on every figure, coverage beside totals,
arithmetic and exact quotes for individual findings, no more contract text than the cited clause, and
framing of "does the supplier owe this" as a reading for procurement and legal to confirm. These are
the same rules the pipeline enforces in SQL, restated for the place where a person reads the output.

### Gate 1 verification

V1 in `01_semantic_view_and_agent.sql` must return identical totals from the semantic view and from
the findings view. Then ask the agent two scripted questions and show the answers:

1. "What is the recoverable overcharge by supplier, per currency?" — expect a per-currency
   breakdown; on the sandbox EUR 1,500.00 must not appear inside a USD total.
2. "Show the evidence for the largest rate variance." — expect the arithmetic and a quoted clause; on
   the sandbox, Northwind or Litware with the Schedule A or equipment price line.

If the agent adds kinds or currencies together, fix the instructions before anyone else uses it.

### Access

Grant the agent and semantic view only to the roles preflight identified as entitled to findings.
Findings contain negotiated prices; the agent can answer "what do we pay this supplier per hour".

```sql
GRANT USAGE ON AGENT {{AGENT_NAME}} TO ROLE <procurement_role>;
GRANT SELECT ON SEMANTIC VIEW SPEND_LEAKAGE_SV TO ROLE <procurement_role>;
-- plus SELECT on the four current-run views and USAGE on the warehouse
```

## Schedule

### How a scheduled run works

```
task fires (weekday morning)
  -> RUN_LEAKAGE_PIPELINE(CURRENT_DATE(), FALSE)      as-of date pinned once, logged
       -> consume CONTRACT_FILES_STREAM into CONTRACT_ARRIVALS
       -> if any arrivals (or forced):
            parse_and_register   (cache skips unchanged files)
            extract_terms        (new run_id; same experiment_id)
       -> reconcile              (every run)
       -> PIPELINE_RUNS status DONE, or FAILED with the error
```

- **Templates.** The phase files are staged unsubstituted and executed with
  `EXECUTE IMMEDIATE FROM '@stage/file.sql' USING (...)`, which renders them as Jinja; their
  `{{NAME}}` placeholders are Jinja variables. The same files therefore run by hand and on a
  schedule, and there is one copy of each prompt. Jinja renders an undefined variable as an empty
  string, so the procedure passes every placeholder each file uses; re-check the list whenever a file
  gains one.
- **Hashes.** The staged files' MD5 values from the code stage's directory table stand in for
  `PROMPT_HASH` and `PARAM_HASH`, and are logged on each run.
- **The clock.** `CURRENT_DATE()` is evaluated once, in the task body, and passed down. No business
  logic reads the clock (rule 14). A rerun of a failed day passes that day's date explicitly.
- **Cost on quiet days.** With no arrivals, a run is reconciliation only: SQL plus `AI_SIMILARITY` on
  new SKU-less lines.

Gate 2: state the objects, the cadence, and the per-run cost model (pages for new contracts, tokens
for their extraction, nothing for unchanged ones). Use weekday business-hours cron by default — the
output is acted on by people — for example `0 7 * * 1-5 America/New_York`. Create the task
suspended, run `CALL RUN_LEAKAGE_PIPELINE('<as_of>'::DATE, TRUE);` once by hand, show
`PIPELINE_RUNS`, and resume only when the user confirms.

### When extraction should rerun on unchanged contracts

Only when the prompt version changes. That is a new experiment, evaluated in Phase 5 before it is
promoted; promotion is changing `{{PROD_EXPERIMENT_ID}}` in the views and the procedure, then a forced
run.

### Alternative: dynamic tables

Cortex AI functions are supported in the `SELECT` of incrementally refreshed dynamic tables. A
dynamic-table build is reasonable for the extraction layer when contracts arrive as rows in a table
(a CLM export), with `TARGET_LAG = DOWNSTREAM` and a reconciliation dynamic table on top. It is less
natural here because:

- reconciliation pins an as-of date and accumulates findings by run with carried-forward review
  status, which is task-and-table semantics rather than declarative refresh;
- several steps (deduplication, families) are set-based across all documents, which forces full
  refresh of those layers.

If the customer prefers dynamic tables, load the `dynamic-tables` skill, keep the AI layers
incremental, and keep findings in a task-written table.

### dbt

In dbt mode, the scheduled unit is the deployed dbt project (`EXECUTE DBT PROJECT` from a task), with
`as_of_date` and `run_id` passed as vars; see `DBT_MATERIALIZATION.md` and delegate the mechanics to
the `dbt-projects-on-snowflake` skill. The semantic view and agent stay as post-deploy DDL from
`01_semantic_view_and_agent.sql`.

## Monitoring

Run these weekly, or schedule them as an automation:

```sql
-- Run health.
SELECT status, COUNT(*), MAX(started_at) FROM PIPELINE_RUNS
WHERE started_at >= DATEADD(day, -30, CURRENT_TIMESTAMP()) GROUP BY 1;

-- Drift in extraction quality: failures and unverified terms per run.
SELECT run_id, COUNT_IF(status = 'FAILED') AS failed, COUNT_IF(status = 'UNVERIFIED') AS unverified, COUNT(*) AS terms
FROM CONTRACT_HEADER_TERMS GROUP BY 1 ORDER BY MAX(extracted_at) DESC LIMIT 10;

-- Coverage drift: share of spend price-checked, per currency, by run.
SELECT run_id, currency,
       ROUND(100 * SUM(IFF(price_check_status = 'READY', line_amount, 0)) / NULLIF(SUM(line_amount), 0), 1) AS pct_price_checked
FROM INVOICE_CONTRACT_MATCH GROUP BY 1, 2 ORDER BY 1 DESC, 2;

-- Cost per run (lags up to 24 hours).
SELECT SPLIT_PART(query_tag, ':', 3) AS run_id, function_name, SUM(credits) AS credits
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
WHERE query_tag LIKE '{{QUERY_TAG_PREFIX}}:%'
GROUP BY 1, 2 ORDER BY 1 DESC, 3 DESC;
```

A falling price-checked share usually means new suppliers without contracts in the CLM, or a new
invoice format without SKUs; both are worth telling procurement about directly.

Then write `phases.operationalize: done` and record every created object, including the task and
whether it was resumed.

## Teardown

Suspend the task first, then drop exactly what `created_objects` lists. Warn if `LEAKAGE_FINDINGS`
has non-default `review_status` rows.
