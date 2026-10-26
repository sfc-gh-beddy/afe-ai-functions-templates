---
name: build-resolution-knowledge-store
description: "Build the grounding layer for suggested resolutions and deflection: a chunk table over published knowledge base articles and over the resolution notes of closed tickets, redacted before indexing, and a Cortex Search service on it with product, category, article type and source attributes for filtering. Covers excluding draft and retired articles, filtering stock close-note phrases, self-retrieval leakage when evaluating on tickets whose own resolution is indexed, pinning the search embedding model to match the linking embeddings (the service default differs), chunking with SPLIT_TEXT_RECURSIVE_CHARACTER, TARGET_LAG and refresh cost, and gate verification with SEARCH_PREVIEW. Phase 3 of the ticket-triage build. Triggers: knowledge base search, KB index, Cortex Search over KB, ground suggestions, resolution knowledge."
parent_skill: ticket-triage
---

# Build the resolution knowledge store

Suggested resolutions and deflection are only as good as what they are grounded in. This phase builds a
single searchable corpus from two sources:

1. **Published KB articles** — authoritative, reviewed, often incomplete and sometimes stale.
2. **Resolution notes from closed tickets** — what agents actually did, covering issues nobody wrote an
   article for, and also noisy, terse, and full of personal data.

Both are chunked into one table and indexed with a Cortex Search service. Every chunk carries a stable
`chunk_id` and its provenance (`article_id` or `source_ticket_id`), which is what a citation points at.

## What gets created

| Object | Type | Purpose |
|---|---|---|
| `KB_CHUNKS` | table | Chunked, redacted grounding text with provenance and filter attributes |
| `TRIAGE_KB_SEARCH` | Cortex Search service | Hybrid search over `chunk_text`, filterable on attributes |

Cost profile: chunking is deterministic SQL; optional `AI_REDACT` runs once per resolved-ticket note
(estimate it at the gate); the search service bills for indexing (embedding the chunks), serving, and the
refresh warehouse. Report the chunk count and an `AI_COUNT_TOKENS` floor for the chunk text before
creating the service.

## Step 1 — KB articles: published only

Draft articles have not been reviewed; retired articles describe things that no longer work. Indexing
either produces confident wrong suggestions. The sandbox deliberately includes one of each
(`KB-SYN-0012` draft, `KB-SYN-0013` retired) so the gate can check they are absent.

Chunk on character count with `SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(text, format, chunk_size,
overlap)` (chunk size is in **characters**, not tokens). KB articles are short procedures; a chunk that
splits step 3 from step 4 retrieves half an answer. Prefer chunks large enough to hold a whole procedure
for short articles, and prepend the title to every chunk so a mid-article chunk still says what it is
about.

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.KB_CHUNKS (
    chunk_id          VARCHAR,
    source_type       VARCHAR,       -- KB | RESOLVED_TICKET
    article_id        VARCHAR,
    source_ticket_id  VARCHAR,
    title             VARCHAR,
    chunk_text        VARCHAR,
    product           VARCHAR,
    category          VARCHAR,
    article_type      VARCHAR,       -- HOWTO | KNOWN_ISSUE | PROCESS | POLICY | RESOLUTION
    is_self_service   BOOLEAN,       -- can an end user follow it without an agent?
    known_issue_id    VARCHAR,
    source_updated_at TIMESTAMP_NTZ,
    redacted          BOOLEAN,
    built_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO <db>.<schema>.KB_CHUNKS
    (chunk_id, source_type, article_id, source_ticket_id, title, chunk_text, product, category,
     article_type, is_self_service, known_issue_id, source_updated_at, redacted)
SELECT
    a.<kb_id_col> || '#' || c.index                              AS chunk_id,
    'KB',
    a.<kb_id_col>,
    NULL,
    a.<kb_title_col>,
    a.<kb_title_col> || '\n' || c.value::STRING                  AS chunk_text,
    a.product,
    a.category,
    a.article_type,
    a.article_type = 'HOWTO'                                      AS is_self_service,
    ki.known_issue_id,
    a.updated_at,
    FALSE
-- Join the known-issue table BEFORE the lateral flatten: a LEFT JOIN written
-- after "a, LATERAL FLATTEN(...) c" binds to c and cannot see a.
FROM <kb_source_table> a
LEFT JOIN <known_issues_table> ki ON ki.article_id = a.<kb_id_col>,
     LATERAL FLATTEN(input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
         a.<kb_body_col>, 'none', 1500, 150)) c
WHERE a.<kb_status_col> = 'published'
  AND NOT EXISTS (SELECT 1 FROM <db>.<schema>.KB_CHUNKS k WHERE k.article_id = a.<kb_id_col>);
```

`is_self_service` is not something a search score can tell you, and it decides deflection eligibility.
Known-issue articles whose workaround the end user can apply are self-service; ones whose workaround is
applied by a team (the sandbox's `KB-SYN-0008`) are not. Set it from `article_type` plus a review of the
known-issue articles with the user — do not leave it to the suggestion model.

```sql
-- After insert, mark known-issue articles the user confirmed as end-user workarounds.
UPDATE <db>.<schema>.KB_CHUNKS
SET is_self_service = TRUE
WHERE source_type = 'KB' AND article_type = 'KNOWN_ISSUE'
  AND article_id IN (<confirmed_end_user_workaround_article_ids>);
-- Sandbox: ('KB-SYN-0004', 'KB-SYN-0006'). KB-SYN-0008 stays FALSE: its workaround
-- is applied by the Business Applications team, so FI-204 tickets link to the
-- known issue but are not deflectable.
```

## Step 2 — resolution notes from closed tickets

A large share of close notes are stock phrases ("Resolved.", "Closed by caller.", "User confirmed
working.") with nothing to retrieve. Filter them before indexing, and measure how much is left — if it is
little, say so: deflection then rests on the KB alone.

```sql
-- How much usable resolution text is there?
SELECT
    COUNT(*)                                                         AS closed_tickets,
    COUNT_IF(LENGTH(TRIM(<resolution_notes_col>)) >= 40)             AS substantive_notes,
    ROUND(100.0 * COUNT_IF(LENGTH(TRIM(<resolution_notes_col>)) >= 40) / NULLIF(COUNT(*), 0), 1) AS pct
FROM <source_table>
WHERE <resolved_at_col> IS NOT NULL;
```

Build each resolved-ticket chunk as problem plus resolution, so retrieval can match on the problem and
the suggestion can read the fix. **Redact before indexing.** Resolved-ticket text is a new copy of personal
data, and if deflection is ever exposed to end users it reaches a far wider audience than the ticket table
does. `AI_REDACT` is best-effort per its documentation; review a sample at the gate.

```sql
INSERT INTO <db>.<schema>.KB_CHUNKS
    (chunk_id, source_type, article_id, source_ticket_id, title, chunk_text, product, category,
     article_type, is_self_service, known_issue_id, source_updated_at, redacted)
SELECT
    'RT#' || t.<id_col>,
    'RESOLVED_TICKET',
    NULL,
    t.<id_col>,
    t.<subject_col>,
    AI_REDACT(
        'Problem: ' || CONCAT_WS(' ', t.<subject_col>, LEFT(t.<body_col>, 800))
        || '\nResolution: ' || t.<resolution_notes_col>
    ),
    NULL,                         -- product/category filled from classification output in phase 4 if desired
    NULL,
    'RESOLUTION',
    FALSE,                        -- resolved-ticket notes describe what an AGENT did; not end-user steps
    NULL,
    t.<resolved_at_col>,
    TRUE
FROM <source_table> t
WHERE t.<resolved_at_col> IS NOT NULL
  AND LENGTH(TRIM(t.<resolution_notes_col>)) >= 40
  -- NOT (x ILIKE ANY (...)), not "x NOT ILIKE ANY": the latter is a syntax error.
  AND NOT (t.<resolution_notes_col> ILIKE ANY ('closed by caller%', 'resolved.', 'user confirmed working%'))
  AND NOT EXISTS (SELECT 1 FROM <db>.<schema>.KB_CHUNKS k WHERE k.source_ticket_id = t.<id_col>);
```

Gate this insert: it calls `AI_REDACT` once per qualifying ticket. Estimate first:

```sql
SELECT COUNT(*) AS rows_to_redact,
       SUM(AI_COUNT_TOKENS('ai_redact',
           'Problem: ' || CONCAT_WS(' ', <subject_col>, LEFT(<body_col>, 800)) || '\nResolution: ' || <resolution_notes_col>
       )) AS approx_input_tokens
FROM <source_table>
WHERE <resolved_at_col> IS NOT NULL AND LENGTH(TRIM(<resolution_notes_col>)) >= 40;
```

If `AI_COUNT_TOKENS` returns `NULL` for `'ai_redact'`, the function name is not supported by the
estimator in this account; re-run with `return_error_details => TRUE`, report the estimate as
unavailable, and run on a 200-row sample first to observe actual usage in
`CORTEX_AI_FUNCTIONS_USAGE_HISTORY`.

### Self-retrieval leakage in evaluation

When the harness evaluates on tickets that are already closed — every sandbox ticket, and any historical
holdout — each ticket's **own** resolution note is in the index. Retrieval finds it at the top, the
suggestion cites it, and deflection precision looks excellent because the pipeline read the answer.

In production this cannot happen (a new ticket has no resolution yet). In evaluation it must be prevented
explicitly, by one of:

- **temporal split** — index only resolutions of tickets resolved before the evaluation window starts;
- **self-exclusion filter** at query time — `{"@not": {"@eq": {"source_ticket_id": "<this ticket>"}}}`
  in the `CORTEX_SEARCH_BATCH` filter (requires `source_ticket_id` as an attribute; it is one below).

Prefer the temporal split for headline numbers: self-exclusion still leaves near-duplicates of the same
incident in the index, which is realistic for production but makes cluster tickets easy. Record which was
used in the evaluation report.

## Step 3 — the Cortex Search service

Pin the embedding model explicitly. The service default (`snowflake-arctic-embed-m-v1.5`, per the
CREATE CORTEX SEARCH SERVICE docs) differs from the `AI_EMBED` model used for duplicate and known-issue
linking (`models.embed`). Mixing them is not a correctness bug for search itself, but it means "similar" in
phase 5 and "similar" in phase 6 are measured in different spaces, which makes thresholds and diagnostics
confusing. Use one model unless there is a measured reason not to.

```sql
CREATE CORTEX SEARCH SERVICE IF NOT EXISTS <db>.<schema>.TRIAGE_KB_SEARCH
  ON chunk_text
  ATTRIBUTES source_type, article_type, product, category, is_self_service, source_ticket_id, article_id
  WAREHOUSE = <warehouse>
  TARGET_LAG = '1 hour'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
  COMMENT = 'ticket-triage grounding: published KB + redacted resolved-ticket notes'
AS
SELECT chunk_id, chunk_text, title, source_type, article_type, product, category,
       is_self_service, source_ticket_id, article_id, known_issue_id, source_updated_at
FROM <db>.<schema>.KB_CHUNKS;
```

Notes:

- Columns returned in search results must be in the service's source query; `chunk_id`, `article_id` and
  `source_ticket_id` are there so citations can be validated.
- Filters apply only to `ATTRIBUTES` columns. Filter values must match the stored format exactly — the
  product string extracted from a ticket ("Microsoft Outlook") will not equal the KB product ("Outlook")
  by default. Either normalize products to a canonical list in phase 4 or do not filter on product.
- `TARGET_LAG` controls freshness and refresh cost. KB content changes slowly; an hour is generous. Use
  `CREATE ... IF NOT EXISTS` and `ALTER` rather than `CREATE OR REPLACE`, which rebuilds the whole index.

## Verification before declaring the phase done

```sql
-- 1. Chunk inventory and provenance. Draft and retired articles absent.
SELECT source_type, article_type, COUNT(*) AS chunks,
       COUNT(DISTINCT COALESCE(article_id, source_ticket_id)) AS sources,
       COUNT_IF(chunk_id IS NULL) AS null_ids
FROM <db>.<schema>.KB_CHUNKS GROUP BY 1, 2 ORDER BY 1, 2;

SELECT COUNT(*) AS non_published_indexed
FROM <db>.<schema>.KB_CHUNKS k
JOIN <kb_source_table> a ON a.<kb_id_col> = k.article_id
WHERE a.<kb_status_col> <> 'published';
-- Expect zero.

-- 2. chunk_id is unique (citations point at it).
SELECT chunk_id, COUNT(*) FROM <db>.<schema>.KB_CHUNKS GROUP BY 1 HAVING COUNT(*) > 1;
-- Expect zero rows.
```

```sql
-- 3. Service state.
DESCRIBE CORTEX SEARCH SERVICE <db>.<schema>.TRIAGE_KB_SEARCH;
-- indexing_state and serving_state RUNNING; indexing_error empty.
```

```sql
-- 4. Retrieval smoke test on two known issues. SEARCH_PREVIEW takes constants only,
--    which is exactly right for a gate check (and why it cannot be used per row).
SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  '<db>.<schema>.TRIAGE_KB_SEARCH',
  '{"query": "VPN disconnects after laptop wakes from sleep error VPN-809",
    "columns": ["chunk_id", "article_id", "title", "source_type"],
    "filter": {"@eq": {"source_type": "KB"}},
    "limit": 3}');

SELECT SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
  '<db>.<schema>.TRIAGE_KB_SEARCH',
  '{"query": "Outlook closes on start after update 0x800CCC0E",
    "columns": ["chunk_id", "article_id", "title", "source_type"],
    "limit": 3}');
```

In the sandbox the first should return `KB-SYN-0004` at or near the top, the second `KB-SYN-0006`. Show the
returned chunks. If they do not appear, check the service is past initial indexing before tuning anything.

```sql
-- 5. Redaction spot check: no fake secret survived into the index.
SELECT COUNT(*) AS leaked_fake_secrets
FROM <db>.<schema>.KB_CHUNKS
WHERE chunk_text ILIKE '%SYN-FAKE-%';
-- Expect zero. Non-zero means AI_REDACT did not catch this pattern; add a
-- deterministic REGEXP_REPLACE for credential patterns before the AI_REDACT call.
```

`AI_REDACT` targets PII categories; a pasted password is not obviously one of them. If check 5 fails, add a
deterministic credential scrub (pattern-based, tuned on preflight's secrets counts) in front of
`AI_REDACT`, rebuild the resolved-ticket chunks, and re-check. Do not mark the phase done with leaked
credentials in the index.

Then record `knowledge.search_service`, `phases.knowledge: done`, the objects in `created_objects`, and which
self-retrieval protection the evaluation will use.
