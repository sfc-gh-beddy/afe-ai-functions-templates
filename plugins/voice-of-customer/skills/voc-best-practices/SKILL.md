---
name: voc-best-practices
description: "Correctness rules every voice-of-customer pipeline must follow. Always loaded by the voice-of-customer router. Catches silent failure modes where SQL runs clean, row counts look reasonable, and theme counts are wrong: AI_CLASSIFY and AI_SENTIMENT per-row NULLs read as no topic or neutral, return_error_details unwrapping, governed category lists bound from a versioned taxonomy, the 20-category accuracy ceiling and two-level classification, multi-label mode, label description and task length limits, few-shot leakage into evaluation, AI_SENTIMENT 10-aspect and 30-character limits and the 2,048-token window, unknown versus neutral versus mixed, attributing item-level sentiment to every topic, star ratings as false ground truth, translation before classification, dedup scope (syndication versus template collision versus campaigns), relevance gating, taxonomy version stamping and drift roll-ups, trend math (share not counts, stddev floors, multiple comparisons, incomplete weeks), AI_SUMMARIZE_AGG minimum support and leakage, SKU linking without fabrication, materializing AI outputs, cost estimation with descriptions and examples included, PII, and accuracy-harness measurement bugs."
parent_skill: voice-of-customer
---

# Voice of Customer: correctness rules

Every rule here has a failure mode where the SQL succeeds, the dashboard renders, and the numbers
are wrong. Apply them to every artifact this plugin generates. Rules marked **[verified in docs]**
are stated in the Snowflake function reference; rules marked **[design rule]** are this plugin's
discipline.

---

## A. Calling the functions

### 1. A NULL is an error until proven otherwise [verified in docs]

`AI_CLASSIFY` and `AI_SENTIMENT` return `NULL` when they cannot process an input, and a multi-row
query completes anyway. Without error details, a failed row is indistinguishable from an item with no
topic, and a later `COALESCE(sentiment, 'neutral')` converts every failure into neutral sentiment that
dilutes every average.

**The rule:** pass `return_error_details => TRUE` (the last positional argument) on every call over a
table. The function then returns an OBJECT with `value` and `error`, one of which is NULL. Store the
whole OBJECT as `raw_response VARIANT`, derive results from `raw_response:value`, and write every
non-NULL `raw_response:error` to `VOC_QUALITY_LOG`.

```sql
-- Topic call: the raw OBJECT is persisted, results are derived from it.
SELECT feedback_id,
       AI_CLASSIFY(text_for_ai, :l1_categories, :l1_config, TRUE) AS raw_response
FROM VOC_FEEDBACK_STG
WHERE is_included;

-- Derivation. labels is an ARRAY under value.
SELECT feedback_id,
       raw_response:value:labels::ARRAY AS labels_l1,
       raw_response:error::STRING       AS error_message
FROM <topics_raw>;
```

Never `COALESCE` an AI result to a default. An empty array means "classified, no labels"; `NULL`
means "not classified". Keep them distinct all the way to the dashboard.

### 2. Check the return type once, on this account, before writing derivations [design rule]

The `AI_CLASSIFY` reference describes the return as "a serialized object". On the accounts this
plugin was built against it is an OBJECT, but do not assume. On the first sample run:

```sql
SELECT TYPEOF(AI_CLASSIFY('test', ['a','b'], {}, TRUE)) AS t;
```

If it is `VARCHAR` rather than `OBJECT`, wrap with `PARSE_JSON(TO_VARCHAR(...))`. That wrapper works
either way, and is the safe form for a pipeline that will be deployed to more than one account.

### 3. Bind the category list from the taxonomy table; never inline it [design rule]

A category array typed into a SQL file drifts from the governed taxonomy the first time someone
edits one. Bind categories from `VOC_TAXONOMY_L1_CATEGORIES` / `VOC_TAXONOMY_L2_CATEGORIES` for the
pinned `taxonomy_version`, and persist a `config_hash` of the exact array, task description and
examples used:

```sql
SELECT SHA2(TO_JSON(OBJECT_CONSTRUCT('categories', c.categories,
                                     'task', :task_description,
                                     'examples', e.examples)), 256) AS config_hash
FROM VOC_TAXONOMY_L1_CATEGORIES c
LEFT JOIN VOC_TAXONOMY_EXAMPLES_CFG e
  ON e.taxonomy_version = c.taxonomy_version AND e.level = 'L1'
WHERE c.taxonomy_version = :taxonomy_version;
```

Labels and input text are **case sensitive** [verified in docs]. "Product quality" and "Product
Quality" are different labels, and a join from results back to the taxonomy on the wrong case
silently drops rows.

### 4. Stay well under twenty categories per call; classify in two levels [verified in docs]

The reference states that more than about twenty categories may reduce accuracy, and every label and
description adds input tokens to every row. A flat taxonomy of 60 L2 nodes in one call is both less
accurate and more expensive than two calls of eight to twelve.

**The rule:** classify L1 first (multi-label), then classify L2 **only against the children of each
assigned L1**. Never run L2 against the full L2 list. The `build-voc-taxonomy` contract checks enforce
the list sizes.

### 5. Use multi-label mode for feedback [verified in docs]

`output_mode` defaults to `'single'`. Feedback routinely discusses several topics ("arrived late and
the zipper broke"). Single-label mode returns exactly one label, so recall on every secondary topic is
zero and the dashboard under-reports whichever topic tends to be mentioned second. Use
`{'output_mode': 'multi'}` at L1. At L2, use multi as well: one item can name two children of one
parent ("powerful but the lid cracked").

### 6. Keep descriptions and the task short, distinct, and within limits [verified in docs]

- Label `description` is at most 25 words; `task_description` at most 50 words.
- Descriptions should say **what distinguishes** a label from its siblings, not restate the label.
- Every description and example is billed as input tokens on **every** call.
- Avoid abbreviations, codes and jargon in labels ("RMA", "DOA", "WISMO"). Write "Defective on
  Arrival", "Where Is My Order".

### 7. Few-shot examples must never overlap the evaluation set [design rule]

An example whose text is in the labeled set measures the prompt's memory, not the classifier.
`VOC_TAXONOMY_EXAMPLES` is authored separately from the sandbox fragments and from any customer
labeled sample. `evaluate-voc-accuracy` checks for overlap by normalised text and fails the run if it
finds any.

### 8. AI_SENTIMENT limits are hard limits [verified in docs]

- At most **10 aspects** per call, each at most **30 characters**.
- Optimised for **2,048 tokens**; longer inputs **return an error** (so a `NULL` under rule 1).
- Supported languages: English, French, German, Hindi, Italian, Spanish, Portuguese.
- The `overall` category is always returned in addition to the requested aspects.

More than ten aspects means batching the aspect list across calls and merging, which doubles cost:
design the aspect list to fit in one call. Aspects get **no description**: the aspect name is the
only guidance the function receives, so "Price and Value" is better than "Value".

### 9. Over-window items are segmented, never silently truncated [design rule]

`LEFT(text, 6000)` keeps the start of a long survey answer and drops the rest, which is often where
the specific complaint is. Segment on paragraph or sentence boundaries into chunks under the window
(measured with `AI_COUNT_TOKENS('ai_sentiment', chunk)`, which is exact for the default model), run
`AI_SENTIMENT` per chunk, and merge per aspect:

| Chunk results for one aspect | Merged |
|---|---|
| all `unknown` | `unknown` |
| some `positive`, no `negative` (ignoring unknown, neutral) | `positive` |
| some `negative`, no `positive` | `negative` |
| any `mixed`, or both `positive` and `negative` | `mixed` |
| only `neutral` and `unknown` | `neutral` |

Record `was_segmented` and `segment_count` on the row. `AI_CLASSIFY` has a larger window; classify
the full text unless it also errors.

## B. Interpreting results

### 10. `unknown` is not neutral, and `mixed` is not neutral [verified in docs]

`unknown` means the aspect was not mentioned. `neutral` means mentioned without polarity. `mixed`
means praised and criticised in the same item. Three common bugs:

- Counting `unknown` as zero in an average, which drags every aspect toward neutral in proportion to
  how rarely it is mentioned.
- Mapping `mixed` to neutral, which discards the reviews with the most specific feedback.
- Mapping `mixed` to both a positive and a negative, which double-counts the item.

Net sentiment for an aspect is computed only over items where the aspect was mentioned:

```sql
SELECT aspect,
       COUNT_IF(sentiment <> 'unknown')                                        AS mentions,
       COUNT_IF(sentiment = 'positive')                                        AS pos,
       COUNT_IF(sentiment = 'negative')                                        AS neg,
       COUNT_IF(sentiment = 'mixed')                                           AS mixed,
       ROUND((COUNT_IF(sentiment = 'positive') - COUNT_IF(sentiment = 'negative'))
             / NULLIF(COUNT_IF(sentiment <> 'unknown'), 0), 3)                AS net_sentiment
FROM VOC_ASPECT_SENTIMENT
WHERE run_id = :run_id AND sentiment IS NOT NULL
GROUP BY aspect;
```

### 11. Topic sentiment comes from the aspect, not from the item [design rule]

"Fast delivery, but the motor burned out" is negative overall, negative on Product Quality, and
positive on Shipping. Joining item-level `overall` sentiment onto every topic the item carries makes
Shipping look negative. Each taxonomy node carries an `aspect_name`; the sentiment for a topic on an
item is that aspect's sentiment from `AI_SENTIMENT`, never the overall.

Where the topic was assigned but its aspect came back `unknown`, the two functions disagree. Report
the disagreement rate; do not paper over it by substituting overall sentiment.

### 12. Star ratings and NPS are context, never sentiment truth [design rule]

Customers give five stars for the delivery driver and complain about the product in the text. Ratings
are useful context and a weak sanity check in aggregate. They are never the label a sentiment model
is scored against, and a "validation" of `AI_SENTIMENT` against stars measures the disagreement
between stars and text, not model accuracy.

### 13. Derived flags use the same discipline [design rule]

Return intent ("sending these back") and similar flags are binary `AI_CLASSIFY` calls with two
explicit, described labels, never a keyword match. "Returned to the store to buy a second one" is not
return intent. Measure the flag against labeled cases before it drives a returns figure.

## C. Preparing the input

### 14. Translate before classifying, and keep the original [design rule]

`AI_CLASSIFY` is optimised for English; `AI_SENTIMENT` errors outside its supported languages. The
source's reported language is often missing or wrong. Resolve the language per item, translate
non-English text with `AI_TRANSLATE(text, '', 'en', TRUE)` (empty source auto-detects), and keep
`original_text`, `original_language` and `text_for_ai` as separate columns. Evaluate translated
items as their own slice: an aggregate that is good on English and poor on translated text is a
multilingual-market blind spot.

### 15. Dedup scope is author plus text, not text alone [design rule]

Three cases look alike and need different handling:

| Case | Signature | Handling |
|---|---|---|
| Syndication | same author, same text, different `source_system` | collapse to one canonical item |
| Template collision | same short text, different authors ("Great product, fast shipping") | keep all: they are different customers |
| Campaign or bot | same text, many authors, short time window | spam-gate if off-topic; if on-topic, keep one and flag `is_campaign` so it is not counted as independent customers |

A text-only `MD5(text)` key deletes real customers in the second case. An id-only key double-counts
the first. The normalised text for hashing is `LOWER(REGEXP_REPLACE(TRIM(text), '\\s+', ' '))`.

### 16. Gate relevance before classification [design rule]

Spam, store-hours questions, and empty strings classified against a product taxonomy land somewhere,
usually in whichever topic their vocabulary resembles, and they inflate it. Gate first with a binary
`AI_CLASSIFY` (or `AI_FILTER`) and record `exclusion_reason`. Keep two different "none" outcomes
distinct:

- **Not feedback** (spam, off-topic, pre-sales question): excluded before classification.
- **Other Feedback**: genuine feedback the taxonomy does not cover. This is the drift signal and must
  be measured, not excluded.

### 17. Redact before text leaves the item [design rule]

If `normalize.redact_pii` is true, run `AI_REDACT` in normalize and build `text_for_ai` from the
redacted text, so classification, embeddings and summaries never see raw personal data. Summaries are
the highest-risk output: one vivid review with a name in it can become the headline sentence.

### 18. Link SKUs by constrained choice, never by generation [design rule]

When the source carries no SKU (social, survey), resolve it from text with `AI_CLASSIFY` over the
**product names of candidate SKUs**, constrained by product line or brand where known, with an
explicit "No specific product" label. Never ask `AI_COMPLETE` to "extract the SKU": it will produce a
plausible SKU that does not exist. Validate every linked SKU against the product dimension and record
`sku_source` (`source`, `linked`, `unresolved`).

## D. Taxonomy versions and drift

### 19. Every result row carries its taxonomy version [design rule]

Topic labels are only comparable within a version. After a split, "Durability" under v2 excludes hinge
failures that "Durability" under v1 included; plotting both on one line shows a fake drop. Stamp
`taxonomy_version` on every row, and never union results across versions without rolling up through
`VOC_TAXONOMY_MAP`.

### 20. Roll up to the coarser version to compare [design rule]

| Relation | Old to new | New to old | For a continuous trend line |
|---|---|---|---|
| SAME | exact | exact | use either |
| RENAME | exact | exact | relabel old to new |
| SPLIT | ambiguous | exact | roll new children **up** to the old parent |
| MERGE | exact | ambiguous | roll old nodes **up** to the new node |
| RETIRE | none | n/a | end the series; do not re-home history by guess |

Never re-assign historical items to a split child by inference from the parent label. If history must
be re-expressed in the new version, re-classify it (that is a new experiment, with a cost estimate).

### 21. The Other Feedback rate is the drift alarm [design rule]

A rising share of genuine feedback in Other Feedback, or a rising share of L1 assignments with no
confident L2, means the taxonomy no longer fits. Track it weekly; when it exceeds
`taxonomy.other_rate_threshold`, run out-of-taxonomy clustering and take the proposals to the
taxonomy owner. New nodes are a governed change (a new version), not an edit in place.

### 22. Model-proposed theme names are proposals [design rule]

`AI_COMPLETE` may name a cluster of out-of-taxonomy feedback. The name is a suggestion for a human
owner, carried with its cluster size and example ids. It never becomes a taxonomy node without a
version bump, and the pipeline never classifies against an unreviewed label.

## E. Time series and emerging themes

### 23. Trend on share, not raw counts [design rule]

Feedback volume moves with sales, promotions and survey sends. A theme whose count doubles because
total volume doubled is not emerging. Compute the theme's share of deduplicated, included feedback for
the same grain and week, and test the share against its baseline. Report the count alongside.

### 24. Floor the baseline variance and require minimum support [design rule]

A low-volume series with a baseline standard deviation near zero turns one mention into an enormous
z-score. Use `GREATEST(baseline_stddev, <floor>)` and require `mentions >= emerging.min_weekly_mentions`
as well as the z threshold.

### 25. Many series means false alarms; say how many to expect [design rule]

Testing hundreds of topic by SKU by region series every week at a fixed threshold produces false
positives by construction. Report the number of series tested alongside the number of candidates, and
prefer persistence (two consecutive weeks over threshold) for anything that pages a human.

### 26. Bucket by when the customer wrote, and mark the incomplete week [design rule]

Use the feedback `created_at`, not ingestion time, or a backfill looks like a spike. The current
week is incomplete and late-arriving feedback makes it look low; exclude it from detection or flag it
`is_partial_week`.

## F. Summaries

### 27. Summaries need minimum support and a clean group [design rule]

`AI_SUMMARIZE_AGG` and `AI_AGG` handle inputs larger than a model context window [verified in docs],
which makes it easy to summarise a group of four items or a group full of spam. Summarise only groups
with at least `summaries.min_items_per_summary` included, deduplicated, redacted items. Store each
summary with its `item_count`, group keys, period, `taxonomy_version` and `run_id`.

### 28. Use AI_AGG when the question is specific [verified in docs]

`AI_SUMMARIZE_AGG` produces a general-purpose summary. When the consumer is a product manager asking
what customers say about one defect, use `AI_AGG` with a declarative instruction that names the
product, the topic, and the audience, as the reference recommends. Never ask the summary to produce
numbers: counts come from SQL and are shown next to the summary, not inside it.

### 29. A summary is not evidence [design rule]

A summary is a reading aid. Any claim that drives a decision is backed by the counts and by example
item ids pulled in SQL, displayed alongside. `summarize-voc-themes` includes a citation check that
samples summary sentences and verifies supporting items exist.

## G. Pipeline mechanics

### 30. Materialize every AI output [design rule]

A view that wraps an AI function re-invokes and re-bills it on every downstream select, and returns
different text each time for generative functions. AI outputs land in tables; views sit on top.

### 31. Incremental on new items, accumulating across experiments [design rule]

Classify only items not yet classified under the current `experiment_id` and `taxonomy_version`, and
retry only rows whose stored `raw_response:error` is non-NULL. A missing incremental filter
re-classifies the full history every run.

### 32. Estimate cost with the real call shape [verified in docs]

`AI_COUNT_TOKENS('ai_classify', text, categories, config)` accepts the categories and the config
object, so the estimate includes descriptions and examples; estimate with the actual bound arrays, not
with the text alone. `AI_COUNT_TOKENS('ai_sentiment', text)` is exact for the default model. The
function name is lowercase and starts with `ai_`. Report tokens, call input-only figures a floor where
output also bills, and reconcile against
`SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY` after the first real run. Never convert
to currency.

That view carries `QUERY_ID`, `FUNCTION_NAME`, `MODEL_NAME`, `TOKENS`, `TOKEN_CREDITS` and
`WAREHOUSE_ID`, and **no timestamp** [verified in docs]. A filter on a start time against it does not
exist; attribute usage to a run by setting `ALTER SESSION SET QUERY_TAG = 'voc:<run_id>'` before the
run and joining to `ACCOUNT_USAGE.QUERY_HISTORY` on `query_id`. Usage can take a few hours to appear,
so a cost readout run immediately after the pipeline under-reports.

### 33. Orchestration [design rule]

- No `TEMPORARY` tables shared between tasks; each task runs in its own session.
- Fully qualify every object a task reads or writes.
- Make each step idempotent on `run_id`; task retries re-run the whole step.
- Never length-constrain a `VARCHAR` that holds model output (summaries, proposals, errors).

### 34. Re-running the same item can change the answer [design rule]

Managed-model functions are not guaranteed bit-for-bit repeatable across time, and Snowflake can
update the underlying model. Measure test-retest agreement on a fixed sample of a few hundred items at
build time and after any announced model update, and report it with the accuracy figures.

## H. Measuring accuracy

### 35. Join from ground truth with a full outer join [design rule]

Build evaluation from labels outward. An item the pipeline excluded, errored on, or returned nothing
for must count as false negatives for every label it carries. A `LEFT JOIN` from predictions to
labels makes total failure look like perfect recall on the survivors.

### 36. Score multi-label as sets; report micro and macro [design rule]

Per item, compare the predicted label set to the true label set. Micro pools all label decisions;
macro averages per class so rare topics count. A pipeline that is excellent on Product Quality and
poor on Packaging shows strong micro and weak macro, and the rare topics are often the expensive
ones.

### 37. Score L2 only where L2 is labeled, and only under the correct parent [design rule]

Some truths are L1-only ("Great product"). Score those at L1 and exclude them from L2 metrics rather
than counting any L2 prediction as wrong. An L2 prediction under the wrong L1 is wrong at both levels.

### 38. Separate aspect detection from aspect polarity [design rule]

"Was the aspect mentioned" (`unknown` versus anything else) and "was the polarity right" (given it was
mentioned) fail for different reasons and are fixed differently. Report both, plus the full 5x5
confusion matrix including `unknown` and `mixed`.

### 39. Hold the truth to the taxonomy version the run used [design rule]

A run on v2 scored against v1 labels marks every correct "Hinge Breakage" as wrong. The answer key is
keyed by `taxonomy_version`; the harness joins on it.

### 40. Synthetic accuracy is an upper bound [design rule]

The sandbox is composed from clean, single-topic fragments plus a set of hard cases. Real feedback is
noisier, longer and more ambiguous. Present sandbox accuracy as what the pipeline achieves on known
cases, and require a labeled sample of the customer's own feedback before any accuracy figure is used
in a business case.
