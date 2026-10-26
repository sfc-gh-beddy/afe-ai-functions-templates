---
name: icd10-extraction-system-of-record
description: "Preflight discovery for an ICD-10 / HCC suspecting build. Establishes what the account can actually run and what already exists, before anything is created: Cortex AI function access via EXPLAIN_PRIVILEGES, per-stage model availability via SHOW CORTEX BASE MODELS (region-dependent), the customer's clinical document inventory and column mapping, the text-native versus scanned split that determines tier mix and cost, existing pipeline objects, and PHI posture (masking policies, row access policies, who can read the output). Always loaded first by the icd10-extraction router."
parent_skill: icd10-extraction
---

# Preflight — what this account can run, and what is already here

Run this before creating anything. It exists to prevent three specific bad outcomes: building a
pipeline around a model the account cannot call, guessing column names that do not exist, and
promising a cost profile that this corpus will not deliver.

Report findings as a compact summary and write settled values into `icd10-project.yml`. Do not
create objects in this phase.

---

## 1. Cortex AI function access

First call of the session. `EXPLAIN_PRIVILEGES` analyzes the current session without executing the
functions — no credits, no model calls.

```sql
SELECT
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COMPLETE('llama3.1-8b','x')$$,                         missing_only => true) AS ai_complete,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_PARSE_DOCUMENT(TO_FILE('@~/x.pdf'), {'mode':'OCR'})$$, missing_only => true) AS ai_parse_document,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_EXTRACT(text => 'x', responseFormat => {'k':'q'})$$,   missing_only => true) AS ai_extract,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_CLASSIFY('x',['a','b'])$$,                             missing_only => true) AS ai_classify,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COUNT_TOKENS('ai_complete','llama3.1-8b','x')$$,        missing_only => true) AS ai_count_tokens;
```

`{"authorized": true}` means the role can call it. Anything else is a blocker for the stages that
depend on it:

| Function | Needed for | If unavailable |
|---|---|---|
| `AI_COMPLETE` | routing classifier, compression, coder, judge | **hard stop** — this is the pipeline |
| `AI_PARSE_DOCUMENT` | OCR for scanned documents | only a blocker if the corpus has scanned files |
| `AI_EXTRACT` | structured-form tier | degrade that tier to `AI_COMPLETE` |
| `AI_CLASSIFY` | optional routing alternative | not a blocker |
| `AI_COUNT_TOKENS` | cost estimation and token windowing | not a blocker; note estimates will be unavailable |

Remediation when access is missing — surface the grant, do not work around it:

```sql
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <role>;
```

If the check itself errors, note that access was not verified and continue. It is best-effort, never
a hard blocker on its own.

## 2. Model availability is regional — verify per stage

Model availability varies by region, and models move through `LEGACY` and `EOL` lifecycle states. A
build that hardcodes a model name copied from a document written elsewhere, or written a few months
ago, will fail at run time or silently run on a model scheduled for removal.

```sql
SHOW CORTEX BASE MODELS;
```

The output carries `lifecycle_status`, `in_region_availability`, `legacy_date`, and `eol_date`.
Filter to what is safe to build on:

```sql
SHOW CORTEX BASE MODELS;

SELECT "name", "lifecycle_status", "legacy_date", "eol_date"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "lifecycle_status" = 'GA'
ORDER BY "name";
```

**Do not pin a model whose `lifecycle_status` is `LEGACY`, `EOL`, or blank.** `LEGACY` means only
accounts already using it can call it and it has a removal date; `EOL` means it is gone. This is a
real trap — several models that appear in older reference material and blog posts are now `LEGACY`.
Check, then pin, and record the check date alongside the choice.

The pipeline needs four models, one per stage. Confirm each candidate is `GA` and available in this
account's region, then pin the choices into `models` in `icd10-project.yml`.

| Stage | Wants | Why |
|---|---|---|
| `classify` | small, fast, GA | routing runs on every document; a large model here is pure waste |
| `compress` | mid-tier, long context | must hold a full chart; context and price matter more than peak quality |
| `extract` (coder) | strongest available | clinical reasoning plus code specificity; whole-pipeline accuracy sits here |
| `judge` | mid to strong | scoring is a reasoning task; a weak judge produces undiscriminating scores |

Do not silently substitute a model. If the preferred one is unavailable or `LEGACY`, say which one is
being used instead and what the tradeoff is.

## 3. Find the clinical documents

If the user named a table, describe it. If not, look for candidates rather than asking them to
recall a fully qualified name:

```sql
SELECT table_catalog, table_schema, table_name, row_count,
       ROUND(bytes / POWER(1024, 3), 1) AS gb
FROM information_schema.tables
WHERE table_type = 'BASE TABLE'
  AND (table_name ILIKE '%DOC%'  OR table_name ILIKE '%NOTE%'
    OR table_name ILIKE '%CHART%' OR table_name ILIKE '%CLINICAL%'
    OR table_name ILIKE '%ENCOUNTER%' OR table_name ILIKE '%REFERRAL%')
ORDER BY row_count DESC NULLS LAST
LIMIT 25;
```

Then map columns and write the mapping into `documents` in `icd10-project.yml`. Confirm the mapping
with the user before proceeding — a wrong `patient_id_col` produces a pipeline that runs perfectly
and correlates evidence across the wrong people, which is the single worst failure mode available
here.

Required: document id, patient id, and either text or a stage-relative file path.
Valuable when present: document type, source system, document date, page count.

## 4. The text-native versus scanned split drives everything downstream

This is the number that determines tier mix, and therefore cost, and therefore whether the promised
savings are achievable on this corpus.

```sql
SELECT
    COUNT(*)                                                     AS total_docs,
    COUNT_IF(<text_col> IS NOT NULL AND LENGTH(<text_col>) > 200) AS text_native,
    COUNT_IF(<text_col> IS NULL OR LENGTH(<text_col>) <= 200)     AS needs_ocr,
    ROUND(100.0 * COUNT_IF(<text_col> IS NULL OR LENGTH(<text_col>) <= 200)
          / NULLIF(COUNT(*), 0), 1)                               AS pct_needs_ocr
FROM <source_table>;
```

A mostly text-native corpus routes cheaply and the OCR-avoidance lever matters little. A mostly
scanned corpus is where routing earns its keep. Say which one this is, and set expectations
accordingly rather than repeating a generic savings figure.

## 5. Are the routing signals actually populated?

The cheapest routing exits depend on metadata. If that metadata is mostly `NULL`, those exits cannot
fire and the cost profile changes materially. Check before promising it:

```sql
SELECT
    COUNT(*) AS total,
    ROUND(100.0 * COUNT(<type_col>)          / NULLIF(COUNT(*), 0), 1) AS pct_has_type,
    ROUND(100.0 * COUNT(<source_system_col>) / NULLIF(COUNT(*), 0), 1) AS pct_has_source,
    COUNT(DISTINCT <type_col>)               AS distinct_types,
    COUNT(DISTINCT <source_system_col>)      AS distinct_sources
FROM <source_table>;
```

Then look at the actual distribution — the high-frequency document types are what the skip patterns
and the tier rules will be built from:

```sql
SELECT <type_col> AS document_type, <source_system_col> AS source_system, COUNT(*) AS docs
FROM <source_table>
GROUP BY 1, 2
ORDER BY docs DESC
LIMIT 40;
```

Low cardinality with high population is ideal. Free-text document types with hundreds of distinct
values mean routing will lean on the model classifier rather than cheap metadata rules. Report which
situation this is.

## 6. Claims history for suppression

The pipeline reports gaps, which requires knowing what is already coded.

```sql
SELECT table_schema, table_name, row_count
FROM information_schema.tables
WHERE table_name ILIKE '%CLAIM%' OR table_name ILIKE '%DIAGNOS%'
   OR table_name ILIKE '%HCC%'   OR table_name ILIKE '%RISK%'
ORDER BY row_count DESC NULLS LAST;
```

Note the code format on the claims side. `HCC85` versus `85` versus `I50.22` determines the join,
and getting it wrong empties the output. Record the observed format.

If there is no claims history, say plainly what that means: the pipeline will surface conditions
regardless of whether they are already coded, so a share of output will be restatement rather than
gap, and precision figures will read low for a reason that is not the model's fault.

## 7. Existing pipeline objects

Do not overwrite work already in progress.

```sql
SELECT table_schema, table_name, row_count, created
FROM information_schema.tables
WHERE table_name ILIKE '%SUSPECT%' OR table_name ILIKE '%ROUTING%'
   OR table_name ILIKE '%ICD10%'   OR table_name ILIKE '%HCC%'
ORDER BY created DESC;

SHOW CORTEX SEARCH SERVICES;
```

Anything found gets surfaced to the user with its row count and creation date, and an explicit
question about whether to reuse, rename, or replace.

## 8. PHI posture

A suspect record is a clinical summary with a patient attached — frequently more readable than the
chart it came from. Report the controls that exist, before creating a table that will hold them.

```sql
-- Masking and row access policies already protecting the source documents.
SELECT policy_name, policy_kind, ref_entity_name, ref_column_name
FROM TABLE(information_schema.policy_references(
    ref_entity_name => '<fully_qualified_source_table>',
    ref_entity_domain => 'TABLE'));
```

```sql
-- Who can read the source today? The output table will need a deliberate
-- decision, not an inherited default.
SHOW GRANTS ON TABLE <fully_qualified_source_table>;
```

Report:

- policies protecting the source, and whether the same protection should extend to the output;
- which roles can read the source, and which should be able to read suspects — these are frequently
  not the same set, since suspects are worked by coders rather than clinicians;
- whether the target schema is governed differently from the source schema.

Do not create policies in this phase. Surface the gap and let the user decide, then honour that
decision when the output table is created.

## 9. Warehouse

```sql
SHOW WAREHOUSES LIKE '<candidate>';
```

Confirm size and auto-suspend. AI function throughput is dominated by the inference service rather
than warehouse size, so an oversized warehouse mostly burns credits waiting. A small or medium
warehouse with a short auto-suspend is usually right; note if the chosen one is far larger.

---

## Output of this phase

A short written summary covering: functions available, models pinned per stage, document table and
column mapping, corpus size with the text-native/scanned split, routing signal quality, claims
availability and code format, existing objects, and PHI posture. Then the settled values written
into `icd10-project.yml` and `phases.preflight: done`.

Anything unresolved stays absent from the state file rather than being filled with a plausible
default — an absent key means the next phase asks, and that is the correct behaviour.
