# Diagnosing a VoC pipeline that is not producing what you expect

Work these in order. The first three are the most common and all of them look the same from a
dashboard: theme counts that are plausible and wrong.

## 1. NULLs read as "no topic" or "neutral": check this first

**Symptom:** topic coverage lower than expected, sentiment skewed toward neutral, or a known item has
no labels.

`AI_CLASSIFY` and `AI_SENTIMENT` return `NULL` on a per-row failure and let the query finish. If the
pipeline was built without `return_error_details => TRUE`, a failure is indistinguishable from an
item with no topic, and a downstream `COALESCE(sentiment, 'neutral')` turns errors into neutral
sentiment that then dilutes every average.

```sql
SELECT stage,
       COUNT(*)                         AS calls,
       COUNT_IF(error_message IS NOT NULL) AS errors,
       ROUND(100.0 * COUNT_IF(error_message IS NOT NULL) / NULLIF(COUNT(*), 0), 2) AS pct_error,
       ANY_VALUE(error_message)         AS sample_error
FROM <voc_quality_log>
WHERE run_id = '<run_id>'
GROUP BY 1;
```

Then search the output for silent coercion:

```sql
-- Any COALESCE to 'neutral' or to an empty array in the pipeline SQL is a bug.
-- In the data, count sentiment rows whose raw response was NULL.
SELECT COUNT(*) AS coerced
FROM <voc_aspect_sentiment>
WHERE raw_response IS NULL AND sentiment IS NOT NULL;
```

Common causes, by error text:

- **Context window exceeded** on `AI_SENTIMENT`: the item exceeds 2,048 tokens. Segment it (see
  `extract-aspect-sentiment`, "Over-window items"), do not truncate silently.
- **Unsupported language** on `AI_SENTIMENT`: the item was not translated, or the source reported the
  wrong language. Check `normalize-voc-feedback` language resolution.
- **Too many aspects**: more than 10 aspects in one call. Batch them.
- **Aspect name too long**: an aspect over 30 characters.

## 2. Everything lands in one topic, or in Other Feedback

**Symptom:** one L1 dominates, or the Other Feedback share is far above
`taxonomy.other_rate_threshold`.

```sql
SELECT topic_l1, COUNT(DISTINCT feedback_id) AS items,
       ROUND(100.0 * COUNT(DISTINCT feedback_id)
             / SUM(COUNT(DISTINCT feedback_id)) OVER (), 1) AS pct
FROM <voc_topics>
WHERE run_id = '<run_id>' AND level = 'L1'
GROUP BY 1 ORDER BY 2 DESC;
```

Look for, in order:

- **Label descriptions that overlap.** If two L1 descriptions could both describe the same sentence,
  the classifier picks one consistently and the other starves. Read the descriptions side by side;
  rewrite so each says what distinguishes it.
- **A catch-all with an attractive description.** "Other Feedback" described as "anything about the
  product" absorbs everything. It must be described as the last resort.
- **Taxonomy drift.** A genuinely new subject the taxonomy has no node for lands in Other. Run
  `detect-emerging-themes` out-of-taxonomy clustering on the Other bucket before rewriting labels.
- **Single-label mode on multi-topic text.** With `output_mode` left at `single`, a review about
  delivery and quality gets one label, so recall on the second topic is zero. Use `multi`.

## 3. Counts are doubled, or a theme spikes overnight

**Symptom:** a theme's weekly count jumps with no corresponding operational change, or totals exceed
the source row count after dedup.

```sql
-- Same text, same author, multiple systems: syndication that survived dedup.
SELECT author_key, text_hash, COUNT(*) AS copies, COUNT(DISTINCT source_system) AS systems
FROM <voc_feedback_stg>
GROUP BY 1, 2 HAVING COUNT(*) > 1
ORDER BY copies DESC LIMIT 20;

-- Same text, many authors, short window: a bot or copy-paste campaign.
SELECT text_hash, COUNT(DISTINCT author_key) AS authors,
       MIN(created_at) AS first_seen, MAX(created_at) AS last_seen
FROM <voc_feedback_stg>
GROUP BY 1
HAVING COUNT(DISTINCT author_key) >= 3
   AND DATEDIFF(HOUR, MIN(created_at), MAX(created_at)) < 48
ORDER BY authors DESC LIMIT 20;
```

Syndicated copies should have been collapsed to one canonical item. Copy-paste campaigns should be
gated as spam if off-topic, and flagged (not deleted) if on-topic, since coordinated complaints are
still a signal but must not be counted as independent customers. Short identical genuine texts from
different authors ("Great product, fast shipping") are **not** duplicates; a text-only dedup key
deletes them.

Also check for a **taxonomy version change** on the spike date. If the classification for that week
ran on a different `taxonomy_version`, the series is not comparable across the boundary until it is
rolled up through `VOC_TAXONOMY_MAP`.

## 4. Sentiment looks wrong on specific items

**Symptom:** a reviewer disputes the sentiment on a sample.

- **Sarcasm and negation.** "Love waiting three weeks" and "not bad at all" are known hard cases.
  Check the sandbox hard-case scores in `evaluate-voc-accuracy` before concluding the model is
  broken; if the hard cases pass and production fails, the production text has a pattern the
  sandbox does not.
- **Star rating used as truth.** A 5-star review that says the product disconnects constantly has
  negative product sentiment. If anyone is "validating" sentiment against stars, the validation is
  wrong, not the model.
- **`unknown` read as neutral.** `unknown` means the aspect was not mentioned. It must be excluded
  from aspect averages, not counted as zero.
- **`mixed` dropped.** `mixed` is a real polarity: the aspect was praised and criticised in the same
  item. Mapping it to neutral loses the most actionable reviews.
- **Translated text.** Sentiment on a translation can soften intensifiers. Compare on a sample of
  original-language items if the customer's corpus is materially non-English.

## 5. An emerging theme was missed, or fired on noise

**Symptom:** the business saw an issue the detector did not, or the detector flags weekly noise.

```sql
SELECT week_start, mentions, baseline_mean, baseline_stddev, z_score, is_candidate
FROM <voc_theme_weekly>
WHERE topic_l2 = '<theme>' AND sku = '<sku>' AND region_code = '<region>'
ORDER BY week_start;
```

- **Missed, and the series is flat:** the theme is classified into a broad L2 alongside unrelated
  complaints, so its growth is diluted. This is the out-of-taxonomy case: it shows up in the
  novelty clusters, not in the topic series. Check `VOC_OUT_OF_TAXONOMY_CLUSTERS`.
- **Missed, and the series rises but never crosses the threshold:** the grain is too coarse
  (aggregating all regions hides a one-region issue) or `min_weekly_mentions` is too high for a
  low-volume SKU.
- **Fires on noise:** baseline stddev near zero on a low-volume series makes any single mention a
  large z-score. The detector must require both the z threshold and the minimum mentions, and use a
  stddev floor.

## 6. A summary says something the feedback does not

**Symptom:** a reviewer cannot find support for a sentence in a theme summary.

- **Summary over too few items.** Below `summaries.min_items_per_summary`, one vivid review dominates.
  The skill skips those groups; confirm it did.
- **Summary over an unfiltered group.** Spam or off-topic items in the group leak into the summary.
  Check the group was built from gated, deduplicated items.
- **Generic instruction.** `AI_SUMMARIZE_AGG` produces a general-purpose summary. When the business
  question is specific ("what do customers say about the hinge"), use `AI_AGG` with an instruction
  that names the product, the topic, and the audience.
- Run the citation check in `summarize-voc-themes` on that summary.

## 7. Cost is higher than expected

```sql
-- Did gating and dedup remove rows before the AI calls?
SELECT exclusion_reason, COUNT(*) AS rows
FROM <voc_feedback_stg>
GROUP BY 1 ORDER BY 2 DESC;

-- Billed usage by function for one run. The usage view has no timestamp or
-- query tag, so filter through QUERY_HISTORY on the run's QUERY_TAG.
-- Usage can take a few hours to appear.
SELECT u.function_name, u.model_name, SUM(u.tokens) AS tokens, SUM(u.token_credits) AS credits
FROM snowflake.account_usage.cortex_functions_query_usage_history u
JOIN snowflake.account_usage.query_history q ON q.query_id = u.query_id
WHERE q.query_tag = 'voc:<run_id>'
GROUP BY 1, 2 ORDER BY 3 DESC;
```

Usual causes: classification re-running over the full history because the incremental filter is
missing; a view (not a table) wrapping an AI call so every downstream query re-bills it; long label
descriptions and many few-shot examples multiplied across every row; L2 classification run against
all L2 labels instead of only the children of the assigned L1.
