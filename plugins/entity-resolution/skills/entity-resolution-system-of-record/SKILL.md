---
name: entity-resolution-system-of-record
description: "Preflight discovery for an entity resolution build. Establishes what the account can run and what the data looks like before anything is created: AI_EMBED, AI_SIMILARITY, AI_COMPLETE and AI_COUNT_TOKENS access via EXPLAIN_PRIVILEGES (CORTEX_USER or CORTEX_EMBED_USER), embedding and adjudication model availability and lifecycle via SHOW CORTEX BASE MODELS IN SCHEMA SNOWFLAKE.MODELS, the CORTEX_ENABLED_CROSS_REGION setting, whether snowflake-decision is visible, discovery of customer, vendor and product master tables across systems, column mapping and record_uid construction, record status values to filter, attribute fill rates, placeholder values in identifier columns, sensitive fields to exclude from AI (bank, payment, government ids), existing masking and row access policies, existing matching or MDM objects, and warehouse sizing. Always loaded first by the entity-resolution router."
parent_skill: entity-resolution
---

# Preflight — what this account can run, and what the data looks like

Run this before creating anything. It prevents four bad outcomes: building around a model the account
cannot call, guessing column mappings, promising a blocking strategy the data cannot support, and
sending sensitive fields to a model.

Report a compact summary and write settled values into `er-project.yml`. Create nothing in this phase.

---

## 1. AI function access

`EXPLAIN_PRIVILEGES` analyzes privileges without executing the functions — no credits.

```sql
SELECT
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_EMBED('snowflake-arctic-embed-l-v2.0', 'x')$$, missing_only => true) AS ai_embed,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_SIMILARITY('x', 'y')$$,                          missing_only => true) AS ai_similarity,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COMPLETE('llama3.1-8b', 'x')$$,                  missing_only => true) AS ai_complete,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COUNT_TOKENS('ai_embed', 'snowflake-arctic-embed-l-v2.0', 'x')$$, missing_only => true) AS ai_count_tokens;
```

| Function | Needed for | If unavailable |
|---|---|---|
| `AI_EMBED` | embeddings, semantic blocking, `cos_sim` feature | not a hard stop: scoring falls back to deterministic features and lexical blocking only; say what is lost (word-order and synonym variation) |
| `AI_SIMILARITY` | parity check, ad hoc probes | not a blocker |
| `AI_COMPLETE` | adjudication of the review band | not a hard stop: the review band goes to stewards; say so |
| `AI_COUNT_TOKENS` | estimates at every gate | not a blocker; estimates unavailable |

The function references state the required role: `SNOWFLAKE.CORTEX_USER`, or for `AI_EMBED`
alternatively `SNOWFLAKE.CORTEX_EMBED_USER`. Surface the grant; do not work around it:

```sql
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <role>;
```

If the check itself errors, note that access was not verified and continue.

## 2. Models: availability, lifecycle, region

Cortex Base Models live in `SNOWFLAKE.MODELS`. The command reference notes that an unqualified
`SHOW CORTEX BASE MODELS` can return no rows when another schema is current — scope it:

```sql
SHOW CORTEX BASE MODELS IN SCHEMA SNOWFLAKE.MODELS;

SELECT "name", "lifecycle_status", "in_region_availability", "legacy_date", "eol_date"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
ORDER BY "name";
```

Pin two models into `er-project.yml`, recording `verified_on`:

| Stage | Wants | Notes |
|---|---|---|
| `embed.model` | an embedding model available in region | The `AI_EMBED` reference lists text models including `snowflake-arctic-embed-l-v2.0` (1024 dimensions), `snowflake-arctic-embed-l-v2.0-8k`, `snowflake-arctic-embed-m-v1.5` (768), `multilingual-e5-large`, `voyage-multilingual-2`, `nv-embed-qa-4`, `e5-base-v2`. Prefer a multilingual model when names span languages or scripts. Set `embed.dimensions` to match. |
| `adjudicate.model` | `GA`, strong structured-output adherence, available in region | Do not pin a `LEGACY`, `EOL` or blank-lifecycle model. |

Do not silently substitute. If the preferred model is unavailable, say which is used and why.

### Cross-region inference

Many models are available only through cross-region inference. Check the account setting:

```sql
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
```

If it is `DISABLED` and the chosen model is not in the account's region, the call fails at run time.
Enabling it is an account-level decision (it allows inference to run in another region) and typically
needs `ACCOUNTADMIN`. Surface it to the user with that implication; do not change it from this skill.
Data residency requirements for customer or vendor PII may rule it out — ask.

### `snowflake-decision`

The October 2026 release notes announce Snowflake Decision (`snowflake-decision`, via `AI_COMPLETE`) as
private preview, and the regional availability table lists `snowflake-decision-fast`. Check visibility:

```sql
SHOW CORTEX BASE MODELS LIKE 'snowflake-decision%' IN SCHEMA SNOWFLAKE.MODELS;
```

If no rows, record `adjudicate.engine: ai_complete`. If rows appear, the account may be enrolled — but
the request format is documented on a limited-access page. Record `adjudicate.engine: ai_complete` for
now and note `snowflake_decision_available: true`; `adjudicate-match-pairs` explains how to add it as a
second engine once the format is confirmed from the account's preview documentation.

## 3. Find the master data

If the user named tables, describe them. Otherwise look for candidates rather than asking for fully
qualified names:

```sql
SELECT table_catalog, table_schema, table_name, row_count, last_altered
FROM <db>.information_schema.tables
WHERE table_type IN ('BASE TABLE', 'VIEW')
  AND REGEXP_LIKE(table_name, '.*(CUSTOMER|ACCOUNT|CLIENT|VENDOR|SUPPLIER|PAYEE|PARTNER|PARTY|ORG|COMPANY|PRODUCT|ITEM|MATERIAL|SKU|CATALOG).*', 'i')
ORDER BY row_count DESC NULLS LAST
LIMIT 50;
```

Repeat per database the role can see. For each candidate, establish with the user:

- **system name** — becomes the `source_system` prefix of `record_uid`; short, stable, uppercase
- **entity type** — `CUSTOMER`, `VENDOR`, `PRODUCT`; partner tables with role flags map per role
- **key column** — must be unique in the table; verify:

```sql
SELECT COUNT(*) AS rows, COUNT(DISTINCT <key_col>) AS distinct_keys, COUNT_IF(<key_col> IS NULL) AS null_keys
FROM <table>;
```

  A non-unique key makes `record_uid` non-unique and breaks the crosswalk. If the natural key is
  composite (company code plus vendor number), build the source id as a delimited concatenation and
  record the construction in `sources`.

- **column map** — name (and overflow fields), address lines, city, region, postal, country, phone,
  email, website, tax id; for products description, brand, MPN, GTIN, size, category
- **trust rank** — which system is the system of record for legal names and identifiers
- **status filter** — merged, blocked, deleted, inactive values to exclude:

```sql
SELECT <status_col>, COUNT(*) FROM <table> GROUP BY 1 ORDER BY 2 DESC;
```

Records the business already merged are also a free source of **known true pairs** for evaluating real
data: if a merged record carries a pointer to its survivor, keep that mapping for
`evaluate-match-accuracy`.

Write `sources` and `record_uid_format` into `er-project.yml` and confirm with the user. A wrong key or
an unmapped overflow field produces a pipeline that runs cleanly and is wrong.

## 4. Fill rates and blocking feasibility

Blocking passes only work on populated attributes. Measure per source before choosing rules:

```sql
SELECT
    COUNT(*) AS rows,
    ROUND(100 * COUNT(NULLIF(TRIM(<name_col>), ''))    / COUNT(*), 1) AS pct_name,
    ROUND(100 * COUNT(NULLIF(TRIM(<postal_col>), ''))  / COUNT(*), 1) AS pct_postal,
    ROUND(100 * COUNT(NULLIF(TRIM(<city_col>), ''))    / COUNT(*), 1) AS pct_city,
    ROUND(100 * COUNT(NULLIF(TRIM(<phone_col>), ''))   / COUNT(*), 1) AS pct_phone,
    ROUND(100 * COUNT(NULLIF(TRIM(<email_col>), ''))   / COUNT(*), 1) AS pct_email,
    ROUND(100 * COUNT(NULLIF(TRIM(<tax_id_col>), ''))  / COUNT(*), 1) AS pct_tax_id
FROM <table>;
```

Say which situation this is: identifiers well populated (tax-id and phone rules will carry hard
positives), or sparse (name and location rules plus semantic blocking carry everything, and recall on
relocations and rebrands will be limited — set that expectation now).

## 5. Placeholder values

Find values shared by implausibly many records in every exact-match column:

```sql
SELECT <col> AS value, COUNT(*) AS records
FROM <table>
WHERE <col> IS NOT NULL
GROUP BY 1
HAVING COUNT(*) > 5
ORDER BY 2 DESC
LIMIT 20;
```

Typical finds: `000000000`, `N/A`, `UNKNOWN`, a company's own switchboard on every contact,
`noreply@`, `TBD`. Add each to the placeholder exclusions in the standardize SQL. Placeholders as keys
build giant blocks; placeholders as evidence build false merges and false cannot-links (rules 8, 16).

## 6. Sensitive fields

List columns that must never reach a model or embedding:

```sql
SELECT table_name, column_name, data_type
FROM <db>.information_schema.columns
WHERE table_schema = '<schema>'
  AND REGEXP_LIKE(column_name, '.*(BANK|IBAN|SWIFT|BIC|ROUTING|ACCOUNT_NO|ACCT|CARD|PAN|SSN|NATIONAL_ID|PASSPORT|DOB|BIRTH|SALARY).*', 'i');
```

Add them to `excluded_from_ai`. They are also excluded from staging entirely — nothing in this pipeline
needs them. If the account uses classification tags, `SYSTEM$GET_TAG` or the `data-governance` skill
gives a more complete picture than name patterns.

## 7. Existing protection

```sql
SELECT policy_name, policy_kind, ref_entity_name, ref_column_name
FROM TABLE(<db>.information_schema.policy_references(
    ref_entity_name => '<fully_qualified_table>', ref_entity_domain => 'TABLE'));

SHOW GRANTS ON TABLE <fully_qualified_table>;
```

Report what protects each source, and that the golden table and crosswalk will concentrate attributes
from all of them. Do not create policies here; surface the gap and record the user's decision for
Phase 5 and Phase 7.

## 8. Existing matching or MDM objects

Do not overwrite work in progress, and do not ignore matching the customer already does:

```sql
SELECT table_catalog, table_schema, table_name, row_count, created
FROM <db>.information_schema.tables
WHERE REGEXP_LIKE(table_name, '.*(GOLDEN|MASTER|XREF|CROSSWALK|DEDUP|MATCH|SURVIVOR|^ER_).*', 'i')
ORDER BY created DESC;
```

An existing cross-reference from an MDM tool is valuable: it is a partial answer key on real data, and
a baseline the new pipeline should be compared against rather than silently replaced.

## 9. Warehouse

```sql
SHOW WAREHOUSES LIKE '<candidate>';
```

Pair generation and scoring are SQL joins whose cost scales with candidate pairs; AI function
throughput is dominated by the inference service. A small or medium warehouse with short auto-suspend is
usually right; the semantic KNN self-join is the step most likely to benefit from a larger size on large
partitions.

## 10. Materialization mode and scope

Ask once: dbt or plain SQL (`materialization.mode`), and which entity types are in scope
(`scope.entity_types`, `scope.cross_type_party`). See the router.

---

## Output of this phase

A short written summary: functions available and missing grants; models pinned with lifecycle and
region, cross-region setting; `snowflake-decision` visibility; sources with keys, maps, trust ranks and
filters; fill rates and which blocking rules are feasible; placeholders found; excluded sensitive
columns; protection on sources; existing matching objects; warehouse. Then the settled values in
`er-project.yml` and `phases.preflight: done`. Anything unresolved stays absent.
