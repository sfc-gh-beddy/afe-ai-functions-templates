---
name: entity-resolution-best-practices
description: "Correctness rules every entity resolution pipeline in this plugin must follow. Always loaded by the entity-resolution router. Catches silent failure modes where SQL runs clean and the golden table looks plausible but is wrong: unmeasured blocking recall, blocks that explode on common tokens, NULL-propagating CONCAT_WS in embedding text, AI_SIMILARITY re-embedding cost inside joins, mixed embedding models or templates in one vector column, uncalibrated cosine thresholds, cannot-link evidence overridden by similarity, parent/subsidiary and franchise false merges, product size-variant false merges, transitive chaining into mega-clusters, model position bias, AI_COMPLETE NULL-on-error rows read as NO_MATCH, structured_output accessor shape, reasons-free model decisions, LLM-generated golden values, unstable golden ids, pair ordering and self-pair defects, answer-key leakage through identifiers, evaluation computed only over candidate pairs, singleton-blind cluster metrics, JAROWINKLER 0-100 scale, PII and bank fields in prompts, and experiment tracking requiring incremental materialization."
parent_skill: entity-resolution
---

# Entity resolution — correctness rules

Every rule here describes a failure where the pipeline completes, the row counts look reasonable, and
the result is wrong. Apply them to every artifact this plugin generates. The rules are grouped by the
phase where the failure is introduced, which is rarely the phase where it shows up.

---

## A. Standardization

### 1. `CONCAT_WS` returns NULL if any argument is NULL

Verified in the function reference: `CONCAT_WS` does not skip NULLs — one NULL argument makes the
whole result NULL. `CONCAT` behaves the same way. A serialization template written as
`CONCAT_WS(' | ', name, address, city, phone)` produces NULL for every record missing a phone number,
`AI_EMBED` of that NULL produces no vector, and the record silently drops out of semantic blocking and
scoring. Master data is full of missing phones.

Build serialized text from `ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(...), ' | ')`.
`ARRAY_CONSTRUCT_COMPACT` omits NULL inputs, so a missing attribute simply disappears from the text.
Label each element (`'name: ' || name_norm`) so the label also disappears when the value is NULL —
`'name: ' || NULL` is NULL and is compacted out.

Assert at the gate: `COUNT_IF(embed_text IS NULL OR embed_text = '')` over `ER_RECORDS` is zero.

### 2. Normalize before you block, with one shared expression per attribute

Blocking on raw strings puts `ACME, INC.` and `Acme Inc` in different blocks and the pair is lost
before any AI runs. Normalization (case, punctuation, whitespace, legal-suffix and abbreviation
handling) happens once, in `ER_RECORDS`, and every later phase reads the normalized column. Never
re-normalize inline in a later query with a slightly different expression — two expressions for "the
normalized name" is how a blocking key and a feature disagree about the same record.

### 3. Token maps are data, not a chain of `REPLACE` calls

Nested `REPLACE(REPLACE(...))` on substrings mangles words: replacing `CO` with `COMPANY` turns
`COBALT` into `COMPANYBALT`. Normalize at the **token** level: split on whitespace, look each token up in
`ER_TOKEN_MAP`, re-join in original order with `LISTAGG ... WITHIN GROUP (ORDER BY index)`. The map is a
table the user can inspect and extend, and each entry has a class (`LEGAL_SUFFIX`, `ABBREVIATION`,
`STOPWORD`) so the pipeline can produce both `name_norm` (abbreviations expanded) and `name_core`
(legal suffixes and stopwords also removed).

### 4. `record_uid` is constructed one way, everywhere

`record_uid = source_system || ':' || source_record_id`, with `source_record_id` cast to `VARCHAR`
and trimmed. The answer key, the crosswalk, and the golden id registry all key on it. A numeric key
cast differently in two places (`'00123'` versus `'123'`) silently breaks evaluation joins and makes
recall look terrible for a reason that has nothing to do with matching.

### 5. Respect records the source already retired

Most master systems mark merged, blocked, or deleted records with a status rather than removing them.
Resolving them again re-creates merges the business already made — or worse, links a live record to a
blocked vendor. Apply the per-source `filter` from `er-project.yml`, and report how many rows it
removed per source at the gate.

## B. Blocking

### 6. Blocking recall must be measured, not assumed

Blocking is the step that most often loses true matches, and it is invisible: a pair that is never
generated is never scored, never shown to the model, never counted. Report **pair completeness** —
the share of true duplicate pairs (from the answer key, or from a labeled sample on real data) that
appear in `ER_CANDIDATE_PAIRS` — alongside the **reduction ratio**. A reduction ratio of 99.9 percent
with pair completeness of 70 percent means 30 percent of duplicates were thrown away before matching
began.

### 7. Use several independent blocking passes, and union them

No single key catches everything: a typo in the first four letters defeats a prefix key, a missing
postal code defeats a postal key, a rebrand defeats every name key. Run multiple passes — name prefix
plus postal, phonetic first token plus city, exact tax id, exact phone, exact non-free email domain,
semantic nearest neighbours — and union the pairs, recording which rules produced each pair. The
per-rule contribution report is how you learn which passes earn their cost.

### 8. Cap block sizes, and log what was capped

A blocking key on a common token (`NORTH`, `SERVICES`, a free email domain, a placeholder phone
`0000000000`) creates a block of thousands and an n-squared pair explosion. Two failure modes:
silently exploding cost, or a hard-coded cutoff that silently drops the block. Exclude stopword tokens
and placeholder values from keys, cap at `blocking.max_block_size`, and write every capped block to
`ER_BLOCK_STATS` with its size so the user sees what was not compared.

Placeholder values are real: `N/A`, `UNKNOWN`, `000000000`, `noreply@`, a company's own main switchboard
on every contact. Check the top values of every exact-match key at preflight.

### 9. Order pairs canonically and exclude self-pairs

Always `record_uid_a < record_uid_b`. Without it the same pair appears as (A,B) and (B,A), is scored and
adjudicated twice, double-billed, and counted twice in precision. Self-pairs from a record matching
itself on every key are worse: they are guaranteed matches that inflate precision. Assert both counts
are zero at the gate.

### 10. Never block across entity types by default

A customer and a vendor with the same name may be the same organization, but merging them into one
golden record breaks both the customer and the vendor master. Resolve each entity type independently;
cross-type party linking is a separate, explicit option (`scope.cross_type_party`) that produces a
link table, not a merge.

## C. Embeddings and similarity

### 11. Embed once per record and store the vector. Do not call `AI_SIMILARITY` in a join.

`AI_SIMILARITY(a, b)` computes the cosine similarity of the two inputs' embeddings, and is billed under
the `AI_EMBED` line item. Called over candidate pairs it embeds both texts **per pair**: a record in
twenty candidate pairs is embedded twenty times. Store `AI_EMBED(model, embed_text)` once per record in
`ER_RECORD_EMBEDDINGS` as `VECTOR(FLOAT, <dim>)`, and compare with `VECTOR_COSINE_SIMILARITY`, which is
a vector function with no AI charge.

`AI_SIMILARITY` remains useful for ad hoc probes and for the parity check in `score-candidate-pairs`,
which confirms on a sample that the stored-vector cosine and `AI_SIMILARITY` agree for the configured
model. Run that check rather than assuming parity. Note `VECTOR_COSINE_SIMILARITY` is documented with a
margin of error up to `1e-4`, so compare with a tolerance, never equality.

### 12. One model and one template per vector comparison

Cosine similarity between vectors from different models is meaningless, and between vectors of the same
model built from different serialization templates it is systematically biased. Store `embed_model`,
`embed_template_version`, and `embed_text_hash` with every vector, and filter both sides of every
comparison to the configured pair. Re-embed only rows whose hash or model changed — this is also the
incremental cost lever.

### 13. Respect the embedding model's input limit

The documented context for `snowflake-arctic-embed-l-v2.0` is 512 tokens; the `-8k` variant exists for
longer text. Master records are short, but product descriptions and free-text notes are not. Measure
with `AI_COUNT_TOKENS('ai_embed', <model>, embed_text)` at the gate, and keep the identity-bearing
attributes at the **front** of the template so any truncation removes the least useful content. Do not
put notes or long descriptions in the embedding text of party records at all — they dilute identity.

### 14. Calibrate cosine thresholds on this data. They do not transfer.

A cosine of 0.85 is a strong match for one model and template and noise for another. Vendor names are
short, so two unrelated companies sharing two words can score very high. Never threshold on a cosine
value taken from documentation, a blog, or another engagement. Plot the score distribution for true
matches and true non-matches from the answer key, and set thresholds where the distributions separate.
If they do not separate, the feature is not discriminating — say so instead of picking a number.

### 15. Embeddings do not see the difference that matters

Embeddings are good at "these strings mean the same thing" and bad at "these are different legal
entities":

- **Parent, subsidiary, and sibling companies** (`Harlow Ridge Logistics` versus `Harlow Ridge
  Holdings`, same city, same domain) embed almost identically.
- **Franchise and branch locations** of a brand that are separate legal entities embed identically by
  name and differ only in address and tax id.
- **Product size and color variants** (`12 oz` versus `16 oz`) embed almost identically. A size
  variant is a different SKU.

This is why embeddings feed **blocking and a composite score**, never a merge on their own, and why
deterministic discriminators (rule 16) and the adjudication model see the attributes that differ.

## D. Deterministic evidence and banding

### 16. Cannot-link evidence overrides similarity

Two vendor records with **different** valid tax ids are different payees regardless of name similarity.
Two products with different GTINs are different items. Compute cannot-link flags in SQL and let them
force `AUTO_REJECT` — or, if the user prefers, `REVIEW` with the conflict surfaced — before any score
threshold is applied. Then carry cannot-link pairs into clustering (rule 23), because a chain of
individually acceptable edges can still connect two cannot-link records.

Treat a value as evidence only after excluding placeholders (rule 8). Two records both holding tax id
`000000000` are not a match, and two records holding different placeholders are not a conflict.

### 17. `JAROWINKLER_SIMILARITY` returns 0 to 100

Verified in the reference: integer 0 to 100. Mixing it unscaled with cosine (−1 to 1) in a weighted sum
lets one feature dominate silently. Divide by 100. `EDITDISTANCE` returns a count; normalize by the
longer string length and pass `max_distance` to bound cost on long strings.

### 18. Three bands, not two

Every scored pair lands in exactly one of `AUTO_MATCH`, `REVIEW`, `AUTO_REJECT`. The review band is
what goes to the model. A two-band design (match / no match on one threshold) either sends everything
ambiguous to an automatic decision or sends everything to the model; both are wrong. Assert there are
no NULL bands — a `CASE` without `ELSE` produces NULL bands that drop from every downstream join.

## E. Model adjudication

### 19. Use a JSON schema, and treat NULL as a failure, not a NO_MATCH

Per the current `AI_COMPLETE` reference, a row that cannot be processed returns NULL and does not stop
the query. With `return_error_details => TRUE` the function returns an object with `value` and `error`.
In a matching pipeline a NULL decision that is read as "not a match" silently lowers recall; read as
"unknown" and dropped, it silently lowers recall too. Both must be counted.

- Pass `response_format` with a JSON schema; mark every field the pipeline depends on `required`.
- Use `temperature: 0`. Add "Respond in JSON" to the prompt text.
- Pass `return_error_details => TRUE`, store `error` alongside the response, and write failures to
  `ER_PIPELINE_QUALITY_LOG`.
- A failed pair stays in `REVIEW` with `decision_source = 'MODEL_FAILED'`; it is never auto-accepted
  and never auto-rejected.

Schema constraint keywords that are documented as unsupported — and raise an error — include `minItems`,
`maxItems`, `minimum`, `maximum`, `minLength`, `maxLength`, `format`, `uniqueItems`. Property names
allow letters, digits, hyphen, underscore, at most 64 characters.

### 20. Read `structured_output` defensively

The structured-outputs reference shows that with `show_details => TRUE` the result carries
`structured_output` as an **array** whose first element has `raw_message`. Without `show_details`, the
function returns the object directly. With `return_error_details => TRUE` the whole result is wrapped in
`value`. Write one accessor and use it everywhere:

```sql
COALESCE(
    r:value:structured_output[0]:raw_message,
    r:value:structured_output,
    r:structured_output[0]:raw_message,
    r:structured_output
) AS decision_obj
```

Then assert in the verification query that `decision_obj:decision` is non-null for every row whose
`error` is null. If that count is non-zero, the accessor is wrong for this account, not the model.

### 21. No reasons, no decision

A JSON schema cannot require a non-empty array (`minItems` is unsupported). Enforce in SQL:
`ARRAY_SIZE(decision_obj:reasons) > 0`, and every reason names an attribute that was actually present
in the prompt. A model decision with no reasons is routed to the quality log and left in `REVIEW`.
Reasons are what a steward reads to accept or reject a merge; a bare MATCH is unauditable.

### 22. Measure and neutralize position bias

Models can favor the first-presented record or answer differently when A and B are swapped. Present
the two records in an order chosen by hash of the pair (not always `record_uid_a` first), and re-ask a
sample of `adjudicate.position_swap_sample` pairs in swapped order. Report the disagreement rate. A rate
materially above zero means decisions near the boundary are not stable, and the confidence threshold
for auto-accepting model matches should rise.

Do not include identifiers that encode the answer in the prompt — see rule 30.

### 23. The model decides identity, not hierarchy, unless asked

Ask for a `relationship` field (`SAME_ENTITY`, `PARENT_SUBSIDIARY`, `SIBLING_LOCATION`,
`PRODUCT_VARIANT`, `UNRELATED`, `UNSURE`) separately from the `decision`. Only `SAME_ENTITY` produces a
merge edge. The others are valuable — a parent/subsidiary link is exactly what a single customer view
for cross-sell wants — but they go to a relationship table, not into the golden record. Collapsing
"related" into "same" is the most common way this play over-merges.

## F. Clustering and survivorship

### 24. Transitive closure chains unrelated records together

Connected components over accepted edges means A–B and B–C put A and C in one cluster even if A and C
would never have been matched directly. One bad edge can bridge two large legitimate clusters into a
mega-cluster. Guards, all required:

- **Cannot-link check after clustering.** Any cluster containing two records with a cannot-link flag
  (different valid tax ids, different GTINs) is held, not published, and the weakest edge on the path
  between them is identified for review.
- **Size cap.** Clusters above `thresholds.max_cluster_size` are held for review. Real duplicate
  clusters in master data are small; a cluster of hundreds is almost always a chaining defect or a
  placeholder value acting as a key.
- **Cohesion check.** Report the minimum pairwise composite score among scored pairs inside each
  cluster; clusters below `thresholds.min_cluster_cohesion` are flagged.

Report the largest clusters by name at the gate. Reading the member names of the top five clusters
catches more defects than any metric.

### 25. Survivorship is deterministic SQL. Never ask a model to write the golden record.

A model asked to "produce the best version of these records" will normalize, guess, and occasionally
invent — a plausible street, a merged name that appears in no source. A golden attribute must be a
value that exists in a member record. Apply per-attribute rules in order (most trusted source, most
recent, most complete, most frequent non-null), and store for every attribute the `record_uid` it came
from and the rule that chose it.

### 26. Golden ids must be stable across runs

Re-clustering assigns new cluster numbers every run. If `golden_id` is the cluster number, every
downstream system that keyed on yesterday's golden ids is broken today. Persist an
`ER_GOLDEN_ID_REGISTRY`: on each run, a new cluster inherits the golden id of the prior cluster with which
it shares the most member records; ties and splits are recorded; only genuinely new clusters mint new
ids. Report counts of inherited, split, merged, and new golden ids per run.

### 27. Every source record appears in the crosswalk exactly once

Singletons (records with no match) are golden records too — of size one. A crosswalk that only contains
matched records makes the single customer view silently omit most customers. Assert
`COUNT(DISTINCT record_uid)` in the crosswalk equals the in-scope record count, and no `record_uid`
appears twice within a run.

## G. Evaluation

### 28. Pairwise recall is computed over all true pairs, not candidate pairs

Generate the full set of true duplicate pairs from the answer key and join outward from it. A harness
that evaluates only pairs that survived blocking cannot see blocking losses and reports recall on a
filtered population. Report recall at each stage — after blocking, after banding, after adjudication,
after clustering — so the stage that lost each pair is visible.

### 29. Report cluster metrics, including singletons, and pairwise metrics, by difficulty

Pairwise metrics are dominated by large clusters (a cluster of 5 has 10 pairs). B-cubed precision and
recall weight every record equally and include singletons. Report both. Then break both down by the
answer key's difficulty tier and case role — exact duplicates are trivially found and inflate every
headline number; the hard-negative and hard-positive slices are where the pipeline is actually tested.

### 30. The answer key is quarantined, and identifiers must not leak it

The answer key lives in `eval_schema` and is never joined by a pipeline query, never included in a
prompt, never embedded. In the sandbox, source record ids are random, not derived from the true entity
id — an id like `TE-000123-COPY2` would let both blocking and the model "match" on the id. When adapting
the sandbox, keep that property.

### 31. Calibrate thresholds on a split, and report on the other half

Tuning `auto_match` and `auto_reject` on the same labeled pairs that are then reported is overfitting
with extra steps. Split the labeled entities (by `true_entity_id`, not by pair) into calibration and
holdout halves, calibrate on one, report on the other.

## H. Cost, operations, and data protection

### 32. Instrument real usage

Use `show_details => TRUE` on adjudication to capture per-call `usage`, and reconcile run totals with
`SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY` (columns include `FUNCTION_NAME`,
`MODEL_NAME`, `QUERY_ID`, `TOKENS`, `TOKEN_CREDITS`). Report tokens and call counts; never convert to
dollars. `AI_COUNT_TOKENS` takes the function name first, lowercase: `('ai_embed', model, text)` or
`('ai_complete', model, text)`. It estimates input only, and structured-output schema overhead is billed
as input but may not be counted by the estimate — reconcile after the first real run.

### 33. Materialize every AI call as a table

A view over `AI_EMBED` or `AI_COMPLETE` re-invokes and re-bills inference every time anything selects
from it. Embeddings, scored pairs, and decisions are tables (or dbt `table` / `incremental` models).

### 34. Experiment tracking requires accumulation

Scored pairs, decisions, clusters, golden records, and evaluation rows carry `run_id` and
`experiment_id` and **accumulate**. If they are recreated each run, only one experiment exists at rest
and every comparison query returns a single run while appearing to work. Use `MERGE` keyed on `run_id`
(plain SQL) or `incremental` with `unique_key` including `run_id` (dbt).

### 35. Hash what actually ran

Persist `prompt_hash` computed from the assembled prompt text that was bound into the call, and
`embed_text_hash` for every embedded record. When `prompt_version` matches and `prompt_hash` differs,
trust the hash.

### 36. Bank, payment, and government-id fields never reach a model

Vendor masters carry bank account, IBAN, routing, and remittance fields. They are irrelevant to identity
and are the most sensitive fields in the table. They are in `excluded_from_ai` and never appear in
`embed_text` or a prompt. Tax ids are used for deterministic comparison in SQL; do not put raw tax ids in
prompts either — pass the comparison result (`tax_id: same`, `different`, `one missing`) instead, which
is all the model needs.

Report existing masking and row access policies on the sources at preflight. The golden table and
crosswalk concentrate PII from every source into one place — they need a deliberate access decision,
not an inherited default.

### 37. Never length-constrain model-written columns

`VARCHAR` without a length for reasons, explanations, and any model text. A verbose explanation that
exceeds a declared length fails the insert for the whole batch.

### 38. Orchestration

- No `TEMPORARY` tables shared between tasks; each task has its own session.
- Fully qualify every object in task bodies.
- Idempotent on `run_id`: task retry re-invokes the step, and a non-idempotent adjudication step
  double-bills and double-inserts.
- Incremental runs compare **new and changed** records against **all** existing records, not only
  against each other — a new record's duplicate is usually an old record.
