---
name: suggest-resolutions-and-deflection
description: "Produce cited suggested resolutions for agents and identify deflection candidates, grounded in the Cortex Search knowledge store. Deterministic eligibility exclusions (P1/P2, open-incident children, unclassified), an AI_FILTER answerability gate rather than a topic gate, per-ticket retrieval with the CORTEX_SEARCH_BATCH table function (SEARCH_PREVIEW is constant-only), self-retrieval protection for evaluation, an AI_COMPLETE structured-output pass that must cite supplied chunk ids, SQL-side citation validation against each ticket's own retrieved set, deflection decided from resolves_request, deflection_type, already-tried detection and the cited article's is_self_service flag, and assembly of the TICKET_TRIAGE_OUTPUT table. Phase 6 of the ticket-triage build. Triggers: suggested resolution, deflection candidates, agent assist, KB answer for ticket, self-service deflection, auto-reply candidates."
parent_skill: ticket-triage
---

# Suggest resolutions and identify deflection candidates

Two outputs, one pipeline:

- **Suggested resolution (agent assist).** For an agent working the ticket: the most relevant known fix,
  with the KB article or resolved ticket it came from. Value: time to resolution.
- **Deflection candidate.** A ticket the requester could have resolved without an agent, by following a
  specific published self-service article. Value: contacts avoided. This is a **recommendation with
  evidence**; whether anything is sent to an end user is a customer policy decision informed by the
  deflection precision phase 7 measures.

Every suggestion cites a chunk that this ticket actually retrieved; a suggestion that cannot is not emitted
(best-practices rule 10). Deflection is decided on **answerability**, not topic (rule 11).

Requires phases 3, 4 and (for the open-incident exclusion) 5 for this `run_id`. Set the query tag.

## What gets created

| Object | Grain | Purpose |
|---|---|---|
| `DEFLECTION_GATE` | `run_id` x `ticket_id` | eligibility exclusions and the `AI_FILTER` answerability result |
| `KB_RETRIEVAL` | `run_id` x `ticket_id` x rank | retrieved chunks per ticket, as returned |
| `RESOLUTION_SUGGESTIONS` | `run_id` x `ticket_id` | cited suggestion, deflection decision, reject reason |
| `TICKET_TRIAGE_OUTPUT` | `run_id` x `ticket_id` | the deliverable: labels, entities, links, suggestion, run identity |

## Scope decision — ask once

`suggest.scope` in state:

- `deflection_and_known_issue` (default) — retrieval and drafting run only for tickets that pass the gate or
  carry a known-issue link. Cheapest; covers deflection plus the highest-value agent-assist cases.
- `agent_assist_all` — retrieval and drafting for every eligible ticket. Higher cost; useful when MTTR, not
  deflection, is the main lever.

## Step 1 — Eligibility and the answerability gate

Deterministic exclusions first; they cost nothing and remove the tickets where deflection is wrong by policy:

| Exclusion | Why |
|---|---|
| `pred_priority IN ('P1','P2')` | an urgent ticket gets an agent |
| child in a duplicate cluster at or above `raise_cluster_size` | an open incident deflects to a status page — a different mechanism and metric |
| `pred_queue = 'UNCLASSIFIED'` | nothing is known about it |
| category in the customer's never-deflect list (for example `Security`) | policy; security wants the ticket |

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.DEFLECTION_GATE (
    run_id          VARCHAR,
    ticket_id       VARCHAR,
    excluded_reason VARCHAR,       -- NULL when eligible
    answerable      BOOLEAN,       -- AI_FILTER result; NULL if not run or failed
    gate_error      VARCHAR,
    has_known_issue BOOLEAN
);

INSERT INTO <db>.<schema>.DEFLECTION_GATE (run_id, ticket_id, excluded_reason, has_known_issue)
SELECT c.run_id, c.ticket_id,
       CASE
         WHEN c.pred_queue = 'UNCLASSIFIED'                         THEN 'unclassified'
         WHEN c.pred_priority IN ('P1', 'P2')                       THEN 'priority'
         WHEN d.cluster_size >= :raise_cluster_size AND NOT d.is_root THEN 'open_incident_child'
         WHEN c.pred_category IN (<never_deflect_categories>)       THEN 'policy_category'
       END,
       k.ticket_id IS NOT NULL
FROM <db>.<schema>.TICKET_CLASSIFICATION c
LEFT JOIN <db>.<schema>.DUPLICATE_LINKS d ON d.run_id = c.run_id AND d.ticket_id = c.ticket_id
LEFT JOIN <db>.<schema>.KNOWN_ISSUE_LINKS k
  ON k.run_id = c.run_id AND k.ticket_id = c.ticket_id AND k.rank_in_ticket = 1
WHERE c.run_id = :run_id
  AND NOT EXISTS (SELECT 1 FROM <db>.<schema>.DEFLECTION_GATE g
                  WHERE g.run_id = :run_id AND g.ticket_id = c.ticket_id);
```

Then the answerability gate on eligible tickets. The predicate asks whether the requester could fix it
**themselves**, without an agent or an approval — not whether it is about a topic the KB covers:

```sql
UPDATE <db>.<schema>.DEFLECTION_GATE g
SET answerable = x.r:value::BOOLEAN,
    gate_error = x.r:error::STRING
FROM (
    SELECT g2.run_id, g2.ticket_id,
           AI_FILTER(PROMPT(
             'The person who wrote this IT support ticket could resolve it themselves by following '
             || 'published self-service instructions, without an IT agent changing anything for them and '
             || 'without anyone approving access, and they have not already said those instructions failed. '
             || 'Ticket: {0}', n.full_text), TRUE) AS r
    FROM <db>.<schema>.DEFLECTION_GATE g2
    JOIN <db>.<schema>.TICKETS_NORMALIZED n ON n.ticket_id = g2.ticket_id
    WHERE g2.run_id = :run_id AND g2.excluded_reason IS NULL AND g2.answerable IS NULL
) x
WHERE g.run_id = x.run_id AND g.ticket_id = x.ticket_id;
```

Estimate the eligible count times average `full_text` tokens before running, and gate. Then count
`gate_error IS NOT NULL` — a `NULL` gate result is not "not answerable" (rule 4).

## Step 2 — Retrieval per ticket with `CORTEX_SEARCH_BATCH`

`SNOWFLAKE.CORTEX.SEARCH_PREVIEW` accepts only constants and cannot run per row. The `CORTEX_SEARCH_BATCH`
table function takes a column of queries through `LATERAL` (rule 9).

First, a **probe** on three tickets to record the output column names — the docs say results include the
service's returned columns and relevance scores but do not name the score columns:

```sql
SELECT q.ticket_id, r.*
FROM (SELECT ticket_id, LEFT(classify_text, 500) AS query_text
      FROM <db>.<schema>.TICKETS_NORMALIZED LIMIT 3) q,
LATERAL CORTEX_SEARCH_BATCH(
    service_name => '<db>.<schema>.TRIAGE_KB_SEARCH',
    query        => q.query_text,
    limit        => 5) AS r;
```

Record the score column (if any) as `knowledge.batch_score_col`. If no score column is exposed, retrieval
rank is the only ordering signal and `thresholds.deflection_min_retrieval_score` is not used — say so.

The retrieval query is the requester's problem statement plus the extracted product and error code, which
anchors search on the identifiers that distinguish known issues:

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.KB_RETRIEVAL (
    run_id     VARCHAR,
    ticket_id  VARCHAR,
    rank       NUMBER,
    chunk_id   VARCHAR,
    result     OBJECT,          -- the full returned row, including any score fields
    retrieved_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO <db>.<schema>.KB_RETRIEVAL (run_id, ticket_id, rank, chunk_id, result)
WITH q AS (
    SELECT g.run_id, g.ticket_id,
           CONCAT_WS(' ', LEFT(n.classify_text, 600), e.product, e.error_code) AS query_text,
           -- Evaluation only: exclude this ticket's own resolution note (self-retrieval
           -- leakage). In production a new ticket has no resolution, so the filter is inert.
           OBJECT_CONSTRUCT('@not', OBJECT_CONSTRUCT('@eq',
               OBJECT_CONSTRUCT('source_ticket_id', g.ticket_id)))       AS search_filter
    FROM <db>.<schema>.DEFLECTION_GATE g
    JOIN <db>.<schema>.TICKETS_NORMALIZED n ON n.ticket_id = g.ticket_id
    LEFT JOIN <db>.<schema>.TICKET_ENTITIES e ON e.run_id = g.run_id AND e.ticket_id = g.ticket_id
    WHERE g.run_id = :run_id
      AND g.excluded_reason IS NULL
      AND (g.answerable OR g.has_known_issue)                -- scope deflection_and_known_issue
      AND NOT EXISTS (SELECT 1 FROM <db>.<schema>.KB_RETRIEVAL k
                      WHERE k.run_id = :run_id AND k.ticket_id = g.ticket_id)
)
SELECT q.run_id, q.ticket_id,
       ROW_NUMBER() OVER (PARTITION BY q.ticket_id ORDER BY <score_order_expr>) AS rank,
       r.chunk_id::STRING,
       OBJECT_CONSTRUCT(r.*)
FROM q,
LATERAL CORTEX_SEARCH_BATCH(
    service_name => '<db>.<schema>.TRIAGE_KB_SEARCH',
    query        => q.query_text,
    filter       => q.search_filter,
    limit        => 5) AS r;
```

`<score_order_expr>` is the recorded score column descending if one exists; if not, preserve the function's
returned order (check in the probe whether rows arrive in rank order). Do not invent an order.

Notes from the batch-search docs that change the plan:

- batch jobs have **startup latency**; under roughly 2,000 queries the interactive Python or REST API is
  typically faster. For small incremental runs in production (phase 8), a stored procedure calling the
  interactive API may be the better fit; for sandbox and backfill, batch is right;
- **reranking is ignored** in batch;
- **query embedding is billed** in batch;
- usage is in `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_SEARCH_BATCH_QUERY_USAGE_HISTORY`.

If `knowledge.self_retrieval_guard` is `temporal_split`, the filter is unnecessary; keep it anyway — it is
inert on tickets that were not indexed.

## Step 3 — Draft a cited suggestion

The prompt **supplies** the chunks with their ids and requires the model to cite only from them. Assemble
the prompt text once per ticket in a CTE, hash it, and pass the same column to `AI_COMPLETE` (rule 26).

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.RESOLUTION_SUGGESTIONS (
    run_id                VARCHAR,
    experiment_id         VARCHAR,
    prompt_version        VARCHAR,
    prompt_hash           VARCHAR,
    ticket_id             VARCHAR,
    retrieved_chunk_ids   ARRAY,
    retrieved_count       NUMBER,
    resolves_request      BOOLEAN,
    requester_already_tried BOOLEAN,
    deflection_type       VARCHAR,
    suggested_resolution  VARCHAR,
    citations             ARRAY,
    is_suggested          BOOLEAN,
    is_deflection_candidate BOOLEAN,
    citation_invalid      BOOLEAN,
    reject_reason         VARCHAR,
    raw_response          VARIANT,
    suggest_model         VARCHAR,
    suggested_at          TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO <db>.<schema>.RESOLUTION_SUGGESTIONS
    (run_id, experiment_id, prompt_version, prompt_hash, ticket_id,
     retrieved_chunk_ids, retrieved_count, raw_response, suggest_model)
WITH ctx AS (
    SELECT r.ticket_id,
           ARRAY_AGG(r.chunk_id) WITHIN GROUP (ORDER BY r.rank) AS chunk_ids,
           COUNT(*) AS n,
           LISTAGG('[chunk_id: ' || r.chunk_id || ' | self_service: '
                   || IFF(k.is_self_service, 'yes', 'no') || ']\n' || k.chunk_text, '\n\n')
             WITHIN GROUP (ORDER BY r.rank) AS sources
    FROM <db>.<schema>.KB_RETRIEVAL r
    JOIN <db>.<schema>.KB_CHUNKS k ON k.chunk_id = r.chunk_id
    WHERE r.run_id = :run_id
    GROUP BY r.ticket_id
),
p AS (
    SELECT c.ticket_id, c.chunk_ids, c.n,
           'You help IT support agents. Using ONLY the sources below, decide whether they resolve the '
        || 'request in the ticket, and if so give the resolution steps. Cite the chunk_id of every source '
        || 'you used, exactly as shown; never cite anything not listed. A source on the same topic that '
        || 'does not fix this specific problem does not resolve it. If the requester says they already '
        || 'tried the fix, set requester_already_tried. Classify deflection_type as SELF_SERVICE_HOWTO when '
        || 'the requester can follow published steps, KNOWN_ISSUE_WORKAROUND when a published workaround '
        || 'the requester can apply exists, STATUS_UPDATE when the answer is that an outage is being '
        || 'worked, and NOT_DEFLECTABLE otherwise, including whenever an agent or approval is needed. '
        || 'Respond in JSON.\n\nTICKET:\n' || n.full_text || '\n\nSOURCES:\n' || c.sources AS prompt_text
    FROM ctx c
    JOIN <db>.<schema>.TICKETS_NORMALIZED n ON n.ticket_id = c.ticket_id
    WHERE NOT EXISTS (SELECT 1 FROM <db>.<schema>.RESOLUTION_SUGGESTIONS s
                      WHERE s.run_id = :run_id AND s.ticket_id = c.ticket_id)
)
SELECT :run_id, :experiment_id, :prompt_version,
       SHA2(p.prompt_text, 256),     -- per-row; the template hash is SHA2 of the text before TICKET:
       p.ticket_id, p.chunk_ids, p.n,
       AI_COMPLETE(
         model => '<suggest_model>',
         prompt => p.prompt_text,
         model_parameters => {'temperature': 0, 'max_tokens': 800},
         response_format => {
           'type': 'json',
           'schema': {
             'type': 'object',
             'properties': {
               'resolves_request':        {'type': 'boolean'},
               'requester_already_tried': {'type': 'boolean'},
               'deflection_type':         {'type': 'string',
                                           'enum': ['SELF_SERVICE_HOWTO','KNOWN_ISSUE_WORKAROUND','STATUS_UPDATE','NOT_DEFLECTABLE']},
               'resolution_steps':        {'type': 'string',
                                           'description': 'Numbered steps taken only from the cited sources. Empty if resolves_request is false.'},
               'citations': {
                 'type': 'array',
                 'items': {
                   'type': 'object',
                   'properties': {
                     'chunk_id': {'type': 'string', 'description': 'A chunk_id exactly as listed in SOURCES. Do not invent.'},
                     'used_for': {'type': 'string'}
                   },
                   'required': ['chunk_id']
                 }
               },
               'reasoning': {'type': 'string', 'description': 'One or two sentences.'}
             },
             'required': ['resolves_request','requester_already_tried','deflection_type','citations']
           }
         },
         show_details => TRUE),
       '<suggest_model>'
FROM p;
```

Persist a **template** hash as well (the prompt text with the ticket and sources removed) as `prompt_hash`
on the run, so experiments compare on template, not on per-row text; the per-row hash above proves which
exact text a row saw.

Gate before running: number of tickets with retrieval times average prompt tokens
(`AI_COUNT_TOKENS('ai_complete', '<suggest_model>', prompt_text)` on a sample), plus the note that the schema
adds billed input not counted by the estimate.

## Step 4 — Validate citations and decide

Unpack, then apply every check in SQL. Nothing is deleted; failures set `is_suggested = FALSE` with a reason
so hallucinated provenance is counted.

```sql
UPDATE <db>.<schema>.RESOLUTION_SUGGESTIONS s
SET resolves_request        = v.so:resolves_request::BOOLEAN,
    requester_already_tried = v.so:requester_already_tried::BOOLEAN,
    deflection_type         = v.so:deflection_type::STRING,
    suggested_resolution    = NULLIF(v.so:resolution_steps::STRING, ''),
    citations               = COALESCE(v.so:citations::ARRAY, ARRAY_CONSTRUCT())
FROM (SELECT run_id, ticket_id, raw_response:structured_output AS so
      FROM <db>.<schema>.RESOLUTION_SUGGESTIONS WHERE run_id = :run_id) v
WHERE s.run_id = v.run_id AND s.ticket_id = v.ticket_id;
```

Confirm the `structured_output` path on one row first (same caution as the classification fallback).

```sql
UPDATE <db>.<schema>.RESOLUTION_SUGGESTIONS s
SET citation_invalid        = x.invalid,
    is_suggested            = x.ok_suggest,
    is_deflection_candidate = x.ok_deflect,
    reject_reason           = x.reason
FROM (
    SELECT c.run_id, c.ticket_id, c.invalid,
           (NOT c.unparsed AND c.resolves AND c.n_cit > 0 AND NOT c.invalid AND c.has_steps) AS ok_suggest,
           (NOT c.unparsed AND c.resolves AND c.n_cit > 0 AND NOT c.invalid
            AND c.dtype IN ('SELF_SERVICE_HOWTO', 'KNOWN_ISSUE_WORKAROUND')
            AND NOT c.tried
            AND c.cites_self_service)                                                       AS ok_deflect,
           CASE
             WHEN c.unparsed      THEN 'unparsed_response'
             WHEN c.n_cit = 0     THEN 'no_citation'
             WHEN c.invalid       THEN 'cites_unretrieved_chunk'
             WHEN NOT c.resolves  THEN 'sources_do_not_resolve'
             WHEN c.tried         THEN 'already_tried'
             WHEN NOT c.cites_self_service
                  AND c.dtype IN ('SELF_SERVICE_HOWTO', 'KNOWN_ISSUE_WORKAROUND')
                                  THEN 'cited_source_not_self_service'
           END                                                                              AS reason
    FROM (
        SELECT s2.run_id, s2.ticket_id,
               s2.raw_response:structured_output IS NULL  AS unparsed,
               COALESCE(s2.resolves_request, FALSE)       AS resolves,
               -- unknown "already tried" must never produce a deflection
               COALESCE(s2.requester_already_tried, TRUE) AS tried,
               s2.deflection_type                         AS dtype,
               ARRAY_SIZE(s2.citations)                   AS n_cit,
               s2.suggested_resolution IS NOT NULL        AS has_steps,
               a.invalid, a.cites_self_service
        FROM <db>.<schema>.RESOLUTION_SUGGESTIONS s2
        JOIN (
            -- Flatten in its own derived table: a LATERAL FLATTEN cannot sit on
            -- the left side of a JOIN.
            SELECT ct.run_id, ct.ticket_id,
                   COUNT_IF(ct.not_retrieved) > 0     AS invalid,             -- cites outside THIS ticket's retrieved set
                   COUNT_IF(k.is_self_service) > 0    AS cites_self_service   -- at least one cited chunk is self-service
            FROM (
                SELECT s3.run_id, s3.ticket_id,
                       f.value:chunk_id::STRING AS cited_id,
                       f.value IS NOT NULL
                         AND NOT ARRAY_CONTAINS(f.value:chunk_id::VARIANT, s3.retrieved_chunk_ids) AS not_retrieved
                FROM <db>.<schema>.RESOLUTION_SUGGESTIONS s3,
                     LATERAL FLATTEN(input => s3.citations, outer => TRUE) f
                WHERE s3.run_id = :run_id
            ) ct
            LEFT JOIN <db>.<schema>.KB_CHUNKS k ON k.chunk_id = ct.cited_id
            GROUP BY 1, 2
        ) a ON a.run_id = s2.run_id AND a.ticket_id = s2.ticket_id
        WHERE s2.run_id = :run_id
    ) c
) x
WHERE s.run_id = x.run_id AND s.ticket_id = x.ticket_id;
```

`FLATTEN(..., outer => TRUE)` keeps tickets with an empty citation array in the aggregate, so they are
rejected as `no_citation` rather than disappearing from the update.

Deflection requires **all** of: parsed, resolves, at least one valid citation, a self-service deflection type,
the requester has not already tried it, and at least one cited chunk is self-service. `already_tried`
defaulting to `TRUE` when null is deliberate: an unknown answer must not produce a deflection.

If a retrieval score column exists, also require the top cited chunk's score to clear
`thresholds.deflection_min_retrieval_score` — as a floor only.

## Step 5 — Assemble the triage output

One row per ticket per run; every downstream consumer (semantic view, agent, evaluation) reads this.

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.TICKET_TRIAGE_OUTPUT (
    run_id VARCHAR, experiment_id VARCHAR, experiment_name VARCHAR,
    prompt_version VARCHAR, prompt_hash VARCHAR, taxonomy_version VARCHAR,
    ticket_id VARCHAR, created_at TIMESTAMP_NTZ, channel VARCHAR,
    pred_category VARCHAR, category_source VARCHAR,
    pred_impact VARCHAR, pred_urgency VARCHAR, pred_priority VARCHAR, priority_source VARCHAR,
    pred_queue VARCHAR, queue_source VARCHAR,
    confidence_band VARCHAR, confidence_basis VARCHAR, fallback_confidence NUMBER,
    is_multi_intent BOOLEAN,
    product VARCHAR, product_version VARCHAR, error_code VARCHAR, asset_id VARCHAR, affected_users VARCHAR,
    cluster_id VARCHAR, parent_ticket_id VARCHAR, cluster_size NUMBER, similarity_to_parent FLOAT,
    known_issue_id VARCHAR, known_issue_article_id VARCHAR, known_issue_basis VARCHAR,
    deflection_excluded_reason VARCHAR, answerable BOOLEAN,
    is_suggested BOOLEAN, suggested_resolution VARCHAR, citations ARRAY,
    is_deflection_candidate BOOLEAN, deflection_type VARCHAR, suggestion_reject_reason VARCHAR,
    -- Defined for a later review workflow; nothing in this plugin writes them.
    reviewer_queue VARCHAR, reviewer_priority VARCHAR, reviewer_decision VARCHAR,
    reviewed_by VARCHAR, reviewed_at TIMESTAMP_NTZ,
    built_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO <db>.<schema>.TICKET_TRIAGE_OUTPUT
    (run_id, experiment_id, experiment_name, prompt_version, prompt_hash, taxonomy_version,
     ticket_id, created_at, channel,
     pred_category, category_source, pred_impact, pred_urgency, pred_priority, priority_source,
     pred_queue, queue_source, confidence_band, confidence_basis, fallback_confidence, is_multi_intent,
     product, product_version, error_code, asset_id, affected_users,
     cluster_id, parent_ticket_id, cluster_size, similarity_to_parent,
     known_issue_id, known_issue_article_id, known_issue_basis,
     deflection_excluded_reason, answerable,
     is_suggested, suggested_resolution, citations,
     is_deflection_candidate, deflection_type, suggestion_reject_reason)
SELECT c.run_id, c.experiment_id, c.experiment_name, c.prompt_version, c.prompt_hash, c.taxonomy_version,
       c.ticket_id, n.created_at, n.channel,
       c.pred_category, c.category_source, c.pred_impact, c.pred_urgency, c.pred_priority, c.priority_source,
       c.pred_queue, c.queue_source, c.confidence_band, c.confidence_basis, c.fallback_confidence, c.is_multi_intent,
       e.product, e.product_version, e.error_code, e.asset_id, e.affected_users,
       d.cluster_id, d.parent_ticket_id, d.cluster_size, d.similarity_to_parent,
       k.known_issue_id, k.article_id, k.link_basis,
       g.excluded_reason, g.answerable,
       COALESCE(s.is_suggested, FALSE), s.suggested_resolution, s.citations,
       COALESCE(s.is_deflection_candidate, FALSE), s.deflection_type, s.reject_reason
FROM <db>.<schema>.TICKET_CLASSIFICATION c
JOIN <db>.<schema>.TICKETS_NORMALIZED n ON n.ticket_id = c.ticket_id
LEFT JOIN <db>.<schema>.TICKET_ENTITIES e        ON e.run_id = c.run_id AND e.ticket_id = c.ticket_id
LEFT JOIN <db>.<schema>.DUPLICATE_LINKS d        ON d.run_id = c.run_id AND d.ticket_id = c.ticket_id
LEFT JOIN <db>.<schema>.KNOWN_ISSUE_LINKS k      ON k.run_id = c.run_id AND k.ticket_id = c.ticket_id AND k.rank_in_ticket = 1
LEFT JOIN <db>.<schema>.DEFLECTION_GATE g        ON g.run_id = c.run_id AND g.ticket_id = c.ticket_id
LEFT JOIN <db>.<schema>.RESOLUTION_SUGGESTIONS s ON s.run_id = c.run_id AND s.ticket_id = c.ticket_id
WHERE c.run_id = :run_id
  AND NOT EXISTS (SELECT 1 FROM <db>.<schema>.TICKET_TRIAGE_OUTPUT o
                  WHERE o.run_id = :run_id AND o.ticket_id = c.ticket_id);
```

The output is built from `TICKET_CLASSIFICATION` outward, so every classified ticket appears even when it has
no entities, links or suggestion. If phases 5 or 6 were skipped, their columns are `NULL` and the readout says
those levers were not built.

## Verification before declaring the phase done

```sql
-- 1. The funnel: where tickets left the deflection path, and why.
SELECT COALESCE(g.excluded_reason, 'eligible') AS stage, COUNT(*) AS tickets
FROM <db>.<schema>.DEFLECTION_GATE g WHERE g.run_id = :run_id GROUP BY 1
UNION ALL
SELECT 'gate_answerable', COUNT_IF(answerable) FROM <db>.<schema>.DEFLECTION_GATE WHERE run_id = :run_id
UNION ALL
SELECT 'gate_null_or_error', COUNT_IF(excluded_reason IS NULL AND answerable IS NULL)
FROM <db>.<schema>.DEFLECTION_GATE WHERE run_id = :run_id
UNION ALL
SELECT 'retrieved', COUNT(DISTINCT ticket_id) FROM <db>.<schema>.KB_RETRIEVAL WHERE run_id = :run_id
UNION ALL
SELECT 'suggested', COUNT_IF(is_suggested) FROM <db>.<schema>.RESOLUTION_SUGGESTIONS WHERE run_id = :run_id
UNION ALL
SELECT 'deflection_candidate', COUNT_IF(is_deflection_candidate) FROM <db>.<schema>.RESOLUTION_SUGGESTIONS WHERE run_id = :run_id;
```

```sql
-- 2. Rejections by reason. 'cites_unretrieved_chunk' and 'no_citation' must be investigated, not tolerated.
SELECT reject_reason, COUNT(*) FROM <db>.<schema>.RESOLUTION_SUGGESTIONS
WHERE run_id = :run_id GROUP BY 1 ORDER BY 2 DESC;
```

```sql
-- 3. Hard assertions. Both zero.
SELECT COUNT(*) AS suggested_without_valid_citation
FROM <db>.<schema>.RESOLUTION_SUGGESTIONS
WHERE run_id = :run_id AND is_suggested AND (ARRAY_SIZE(citations) = 0 OR citation_invalid);

SELECT COUNT(*) AS deflection_on_excluded_ticket
FROM <db>.<schema>.TICKET_TRIAGE_OUTPUT
WHERE run_id = :run_id AND is_deflection_candidate AND deflection_excluded_reason IS NOT NULL;
```

```sql
-- 4. Which articles drive deflection. One article producing most candidates deserves a read:
--    is it a genuine high-volume self-service fix, or an over-broad match?
SELECT k.article_id, k.title, COUNT(DISTINCT s.ticket_id) AS candidates
FROM <db>.<schema>.RESOLUTION_SUGGESTIONS s,
     LATERAL FLATTEN(input => s.citations) f,
     <db>.<schema>.KB_CHUNKS k
WHERE k.chunk_id = f.value:chunk_id::STRING
  AND s.run_id = :run_id AND s.is_deflection_candidate
GROUP BY 1, 2 ORDER BY 3 DESC;
```

```sql
-- 5. Output completeness.
SELECT COUNT(*) AS rows, COUNT(DISTINCT ticket_id) AS tickets,
       COUNT_IF(pred_queue IS NULL) AS null_queue, COUNT_IF(confidence_band IS NULL) AS null_band
FROM <db>.<schema>.TICKET_TRIAGE_OUTPUT WHERE run_id = :run_id;
```

In the sandbox, expect deflection candidates concentrated on `KB-SYN-0001`, `-0002`, `-0003`, `-0004`,
`-0005`, `-0006` and `-0009`; the `DEFLECT_DISTRACTOR` (S02) tickets should reject as `already_tried` or
`sources_do_not_resolve`; access requests (S04) should not be candidates; FI-204 (S13) should be suggested to
agents but rejected for deflection as `cited_source_not_self_service`. Precision is measured in phase 7.

Then `phases.suggest: done` and the created tables.
