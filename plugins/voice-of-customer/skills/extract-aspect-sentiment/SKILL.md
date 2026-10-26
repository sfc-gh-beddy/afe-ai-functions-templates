---
name: extract-aspect-sentiment
description: "Score aspect-level sentiment for every included feedback item with AI_SENTIMENT, using the taxonomy's aspect list (at most 10 aspects, each at most 30 characters, bound from VOC_TAXONOMY_ASPECTS). Persists the raw OBJECT with return_error_details, flattens to one row per item and aspect including overall, segments items over the 2,048-token window on sentence boundaries and merges per-aspect results with explicit rules, keeps unknown, neutral and mixed distinct, attributes sentiment to a topic through its aspect rather than the item's overall sentiment, measures topic and aspect disagreement, and never uses star ratings as truth. Phase 5 of the voice-of-customer build."
parent_skill: voice-of-customer
---

# Extract aspect-level sentiment

Topic tells you what the customer talked about. Aspect sentiment tells you which way. The one-line
summary of this phase: **the sentiment of a topic on an item is the sentiment of that topic's aspect,
not the sentiment of the item.**

## Facts about AI_SENTIMENT this phase is built on

From the function reference:

- `AI_SENTIMENT(<text> [, <categories>] [, <return_error_details>])`.
- Up to **10** categories (aspects), each up to **30** characters.
- Returns an OBJECT with a `categories` array of `{name, sentiment}`; the `overall` record is always
  included.
- Sentiment values: `positive`, `negative`, `neutral`, `mixed`, `unknown` (not mentioned).
- Optimised for **2,048 tokens**; longer inputs return an error.
- Languages: English, French, German, Hindi, Italian, Spanish, Portuguese.
- `AI_COUNT_TOKENS('ai_sentiment', text)` is exact for the default model.

Aspect names get no description. The name is all the function sees, so the taxonomy's aspect names
must read as plain topics.

## Before running

```sql
-- Aspect list for the pinned version. Must be 1..10 entries.
SELECT aspects, n_aspects FROM VOC_TAXONOMY_ASPECTS WHERE taxonomy_version = :taxonomy_version;

-- Input token estimate (exact for the default model).
SELECT COUNT(*)                                   AS items,
       SUM(IFF(over_sentiment_window, 0, sentiment_tokens)) AS in_window_tokens,
       COUNT_IF(over_sentiment_window)            AS over_window_items,
       SUM(IFF(over_sentiment_window, sentiment_tokens, 0)) AS over_window_tokens
FROM VOC_FEEDBACK_STG
WHERE is_included;
```

The aspect names add a small, fixed amount per call; estimate one call with
`AI_COUNT_TOKENS('ai_sentiment', <sample text>, <aspects>)` if the account's version of
`AI_COUNT_TOKENS` accepts the categories argument for `ai_sentiment`, otherwise state that the
per-call aspect overhead is not included.

## In-window items

```sql
CREATE TABLE IF NOT EXISTS VOC_SENTIMENT_RAW (
    run_id            VARCHAR,
    experiment_id     VARCHAR,
    taxonomy_version  VARCHAR,
    feedback_id       VARCHAR,
    segment_no        INT,          -- 0 for unsegmented items
    segment_count     INT,
    aspects_bound     ARRAY,
    raw_response      VARIANT,
    scored_at         TIMESTAMP_NTZ
);

INSERT INTO VOC_SENTIMENT_RAW
SELECT :run_id, :experiment_id, a.taxonomy_version, f.feedback_id, 0, 1, a.aspects,
       AI_SENTIMENT(f.text_for_ai, a.aspects, TRUE),
       CURRENT_TIMESTAMP()
FROM VOC_FEEDBACK_STG f
CROSS JOIN (SELECT taxonomy_version, aspects FROM VOC_TAXONOMY_ASPECTS
            WHERE taxonomy_version = :taxonomy_version) a
WHERE f.is_included
  AND NOT f.over_sentiment_window
  AND NOT EXISTS (
      SELECT 1 FROM VOC_SENTIMENT_RAW r
      WHERE r.feedback_id = f.feedback_id
        AND r.experiment_id = :experiment_id
        AND r.taxonomy_version = :taxonomy_version
        AND r.raw_response:error IS NULL);
```

## Over-window items: segment, never truncate

Split on sentence boundaries and pack sentences greedily into chunks that stay under the window with
headroom for the aspect names. Character length is used to pack, then every chunk is measured with
the exact counter before it is scored.

```sql
CREATE OR REPLACE TABLE VOC_SENTIMENT_SEGMENTS AS
WITH sentences AS (
    SELECT f.feedback_id, s.index AS sent_no, TRIM(s.value) AS sentence
    FROM VOC_FEEDBACK_STG f,
         LATERAL SPLIT_TO_TABLE(REGEXP_REPLACE(f.text_for_ai, '([.!?])\\s+', '\\1\n'), '\n') s
    WHERE f.is_included AND f.over_sentiment_window AND TRIM(s.value) <> ''
),
packed AS (
    -- About 4 characters per token for English; 6,000 characters stays well
    -- under 2,048 tokens. The exact check below is what is trusted.
    SELECT feedback_id, sent_no, sentence,
           FLOOR(SUM(LENGTH(sentence) + 1) OVER (PARTITION BY feedback_id ORDER BY sent_no
                                                 ROWS UNBOUNDED PRECEDING) / 6000) AS segment_no
    FROM sentences
)
SELECT feedback_id, segment_no + 1 AS segment_no,
       LISTAGG(sentence, ' ') WITHIN GROUP (ORDER BY sent_no) AS segment_text
FROM packed
GROUP BY feedback_id, segment_no;

-- Every segment must fit. A single sentence longer than the window (no
-- punctuation, pasted logs) will not; split those on whitespace instead.
SELECT feedback_id, segment_no, AI_COUNT_TOKENS('ai_sentiment', segment_text) AS tokens
FROM VOC_SENTIMENT_SEGMENTS
WHERE AI_COUNT_TOKENS('ai_sentiment', segment_text) > 1900;
-- Expect 0 rows before scoring.
```

Then score each segment the same way as in-window items, with `segment_no` and `segment_count` set.

## Flatten and merge

```sql
CREATE OR REPLACE TABLE VOC_ASPECT_SENTIMENT AS
WITH latest AS (
    SELECT *
    FROM VOC_SENTIMENT_RAW
    WHERE raw_response:error IS NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY experiment_id, taxonomy_version, feedback_id, segment_no
                               ORDER BY scored_at DESC) = 1
),
flat AS (
    SELECT l.run_id, l.experiment_id, l.taxonomy_version, l.feedback_id, l.segment_no,
           MAX(l.segment_count) OVER (PARTITION BY l.experiment_id, l.feedback_id) AS segment_count,
           c.value:name::STRING      AS aspect,
           c.value:sentiment::STRING AS sentiment
    FROM latest l, LATERAL FLATTEN(input => l.raw_response:value:categories) c
)
SELECT run_id, experiment_id, taxonomy_version, feedback_id, aspect,
       -- Merge rules (voc-best-practices rule 9). For unsegmented items this
       -- returns the single segment's value unchanged.
       CASE
           WHEN COUNT_IF(sentiment = 'mixed') > 0
             OR (COUNT_IF(sentiment = 'positive') > 0 AND COUNT_IF(sentiment = 'negative') > 0) THEN 'mixed'
           WHEN COUNT_IF(sentiment = 'positive') > 0 THEN 'positive'
           WHEN COUNT_IF(sentiment = 'negative') > 0 THEN 'negative'
           WHEN COUNT_IF(sentiment = 'neutral')  > 0 THEN 'neutral'
           ELSE 'unknown'
       END                                 AS sentiment,
       MAX(segment_count) > 1              AS was_segmented,
       MAX(segment_count)                  AS segment_count,
       ARRAY_AGG(sentiment) WITHIN GROUP (ORDER BY segment_no) AS segment_sentiments
FROM flat
GROUP BY run_id, experiment_id, taxonomy_version, feedback_id, aspect;
```

Rows are produced for every bound aspect plus `overall`. Keep `unknown` rows: they are how detection
is measured, and dropping them makes "not mentioned" indistinguishable from "not scored".

**Merging `overall` across segments** with the same rule is a simplification: a long survey answer
that is mostly negative with one positive sentence becomes `mixed`. That is defensible and visible
(`segment_sentiments` is kept), but say so when presenting overall sentiment for long items.

Log errors exactly as in Phase 4, with stage `aspect_sentiment`.

## Topic sentiment: through the aspect

```sql
CREATE OR REPLACE VIEW VOC_TOPIC_SENTIMENT AS
SELECT t.experiment_id, t.taxonomy_version, t.feedback_id,
       t.topic_l1, t.topic_l2, t.aspect_name,
       a.sentiment AS topic_sentiment,
       o.sentiment AS item_overall_sentiment
FROM VOC_TOPICS t
LEFT JOIN VOC_ASPECT_SENTIMENT a
  ON a.experiment_id = t.experiment_id
 AND a.feedback_id = t.feedback_id
 AND a.aspect = t.aspect_name
LEFT JOIN VOC_ASPECT_SENTIMENT o
  ON o.experiment_id = t.experiment_id
 AND o.feedback_id = t.feedback_id
 AND o.aspect = 'overall';
```

`item_overall_sentiment` is carried for context. Every metric that says "sentiment about Shipping"
uses `topic_sentiment`.

## Disagreement between topic and aspect

A topic assigned by `AI_CLASSIFY` whose aspect comes back `unknown` from `AI_SENTIMENT` means the two
functions disagree about whether the item is about that topic. It is expected occasionally and a
problem when common:

```sql
SELECT topic_l1,
       COUNT(*)                                        AS topic_assignments,
       COUNT_IF(topic_sentiment = 'unknown')           AS aspect_unknown,
       ROUND(COUNT_IF(topic_sentiment = 'unknown') / NULLIF(COUNT(*), 0), 3) AS disagreement_rate
FROM VOC_TOPIC_SENTIMENT
WHERE experiment_id = :experiment_id
GROUP BY 1 ORDER BY 4 DESC;
```

High disagreement on one L1 usually means its aspect name does not read as the same concept as its
taxonomy description ("Website and App" as an aspect versus a description about product page
accuracy). Fix the aspect name or the description, bump `prompt_version`, re-run, and compare.

The reverse also happens: an aspect scored non-`unknown` where no matching topic was assigned. That
is a topic recall signal and the evaluation harness reports it.

## Aggregation rules for anything downstream

These are the definitions the semantic view uses; do not redefine them in a dashboard:

- **Mentions** of an aspect: items where its sentiment is not `unknown`.
- **Net sentiment**: (positive minus negative) divided by mentions. `mixed` and `neutral` count in the
  denominator only.
- **Negative share**: (negative plus mixed) divided by mentions, for "how many customers had a
  complaint about this", since a mixed item contains a complaint.
- Never average a numeric mapping of the five labels. There is no defensible number for `mixed`.
- Never use star rating or NPS as a sentiment label. They can be shown alongside, and their
  correlation with net sentiment is a reasonable sanity check in aggregate, not per item.

## Fallback when AI_SENTIMENT is unavailable or a language is unsupported

Items in unsupported languages should have been translated in Phase 3. If `AI_SENTIMENT` itself is
unavailable, an `AI_COMPLETE` call with a `response_format` schema can return the same structure
(an array of `{aspect, sentiment}` with `sentiment` an `enum` of the five values, every bound aspect
`required`). It is more expensive per item, it is a different system, and it must be evaluated as a
separate experiment. Do not mix fallback rows with `AI_SENTIMENT` rows in one experiment.

## Verification before declaring the phase done

```sql
-- 1. Every included item has an overall row; errors are logged, not missing.
SELECT
    (SELECT COUNT(*) FROM VOC_FEEDBACK_STG WHERE is_included)                        AS included,
    (SELECT COUNT(DISTINCT feedback_id) FROM VOC_ASPECT_SENTIMENT
      WHERE experiment_id = :experiment_id AND aspect = 'overall')                   AS scored,
    (SELECT COUNT(*) FROM VOC_QUALITY_LOG
      WHERE run_id = :run_id AND stage = 'aspect_sentiment')                         AS errors;
-- included = scored + errors (+ items still pending retry). Anything else is a leak.

-- 2. Distribution per aspect, with unknown.
SELECT aspect, sentiment, COUNT(*) AS n
FROM VOC_ASPECT_SENTIMENT WHERE experiment_id = :experiment_id
GROUP BY 1, 2 ORDER BY 1, 3 DESC;

-- 3. No call ever bound more than ten aspects.
SELECT COUNT(*) FROM VOC_SENTIMENT_RAW WHERE ARRAY_SIZE(aspects_bound) > 10;
-- Expect 0.

-- 4. Segmented items.
SELECT COUNT(DISTINCT feedback_id) AS segmented_items, MAX(segment_count) AS max_segments
FROM VOC_ASPECT_SENTIMENT WHERE experiment_id = :experiment_id AND was_segmented;

-- 5. Disagreement table above.
```

On the sandbox: the over-window survey answer is segmented and comes back negative on Returns and
Refunds; the "powerful but the lid cracked" item is `mixed` on Product Quality; the "great fit, slow
delivery" item is positive on Fit and Sizing and negative on Shipping and Delivery; the five-star
review that complains about disconnects is negative on Product Quality.

Then `phases.aspects: done`, objects recorded.
