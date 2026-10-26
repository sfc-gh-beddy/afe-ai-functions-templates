---
name: churn-signals-system-of-record
description: "Preflight discovery for a churn-signals build. Establishes what the account can run and what data exists before anything is created: Cortex AI function access via EXPLAIN_PRIVILEGES (AI_SENTIMENT, AI_CLASSIFY, AI_COMPLETE, AI_SUMMARIZE_AGG, AI_COUNT_TOKENS), model availability and lifecycle via SHOW CORTEX BASE MODELS, CORTEX_ENABLED_CROSS_REGION, Snowflake ML registry privileges, the interaction inventory across tickets, surveys, emails and call notes, the account join key, renewal outcome history and its label quality, usage history, outcome-derived CRM columns that would leak into a model, existing pipeline objects, and customer-data posture (masking, row access, who can read evidence). Always loaded first by the churn-signals router."
parent_skill: churn-signals
---

# Preflight -- what this account can run, and what data is here

Run before creating anything. It exists to prevent four bad outcomes: building around a function or
model the account cannot call; joining interactions to the wrong account; training on labels that
are wrong or too few; and shipping a model that reads a column written after the customer left.

Report a compact summary and write settled values into `churn-project.yml`. Create nothing.

---

## 1. Cortex AI function access

`EXPLAIN_PRIVILEGES` analyses the statement without executing it -- no credits.

```sql
SELECT
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_SENTIMENT('x', ['price'])$$,                       missing_only => true) AS ai_sentiment,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_CLASSIFY('x', ['a','b'], {'output_mode':'multi'})$$, missing_only => true) AS ai_classify,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COMPLETE('<evidence_model>', 'x')$$,               missing_only => true) AS ai_complete,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_SUMMARIZE_AGG(c) FROM (SELECT 'x' AS c)$$,          missing_only => true) AS ai_summarize_agg,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COUNT_TOKENS('ai_sentiment', 'x')$$,                missing_only => true) AS ai_count_tokens;
```

| Function | Needed for | If unavailable |
|---|---|---|
| `AI_CLASSIFY` | reason taxonomy -- the core signal | **hard stop** |
| `AI_SENTIMENT` | aspect sentiment features | degrade: drop sentiment features, say so |
| `AI_COMPLETE` | grounded evidence quote, churn intent, competitor | degrade: no evidence on rows -- a weak deliverable; say so plainly |
| `AI_SUMMARIZE_AGG` | account narratives | not a blocker |
| `AI_COUNT_TOKENS` | gate estimates | not a blocker; estimates unavailable |

Remediation -- surface the grant, do not work around it:

```sql
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <role>;
```

If the check itself errors, note that access was not verified and continue. Best-effort, never a
blocker on its own.

## 2. Models and region

```sql
SHOW CORTEX BASE MODELS;

SELECT "name", "lifecycle_status", "legacy_date", "eol_date"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "lifecycle_status" = 'GA'
ORDER BY "name";
```

Only `AI_COMPLETE` takes a model choice in this play. Pick a small-to-mid GA model for the evidence
stage: it copies a sentence and fills four fields, so a frontier model is waste unless the grounding
rate in Phase 7 says otherwise. Never pin `LEGACY`, `EOL` or blank-status models. Record the choice and
`models.verified_on`. Do not silently substitute; if the preferred model is missing, say which one is
used instead and why.

Cross-region inference changes both availability and where data is processed:

```sql
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
```

Report the value. If it is `DISABLED` and the chosen model is not in-region, the call fails at run
time -- pick an in-region model. If it is enabled, say plainly that inference may be processed in
another region; some customers' data-residency commitments do not allow that, and it is their call,
not ours.

## 3. Snowflake ML registry and training compute

Phase 5 logs a model to the registry in the target schema and runs warehouse inference.

```sql
SHOW GRANTS TO ROLE <role>;
-- Needs on the target schema: CREATE MODEL (and USAGE on db/schema).
-- Needs on the warehouse: USAGE.
```

Training pulls the feature table into Python. Ask where it will run: a local Python with
`snowflake-ml-python`, or a Snowflake Notebook. Record it. For a feature table beyond a few hundred
thousand rows, recommend a Container Runtime notebook and load the `machine-learning` skill for the
compute pool setup rather than improvising one.

## 4. Find the interaction sources

Churn signal is spread across systems. Look for all of them rather than accepting the first table
named.

```sql
SELECT table_catalog, table_schema, table_name, row_count,
       ROUND(bytes / POWER(1024, 3), 2) AS gb
FROM information_schema.tables
WHERE table_type = 'BASE TABLE'
  AND REGEXP_LIKE(table_name, '.*(TICKET|CASE|SURVEY|NPS|CSAT|FEEDBACK|EMAIL|MESSAGE|CALL|NOTE|CONVERSATION|CHAT|INTERACTION|ACTIVITY).*', 'i')
ORDER BY row_count DESC NULLS LAST
LIMIT 40;
```

Then the free-text columns (also `shared/sql/discover_unstructured.sql`):

```sql
SELECT table_schema, table_name, column_name, data_type
FROM information_schema.columns
WHERE data_type IN ('TEXT', 'VARCHAR', 'VARIANT')
  AND REGEXP_LIKE(column_name, '.*(BODY|TEXT|DESCRIPTION|COMMENT|VERBATIM|NOTE|MESSAGE|TRANSCRIPT|FEEDBACK|REASON|SUMMARY).*', 'i')
ORDER BY 1, 2, 3;
```

For each candidate source, establish and record under `sources.interactions` (or `extra_tables`):

- **id**, **text**, **channel** (a column, or a constant per table: `'TICKET'`, `'SURVEY'`, ...).
- **When the customer said it.** Prefer the creation timestamp of the message, not the ticket's
  `updated_at` and never a load/ingest timestamp. This column decides what the model may see; a wrong
  choice here is a leak that no later check can catch. Show `MIN`, `MAX`, and a comparison with any
  load timestamp:

```sql
SELECT MIN(<created_col>) AS first_said, MAX(<created_col>) AS last_said,
       MIN(<loaded_col>)  AS first_loaded, MAX(<loaded_col>) AS last_loaded,
       COUNT_IF(<created_col> > <loaded_col>) AS said_after_loaded   -- should be 0
FROM <source>;
```

- **Thread structure.** Ticket tables often hold one row per ticket with the first message only, or one
  row per message including agent replies. Agent replies are not the customer's voice and must be
  excluded or labeled -- an agent writing "I understand you're considering cancelling" is not a churn
  signal from the customer. Find the author/direction column.

Text length decides cost and the AI_SENTIMENT window:

```sql
SELECT COUNT(*) AS rows,
       COUNT_IF(<text_col> IS NULL OR LENGTH(TRIM(<text_col>)) < 15) AS empty_or_trivial,
       ROUND(AVG(LENGTH(<text_col>)), 0) AS avg_chars,
       APPROX_PERCENTILE(LENGTH(<text_col>), 0.95) AS p95_chars,
       MAX(LENGTH(<text_col>)) AS max_chars
FROM <source>;
```

Rows well above ~8,000 characters are candidates to exceed the 2,048-token AI_SENTIMENT window and
will need windowing (best-practices).

## 5. The account join key -- confirm it explicitly

The worst failure in this play raises no error: complaints joined to the wrong customer's renewal.

```sql
-- What share of interactions resolve to a CRM account?
SELECT COUNT(*) AS interactions,
       COUNT_IF(a.<account_id> IS NOT NULL) AS joined,
       ROUND(100.0 * COUNT_IF(a.<account_id> IS NOT NULL) / NULLIF(COUNT(*), 0), 1) AS pct_joined
FROM <interactions> i
LEFT JOIN <accounts> a ON a.<account_id> = i.<account_key>;
```

If tickets key on a support-org id, a contact email domain, or a billing id, find the mapping table
and record it. Report the join rate. Below roughly 80%, say that a share of the signal will be
invisible to the model and that the at-risk list will under-represent those accounts.

## 6. Renewal outcomes -- the training labels

```sql
SELECT DATE_TRUNC(quarter, <renewal_col>) AS q,
       COUNT(*) AS renewals,
       COUNT_IF(<outcome_col> = '<churn_value>') AS churned,
       ROUND(AVG(IFF(<outcome_col> = '<churn_value>', 1, 0)), 3) AS churn_rate
FROM <outcomes> GROUP BY 1 ORDER BY 1;
```

Establish and record:

- **What counts as churn.** Full non-renewal only, or also downgrades and partial churn? This is a
  business definition; ask the owner, write it into `churn-project.yml`, and keep it fixed per model
  version.
- **Enough positives.** Fewer than a few dozen churned renewals in the history makes AUC unstable
  enough to be meaningless. Say so before Phase 5 rather than after.
- **Notice date.** If notice of non-renewal is tracked, record the column. Notice given more than
  `horizon_days` before renewal makes those rows unpredictable by construction.
- **When the outcome was recorded.** Labels backfilled long after the fact are fine for training but
  matter for the label-known-at-prediction check.

If there is no outcome history at all, the play can still deliver **reasons** (REASONS_ONLY intent)
but not a model. Say so.

## 7. Outcome-derived columns -- name the leaks before they happen

Every CRM has fields that are written *because* the account churned or was flagged. List them now:

```sql
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_name IN ('<accounts>', '<opportunities>', '<health_scores>')
  AND REGEXP_LIKE(column_name,
      '.*(STATUS|STAGE|CANCEL|CHURN|LOST|CLOSED|NOTICE|TERMINAT|RISK|HEALTH|SAVE|ESCALAT).*', 'i');
```

For each, ask: could this value have been known at `renewal_date - horizon_days`? If not, or if it is
a current-state field with no history, add it to `sources.accounts.outcome_derived_cols`. A CSM health
score is the classic case: it is updated after the customer gives notice, so its current value is the
label in disguise. A *historized* health score with an effective date can be a legitimate feature,
point-in-time.

## 8. Usage history

```sql
SELECT MIN(<month_col>), MAX(<month_col>), COUNT(DISTINCT <account_col>) AS accounts,
       COUNT(*) / NULLIF(COUNT(DISTINCT <account_col>), 0) AS months_per_account
FROM <usage>;
```

Usage must reach back at least `lookback_days` plus six months before the earliest training
`as_of_date`, or the trend features are NULL for the oldest rows. Check whether a month's row is final
or revised later (late-arriving usage is a mild leak: a value restated after the cutoff).

## 9. Existing objects

```sql
SELECT table_schema, table_name, row_count, created
FROM information_schema.tables
WHERE REGEXP_LIKE(table_name, '.*(CHURN|AT_RISK|INTERACTION_SIGNALS|ACCOUNT_FEATURES|SIG_).*', 'i')
ORDER BY created DESC;

SHOW MODELS IN SCHEMA <db>.<schema>;
SHOW TASKS IN SCHEMA <db>.<schema>;
```

Surface anything found with row counts and dates, and ask whether to reuse, rename or replace. An
existing model with the same name means Phase 5 must pick a new version name.

## 10. Customer-data posture

Evidence quotes and narratives are customer statements about the vendor, attached to an account
name, often with a contact's name inside the quote. They are more sensitive than the ticket they came
from, because they are concentrated and ranked.

```sql
SELECT policy_name, policy_kind, ref_entity_name, ref_column_name
FROM TABLE(information_schema.policy_references(
    ref_entity_name => '<fully_qualified_interactions_table>', ref_entity_domain => 'TABLE'));

SHOW GRANTS ON TABLE <fully_qualified_interactions_table>;
```

Report: masking/row-access policies on the source; which roles read it today; which roles should read
`AT_RISK_ACCOUNTS` (usually CS leadership and the account's CSM, not all of support); whether a row
access policy by owner is needed. Do not create policies here; record the decision and honour it when
Phase 6 creates the table. If quotes may contain personal data and the output audience is broader than
the source audience, recommend `AI_REDACT` on the evidence quote before display, and note it for
Phase 6.

## 11. Warehouse

```sql
SHOW WAREHOUSES LIKE '<candidate>';
```

AI function throughput is dominated by the inference service, not warehouse size. A small or medium
warehouse with short auto-suspend is usually right. Model training in a notebook uses its own
compute; warehouse inference for scoring is light.

---

## Output of this phase

A short summary: functions available; evidence model pinned and verified date; cross-region setting;
registry privileges and training location; each interaction source with its id/text/channel/said-at
mapping and customer-only filter; account join rate; outcome history with positives per quarter,
churn definition and notice column; outcome-derived columns listed; usage coverage; existing objects;
data posture decision. Then the settled values in `churn-project.yml` and `phases.preflight: done`.
Unresolved values stay absent.
