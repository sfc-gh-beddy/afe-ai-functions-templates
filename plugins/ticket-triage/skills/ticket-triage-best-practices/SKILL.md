---
name: ticket-triage-best-practices
description: "Correctness rules every support/IT ticket triage pipeline must follow. Always loaded by the ticket-triage router. Catches silent failure modes: pipeline code that runs clean, returns plausible routing decisions, and is quietly wrong. Covers answer-key and label leakage (historical category, final assignment group, close notes and later work notes in classifier input), historical labels as noisy rather than ground truth, AI_CLASSIFY label-set contracts (case sensitivity, description and task_description word limits, label count, validating output against the set), NULL-on-error accounting and the default-queue COALESCE trap, not fabricating confidence that AI_CLASSIFY does not return, priority as impact x urgency rather than a direct ask, rules-first queue derivation, multi-intent tickets, CORTEX_SEARCH_BATCH versus constant-only SEARCH_PREVIEW, mandatory citations with SQL-side validation, deflection as answerability not topicality, embedding model symmetry and precomputed vectors instead of per-pair AI_SIMILARITY, anchored rather than transitive duplicate clustering, thread normalization and token windowing, AI_COMPLETE structured-output rules, VARIANT and unbounded VARCHAR, per-queue and macro metrics with full confusion matrices joined from ground truth, pairwise duplicate scoring, deflection precision definition, cost from CORTEX_AI_FUNCTIONS_USAGE_HISTORY by query tag, cross-region and PII boundaries, dynamic-table refresh-mode traps, and experiment tracking."
parent_skill: ticket-triage
---

# Ticket triage — correctness rules

These rules separate a triage pipeline that *appears* to work from one that is right. Every item has a
failure mode where the SQL succeeds, the queue distribution looks plausible, and the result is wrong.
Apply them to every artefact this plugin generates.

---

## 1. The classifier must never see the answer

**The failure:** an accuracy figure far above what an experienced dispatcher achieves, on the first
run. It is almost always leakage, and leakage in ticket data is easy because the answer is sitting in
neighbouring columns.

**Never in the classifier input:**

- the historical `category`, `subcategory`, `priority` or `assignment_group` fields, or any field
  derived from them (a "routing hint" column, a configuration-item owner group that the ITSM tool
  auto-populated *after* assignment);
- **resolution / close notes** — written after the ticket was routed and solved, they name the fix
  and frequently the team;
- **work notes or comments written after the first assignment** — "transferring to Network team" is
  the label in plain text. Only the requester's initial description and any comments timestamped
  before the first assignment are classifier input;
- for the sandbox, anything from the eval schema.

**The answer key and any labeled holdout are quarantined:** they live in `target.eval_schema`, no
pipeline query joins them, and they never appear in a prompt, a few-shot example, or the knowledge
store. Few-shot examples for `AI_CLASSIFY` come from a separate, disjoint example set and their ticket
ids are excluded from evaluation. A `SELECT *` across a schema, or a few-shot example that happens to
be an eval ticket, is enough to make every metric meaningless.

## 2. Historical labels are evidence about the past, not ground truth

On real data the temptation is to score against the existing `category` and `assignment_group`
columns. Be precise about what they are:

- **Final assignment group** is where the ticket ended after any reassignments. It is a reasonable
  proxy for the *correct* queue on tickets that were resolved there, and a poor one for tickets closed
  by the service desk after giving up.
- **First assignment group** is what the current process chose. The share of tickets whose first
  assignment equalled their final one is the **current-state routing accuracy**, and it is the
  baseline the value readout compares against. Get it from the audit/history table when one exists.
- **Category** is very often the form default. A category holding a large share of tickets that reads
  like "Inquiry / Help" is not a category, it is missing data.
- **Priority** on closed tickets may have been edited after the fact (downgraded once the outage was
  over).

So: use historical labels to derive the taxonomy and to report agreement, label every such number
"agreement with historical labels", and quote accuracy only against the sandbox answer key or a holdout
that a customer SME labeled. Never present agreement with a noisy label as accuracy.

## 3. `AI_CLASSIFY` label sets are a contract — honour every constraint

Verified against the `AI_CLASSIFY` documentation:

- **Categories are case sensitive**, and so is the input text. `'Network'` and `'network'` are
  different labels. Store labels in one canonical form and compare with exact equality.
- **At least two unique labels.** Past roughly **twenty**, the docs warn accuracy may drop. A queue
  list of 60 assignment groups is not one `AI_CLASSIFY` call; split hierarchically (category first,
  then queue within the category's candidate set) or derive queue from rules (rule 7).
- **Label descriptions are 25 words or fewer**; **`task_description` is 50 words or fewer**. Both count
  as input tokens on every row. Validate the word counts in SQL when the label table is written.
- **`output_mode: 'multi'`** for multi-label; the default is single, which always returns exactly one
  label.
- **`examples`** need `input`, `labels` and `explanation` on each.
- The return value is an object whose `labels` field is an array. Read `:labels[0]::STRING` for single
  label, and **verify the returned label is a member of the label set** before trusting it.

```sql
-- Every predicted label must exist in the versioned label set. Non-zero means a
-- label-set mismatch (case, whitespace, stale version), not a model error.
SELECT c.pred_category, COUNT(*) AS tickets
FROM ticket_classification c
LEFT JOIN taxonomy_labels t
  ON t.taxonomy_version = c.taxonomy_version
 AND t.dimension = 'category'
 AND t.label = c.pred_category
WHERE c.run_id = :run_id
  AND c.pred_category <> 'UNCLASSIFIED'
  AND t.label IS NULL
GROUP BY 1;
```

Build the label array **from the versioned label table**, not from a literal in the SQL, so the label
set that ran is the label set that was reviewed — and so its hash can be persisted (rule 26).

## 4. Count the NULLs. A failed call is not a classification.

`AI_CLASSIFY`, `AI_FILTER`, `AI_EXTRACT` and `AI_COUNT_TOKENS` return `NULL` on a row they cannot
process, and the statement continues. With `return_error_details => TRUE` they return an object with
`value` and `error` instead. That is right for throughput and invisible unless counted.

**The trap that turns this into a routing bug:**

```sql
-- WRONG. Every failed call becomes a confident route to the service desk.
COALESCE(AI_CLASSIFY(text, :queues):labels[0]::STRING, 'SERVICE_DESK') AS pred_queue
```

The failed rows now look like correct, high-volume service-desk routing; the service desk's precision
drops a little and nothing points at the cause. Instead:

- keep the raw function output (`raw_classify VARIANT`) on the row;
- map `NULL` to an explicit `UNCLASSIFIED` label with `label_source = 'ERROR'`;
- count `UNCLASSIFIED` at every gate and in the harness, where it scores as a miss (rule 18);
- sample a few with `return_error_details => TRUE` to see why.

For `AI_FILTER` the same applies: `NULL` is not `FALSE`. A deflection gate that treats `NULL` as "not
deflectable" undercounts quietly; one that uses `NOT AI_FILTER(...)` to *exclude* tickets keeps the
nulls out of both branches (`NOT NULL` is `NULL`), and they vanish entirely.

## 5. Do not fabricate a confidence score that the function does not return

`AI_CLASSIFY` returns labels, not probabilities. There is no confidence field to read. Inventing one —
asking a second model "how confident are you", or writing a constant — produces a column that looks
like calibration and is not.

What this plugin does instead, and what the router's per-row contract means by confidence:

- `confidence_band` is **derived from observable agreement**, recorded with its basis:
  - `HIGH` — a deterministic rule fired, or `AI_CLASSIFY` and an independent signal agree (category
    implies the predicted queue through `category_queue_map`; the extracted product belongs to that
    queue's product list);
  - `MEDIUM` — `AI_CLASSIFY` returned a valid label with no corroborating signal;
  - `LOW` — signals disagree, the label was `UNCLASSIFIED`, or the ticket went to the `AI_COMPLETE`
    fallback.
- When the fallback runs, its schema-required `confidence` (integer 1-10) is stored in its own column,
  `fallback_confidence`, and labelled self-reported. Language-model self-reported confidence is
  frequently miscalibrated; never merge it into `confidence_band` silently.
- `evaluate-triage-accuracy` produces a **reliability table**: precision by `confidence_band` and by
  `fallback_confidence` bucket. Only after that table shows the bands separate correct from incorrect
  may any downstream automation (auto-assign above a band) rely on them.

If the bands do not separate — precision is flat across bands — say so. A threshold on a flat signal
looks principled and behaves randomly.

## 6. Priority is impact times urgency, derived in SQL — not asked for

**The failure:** "What priority is this ticket, P1-P4?" yields mostly P3. Models anchor on the middle,
and they read requester tone as urgency: "URGENT!!! cannot print" becomes P1 while "FYI the payment
API is returning 500s for all customers" becomes P3.

**The rule:** classify **impact** (how many users / which service tier is affected) and **urgency**
(how fast the business is harmed, is there a workaround) as two separate `AI_CLASSIFY` calls against
the customer's own definitions, then derive priority from the customer's matrix in a deterministic SQL
lookup. This keeps the priority policy in the customer's hands, auditable, and changeable without a
prompt edit.

Urgency label descriptions must say explicitly that exclamation marks, capitals and the word "urgent"
are not evidence of urgency. If the customer has no matrix, `define-triage-taxonomy` builds one with
them; do not invent one silently.

Major-incident signals (multiple users, a service-down statement, a monitoring alert source) can
**raise** priority via a rule. Nothing the requester types can, on its own.

## 7. Rules first, model second, for queue

Most organizations already have deterministic routing knowledge: a category plus a product maps to one
resolver group; tickets from the monitoring integration go to operations; a VIP requester list. Asking a
model to rediscover those rules is slower, costs tokens, and is less accurate than the rule.

Order of evaluation, recorded in `queue_source`:

1. explicit rules (`category_queue_map`, channel/source rules) — `RULE`;
2. `AI_CLASSIFY` over the **candidate** queues for the predicted category — `AI_CLASSIFY`;
3. `AI_COMPLETE` fallback with a schema, for the low-confidence residue — `AI_COMPLETE`;
4. `UNCLASSIFIED` — `ERROR` or `NO_MATCH`.

Report the share of tickets settled at each step. If step 1 settles almost nothing, the mapping table is
incomplete; if step 3 settles a large share, the taxonomy is not separable.

## 8. Multi-intent tickets need a decision, not an accident

"My laptop won't connect to VPN, and also I need access to the finance share" is two tickets. Single-label
classification picks one silently.

Decide explicitly with the customer during taxonomy:

- **Route on primary intent** (single label) and flag `is_multi_intent` from a cheap `AI_CLASSIFY`
  binary or the fallback schema, so agents know to split. This is the default.
- **Multi-label category** (`output_mode: 'multi'`) when the customer's tooling supports multiple
  categories. Queue stays single — a ticket has one owner.

In evaluation, a multi-intent ticket's primary label is scored; the secondary is reported separately so
a correct-but-secondary prediction is visible rather than a silent miss.

## 9. Per-row search needs `CORTEX_SEARCH_BATCH`, not `SEARCH_PREVIEW`

`SNOWFLAKE.CORTEX.SEARCH_PREVIEW` **only accepts constant arguments** (per its docs). It cannot take a
column, so it cannot retrieve per ticket inside a `SELECT` over a table. Writing it that way fails to
compile; working around it with a procedure loop is slow and easy to make non-idempotent.

For per-ticket retrieval over a table, use the `CORTEX_SEARCH_BATCH` table function with `LATERAL`:

```sql
SELECT q.ticket_id, r.*
FROM retrieval_queries q,
LATERAL CORTEX_SEARCH_BATCH(
    service_name => '<db>.<schema>.<service>',
    query        => q.query_text,
    filter       => q.search_filter,
    limit        => 5
) AS r;
```

Documented behaviour to plan around:

- dedicated batch compute with **startup latency**; below roughly 2,000 queries the interactive API is
  typically faster, so for small daily increments the suggestion step may run via the Python or REST
  API in a stored procedure instead;
- **reranking is not supported** in batch; rerank settings are ignored;
- **query embedding is billed** in batch, unlike interactive search;
- batch can query a service that is suspended in serving;
- the output includes relevance scores; **the exact score column names are not specified in the
  docs**, so probe one query, inspect the result columns, and record the name before thresholding on
  it (`knowledge.batch_score_col` in state).

Use `SEARCH_PREVIEW` for gate verification (one known query, constants), not in the pipeline.

## 10. Every suggestion cites a source that exists, enforced in SQL

**The failure:** a fluent, plausible resolution with no source — or a source id that does not exist.
An agent who follows it and finds it wrong stops trusting every suggestion; an end user who follows it
opens a second ticket.

**The rules:**

- The prompt **supplies** each retrieved chunk with its `chunk_id` and instructs the model to cite only
  from that set. A model asked for provenance it was not given will fabricate it.
- `citations` is a schema-`required` array of objects each with a required `chunk_id`.
- A JSON schema cannot express "non-empty array" — `minItems` is unsupported. Enforce in SQL, and check
  each cited id was in **this ticket's** retrieved set, not merely in the index:

```sql
SELECT s.ticket_id,
       ARRAY_SIZE(s.citations) = 0 AS uncited,
       EXISTS (
         SELECT 1 FROM TABLE(FLATTEN(input => s.citations)) f
         WHERE NOT ARRAY_CONTAINS(f.value:chunk_id::VARIANT, s.retrieved_chunk_ids)
       ) AS cites_unretrieved
FROM resolution_suggestions s
WHERE s.run_id = :run_id AND s.is_suggested;
```

Rows failing either check are kept with `is_suggested = FALSE` and a `reject_reason`, so hallucinated
provenance is counted rather than silently dropped.

## 11. Deflection means the source resolves the ask — not that it is on topic

**The failure:** "Is this ticket about password resets?" flags a ticket that says "I followed the
password reset article and it says my account is locked". Topic match, not answerable. Deflection
precision collapses, and deflection precision is the number that decides whether anything ever reaches
an end user.

**The rules:**

- The `AI_FILTER` gate asks about **answerability by self-service** ("Could the requester resolve this
  themselves by following published instructions, without an agent changing anything on their
  behalf?"), not topic.
- The suggestion schema has an explicit `resolves_request` boolean and a `deflection_type` enum
  (`SELF_SERVICE_HOWTO`, `KNOWN_ISSUE_WORKAROUND`, `STATUS_UPDATE`, `NOT_DEFLECTABLE`). Only the first
  two count as deflection candidates.
- **Exclude** from deflection: tickets linked to an open parent incident (they deflect to a status page,
  a different mechanism and a different metric), tickets where the requester states they already tried
  the cited fix, access and permission requests (an agent or approval is required by definition), and
  P1/P2.
- A retrieval score is a **floor**, never the decision. On-topic is not the same as answers-it.
- Deflection is measured precision-first. A recommendation with 70 percent precision may be useful as
  agent assist and harmful as an auto-reply. The readout states the precision required for each use.

## 12. One embedding model, on normalized text, precomputed

- **The same model for both sides.** Ticket and KB embeddings from different models live in different
  spaces; cosine similarity between them is meaningless and still returns a number. Record the model on
  every embedding row and assert one distinct value before any similarity join.
- **Declare the vector type to match the model.** `snowflake-arctic-embed-l-v2.0` produces 1024
  dimensions (per the vector-embeddings docs); store as `VECTOR(FLOAT, 1024)`. Mixed dimensions fail at
  insert; a wrong declared size is caught early, which is the point.
- **Embed normalized text**, not the raw thread. Signatures, legal disclaimers and portal templates
  dominate short tickets and make tickets from one sender similar and everyone else different.
- **Precompute with `AI_EMBED`, compare with `VECTOR_COSINE_SIMILARITY`.** `AI_SIMILARITY(text, text)`
  embeds both inputs on every call (billed under `AI_EMBED`, per docs). Calling it pairwise over N
  tickets embeds each ticket up to N times. It is fine for one-off checks, never for a pairwise join.
- **Block before comparing.** Pairwise across a corpus is N squared. Compare within a time window and
  within predicted category (and product when extracted), which is also what makes the results
  sensible.

## 13. Cluster by anchoring, not by transitive closure

**The failure:** connected components over a similarity graph. A links to B at 0.86, B to C at 0.86, C to
D … and a VPN outage cluster absorbs a password reset at the far end of a chain where no pair is
dissimilar enough to break it. One giant cluster appears; nothing errors.

**The rule:** anchored (star) clustering. Each ticket links to at most one **parent**: the earliest
ticket within the window that it is similar to above threshold *and that is not itself a child*. A child
must be similar to its parent directly, not via a chain. If the customer already records a major
incident as a parent, that incident is the anchor and new tickets attach to it.

Verify at the gate: read the largest cluster's members. If they are not obviously the same issue, the
threshold or the blocking key is wrong.

## 14. Normalize threads and window by tokens before any AI call

Email-to-case tickets carry the full quoted history of every reply, signatures, confidentiality
footers, and auto-generated headers. They inflate cost (often the largest single lever), dilute the
classifier, and push long threads past the context window so the call returns `NULL` (rule 4).

- Strip quoted replies, signatures and disclaimers with patterns tuned to **this** mail system (show
  the user what a pattern removes, with counts, before committing it — patterns are not portable).
- Build classifier input from subject plus the requester's first message plus comments before the
  first assignment (rule 1). Build linking input from the same. The suggestion step may use the full
  normalized thread.
- `CONCAT(subject, ' ', body)` is `NULL` when either is `NULL`. Use `CONCAT_WS` or `COALESCE` each
  part; subject-only tickets are common.
- Window by tokens using `AI_COUNT_TOKENS('ai_complete', '<model>', text)` — function name first,
  lowercase, then model, then text. A wrong function name returns `NULL`, not an error. Truncation keeps
  the **beginning** of a ticket (the problem statement), which is the opposite of clinical charts.

## 15. `AI_COMPLETE` structured output: schema, not prose

Wherever `AI_COMPLETE` runs (classification fallback, entity fallback, suggestions):

- pass `response_format` with a JSON schema and mark every field the pipeline reads `required`;
- `temperature: 0`;
- add "Respond in JSON" to the prompt text as well on reasoning-heavy steps;
- use `TRY_COMPLETE` or error details so one row does not abort the batch;
- schema constraints: property names letters, digits, hyphen, underscore, at most 64 characters;
  `minItems`, `maxItems`, `minimum`, `maximum`, `minLength`, `maxLength` and `format` are not
  supported; use `enum` for label fields so the model cannot invent a queue;
- a prompt object with file inputs cannot take `response_format`. Turn attachments (screenshots,
  error dialogs) into text first, then make a separate single-string call with the schema.

Never parse JSON out of free text with `TRY_PARSE_JSON` on a schema-less path in this plugin; a parse
failure becomes `NULL`, which becomes `UNCLASSIFIED` or "no suggestion", which looks like a correct
negative.

## 16. Types: VARIANT for structure, unbounded VARCHAR for model text

- Keep `raw_classify`, `raw_extract`, `citations`, `retrieved_chunk_ids` and `entities` as `VARIANT` or
  `ARRAY`. `...::VARCHAR` produces a string that looks like JSON and silently breaks every downstream
  `FLATTEN`.
- Declare model-written text (`suggested_resolution`, `reasoning`, `error_message`) as `VARCHAR` with no
  length. Snowflake stores it the same; a length limit only guarantees an eventual "String is too long"
  failure on a verbose row.
- Give label columns headroom (`VARCHAR` unbounded) so a contract violation lands as inspectable data
  that rule 3's membership check then catches, rather than aborting the insert.

## 17. Never report accuracy alone; report per queue and macro, with support

Queue distributions are skewed. If the service desk holds most tickets, "always service desk" scores
high accuracy and high micro-F1 while routing every specialist ticket wrong — which is the exact cost the
play exists to remove.

Report, for queue and for category:

- per-label precision, recall, F1 **and support** (true count);
- **macro**-F1 (unweighted mean over labels) as the headline;
- micro-F1 and accuracy alongside, labelled;
- weighted-F1 only if the customer asks, labelled.

Labels with support under ~30 in the evaluation set are reported with a "low support" flag; their
F1 is a few coin flips, and a macro average over many such labels is noisy. Say so rather than hiding
them.

## 18. Build the evaluation from ground truth outward, and score UNCLASSIFIED as a miss

If the harness starts from predictions and `LEFT JOIN`s the answer key, a ticket the pipeline dropped —
null classification, failed parse, filtered upstream — is absent from evaluation and costs nothing.
Total failure then reports as high precision on survivors.

Start from the answer key, `LEFT JOIN` predictions for the run, and treat missing or `UNCLASSIFIED`
predictions as a predicted label of `UNCLASSIFIED`: a false negative for the true label and a false
positive for nobody. Report the `UNCLASSIFIED` count beside every metric.

## 19. Confusion matrices must include the zero cells

`GROUP BY true_label, pred_label` only returns cells that occurred. A P1 row with no P1 predictions
simply does not appear, and a reader sees a tidy matrix with no P1 problem. Cross join the label set with
itself and left join the counts so every cell is present, zero or not.

## 20. Score duplicates pairwise, not by cluster count

"We found 12 clusters and the answer key has 12" says nothing. Score on **pairs**: every pair of tickets
the pipeline put in the same cluster is a predicted positive; every pair the answer key puts in the same
cluster is a true positive. Pairwise precision and recall catch both over-merging (rule 13) and
fragmentation. Report the parent-identification rate separately (did the cluster's parent match the
answer key's parent).

## 21. Define deflection precision before measuring it

A deflection true positive is a ticket that the pipeline flagged as a candidate **and** the answer key
marks deflectable **and** at least one cited source is an acceptable source for it (the labelled article,
or one the labeller marked equivalent). Flagged-and-deflectable but citing the wrong article is a false
positive: an end user following it would not have been helped.

Report deflection precision, recall, the citation-validity rate, and the wrong-article count separately.

## 22. Cost: tokens and credits, from the right view, attributed by query tag

- `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY` is **no longer updated** (per its docs).
  Use `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY`, which carries `START_TIME`, `END_TIME`,
  `FUNCTION_NAME`, `MODEL_NAME`, `QUERY_ID`, `QUERY_TAG`, `CREDITS` and a `METRICS` array. It includes
  usage from 5 January 2026 onward; query tag and role attribution are available for data after
  16 February 2026.
- Set `QUERY_TAG` to the `run_id` for every pipeline session so credits attribute to a run.
- Report **cost per 1K tickets per stage** in credits and tokens. Never convert to currency, never look up
  a price, even when asked; the customer's contract rate is theirs to apply.
- `AI_COUNT_TOKENS` estimates input only; output tokens bill on top. On structured-output calls the
  schema adds billed input that the estimate does not count (observed in the reference play; reconcile
  against the usage view after the first real run rather than assuming it does not apply here).
- `CORTEX_SEARCH_BATCH` bills serving, query embedding and warehouse separately; its own usage view is
  `CORTEX_SEARCH_BATCH_QUERY_USAGE_HISTORY` (per docs).

## 23. Cross-region and PII boundaries

- **Never set `CORTEX_ENABLED_CROSS_REGION`.** Report it; the account administrator decides. Enabling it
  sends ticket text — which contains personal data — to another region for inference.
- Never write ticket text, entities or suggestions to a local file, a log, an issue tracker or any
  external endpoint.
- **A knowledge store built from resolved tickets is a new copy of sensitive text** with potentially a
  wider audience than the ticket table — especially if deflection is ever exposed to end users. Redact
  before indexing (`AI_REDACT`, which its docs describe as best-effort; review a sample at the gate), and
  apply the same masking and access decision preflight recorded.
- Pasted credentials found in preflight are a security finding to raise with the customer, not something
  to index.

## 24. Dynamic tables over AI functions: check the refresh mode you actually got

Cortex AI functions in the `SELECT` list are supported for incremental refresh (per the dynamic-table
supported-queries page). But if any other construct in the definition is not incremental-eligible,
Snowflake silently chooses **full** refresh — which re-runs every AI call on every row on every refresh.

After creating any dynamic table that calls an AI function, check `refresh_mode` (and the reason) in
`SHOW DYNAMIC TABLES` output. If it is `FULL`, stop and restructure, or use a stream and task instead.
Also note that re-initializing a dynamic table (e.g. after `CREATE OR REPLACE`) reprocesses everything;
treat it as a costed event.

## 25. Orchestration correctness

- Idempotent on `run_id` + `ticket_id`. Task auto-retry re-runs the whole step; a non-idempotent step
  double-bills inference and double-inserts suggestions.
- No `TEMPORARY` tables shared between tasks — each task runs in its own session.
- A stream is consumed by the DML that reads it in a committed transaction; two tasks reading one stream
  race. One stream per consumer.
- Create objects fully qualified. An object created after an unqualified `USE SCHEMA` lands somewhere
  the reader does not expect.

## 26. Every run is attributable: experiment ids, prompt hash, taxonomy version

- Classify, link, suggest and evaluation layers **accumulate** (incremental or append keyed on
  `run_id`); a `CREATE OR REPLACE` table at rest holds one experiment and every comparison query returns
  one row while appearing to work.
- Persist `prompt_hash` computed from the **assembled** prompt **plus** the serialized label set and
  examples actually passed to `AI_CLASSIFY`. A changed description with the same `prompt_version` is a
  different experiment; trust the hash.
- Persist `taxonomy_version`. Per-queue metrics across taxonomy versions are not comparable; the harness
  must say so rather than plot them on one axis.

## 27. Taxonomy drift is a production failure mode

Organizations reorganize: a queue is split, a team is renamed, a product is retired. The classifier keeps
routing to the old label with high confidence, and nothing errors.

- The label table carries `active` and an effective date; the classifier reads only active labels.
- The operationalized pipeline reports, weekly, the share of tickets whose predicted queue was later
  reassigned by an agent (from the ITSM audit trail once write-back exists, or from final assignment
  otherwise). A rising rate for one queue is the signal to revisit the taxonomy.
