---
name: voc-system-of-record
description: "Preflight discovery for a voice-of-customer build. Establishes what the account can run and what feedback data exists before anything is created: AI function access (AI_CLASSIFY, AI_SENTIMENT, AI_SUMMARIZE_AGG, AI_AGG, AI_TRANSLATE, AI_REDACT, AI_EMBED, AI_COMPLETE, AI_COUNT_TOKENS) via EXPLAIN_PRIVILEGES, model availability and lifecycle via SHOW CORTEX BASE MODELS, CORTEX_ENABLED_CROSS_REGION and model allowlist and RBAC restrictions, feedback inventory across reviews, social, surveys and support, column mapping, language mix, length distribution against the AI_SENTIMENT 2,048-token window, duplicate and syndication rate, SKU and region linkability, any existing taxonomy or tagging, existing pipeline objects, and sensitive-data posture (PII in feedback text, masking and row access policies, who should read verbatims). Always loaded first by the voice-of-customer router."
parent_skill: voice-of-customer
---

# Preflight: what this account can run, and what feedback is here

Run this before creating anything. It prevents four specific bad outcomes: building around a
function or model the account cannot call, guessing column names, promising a cost profile the
corpus will not deliver, and processing personal data under a posture nobody decided.

Report findings as a compact summary and write settled values into `voc-project.yml`. Create
nothing in this phase.

---

## 1. AI function access

`EXPLAIN_PRIVILEGES` analyses the statement without executing it: no model calls, no credits.

```sql
SELECT
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_CLASSIFY('x', ['a','b'])$$,                         missing_only => TRUE) AS ai_classify,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_SENTIMENT('x', ['a'])$$,                            missing_only => TRUE) AS ai_sentiment,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_SUMMARIZE_AGG(column1) FROM VALUES ('x')$$,          missing_only => TRUE) AS ai_summarize_agg,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_AGG(column1, 'Summarize') FROM VALUES ('x')$$,       missing_only => TRUE) AS ai_agg,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_TRANSLATE('x', '', 'en')$$,                          missing_only => TRUE) AS ai_translate,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_REDACT('x')$$,                                       missing_only => TRUE) AS ai_redact,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_EMBED('snowflake-arctic-embed-l-v2.0', 'x')$$,       missing_only => TRUE) AS ai_embed,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COMPLETE('claude-sonnet-4-5', 'x')$$,                missing_only => TRUE) AS ai_complete,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COUNT_TOKENS('ai_sentiment', 'x')$$,                 missing_only => TRUE) AS ai_count_tokens;
```

`{"authorized": true}` means the role can call it. Map anything else to impact:

| Function | Needed for | If unavailable |
|---|---|---|
| `AI_CLASSIFY` | topic classification, relevance gate, return-intent flag | **hard stop**: fall back to `AI_COMPLETE` with a schema only if that is authorised, and say accuracy is unmeasured until re-evaluated |
| `AI_SENTIMENT` | aspect-level sentiment | **hard stop** for the aspect phase; an `AI_COMPLETE` schema fallback exists but is costlier and must be re-evaluated |
| `AI_SUMMARIZE_AGG`, `AI_AGG` | theme summaries | summaries phase blocked; everything else proceeds |
| `AI_TRANSLATE` | non-English feedback | blocker only if the language mix (section 5) is material |
| `AI_REDACT` | PII redaction before AI calls and in summaries | blocker only if the posture (section 9) requires redaction |
| `AI_EMBED` | out-of-taxonomy theme detection | emerging-theme phase degrades to topic-series spikes only; drift detection is weaker |
| `AI_COMPLETE` | naming proposed themes | proposals become manual; not a blocker |
| `AI_COUNT_TOKENS` | cost estimation, window checks | not a blocker; window checks fall back to character heuristics, say so |

Remediation: surface the grant, do not work around it.

```sql
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <role>;
```

If `EXPLAIN_PRIVILEGES` itself errors, note that access was not verified and continue. It is
best-effort, never a blocker on its own.

## 2. Models: which calls choose one, and which do not

`AI_CLASSIFY`, `AI_SENTIMENT`, `AI_SUMMARIZE_AGG`, `AI_AGG`, `AI_TRANSLATE` and `AI_REDACT` run on
Snowflake-managed models and take no model argument. Do not try to "pin" a model for them; pin the
**function** behaviour by recording the run date and re-running the evaluation after Snowflake
release notes announce a change to the underlying model.

Two calls do choose a model: `AI_EMBED` (emerging-theme novelty) and `AI_COMPLETE` (naming proposed
themes, optional fallbacks). Verify both:

```sql
SHOW CORTEX BASE MODELS;

SELECT "name", "lifecycle_status", "legacy_date", "eol_date"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "lifecycle_status" = 'GA'
ORDER BY "name";
```

**Do not pin a model whose `lifecycle_status` is `LEGACY`, `EOL`, or blank.** Record the choice and
the check date in `models` in `voc-project.yml`. If the preferred model is unavailable, say which one
is used instead and what the tradeoff is.

For `AI_EMBED`, the model choice fixes the vector dimension. Embeddings from different models are
not comparable, so a model change requires re-embedding everything, including the taxonomy node
embeddings. Record `models.embed` and `models.embed_dims` and verify the dimension with a one-row
call rather than assuming it:

```sql
-- There is no VECTOR_DIMS function; cast to ARRAY and count.
SELECT ARRAY_SIZE(AI_EMBED('<embed_model>', 'dimension check')::ARRAY) AS dims;
```

## 3. Region, cross-region inference, and model restrictions

```sql
SELECT CURRENT_REGION();
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
SHOW PARAMETERS LIKE 'CORTEX_MODELS_ALLOWLIST' IN ACCOUNT;
```

Report three things:

- **Region availability.** A function or model not available in-region either fails or requires
  cross-region inference. Check the regional availability page for every function this build uses,
  not only the ones with a model argument.
- **`CORTEX_ENABLED_CROSS_REGION`.** If it is `DISABLED` and something needed is not in-region, that
  is a blocker. If it is enabled, feedback text is processed in another region: this is a data
  residency question for the customer's governance team, especially for EU feedback. Surface it;
  do not decide it.
- **Allowlist and model RBAC.** A model outside `CORTEX_MODELS_ALLOWLIST`, or without model RBAC
  usage for the role, fails at call time even though `EXPLAIN_PRIVILEGES` on the function passed.
  Test-call each pinned model once on a literal string.

Changing `CORTEX_ENABLED_CROSS_REGION` is an account-level decision for an `ACCOUNTADMIN` and the
customer's governance owner. Never change it from this build.

## 4. Find the feedback

If the user named tables, describe them. Otherwise look rather than ask them to recall names:

```sql
SELECT table_catalog, table_schema, table_name, row_count,
       ROUND(bytes / POWER(1024, 3), 2) AS gb, last_altered
FROM information_schema.tables
WHERE table_type IN ('BASE TABLE', 'VIEW', 'DYNAMIC TABLE')
  AND (table_name ILIKE '%REVIEW%'   OR table_name ILIKE '%FEEDBACK%'
    OR table_name ILIKE '%SURVEY%'   OR table_name ILIKE '%NPS%'
    OR table_name ILIKE '%VERBATIM%' OR table_name ILIKE '%SOCIAL%'
    OR table_name ILIKE '%MENTION%'  OR table_name ILIKE '%COMMENT%'
    OR table_name ILIKE '%CSAT%'     OR table_name ILIKE '%RATING%')
ORDER BY row_count DESC NULLS LAST
LIMIT 40;
```

For free-text columns across the account, `shared/sql/discover_unstructured.sql` in the repository
lists candidate `VARCHAR`/`VARIANT` columns by name pattern. Social listening exports frequently land
as `VARIANT`; check for nested text fields (`raw:text`, `raw:body`, `raw:content`).

For each candidate source, map columns into `sources` in `voc-project.yml` and **confirm with the
user**:

- Required: item id, text, created timestamp, channel (constant per source is fine).
- Strongly valuable: SKU or product id, region or market, author key (for dedup scope only),
  source system (for syndication detection), reported language.
- Context only: star rating, NPS score. Record them, but they are never sentiment ground truth.

A wrong SKU mapping is the worst failure available here: the pipeline runs perfectly and attributes
complaints to the wrong product. Show five joined rows (text, mapped SKU, product name) and ask the
user whether they match.

## 5. Language mix

`AI_CLASSIFY` is optimised for English; `AI_SENTIMENT` supports English, French, German, Hindi,
Italian, Spanish and Portuguese and errors outside them. The reported language column is often
missing or wrong. Measure rather than trust it:

```sql
-- Reported language, if the source has it.
SELECT <language_col> AS reported_language, COUNT(*) AS items
FROM <source_table> GROUP BY 1 ORDER BY 2 DESC;
```

Then sample 200 rows and detect. There is no dedicated language-detection function; use
`AI_CLASSIFY` with a short language list on a sample only, never on the full table at preflight:

```sql
WITH s AS (SELECT <text_col> AS t FROM <source_table> SAMPLE (200 ROWS))
SELECT AI_CLASSIFY(LEFT(t, 1000),
                   ['English','Spanish','French','German','Portuguese','Italian','Japanese','Chinese','Other language'],
                   {'task_description': 'Identify the language the customer text is written in.'}
                  ):labels[0]::STRING AS detected_language,
       COUNT(*) AS items
FROM s GROUP BY 1 ORDER BY 2 DESC;
```

Report the non-English share and record `normalize.translate_non_english`. A corpus under a few
percent non-English can reasonably exclude those items with a recorded exclusion reason; a materially
multilingual corpus must translate, and the evaluation must then include translated items.

## 6. Length against the sentiment window

`AI_SENTIMENT` is optimised for 2,048 tokens and errors above it. Survey open-ends and long reviews
exceed it more often than expected. `AI_COUNT_TOKENS('ai_sentiment', ...)` is exact for the default
model, so measure on a sample:

```sql
WITH s AS (SELECT <text_col> AS t FROM <source_table> SAMPLE (1000 ROWS))
SELECT
    APPROX_PERCENTILE(AI_COUNT_TOKENS('ai_sentiment', t), 0.50) AS p50_tokens,
    APPROX_PERCENTILE(AI_COUNT_TOKENS('ai_sentiment', t), 0.95) AS p95_tokens,
    MAX(AI_COUNT_TOKENS('ai_sentiment', t))                     AS max_tokens,
    COUNT_IF(AI_COUNT_TOKENS('ai_sentiment', t) > 2048)         AS over_window,
    COUNT_IF(LENGTH(TRIM(t)) < 15)                              AS near_empty
FROM s;
```

Over-window items need segmentation in `extract-aspect-sentiment`; near-empty items ("ok", "5") carry
no topic and should be excluded by the relevance gate rather than classified.

## 7. Duplicates, syndication and campaigns

```sql
SELECT
    COUNT(*)                                                              AS items,
    COUNT(DISTINCT MD5(LOWER(TRIM(<text_col>))))                          AS distinct_texts,
    COUNT(DISTINCT <author_col> || '::' || MD5(LOWER(TRIM(<text_col>))))  AS distinct_author_texts
FROM <source_table>;
```

- `items` much greater than `distinct_author_texts`: the same person's text appears several times,
  usually review syndication across retailer sites. Dedup by author and text.
- `distinct_author_texts` much greater than `distinct_texts`: many authors share text. Some is
  template collision ("Great product"), some is campaigns or bots. Text-only dedup would delete real
  customers; it must not be the default.

Report the rates and record `normalize.dedup_scope`.

## 8. Existing taxonomy, tagging and pipeline objects

Many VoC programs already have a taxonomy, a vendor tagging scheme, or a support reason-code list.
Reusing it is usually right: the business already reports on it.

```sql
SELECT table_schema, table_name, row_count
FROM information_schema.tables
WHERE table_name ILIKE '%TAXONOM%' OR table_name ILIKE '%CATEGOR%'
   OR table_name ILIKE '%TOPIC%'   OR table_name ILIKE '%REASON%'
   OR table_name ILIKE '%TAG%'     OR table_name ILIKE '%THEME%'
ORDER BY row_count DESC NULLS LAST;
```

If a tagging column exists on the feedback itself (vendor-assigned topics), it is **not** ground
truth: vendor tags have their own error rate. It is a useful comparison and a bootstrap source for
the taxonomy. Record its location.

Existing pipeline objects:

```sql
SELECT table_schema, table_name, row_count, created
FROM information_schema.tables
WHERE table_name ILIKE 'VOC%' OR table_name ILIKE '%SENTIMENT%' OR table_name ILIKE '%ENRICHED%'
ORDER BY created DESC;

SHOW SEMANTIC VIEWS;
SHOW AGENTS;
```

Surface anything found with row counts and dates and ask whether to reuse, rename or replace.

## 9. Sensitive-data posture

Feedback text routinely contains personal data: names, emails, phone numbers, order numbers,
addresses, and occasionally health or payment details. Social handles are personal data. Report the
existing controls and get a decision before anything processes the text.

```sql
SELECT policy_name, policy_kind, ref_entity_name, ref_column_name
FROM TABLE(information_schema.policy_references(
    ref_entity_name   => '<fully_qualified_source_table>',
    ref_entity_domain => 'TABLE'));

SHOW GRANTS ON TABLE <fully_qualified_source_table>;
```

Check whether the account has run sensitive-data classification on the feedback tables (tags such as
`SNOWFLAKE.CORE.SEMANTIC_CATEGORY` on the columns). If governance work is needed, delegate it to the
`data-governance` skill rather than doing it here.

Decide with the user, and record in `normalize.redact_pii`:

- **Redact before AI processing and in all derived text** (`AI_REDACT` in normalize). Safest; costs
  one extra call per item; summaries then cannot leak a name.
- **Redact only in derived outputs** (summaries, agent responses). Classification sees raw text;
  summaries are built from redacted text.
- **No redaction**, with a recorded reason (for example, text already scrubbed upstream).

Also decide who reads what. Aggregates (topic counts, aspect scores) can usually be shared widely.
Verbatims cannot. The semantic view and agent built in Phase 7 must not expose author keys and should
expose verbatims only to roles that can read the source.

## 10. Warehouse

```sql
SHOW WAREHOUSES LIKE '<candidate>';
```

AI function throughput is dominated by the inference service rather than warehouse size. A small or
medium warehouse with short auto-suspend is usually right; say so if the chosen one is much larger.

---

## Output of this phase

A short written summary: functions authorised, models pinned with check date, region and
cross-region setting with the residency implication, sources and column mappings (confirmed), corpus
size by channel, language mix, length distribution and over-window share, duplicate and syndication
rates, existing taxonomy or tagging, existing objects, and the sensitive-data decision. Then the
settled values written to `voc-project.yml` and `phases.preflight: done`.

Anything unresolved stays absent from the state file. An absent key means the next phase asks.
