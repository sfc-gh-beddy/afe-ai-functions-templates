# Diagnosing a triage pipeline that is not producing what you expect

Work these in order. Most reported failures are one of the first four, and they look alike from the
output table: one queue gets everything, or the accuracy number is suspiciously good or bad.

Object names below are placeholders; read the real ones from `created_objects` in
`triage-project.yml`.

## 1. Silent nulls from AI functions — check this first

**Symptom:** fewer classified tickets than input tickets, many `UNCLASSIFIED`, entity fields empty
on tickets that plainly name a product, or deflection candidates far below what the KB suggests.

`AI_CLASSIFY`, `AI_FILTER`, `AI_EXTRACT` and `AI_COUNT_TOKENS` return `NULL` on a row they cannot
process and let the statement continue. That is good for throughput and terrible for visibility: a
`NULL` label becomes `UNCLASSIFIED` (or worse, is coalesced into a default queue), a `NULL` filter
result reads as "not deflectable", a `NULL` extraction reads as "no product mentioned".

```sql
SELECT
    COUNT(*)                                                     AS tickets,
    COUNT_IF(raw_classify IS NULL)                               AS classify_null,
    COUNT_IF(raw_classify:error IS NOT NULL)                     AS classify_error,
    COUNT_IF(fallback_used AND NOT parse_ok)                     AS fallback_unparsed,
    COUNT_IF(pred_category = 'UNCLASSIFIED')                     AS unclassified
FROM <ticket_classification>
WHERE run_id = '<run_id>';
```

Re-run a handful of the `NULL` rows with `return_error_details => TRUE` to see the actual error.
Typical causes, in order of frequency:

- **Input too long.** An email thread with forty quoted replies exceeds the context window.
  Normalization (thread flattening, signature and quote stripping) is not optional — see
  `classify-and-route-tickets`.
- **Empty input.** Subject-only tickets where the body is `NULL`, and `CONCAT` with a `NULL`
  returned `NULL`. Use `CONCAT_WS` or `COALESCE` each part.
- **Non-English text.** `AI_CLASSIFY` documentation recommends English input. Route by detected
  language and translate first if the corpus is multilingual.
- **Region.** The function or model is not available in-region and cross-region is disabled.
  Preflight should have caught this; re-check `CORTEX_ENABLED_CROSS_REGION`.

## 2. Everything lands in one queue

**Symptom:** a predicted-queue distribution dominated by one value, usually the general service desk
queue or the first label in the list.

```sql
SELECT pred_queue, queue_source, COUNT(*) AS tickets,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM <ticket_classification>
WHERE run_id = '<run_id>'
GROUP BY 1, 2 ORDER BY 3 DESC;
```

Compare against the historical share from preflight. Then look for:

- **A catch-all label in the set.** "General", "Other", "Service Desk" with a vague description
  absorbs everything uncertain. Either remove it and let low-confidence tickets go to the
  `UNCLASSIFIED` path explicitly, or describe it narrowly ("requests that match no other queue
  after review").
- **A `COALESCE(pred_queue, 'SERVICE_DESK')`** somewhere downstream. This converts every null in rule
  1 into a confident-looking routing decision. Search for it before tuning anything.
- **Labels that differ only by name.** `Network` and `Network Ops` with no descriptions. The model
  cannot separate what the taxonomy does not separate. Fix in `define-triage-taxonomy`.
- **The mapping table defaulting.** If queue is derived from category plus product via
  `category_queue_map`, a missing mapping row for a common category sends all of it to the fallback.

## 3. Accuracy is suspiciously high

**Symptom:** queue F1 above what a human dispatcher would plausibly achieve, on a first run.

Assume leakage until proven otherwise. In order:

- **The historical label is in the prompt.** The ticket text passed to the classifier includes the
  existing `category` or `assignment_group` field, or a work note that says "reassigning to
  Network". The model is reading the answer. Check exactly which columns feed `clean_text`.
- **Resolution notes in the input.** Close notes are written after the ticket was routed and solved;
  they name the fix and often the team. They belong in the knowledge store, never in the classifier
  input.
- **The answer key is reachable.** Something selects from the eval schema. See best-practices
  rule 1.
- **Scoring against the final assignment group** on real data, where the model was also shown later
  work notes. Final group plus late notes is circular.

## 4. Accuracy looks good but the pipeline is not useful

**Symptom:** accuracy or micro-F1 is high; agents say routing is no better.

Accuracy on an imbalanced queue distribution is mostly the majority-class rate. If 60 percent of
tickets belong to the service desk, a classifier that always says "service desk" is 60 percent
accurate. That is why the harness reports **per-queue** precision and recall and **macro**-F1.

```sql
SELECT queue, support, precision_q, recall_q, f1_q
FROM <eval_queue_metrics>
WHERE run_id = '<run_id>'
ORDER BY support ASC;
```

Read the small queues first. A queue with recall near zero is a queue whose tickets are all being
mis-routed somewhere else — exactly the reassignment cost the play exists to remove.

## 5. Priorities are all the same

**Symptom:** nearly everything predicted P3, or the confusion matrix has an empty P1 row.

- **Priority asked directly.** Asking a model "what priority is this" anchors on the default. Classify
  **impact** and **urgency** separately against the customer's definitions, then derive priority from
  their matrix in SQL. See `classify-and-route-tickets`.
- **Requester tone treated as urgency.** "URGENT!!!" in a subject line is not urgency in ITIL terms.
  The urgency label descriptions must say so.
- **No P1 examples.** Major incidents are rare. If the sandbox or holdout has three P1 tickets, P1
  recall is three coin flips. Report the support count next to every cell of the confusion matrix.

## 6. Duplicates are not linking, or link wildly

**Symptom A — nothing links:** planted duplicate clusters come back as singletons.

```sql
SELECT ROUND(similarity, 2) AS sim_bucket, COUNT(*) AS pairs
FROM <duplicate_pairs_candidates>   -- before thresholding
WHERE run_id = '<run_id>'
GROUP BY 1 ORDER BY 1 DESC;
```

- The threshold was copied from another corpus. Cosine thresholds are model- and corpus-specific;
  tune on planted clusters.
- Embeddings were computed on the raw thread including signatures and disclaimers, which dominate
  short tickets and make every ticket from the same sender look alike and every ticket from
  different senders look different. Embed the normalized text.
- The time window or blocking key is too narrow (blocking on exact product string when extraction
  returns "Outlook" for one ticket and "Microsoft Outlook" for another).

**Symptom B — giant clusters:** one cluster holds hundreds of unrelated tickets.

- **Transitive chaining.** A links to B, B to C, and so on until a password reset is clustered with a
  printer jam. Use anchored (star) clustering to the earliest ticket rather than connected
  components. See `link-duplicates-and-known-issues`.
- **Boilerplate embeddings.** A portal template ("Please describe your issue: ...") embedded as part of
  every ticket.

## 7. Suggestions cite nothing, or cite the wrong article

```sql
SELECT
    COUNT(*)                                            AS gated_in,
    COUNT_IF(retrieved_count = 0)                       AS no_retrieval,
    COUNT_IF(is_suggested)                              AS suggested,
    COUNT_IF(is_suggested AND ARRAY_SIZE(citations)=0)  AS uncited,      -- must be zero
    COUNT_IF(citation_invalid)                          AS bad_citation  -- must be zero
FROM <resolution_suggestions>
WHERE run_id = '<run_id>';
```

- **No retrieval at all:** the service is still indexing, the filter on `product` uses a value format
  that differs between the ticket entities and the KB attributes, or only draft articles were
  indexed. Run one query by hand with `SNOWFLAKE.CORTEX.SEARCH_PREVIEW` (constants only) to isolate.
- **Retrieval succeeds, citations do not validate:** the prompt did not supply chunk ids with the
  chunk text, so the model invented them; or the model cited an `article_id` where the schema asked
  for `chunk_id`. Both are contract problems — fix the prompt and schema, not the validator.
- **Retired articles cited:** the index includes archived articles. Filter on workflow state at
  index time.

## 8. Too many deflection candidates

**Symptom:** a large share of tickets flagged deflectable; spot checks show many are not.

Deflection precision is the metric that decides whether anything is ever shown to an end user, so
over-calling is the expensive failure here.

- **The gate is checking topic, not answerability.** "Is this about password reset?" passes tickets
  where the user already followed the reset article and it failed. The `AI_FILTER` predicate and the
  suggestion schema must both ask whether the cited source *resolves the specific ask*, and the
  normalized text must include the user's statement of what they already tried.
- **Incidents treated as requests.** An outage ticket matched to "how to connect to VPN" is not
  deflectable however good the article. Exclude tickets linked to an open parent incident from
  deflection; they deflect to the incident status page, which is a different mechanism.
- **Threshold on retrieval score alone.** A high search score means the article is on-topic, not that
  it answers the question. Use it as a floor, never as the decision.

## 9. Cost is higher than expected

```sql
-- Which path did tickets take?
SELECT category_source, fallback_used, COUNT(*) AS tickets
FROM <ticket_classification> WHERE run_id = '<run_id>' GROUP BY 1, 2;

-- Did normalization actually shrink input?
SELECT ROUND(AVG(raw_tokens))   AS avg_raw_tokens,
       ROUND(AVG(clean_tokens)) AS avg_clean_tokens,
       ROUND(100 * (1 - AVG(clean_tokens) / NULLIF(AVG(raw_tokens), 0)), 1) AS pct_reduction
FROM <tickets_normalized>;

-- Billed credits for this run, by function and model.
SELECT function_name, model_name, SUM(credits) AS credits
FROM snowflake.account_usage.cortex_ai_functions_usage_history
WHERE query_tag = '<run_id>'
GROUP BY 1, 2 ORDER BY 3 DESC;
```

- **Fallback share high:** the confidence floor is too strict, or the taxonomy has labels the
  first-pass classifier cannot separate. A taxonomy fix is cheaper than a model upgrade.
- **Normalization reduction near zero on an email-heavy corpus:** quoted-reply stripping is not
  matching this mail system's quote markers. Inspect three long tickets.
- **Suggestion pass running on every ticket:** the `AI_FILTER` gate was bypassed or its predicate
  is so broad everything passes.
- **No rows in the usage view:** the query tag was not set, or the view has not caught up (best effort
  within minutes; see docs). Do not fall back to quoting a price.
