---
name: ticket-triage-system-of-record
description: "Preflight discovery for a support or IT ticket triage build. Establishes what the account can actually run and what already exists, before anything is created: Cortex AI function access via EXPLAIN_PRIVILEGES (AI_CLASSIFY, AI_EXTRACT, AI_COMPLETE, AI_EMBED, AI_FILTER, AI_REDACT, AI_COUNT_TOKENS) and Cortex Search privileges, per-stage model availability via SHOW CORTEX BASE MODELS, account region and CORTEX_ENABLED_CROSS_REGION, the ticket table and column mapping, historical label quality (category default rate, final-versus-first assignment group, reassignment rate), knowledge base inventory and freshness, thread length and token profile, language mix, existing triage objects, and PII posture including pasted credentials. Always loaded first by the ticket-triage router."
parent_skill: ticket-triage
---

# Preflight — what this account can run, and what is already here

Run this before creating anything. It exists to prevent four specific bad outcomes: building around
a function or model the account cannot call, guessing column names that do not exist, scoring against
historical labels that are mostly defaults, and promising a deflection lever on a knowledge base that
is stale or empty.

Report findings as a compact summary and write settled values into `triage-project.yml`. Do not create
objects in this phase. All queries here are read-only; run them against metadata and aggregates, and
do not print ticket text unless the user asks to see a sample.

---

## 1. Cortex AI function access

First call of the session. `EXPLAIN_PRIVILEGES` analyzes the statement without executing it — no
credits, no model calls.

```sql
SELECT
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_CLASSIFY('x', ['a','b'])$$,                          missing_only => true) AS ai_classify,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_EXTRACT(text => 'x', responseFormat => {'k':'q'})$$,  missing_only => true) AS ai_extract,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COMPLETE('llama3.1-8b', 'x')$$,                       missing_only => true) AS ai_complete,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_EMBED('snowflake-arctic-embed-l-v2.0', 'x')$$,        missing_only => true) AS ai_embed,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_FILTER('x')$$,                                         missing_only => true) AS ai_filter,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_REDACT('x')$$,                                         missing_only => true) AS ai_redact,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COUNT_TOKENS('ai_complete', 'llama3.1-8b', 'x')$$,     missing_only => true) AS ai_count_tokens;
```

`{"authorized": true}` means the role can call it. Anything else is a blocker for the stages that
depend on it:

| Function | Needed for | If unavailable |
|---|---|---|
| `AI_CLASSIFY` | category, impact, urgency, queue | **hard stop** unless `AI_COMPLETE` is available and the user accepts the cost of using it for everything |
| `AI_COMPLETE` | low-confidence fallback, suggested resolutions | classification degrades to `AI_CLASSIFY` only (no fallback); suggestions and deflection cannot be built |
| `AI_EXTRACT` | product, version, error, asset entities | degrade to an `AI_COMPLETE` schema call |
| `AI_EMBED` | duplicate and known-issue linking | phase 5 cannot run |
| `AI_FILTER` | deflection gate | gate with an `AI_CLASSIFY` binary instead |
| `AI_REDACT` | PII scrub before prompts and indexing | not a blocker; say redaction will be pattern-based only and what that misses |
| `AI_COUNT_TOKENS` | cost estimation | not a blocker; estimates will be unavailable |

`AI_EMBED` can also be authorized through the narrower `SNOWFLAKE.CORTEX_EMBED_USER` database role
(per docs); a role that has only that will pass the embed check and fail the others. Report it as such
rather than as general access.

Remediation when access is missing — surface the grant, do not work around it:

```sql
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <role>;
```

Cortex Search needs separate object privileges for phase 3:

```sql
SHOW GRANTS TO ROLE <role>;
-- Look for CREATE CORTEX SEARCH SERVICE on the target schema, and USAGE on the
-- warehouse the service will use for refreshes.
```

If a check itself errors, note that access was not verified and continue. It is best-effort, never a
hard blocker on its own.

## 2. Region, cross-region inference and model availability

Model availability varies by region and models move through `LEGACY` and `EOL`. A build that pins a
model name copied from elsewhere will fail at run time or quietly run on a model scheduled for
removal.

```sql
SELECT CURRENT_REGION() AS region, CURRENT_ACCOUNT() AS account;
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
```

`CORTEX_ENABLED_CROSS_REGION` is an account-level parameter. Record the observed value in
`cortex.cross_region`. **Do not change it** — enabling cross-region inference sends prompts to another
region for processing, which is a data-residency decision for the customer's account administrator and
often their privacy or legal team. Ticket text routinely contains personal data; say so when raising it.

```sql
SHOW CORTEX BASE MODELS;

SELECT "name", "lifecycle_status", "in_region_availability", "legacy_date", "eol_date"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "lifecycle_status" = 'GA'
ORDER BY "name";
```

**Do not pin a model whose `lifecycle_status` is `LEGACY`, `EOL`, or blank.** Pin by stage:

| Stage | Wants | Why |
|---|---|---|
| `classify_fallback` | small-to-mid, GA, cheap | runs on the low-confidence residue; volume is a fraction of the corpus but it is still every ambiguous ticket |
| `extract` | only if `AI_EXTRACT` is insufficient | most entity fields are short spans; `AI_EXTRACT` is the default |
| `suggest` | strongest available that is in-region or permitted cross-region | grounded drafting with citation discipline; schema adherence degrades on weak models |
| `embed` | `snowflake-arctic-embed-l-v2.0` unless the corpus is materially non-English | the default text model for `AI_SIMILARITY` per docs; 1024 dimensions. Use a multilingual model if the language mix requires it, and keep **one** model for tickets and KB |

`AI_CLASSIFY`, `AI_EXTRACT`, `AI_FILTER` and `AI_REDACT` do not take a model argument; their
region availability is published per function in the docs (text input is supported broadly, including
cross-region). Check the function pages for the current table rather than assuming.

Do not silently substitute a model. If the preferred one is unavailable, say which one is used instead
and what the tradeoff is. Record `models.verified_on`.

## 3. Find the tickets

If the user named a table, describe it. If not, look for candidates:

```sql
SELECT table_catalog, table_schema, table_name, row_count,
       ROUND(bytes / POWER(1024, 3), 2) AS gb, last_altered
FROM information_schema.tables
WHERE table_type IN ('BASE TABLE', 'VIEW')
  AND (table_name ILIKE '%TICKET%'   OR table_name ILIKE '%INCIDENT%'
    OR table_name ILIKE '%CASE%'     OR table_name ILIKE '%REQUEST%'
    OR table_name ILIKE '%SR\\_%'     OR table_name ILIKE '%SUPPORT%'
    OR table_name ILIKE '%TASK_SLA%' OR table_name ILIKE '%SYS_JOURNAL%'
    OR table_name ILIKE '%KB%'       OR table_name ILIKE '%KNOWLEDGE%')
ORDER BY row_count DESC NULLS LAST
LIMIT 40;
```

`shared/sql/discover_unstructured.sql` in the repo is the cross-play version of this search. Connector
landings from common ITSM and CRM systems tend to arrive as many tables (incident, task, journal or
comment, audit or history, knowledge); map the ones that matter rather than all of them.

Map columns and write the mapping into `tickets` in `triage-project.yml`. Confirm with the user.

Required: ticket id, created timestamp, and at least one free-text field (subject or description).
Valuable when present: body, comment/work-note thread, channel, requester, historical category,
priority and assignment group, reassignment count, resolution notes, resolved timestamp,
parent-incident link, language.

**Get the first assignment, not only the final one.** The final assignment group is where the ticket
ended up after any ping-pong. A model that predicts the final group perfectly is what the pipeline
should do; a baseline that measures how often the *first* assignment matched the final one is the
current-state routing accuracy the value readout compares against. That usually lives in an audit or
history table:

```sql
-- Shape only; column names vary by source system. Confirm with the user.
SELECT COUNT(DISTINCT <ticket_id>) AS tickets_with_assignment_history
FROM <audit_table>
WHERE <field_name_col> = '<assignment_group_field>';
```

If there is no assignment history, say so: current-state first-touch accuracy then has to be estimated
from `reassignment_count`, and the readout will mark it as derived.

## 4. Historical label quality

Historical labels are used to **derive** the taxonomy and as a **noisy** comparison point. They are not
ground truth, and this section is how to say how noisy they are.

```sql
SELECT
    COUNT(*)                                                         AS tickets,
    ROUND(100.0 * COUNT(<hist_category_col>) / NULLIF(COUNT(*),0), 1) AS pct_has_category,
    COUNT(DISTINCT <hist_category_col>)                              AS distinct_categories,
    COUNT(DISTINCT <hist_queue_col>)                                 AS distinct_queues,
    COUNT(DISTINCT <hist_priority_col>)                              AS distinct_priorities,
    ROUND(AVG(<reassignment_count_col>), 2)                          AS avg_reassignments,
    ROUND(100.0 * COUNT_IF(<reassignment_count_col> > 0) / NULLIF(COUNT(*),0), 1) AS pct_reassigned
FROM <source_table>
WHERE <created_at_col> >= DATEADD(MONTH, -12, CURRENT_DATE());
```

```sql
-- Default-value rate. A category that holds a large share is often the form's
-- default ("Inquiry / Help", "Other"), not a real category.
SELECT <hist_category_col> AS category, COUNT(*) AS tickets,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM <source_table>
WHERE <created_at_col> >= DATEADD(MONTH, -12, CURRENT_DATE())
GROUP BY 1 ORDER BY 2 DESC LIMIT 30;
```

```sql
-- Queue concentration and long tail.
SELECT <hist_queue_col> AS queue, COUNT(*) AS tickets,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
       ROUND(AVG(<reassignment_count_col>), 2) AS avg_reassign
FROM <source_table>
WHERE <created_at_col> >= DATEADD(MONTH, -12, CURRENT_DATE())
GROUP BY 1 ORDER BY 2 DESC;
```

Report, plainly:

- the share of tickets carrying the top category, and whether it looks like a default;
- how many queues hold 80 percent of volume, and how many queues have fewer than ~30 tickets a year
  (these cannot be measured reliably and are candidates to merge in the taxonomy phase);
- reassignment rate overall and by queue — the queues with the highest rate are where routing value is;
- the priority distribution, and whether P1/P2 are rare enough that their recall will be noisy.

## 5. Text profile and token budget

```sql
SELECT
    COUNT(*)                                                    AS tickets,
    COUNT_IF(<body_col> IS NULL OR LENGTH(TRIM(<body_col>)) = 0) AS empty_body,
    ROUND(AVG(LENGTH(<body_col>)))                              AS avg_body_chars,
    APPROX_PERCENTILE(LENGTH(<body_col>), 0.5)                  AS p50_chars,
    APPROX_PERCENTILE(LENGTH(<body_col>), 0.95)                 AS p95_chars,
    MAX(LENGTH(<body_col>))                                     AS max_chars
FROM <source_table>
WHERE <created_at_col> >= DATEADD(MONTH, -3, CURRENT_DATE());
```

A p95 many times the median usually means email threads with full quoted history; normalization will
be the largest cost lever. Measure tokens on a sample rather than estimating from characters:

```sql
SELECT ROUND(AVG(AI_COUNT_TOKENS('ai_complete', '<classify_fallback_model>', <body_col>))) AS avg_tokens,
       MAX(AI_COUNT_TOKENS('ai_complete', '<classify_fallback_model>', <body_col>))        AS max_tokens
FROM (SELECT <body_col> FROM <source_table> SAMPLE (500 ROWS));
```

Function and model names are lowercase; a wrong function name returns `NULL`, not an error.
Pass `return_error_details => TRUE` while developing.

Language mix, when there is no language column — on a small sample only:

```sql
SELECT AI_CLASSIFY(LEFT(<body_col>, 500),
                   ['English', 'Spanish', 'French', 'German', 'Portuguese', 'Japanese', 'Other']
       ):labels[0]::STRING AS lang, COUNT(*) AS tickets
FROM (SELECT <body_col> FROM <source_table> WHERE <body_col> IS NOT NULL SAMPLE (200 ROWS))
GROUP BY 1 ORDER BY 2 DESC;
```

`AI_CLASSIFY` documentation recommends English input. If a material share is non-English, plan an
`AI_TRANSLATE` step in normalization and a multilingual embedding model, and say what that adds.

## 6. Knowledge base inventory

Deflection and suggested resolutions are only as good as the KB. Check it before promising either.

```sql
SELECT <kb_status_col> AS state, COUNT(*) AS articles,
       MIN(<kb_updated_col>) AS oldest, MAX(<kb_updated_col>) AS newest
FROM <kb_source_table>
GROUP BY 1 ORDER BY 2 DESC;
```

```sql
-- Coverage: how many resolved tickets in the last quarter reference a KB article?
-- Column varies by source; many systems record an attached-knowledge link.
SELECT ROUND(100.0 * COUNT_IF(<kb_link_col> IS NOT NULL) / NULLIF(COUNT(*),0), 1) AS pct_resolved_with_kb
FROM <source_table>
WHERE <resolved_at_col> >= DATEADD(MONTH, -3, CURRENT_DATE());
```

Report article count by state, age of the newest published article, and whether resolved-ticket
close notes are usable as a second knowledge source (populated, longer than a stock phrase like
"resolved" or "closed by caller"). If the KB is small, stale or mostly draft, say plainly that
deflection will be bounded by KB coverage, and that resolved-ticket notes are the realistic grounding
source.

## 7. Existing triage objects

Do not overwrite work already in progress.

```sql
SELECT table_schema, table_name, row_count, created
FROM information_schema.tables
WHERE table_name ILIKE '%TRIAGE%' OR table_name ILIKE '%TICKET_CLASS%'
   OR table_name ILIKE '%KB_CHUNK%' OR table_name ILIKE '%DEFLECT%'
ORDER BY created DESC;

SHOW CORTEX SEARCH SERVICES IN ACCOUNT;
SHOW SEMANTIC VIEWS IN ACCOUNT;
SHOW AGENTS IN ACCOUNT;
```

Anything found gets surfaced with row count and creation date, and an explicit question: reuse, rename,
or replace.

## 8. PII and secrets posture

A ticket is a free-text field filled in by people under stress. Expect names, emails, phone numbers,
account and order numbers, employee ids, hostnames and IP addresses, and pasted credentials, tokens
and private keys.

```sql
SELECT policy_name, policy_kind, ref_entity_name, ref_column_name
FROM TABLE(information_schema.policy_references(
    ref_entity_name   => '<fully_qualified_source_table>',
    ref_entity_domain => 'TABLE'));

SHOW GRANTS ON TABLE <fully_qualified_source_table>;
```

Then size the secrets problem on a small sample with deterministic patterns — this is a count, not a
display; do not print matches:

```sql
SELECT
  COUNT_IF(REGEXP_LIKE(<body_col>, '.*(password|passwd|pwd)\\s*[:=]\\s*\\S+.*', 'is'))  AS password_like,
  COUNT_IF(REGEXP_LIKE(<body_col>, '.*-----BEGIN [A-Z ]*PRIVATE KEY-----.*', 's'))      AS private_key_like,
  COUNT_IF(REGEXP_LIKE(<body_col>, '.*(api[_-]?key|token|secret)\\s*[:=]\\s*\\S{16,}.*', 'is')) AS token_like,
  COUNT(*) AS sampled
FROM (SELECT <body_col> FROM <source_table> SAMPLE (2000 ROWS));
```

Report:

- policies on the source table, and whether the output and the KB chunk table need the same;
- which roles read tickets today, and which should read triage output and suggestions (agents) versus
  the knowledge store (potentially end users, if deflection is ever exposed — a much wider audience);
- whether redaction should run before indexing resolved-ticket notes. If those notes will back an
  end-user-facing deflection flow, the answer is yes, and `AI_REDACT` is best-effort per its docs, so
  a review sample is part of the gate.

Do not create policies in this phase. Surface the gap and let the user decide.

## 9. Warehouse

```sql
SHOW WAREHOUSES LIKE '<candidate>';
```

AI function throughput is dominated by the inference service, not warehouse size, so an oversized
warehouse mostly burns credits waiting. A small or medium warehouse with a short auto-suspend is
usually right. The Cortex Search service needs a warehouse for refreshes too; it can be the same one.

## 10. Materialization choice

Ask once, now, using `ask_user_question`: dbt project or plain SQL. Explain the tradeoff from
`DBT_MATERIALIZATION.md` in two sentences. Record `materialization.mode`.

---

## Output of this phase

A short written summary covering: functions available and missing grants, region and cross-region
setting, models pinned per stage, ticket table and column mapping, historical label quality (default
rate, queue concentration, reassignment rate, availability of first-assignment history), text and
token profile, language mix, KB inventory and freshness, existing objects, PII and secrets posture,
and the materialization choice. Then the settled values written into `triage-project.yml` and
`phases.preflight: done`.

Anything unresolved stays absent from the state file rather than being filled with a plausible
default.
