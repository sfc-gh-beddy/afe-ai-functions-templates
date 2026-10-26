---
name: link-duplicates-and-known-issues
description: "Link each ticket to duplicates of the same incident and to known issues, using precomputed AI_EMBED vectors compared with VECTOR_COSINE_SIMILARITY. Embeds normalized classifier text once per ticket and model, blocks candidate pairs by predicted category and a time window, builds anchored (star) clusters with a parent ticket instead of transitive connected components, links to open known issues by exact normalized error code or semantic similarity to the known-issue article, keeps candidates before thresholding for tuning, applies rule-based priority raises from cluster size, and verifies coherence of the largest cluster and absence of cross-category links. Phase 5 of the ticket-triage build. Triggers: duplicate tickets, link to parent incident, major incident clustering, known issue matching, similar tickets, ticket deduplication."
parent_skill: ticket-triage
---

# Link duplicates and known issues

Two different questions, answered with the same embeddings:

- **Is this ticket another report of something already open?** (duplicate / child of a parent incident).
  Value: one investigation instead of fifty, faster MTTR for everyone after the first reporter, and a
  major-incident signal that raises priority.
- **Is this a known issue with a published workaround?** Value: time to fix collapses to time to find the
  article, and the ticket may be deflectable (phase 6 decides that, not this phase).

Read best-practices rules 12, 13 and 20 before starting. Requires phase 4 output for this `run_id`.

## What gets created

| Object | Grain | Notes |
|---|---|---|
| `TICKET_EMBEDDINGS` | `ticket_id` x `embed_model` | not per run: same text and model, same vector |
| `KNOWN_ISSUE_EMBEDDINGS` | `known_issue_id` x `embed_model` | |
| `DUPLICATE_CANDIDATES` | `run_id` x pair | **before** thresholding, for tuning and diagnosis |
| `DUPLICATE_LINKS` | `run_id` x `ticket_id` | parent, cluster, similarity to parent |
| `KNOWN_ISSUE_LINKS` | `run_id` x `ticket_id` x `known_issue_id` | basis: error code, semantic, or both |

## Step 1 — Embed once, with one model

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.TICKET_EMBEDDINGS (
    ticket_id   VARCHAR,
    embed_model VARCHAR,
    text_hash   VARCHAR,                   -- re-embed only when the normalized text changes
    embedding   VECTOR(FLOAT, 1024),       -- snowflake-arctic-embed-l-v2.0 is 1024-d
    embedded_at TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

The declared dimension must match `models.embed`. If the customer chose a different model, check its
dimension in the vector-embeddings documentation and change the type; an insert of the wrong size fails,
which is the desired behaviour.

Estimate, gate, then embed:

```sql
SELECT COUNT(*) AS to_embed,
       SUM(AI_COUNT_TOKENS('ai_embed', '<embed_model>', n.classify_text)) AS input_tokens
FROM <db>.<schema>.TICKETS_NORMALIZED n
WHERE NOT EXISTS (SELECT 1 FROM <db>.<schema>.TICKET_EMBEDDINGS e
                  WHERE e.ticket_id = n.ticket_id AND e.embed_model = '<embed_model>'
                    AND e.text_hash = SHA2(n.classify_text, 256));
```

If `'ai_embed'` with a model argument returns `NULL`, re-run with `return_error_details => TRUE`; the
estimator form may differ for embedding functions in this account. Report the estimate as unavailable rather
than guessing.

```sql
INSERT INTO <db>.<schema>.TICKET_EMBEDDINGS (ticket_id, embed_model, text_hash, embedding)
SELECT n.ticket_id, '<embed_model>', SHA2(n.classify_text, 256),
       AI_EMBED('<embed_model>', n.classify_text)
FROM <db>.<schema>.TICKETS_NORMALIZED n
WHERE n.classify_text IS NOT NULL AND LENGTH(n.classify_text) > 0
  AND NOT EXISTS (SELECT 1 FROM <db>.<schema>.TICKET_EMBEDDINGS e
                  WHERE e.ticket_id = n.ticket_id AND e.embed_model = '<embed_model>'
                    AND e.text_hash = SHA2(n.classify_text, 256));
```

Embed `classify_text` — the normalized, pre-assignment text — not the raw thread. Signatures, footers and
quoted replies dominate short tickets and make similarity track the sender rather than the problem.

Known issues get the same model, over the symptom-bearing text of their article:

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.KNOWN_ISSUE_EMBEDDINGS (
    known_issue_id VARCHAR,
    article_id     VARCHAR,
    product        VARCHAR,
    error_code     VARCHAR,
    embed_model    VARCHAR,
    embedding      VECTOR(FLOAT, 1024)
);

INSERT INTO <db>.<schema>.KNOWN_ISSUE_EMBEDDINGS
SELECT ki.known_issue_id, ki.article_id, ki.product,
       UPPER(TRIM(ki.error_code)),                 -- same normalization as TICKET_ENTITIES.error_code
       '<embed_model>',
       AI_EMBED('<embed_model>', ki.title || '\n' || LEFT(a.<kb_body_col>, 2000))
FROM <known_issues_table> ki
JOIN <kb_source_table> a ON a.<kb_id_col> = ki.article_id
WHERE ki.status = 'OPEN'
  AND NOT EXISTS (SELECT 1 FROM <db>.<schema>.KNOWN_ISSUE_EMBEDDINGS x
                  WHERE x.known_issue_id = ki.known_issue_id AND x.embed_model = '<embed_model>');
```

Do **not** use `AI_SIMILARITY(text_a, text_b)` for the pairwise join. It embeds both inputs on every call
(billed under `AI_EMBED`), so a pairwise join embeds each ticket once per comparison. Precomputed vectors and
`VECTOR_COSINE_SIMILARITY` embed each ticket once.

## Step 2 — Candidate pairs, blocked

Pairwise across a corpus is quadratic and mostly nonsense. Block on what a duplicate must share:

- **same predicted category** in this run (a "printer offline" and a "VPN offline" are not duplicates however
  much the word overlaps — the sandbox's `LEXICAL_TRAP` scenario tests this);
- **a time window** (`window_hours`, set with the customer; incidents are hours, not weeks). Two separate
  outages with the same symptoms a month apart are two incidents — the sandbox's `S07` and `S27` test exactly
  that;
- optionally **same canonical product** when both tickets have one.

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.DUPLICATE_CANDIDATES (
    run_id          VARCHAR,
    ticket_id       VARCHAR,        -- the later ticket
    other_ticket_id VARCHAR,        -- an earlier ticket
    similarity      FLOAT,
    minutes_apart   NUMBER,
    same_product    BOOLEAN,
    pred_category   VARCHAR
);

INSERT INTO <db>.<schema>.DUPLICATE_CANDIDATES
SELECT :run_id, a.ticket_id, b.ticket_id,
       VECTOR_COSINE_SIMILARITY(ea.embedding, eb.embedding),
       DATEDIFF(MINUTE, nb.created_at, na.created_at),
       EQUAL_NULL(xa.product, xb.product) AND xa.product IS NOT NULL,
       a.pred_category
FROM <db>.<schema>.TICKET_CLASSIFICATION a
JOIN <db>.<schema>.TICKET_CLASSIFICATION b
  ON b.run_id = a.run_id
 AND b.pred_category = a.pred_category
 AND b.ticket_id <> a.ticket_id
JOIN <db>.<schema>.TICKETS_NORMALIZED na ON na.ticket_id = a.ticket_id
JOIN <db>.<schema>.TICKETS_NORMALIZED nb ON nb.ticket_id = b.ticket_id
 AND nb.created_at <  na.created_at
 AND nb.created_at >= DATEADD(HOUR, -:window_hours, na.created_at)
JOIN <db>.<schema>.TICKET_EMBEDDINGS ea ON ea.ticket_id = a.ticket_id AND ea.embed_model = '<embed_model>'
JOIN <db>.<schema>.TICKET_EMBEDDINGS eb ON eb.ticket_id = b.ticket_id AND eb.embed_model = '<embed_model>'
LEFT JOIN <db>.<schema>.TICKET_ENTITIES xa ON xa.run_id = a.run_id AND xa.ticket_id = a.ticket_id
LEFT JOIN <db>.<schema>.TICKET_ENTITIES xb ON xb.run_id = b.run_id AND xb.ticket_id = b.ticket_id
WHERE a.run_id = :run_id
  AND a.pred_category <> 'UNCLASSIFIED'
  AND NOT EXISTS (SELECT 1 FROM <db>.<schema>.DUPLICATE_CANDIDATES d
                  WHERE d.run_id = :run_id AND d.ticket_id = a.ticket_id);
```

No similarity threshold yet: keep every blocked pair so the threshold can be chosen from the distribution
(and tuned in phase 7 against planted clusters) without recomputing. If the blocked pair count is very large,
add a loose floor (for example 0.5) and say so.

```sql
-- Similarity distribution of blocked pairs. Look for the separation between a
-- dense high band (true duplicates) and the bulk (same category, different issue).
SELECT ROUND(similarity, 2) AS sim, COUNT(*) AS pairs
FROM <db>.<schema>.DUPLICATE_CANDIDATES
WHERE run_id = :run_id
GROUP BY 1 ORDER BY 1 DESC;
```

Pick a provisional `thresholds.duplicate_similarity` at the visible gap, read the ten pairs just above and
just below it with the user, and record it. Do not copy a threshold from another corpus or another embedding
model; cosine scales differ.

## Step 3 — Anchored clustering

Connected components over the thresholded graph chain unrelated tickets together (rule 13). Instead, every
child attaches to a **root** it is directly similar to. Three passes, all set-based:

1. **Roots**: tickets with no earlier above-threshold neighbour in the window.
2. **Attach**: each non-root attaches to the **earliest root** it is directly similar to, above threshold,
   within the window.
3. **Orphans**: a non-root whose similar earlier tickets are all themselves children, with no directly
   similar root, becomes a root. This is the case transitive closure would have chained.

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.DUPLICATE_LINKS (
    run_id               VARCHAR,
    ticket_id            VARCHAR,
    parent_ticket_id     VARCHAR,      -- NULL for roots
    cluster_id           VARCHAR,      -- the root's ticket_id
    similarity_to_parent FLOAT,
    is_root              BOOLEAN,
    cluster_size         NUMBER,
    threshold_used       FLOAT,
    window_hours_used    NUMBER
);

INSERT INTO <db>.<schema>.DUPLICATE_LINKS
    (run_id, ticket_id, parent_ticket_id, cluster_id, similarity_to_parent, is_root,
     threshold_used, window_hours_used)
WITH edges AS (
    SELECT ticket_id, other_ticket_id, similarity
    FROM <db>.<schema>.DUPLICATE_CANDIDATES
    WHERE run_id = :run_id AND similarity >= :dup_threshold
),
all_t AS (
    SELECT ticket_id FROM <db>.<schema>.TICKET_CLASSIFICATION WHERE run_id = :run_id
),
roots AS (               -- pass 1
    SELECT t.ticket_id FROM all_t t
    WHERE NOT EXISTS (SELECT 1 FROM edges e WHERE e.ticket_id = t.ticket_id)
),
attached AS (            -- pass 2: earliest directly-similar root
    SELECT e.ticket_id,
           MIN_BY(e.other_ticket_id, n.created_at) AS parent_ticket_id,
           MIN_BY(e.similarity,      n.created_at) AS sim
    FROM edges e
    JOIN roots r ON r.ticket_id = e.other_ticket_id
    JOIN <db>.<schema>.TICKETS_NORMALIZED n ON n.ticket_id = e.other_ticket_id
    GROUP BY e.ticket_id
)
SELECT :run_id, t.ticket_id,
       a.parent_ticket_id,
       COALESCE(a.parent_ticket_id, t.ticket_id),
       a.sim,
       a.parent_ticket_id IS NULL,           -- roots and pass-3 orphans
       :dup_threshold, :window_hours
FROM all_t t
LEFT JOIN attached a ON a.ticket_id = t.ticket_id
WHERE NOT EXISTS (SELECT 1 FROM <db>.<schema>.DUPLICATE_LINKS d
                  WHERE d.run_id = :run_id AND d.ticket_id = t.ticket_id);

UPDATE <db>.<schema>.DUPLICATE_LINKS d
SET cluster_size = s.n
FROM (SELECT cluster_id, COUNT(*) AS n FROM <db>.<schema>.DUPLICATE_LINKS
      WHERE run_id = :run_id GROUP BY 1) s
WHERE d.run_id = :run_id AND d.cluster_id = s.cluster_id;
```

Pass 3 falls out of the `LEFT JOIN`: a ticket with edges but no root among its neighbours gets no parent and
becomes its own root. Two consequences to state plainly to the user:

- this is a set-based approximation of incremental anchored clustering, not a global optimum; a long
  incident whose tickets arrive outside the window of the first report forms more than one cluster. Widening
  the window trades that for more false merges — tune it on the sandbox, where both failure modes are planted;
- in production (phase 8) new tickets attach incrementally to existing roots, which is the exact algorithm.

**Existing parent links.** If the source system already records parent incidents (`tickets.parent_col`), use
an existing parent as the root for any ticket linked to it, and report agreement between the pipeline's
clusters and the recorded parents. Recorded parents are, like other historical labels, incomplete.

## Step 4 — Known-issue links

Two independent signals, recorded separately:

- **Error code** — an exact match on the normalized error code is strong evidence and cheap.
- **Semantic** — similarity between the ticket and the known-issue article above
  `thresholds.known_issue_similarity`, restricted to the same canonical product when both have one.

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.KNOWN_ISSUE_LINKS (
    run_id           VARCHAR,
    ticket_id        VARCHAR,
    known_issue_id   VARCHAR,
    article_id       VARCHAR,
    similarity       FLOAT,
    error_code_match BOOLEAN,
    link_basis       VARCHAR,      -- ERROR_CODE | SEMANTIC | BOTH
    rank_in_ticket   NUMBER
);

INSERT INTO <db>.<schema>.KNOWN_ISSUE_LINKS
WITH scored AS (
    SELECT c.ticket_id, k.known_issue_id, k.article_id,
           VECTOR_COSINE_SIMILARITY(e.embedding, k.embedding) AS sim,
           EQUAL_NULL(x.error_code, k.error_code) AND k.error_code IS NOT NULL AS code_match
    FROM <db>.<schema>.TICKET_CLASSIFICATION c
    JOIN <db>.<schema>.TICKET_EMBEDDINGS e
      ON e.ticket_id = c.ticket_id AND e.embed_model = '<embed_model>'
    LEFT JOIN <db>.<schema>.TICKET_ENTITIES x
      ON x.run_id = c.run_id AND x.ticket_id = c.ticket_id
    JOIN <db>.<schema>.KNOWN_ISSUE_EMBEDDINGS k
      ON k.embed_model = '<embed_model>'
     AND (x.product IS NULL OR k.product IS NULL OR x.product = k.product)
    WHERE c.run_id = :run_id
)
SELECT :run_id, ticket_id, known_issue_id, article_id, sim, code_match,
       CASE WHEN code_match AND sim >= :ki_threshold THEN 'BOTH'
            WHEN code_match                        THEN 'ERROR_CODE'
            ELSE 'SEMANTIC' END,
       ROW_NUMBER() OVER (PARTITION BY ticket_id ORDER BY code_match DESC, sim DESC)
FROM scored
WHERE (code_match OR sim >= :ki_threshold)
  AND NOT EXISTS (SELECT 1 FROM <db>.<schema>.KNOWN_ISSUE_LINKS l
                  WHERE l.run_id = :run_id AND l.ticket_id = scored.ticket_id);
```

Keep only `rank_in_ticket = 1` in the triage output; keep the rest for diagnosis. The non-English sandbox
scenario (S23) should still link through its error code even if semantic similarity is weak — a useful
illustration of why the two signals are kept separate.

Known-issue linking says **what the problem is**. Whether the requester can fix it themselves is phase 6's
question, decided against the article's `is_self_service` flag; the sandbox's FI-204 scenario (S13) links to a
known issue whose workaround only the application team can apply.

## Step 5 — Priority raises from clusters

Apply the customer's raise rule (recorded in state during phase 4) now that clusters exist. For example, a
cluster at or above `raise_cluster_size` sets impact to `HIGH` for every member and re-derives priority from
the matrix:

```sql
UPDATE <db>.<schema>.TICKET_CLASSIFICATION c
SET pred_impact = 'HIGH', pred_priority = m.priority, priority_source = 'MATRIX+RAISE'
FROM <db>.<schema>.DUPLICATE_LINKS d, <db>.<schema>.PRIORITY_MATRIX m
WHERE c.run_id = :run_id AND d.run_id = c.run_id AND d.ticket_id = c.ticket_id
  AND d.cluster_size >= :raise_cluster_size
  AND m.taxonomy_version = c.taxonomy_version AND m.impact = 'HIGH' AND m.urgency = c.pred_urgency
  AND c.pred_impact <> 'HIGH';
```

Only raise, never lower. Record how many tickets were raised; the priority confusion matrix in phase 7 shows
whether the rule helped.

## Verification before declaring the phase done

```sql
-- 1. Embedding coverage and model symmetry.
SELECT embed_model, COUNT(*) FROM <db>.<schema>.TICKET_EMBEDDINGS GROUP BY 1;
SELECT embed_model, COUNT(*) FROM <db>.<schema>.KNOWN_ISSUE_EMBEDDINGS GROUP BY 1;
-- Exactly one model on both sides, matching models.embed.
```

```sql
-- 2. Cluster size distribution.
SELECT cluster_size, COUNT(DISTINCT cluster_id) AS clusters
FROM <db>.<schema>.DUPLICATE_LINKS WHERE run_id = :run_id
GROUP BY 1 ORDER BY 1 DESC;
```

```sql
-- 3. Read the largest cluster. Members must be obviously the same issue.
WITH big AS (
    SELECT cluster_id FROM <db>.<schema>.DUPLICATE_LINKS
    WHERE run_id = :run_id ORDER BY cluster_size DESC LIMIT 1)
SELECT d.ticket_id, d.parent_ticket_id, ROUND(d.similarity_to_parent, 3) AS sim,
       n.created_at, LEFT(n.classify_text, 160) AS preview
FROM <db>.<schema>.DUPLICATE_LINKS d
JOIN big USING (cluster_id)
JOIN <db>.<schema>.TICKETS_NORMALIZED n ON n.ticket_id = d.ticket_id
ORDER BY n.created_at;
-- Show the user only on request outside the sandbox (ticket text).
```

```sql
-- 4. Structural assertions. All must return zero.
-- (a) every child is directly similar to its parent above threshold (no chaining)
SELECT COUNT(*) AS chained_children
FROM <db>.<schema>.DUPLICATE_LINKS
WHERE run_id = :run_id AND NOT is_root AND (similarity_to_parent IS NULL OR similarity_to_parent < threshold_used);

-- (b) no parent is itself a child
SELECT COUNT(*) AS parent_is_child
FROM <db>.<schema>.DUPLICATE_LINKS c
JOIN <db>.<schema>.DUPLICATE_LINKS p ON p.run_id = c.run_id AND p.ticket_id = c.parent_ticket_id
WHERE c.run_id = :run_id AND NOT p.is_root;

-- (c) no link crosses predicted category (blocking held)
SELECT COUNT(*) AS cross_category_links
FROM <db>.<schema>.DUPLICATE_LINKS d
JOIN <db>.<schema>.TICKET_CLASSIFICATION a ON a.run_id = d.run_id AND a.ticket_id = d.ticket_id
JOIN <db>.<schema>.TICKET_CLASSIFICATION b ON b.run_id = d.run_id AND b.ticket_id = d.parent_ticket_id
WHERE d.run_id = :run_id AND a.pred_category <> b.pred_category;
```

```sql
-- 5. Known-issue links by basis.
SELECT known_issue_id, link_basis, COUNT(*) AS tickets
FROM <db>.<schema>.KNOWN_ISSUE_LINKS
WHERE run_id = :run_id AND rank_in_ticket = 1
GROUP BY 1, 2 ORDER BY 1, 2;
```

In the sandbox, expect three dominant clusters (two VPN outages kept apart, one mail-delay incident), each
known issue linked mostly by `BOTH` or `ERROR_CODE`, and the printer-offline tickets in none of the VPN
clusters. Pairwise precision and recall against the answer key are computed in phase 7, not here.

Then record `thresholds.duplicate_similarity`, `thresholds.known_issue_similarity`, the window and raise rule,
`phases.link: done`, and the created tables.
