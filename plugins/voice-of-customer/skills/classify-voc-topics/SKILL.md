---
name: classify-voc-topics
description: "Classify every included feedback item against the governed, versioned VoC taxonomy with AI_CLASSIFY. Two-level, multi-label: L1 against the bound L1 category list with descriptions, task description and few-shot examples, then L2 only against the children of each assigned L1. Persists the raw OBJECT with return_error_details, flattens to one row per assigned topic, stamps taxonomy_version, run_id, experiment_id and a config_hash of the exact categories bound, logs every error, runs incrementally, and derives a return-intent flag with a described binary AI_CLASSIFY. Explains why AI_CLASSIFY returns no confidence score and how to build a review queue from disagreement signals instead. Includes an AI_COMPLETE structured-output fallback for accounts without AI_CLASSIFY. Phase 4 of the voice-of-customer build."
parent_skill: voice-of-customer
---

# Classify topics

The output of this phase is the spine of every dashboard: which topics each customer raised, under
which taxonomy version. Two properties matter more than anything else: every label comes from the
governed taxonomy, and every unlabeled item is explained.

## Before running

1. `taxonomy.active_version` is set and the taxonomy contract checks are zero.
2. `experiment.run_id`, `experiment_id`, `experiment_name` and `prompt_version` are set.
3. Estimate with the real call shape, on a sample, projected to the included row count:

```sql
WITH s AS (
    SELECT text_for_ai FROM VOC_FEEDBACK_STG WHERE is_included SAMPLE (500 ROWS)
),
cfg AS (
    SELECT c.categories,
           OBJECT_CONSTRUCT('task_description', :l1_task_description,
                            'output_mode', 'multi',
                            'examples', e.examples) AS config
    FROM VOC_TAXONOMY_L1_CATEGORIES c
    LEFT JOIN VOC_TAXONOMY_EXAMPLES_CFG e
      ON e.taxonomy_version = c.taxonomy_version AND e.level = 'L1'
    WHERE c.taxonomy_version = :taxonomy_version
)
SELECT AVG(AI_COUNT_TOKENS('ai_classify', s.text_for_ai, cfg.categories, cfg.config)) AS avg_l1_tokens,
       (SELECT COUNT(*) FROM VOC_FEEDBACK_STG WHERE is_included)                       AS included_items
FROM s CROSS JOIN cfg;
```

L2 adds roughly one more call per assigned L1 with a shorter category list; estimate it the same way
against `VOC_TAXONOMY_L2_CATEGORIES`. Present tokens, and say the estimate covers input only.

## The task description

At most 50 words. It is the one place to state the rules the labels cannot:

> Assign every topic this customer feedback discusses. A text can have several topics. Judge what the
> customer means, including sarcasm. Use Other Feedback only when no other topic applies.

Keep the text identical across runs unless `prompt_version` is bumped; it is part of `config_hash`.

## L1: multi-label against the bound list

```sql
CREATE TABLE IF NOT EXISTS VOC_TOPICS_RAW (
    run_id            VARCHAR,
    experiment_id     VARCHAR,
    prompt_version    VARCHAR,
    taxonomy_version  VARCHAR,
    config_hash       VARCHAR,
    feedback_id       VARCHAR,
    level             VARCHAR,       -- L1 | L2
    parent_l1         VARCHAR,       -- set for L2 calls
    raw_response      VARIANT,       -- full OBJECT with value and error
    classified_at     TIMESTAMP_NTZ
);

INSERT INTO VOC_TOPICS_RAW
WITH cfg AS (
    SELECT c.taxonomy_version, c.categories,
           OBJECT_CONSTRUCT('task_description', :l1_task_description,
                            'output_mode', 'multi',
                            'examples', e.examples) AS config
    FROM VOC_TAXONOMY_L1_CATEGORIES c
    LEFT JOIN VOC_TAXONOMY_EXAMPLES_CFG e
      ON e.taxonomy_version = c.taxonomy_version AND e.level = 'L1'
    WHERE c.taxonomy_version = :taxonomy_version
)
SELECT :run_id, :experiment_id, :prompt_version, cfg.taxonomy_version,
       SHA2(TO_JSON(OBJECT_CONSTRUCT('categories', cfg.categories, 'config', cfg.config)), 256),
       f.feedback_id, 'L1', NULL,
       AI_CLASSIFY(f.text_for_ai, cfg.categories, cfg.config, TRUE),
       CURRENT_TIMESTAMP()
FROM VOC_FEEDBACK_STG f
CROSS JOIN cfg
WHERE f.is_included
  -- Incremental: skip items already classified successfully under this
  -- experiment and taxonomy version; retry the ones that errored.
  AND NOT EXISTS (
      SELECT 1 FROM VOC_TOPICS_RAW r
      WHERE r.feedback_id = f.feedback_id
        AND r.experiment_id = :experiment_id
        AND r.taxonomy_version = :taxonomy_version
        AND r.level = 'L1'
        AND r.raw_response:error IS NULL);
```

If an earlier attempt errored and the retry succeeds, both rows exist. Downstream reads the latest
successful row per item, level and parent (see "Flatten").

`config_hash` covers the categories (with descriptions), the task description and the examples, so a
reworded description without a version bump is still visible.

## L2: only the children of each assigned L1

```sql
INSERT INTO VOC_TOPICS_RAW
WITH l1 AS (
    SELECT r.feedback_id, lbl.value::STRING AS topic_l1
    FROM VOC_TOPICS_RAW r,
         LATERAL FLATTEN(input => r.raw_response:value:labels) lbl
    WHERE r.experiment_id = :experiment_id
      AND r.taxonomy_version = :taxonomy_version
      AND r.level = 'L1'
      AND r.raw_response:error IS NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY r.feedback_id, lbl.value::STRING
                               ORDER BY r.classified_at DESC) = 1
),
cfg AS (
    SELECT c.taxonomy_version, c.topic_l1, c.categories,
           OBJECT_CONSTRUCT('task_description',
                            'Assign every subtopic of ' || c.topic_l1 || ' this customer feedback discusses.',
                            'output_mode', 'multi',
                            'examples', COALESCE(e.examples, ARRAY_CONSTRUCT())) AS config
    FROM VOC_TAXONOMY_L2_CATEGORIES c
    LEFT JOIN VOC_TAXONOMY_EXAMPLES_CFG e
      ON e.taxonomy_version = c.taxonomy_version AND e.level = 'L2' AND e.parent_l1 = c.topic_l1
    WHERE c.taxonomy_version = :taxonomy_version
      AND c.n_categories >= 2               -- AI_CLASSIFY needs at least two categories
)
SELECT :run_id, :experiment_id, :prompt_version, cfg.taxonomy_version,
       SHA2(TO_JSON(OBJECT_CONSTRUCT('categories', cfg.categories, 'config', cfg.config)), 256),
       l1.feedback_id, 'L2', l1.topic_l1,
       AI_CLASSIFY(f.text_for_ai, cfg.categories, cfg.config, TRUE),
       CURRENT_TIMESTAMP()
FROM l1
JOIN cfg ON cfg.topic_l1 = l1.topic_l1
JOIN VOC_FEEDBACK_STG f ON f.feedback_id = l1.feedback_id
WHERE NOT EXISTS (
    SELECT 1 FROM VOC_TOPICS_RAW r
    WHERE r.feedback_id = l1.feedback_id
      AND r.experiment_id = :experiment_id
      AND r.taxonomy_version = :taxonomy_version
      AND r.level = 'L2' AND r.parent_l1 = l1.topic_l1
      AND r.raw_response:error IS NULL);
```

An empty `examples` array: if `AI_CLASSIFY` rejects an empty array on this account, build the config
without the `examples` key when there are none (`OBJECT_DELETE(config, 'examples')`). Test once on
the first L1 without examples.

Other Feedback has a single child and is skipped at L2 by the `n_categories >= 2` filter; its items
carry L1 only, which is correct.

## Flatten to one row per assigned topic

```sql
CREATE OR REPLACE TABLE VOC_TOPICS AS
WITH latest AS (
    SELECT *
    FROM VOC_TOPICS_RAW
    WHERE raw_response:error IS NULL
    QUALIFY ROW_NUMBER() OVER (
        PARTITION BY experiment_id, taxonomy_version, feedback_id, level, COALESCE(parent_l1, '')
        ORDER BY classified_at DESC) = 1
),
l1 AS (
    SELECT l.run_id, l.experiment_id, l.prompt_version, l.taxonomy_version, l.config_hash,
           l.feedback_id, x.value::STRING AS topic_l1
    FROM latest l, LATERAL FLATTEN(input => l.raw_response:value:labels) x
    WHERE l.level = 'L1'
),
l2 AS (
    SELECT l.experiment_id, l.taxonomy_version, l.feedback_id, l.parent_l1 AS topic_l1,
           x.value::STRING AS topic_l2
    FROM latest l, LATERAL FLATTEN(input => l.raw_response:value:labels) x
    WHERE l.level = 'L2'
)
SELECT l1.run_id, l1.experiment_id, l1.prompt_version, l1.taxonomy_version, l1.config_hash,
       l1.feedback_id, l1.topic_l1, l2.topic_l2,
       t.aspect_name, t.lever, t.business_owner
FROM l1
LEFT JOIN l2
  ON l2.experiment_id = l1.experiment_id
 AND l2.taxonomy_version = l1.taxonomy_version
 AND l2.feedback_id = l1.feedback_id
 AND l2.topic_l1 = l1.topic_l1
LEFT JOIN (SELECT DISTINCT taxonomy_version, topic_l1, topic_l2, aspect_name, lever, business_owner
           FROM VOC_TAXONOMY) t
  ON t.taxonomy_version = l1.taxonomy_version
 AND t.topic_l1 = l1.topic_l1
 AND t.topic_l2 = COALESCE(l2.topic_l2, t.topic_l2)
QUALIFY ROW_NUMBER() OVER (PARTITION BY l1.experiment_id, l1.taxonomy_version, l1.feedback_id,
                                        l1.topic_l1, COALESCE(l2.topic_l2, '')
                           ORDER BY t.topic_l2) = 1;
```

The last join attaches `aspect_name` and `lever` from the taxonomy row; for an L1-only row it takes
the L1's aspect (constant across its children by design). A topic label that does not join to the
taxonomy indicates the wrong `taxonomy_version` was joined, and the dbt test
`assert_topics_are_in_taxonomy` catches it.

An item with an L1 but no L2 is kept with `topic_l2` NULL. That is an honest "the subtopic is
unclear", and the per-L1 rate is a taxonomy-fit signal.

## Log every error and every empty result

```sql
INSERT INTO VOC_QUALITY_LOG (run_id, stage, feedback_id, error_message, logged_at)
SELECT run_id, 'topics_' || LOWER(level), feedback_id, raw_response:error::STRING, CURRENT_TIMESTAMP()
FROM VOC_TOPICS_RAW
WHERE run_id = :run_id AND raw_response:error IS NOT NULL;
```

Also count items that classified successfully with an **empty** L1 label array. In multi-label mode
that means the classifier assigned nothing. It is not an error and not Other Feedback; report it as
its own number.

## Derived flag: return intent

Returns are an OpEx lever, so the play flags feedback where the customer says they returned, are
returning, or are considering returning the item. Use a described binary classification, never a
keyword match:

```sql
CREATE OR REPLACE TABLE VOC_RETURN_INTENT AS
SELECT :run_id AS run_id, :experiment_id AS experiment_id, f.feedback_id,
       AI_CLASSIFY(f.text_for_ai,
           [{'label': 'Return intent',
             'description': 'The customer has returned, is returning, or is considering returning or exchanging this item.'},
            {'label': 'No return intent',
             'description': 'No return or exchange of this item is mentioned or considered.'}],
           {'task_description': 'Does the customer say they returned or plan to return this purchase?'},
           TRUE) AS raw_response
FROM VOC_FEEDBACK_STG f
WHERE f.is_included;
```

Measure it against the labeled return-intent cases before it feeds any returns figure. Limit it to
review and survey channels if social posts produce false positives on this account.

## There is no confidence score, and do not invent one

`AI_CLASSIFY` returns labels, not probabilities. Do not ask a generative model to "rate your
confidence" and present that as calibrated. If the business needs a review queue, build it from
signals that are actually informative:

| Signal | Meaning |
|---|---|
| L1 assigned, L2 empty | subtopic unclear, often a taxonomy gap |
| topic assigned, its aspect `unknown` in `AI_SENTIMENT` | the two functions disagree about what the item is about |
| Other Feedback | taxonomy gap |
| item was translated | known lower-accuracy slice |
| item is over the sentiment window | segmented sentiment |
| test-retest disagreement on a re-run sample | unstable item |

Measure how often each signal coincides with an error on the labeled set; route only the signals
that predict errors.

## Fallback: AI_COMPLETE with a schema

Only when `AI_CLASSIFY` is unavailable. Constrain the output to the taxonomy with an `enum` built from
the bound category list, `temperature: 0`, and `response_format`:

```sql
AI_COMPLETE(
    model => :fallback_model,
    prompt => 'Assign every topic this customer feedback discusses, from the allowed list only. '
           || 'Topics: ' || :l1_label_descriptions_text || ' Feedback: ' || f.text_for_ai,
    model_parameters => {'temperature': 0},
    response_format => {
        'type': 'json',
        'schema': {
            'type': 'object',
            'properties': {
                'topics': {'type': 'array',
                           'items': {'type': 'string', 'enum': :l1_label_array}}
            },
            'required': ['topics']
        }
    },
    show_details => TRUE)
```

Building the `response_format` from a bound array may require constructing the statement text, since
the argument may need to be a constant; test on this account. The fallback is a different system:
re-run the full evaluation on it and report it as a separate experiment.

## Verification before declaring the phase done

```sql
-- 1. Coverage and the Other Feedback rate.
SELECT
    COUNT(DISTINCT f.feedback_id)                                         AS included,
    COUNT(DISTINCT t.feedback_id)                                         AS with_any_l1,
    COUNT(DISTINCT IFF(t.topic_l1 = 'Other Feedback', t.feedback_id, NULL)) AS in_other,
    ROUND(COUNT(DISTINCT IFF(t.topic_l1 = 'Other Feedback', t.feedback_id, NULL))
          / NULLIF(COUNT(DISTINCT f.feedback_id), 0), 3)                  AS other_rate
FROM VOC_FEEDBACK_STG f
LEFT JOIN VOC_TOPICS t
  ON t.feedback_id = f.feedback_id AND t.experiment_id = :experiment_id
WHERE f.is_included;

-- 2. Errors.
SELECT stage, COUNT(*) FROM VOC_QUALITY_LOG
WHERE run_id = :run_id AND stage LIKE 'topics_%' GROUP BY 1;

-- 3. Distribution, and L2 coverage per L1.
SELECT topic_l1,
       COUNT(DISTINCT feedback_id) AS items,
       ROUND(COUNT_IF(topic_l2 IS NULL) / COUNT(*), 3) AS l2_missing_rate
FROM VOC_TOPICS
WHERE experiment_id = :experiment_id
GROUP BY 1 ORDER BY 2 DESC;

-- 4. Multi-label actually happening.
SELECT n_topics, COUNT(*) AS items FROM (
    SELECT feedback_id, COUNT(DISTINCT topic_l1) AS n_topics
    FROM VOC_TOPICS WHERE experiment_id = :experiment_id GROUP BY 1)
GROUP BY 1 ORDER BY 1;
```

If check 4 shows every item with exactly one topic, the call is running in single-label mode.

Then `phases.topics: done`, objects recorded. Do not quote accuracy from this phase; that is Phase 8.
