---
name: summarize-voc-themes
description: "Write theme summaries tied to products, SKUs, regions and periods with AI_SUMMARIZE_AGG and AI_AGG, and operationalize the voice-of-customer pipeline. Summaries run only over clean groups (included, deduplicated, redacted, minimum support), carry their item counts and SQL-computed metrics alongside, never contain numbers produced by the model, and are checked for support with an embedding-based citation check. Then builds the one-row-per-item enriched table, an incremental pipeline (streams and tasks for AI steps, dynamic tables for pure-SQL aggregates), a semantic view with governed metric definitions (mentions, net sentiment, negative share, excluding unknown), an optional Cortex Search service over redacted verbatims, and a Cortex Agent for CoWork users. Phase 7 of the voice-of-customer build."
parent_skill: voice-of-customer
---

# Summarize themes and operationalize

Counts say how much; summaries say what. A product manager reading "Product Quality negative share
up 3x on the Fold headphones in Europe" needs the next sentence: "customers report the fold hinge on
the left earcup cracking within weeks." This phase writes that sentence for every group with enough
feedback to justify one, and then puts the whole pipeline on a schedule behind a semantic view and an
agent.

## 1. The enriched table

One row per included item, with arrays of topics and aspects. It is the grain the semantic view and
the summaries read.

```sql
CREATE OR REPLACE TABLE VOC_FEEDBACK_ENRICHED AS
SELECT
    f.feedback_id, f.source_channel, f.source_system, f.created_at, f.week_start,
    f.sku, f.sku_source, f.product_line, f.region_code,
    f.star_rating, f.nps_score, f.original_language, f.was_translated,
    f.is_campaign, f.over_sentiment_window,
    f.text_for_ai                                     AS display_text,   -- redacted if the posture requires it
    t.topics_l1, t.topics_l2,
    o.sentiment                                       AS overall_sentiment,
    a.aspect_sentiments,
    ri.raw_response:value:labels[0]::STRING = 'Return intent' AS has_return_intent,
    :run_id AS run_id, :experiment_id AS experiment_id, :taxonomy_version AS taxonomy_version
FROM VOC_FEEDBACK_STG f
LEFT JOIN (
    SELECT feedback_id,
           ARRAY_AGG(DISTINCT topic_l1) AS topics_l1,
           ARRAY_AGG(DISTINCT topic_l1 || ' > ' || topic_l2) AS topics_l2
    FROM VOC_TOPICS WHERE experiment_id = :experiment_id
    GROUP BY 1) t ON t.feedback_id = f.feedback_id
LEFT JOIN VOC_ASPECT_SENTIMENT o
  ON o.feedback_id = f.feedback_id AND o.experiment_id = :experiment_id AND o.aspect = 'overall'
LEFT JOIN (
    SELECT feedback_id, OBJECT_AGG(aspect, sentiment::VARIANT) AS aspect_sentiments
    FROM VOC_ASPECT_SENTIMENT
    WHERE experiment_id = :experiment_id AND aspect <> 'overall'
    GROUP BY 1) a ON a.feedback_id = f.feedback_id
LEFT JOIN VOC_RETURN_INTENT ri
  ON ri.feedback_id = f.feedback_id AND ri.experiment_id = :experiment_id
WHERE f.is_included;
```

`ARRAY_AGG(DISTINCT ... || ' > ' || topic_l2)` drops L1-only rows because the concatenation is NULL;
that is intended, since `topics_l2` lists only resolved subtopics.

Also materialize the topic-grain table the semantic view uses (the `VOC_TOPIC_SENTIMENT` view from
Phase 5 joined to item attributes), as a table, so dashboard queries do not re-run joins over the raw
tables:

```sql
CREATE OR REPLACE TABLE VOC_TOPIC_FACTS AS
SELECT ts.feedback_id, ts.topic_l1, ts.topic_l2, ts.aspect_name, ts.topic_sentiment,
       e.week_start, e.sku, e.product_line, e.region_code, e.source_channel, e.is_campaign,
       t.lever, t.business_owner, ts.taxonomy_version, ts.experiment_id
FROM VOC_TOPIC_SENTIMENT ts
JOIN VOC_FEEDBACK_ENRICHED e ON e.feedback_id = ts.feedback_id
LEFT JOIN (SELECT DISTINCT taxonomy_version, topic_l1, topic_l2, lever, business_owner FROM VOC_TAXONOMY) t
  ON t.taxonomy_version = ts.taxonomy_version AND t.topic_l1 = ts.topic_l1
 AND EQUAL_NULL(t.topic_l2, ts.topic_l2)
WHERE ts.experiment_id = :experiment_id;
```

## 2. Theme summaries

### Which function

- **`AI_SUMMARIZE_AGG(expr)`**: a general-purpose summary of a group. Use it for broad digests ("what
  did customers say about this SKU this week").
- **`AI_AGG(expr, instruction)`**: a summary steered by a declarative instruction. Use it whenever the
  consumer and the question are known ("for the product engineering team, describe the specific
  failure modes customers report about Product Quality on this product").

Both handle groups larger than a model context window. Neither should be asked for numbers: the
counts are computed in SQL and stored next to the summary.

### Which groups

Summarise only groups with at least `summaries.min_items_per_summary` included items, built from
`VOC_FEEDBACK_ENRICHED` (so excluded, duplicate and spam items cannot leak in), and from
`display_text` (redacted when the posture requires). A summary over a handful of items is one
customer's opinion with a headline.

```sql
CREATE TABLE IF NOT EXISTS VOC_THEME_SUMMARIES (
    run_id            VARCHAR,
    experiment_id     VARCHAR,
    taxonomy_version  VARCHAR,
    period_start      DATE,
    period_grain      VARCHAR,
    sku               VARCHAR,
    region_code       VARCHAR,
    topic_l1          VARCHAR,
    sentiment_filter  VARCHAR,       -- NEGATIVE_OR_MIXED | POSITIVE | ALL
    item_count        INT,
    negative_share    FLOAT,         -- computed in SQL, never by the model
    example_ids       ARRAY,         -- a handful of ids, for drill-through
    summary_text      VARCHAR,       -- no length limit: model output
    function_used     VARCHAR,
    instruction       VARCHAR,
    summarized_at     TIMESTAMP_NTZ
);

INSERT INTO VOC_THEME_SUMMARIES
WITH grp AS (
    SELECT f.week_start AS period_start, f.sku, f.region_code, f.topic_l1,
           f.feedback_id, e.display_text, f.topic_sentiment
    FROM VOC_TOPIC_FACTS f
    JOIN VOC_FEEDBACK_ENRICHED e ON e.feedback_id = f.feedback_id
    WHERE f.experiment_id = :experiment_id
      AND f.topic_sentiment IN ('negative', 'mixed')
      AND f.week_start >= :summary_window_start
      AND f.week_start <  DATE_TRUNC('WEEK', CURRENT_DATE())
),
eligible AS (
    SELECT period_start, sku, region_code, topic_l1
    FROM grp
    GROUP BY 1, 2, 3, 4
    HAVING COUNT(DISTINCT feedback_id) >= :min_items_per_summary
)
SELECT :run_id, :experiment_id, :taxonomy_version, g.period_start, 'WEEK',
       g.sku, g.region_code, g.topic_l1, 'NEGATIVE_OR_MIXED',
       COUNT(DISTINCT g.feedback_id),
       NULL,                                                   -- filled from VOC_TOPIC_FACTS below
       ARRAY_SLICE(ARRAY_AGG(g.feedback_id) WITHIN GROUP (ORDER BY g.feedback_id), 0, 5),
       AI_AGG(g.display_text,
              'You are reading customer complaints about ' || g.topic_l1 || ' for one product in one region '
           || 'during one week. For the team that owns ' || g.topic_l1 || ', describe in at most four sentences '
           || 'the specific problems customers report, most frequent first. Use plain language. '
           || 'Do not include numbers, percentages, customer names, or quotes.'),
       'AI_AGG',
       'complaints-by-topic-v1',
       CURRENT_TIMESTAMP()
FROM grp g
JOIN eligible e
  ON e.period_start = g.period_start AND EQUAL_NULL(e.sku, g.sku)
 AND EQUAL_NULL(e.region_code, g.region_code) AND e.topic_l1 = g.topic_l1
GROUP BY g.period_start, g.sku, g.region_code, g.topic_l1;
```

The instruction is assembled from the group's own topic label. That is safe here because labels come
from the governed taxonomy; never concatenate free text from feedback into an instruction.

Then fill `negative_share` from SQL (negative or mixed topic mentions over included items for the
same SKU, region and week), so the number shown beside the summary is the governed metric.

For portfolio digests (all topics for one SKU and month), `AI_SUMMARIZE_AGG(display_text)` over the
same eligibility rule is enough. Record `function_used` so readers know which they are looking at.

### Cost

Summaries run once per eligible group per period, not per item, so they are cheap relative to
classification. Estimate the input with `AI_COUNT_TOKENS('ai_complete', <model>, <concatenated
group text>)` only as a rough floor; `AI_AGG` and `AI_SUMMARIZE_AGG` add their own prompting, and
the billed figure must be read back from `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` after the first run.
Say so rather than presenting the estimate as exact.

### Citation check

A summary sentence that no item supports is the failure that destroys trust. Check a sample:

```sql
-- Split summaries into sentences, embed each, and find the most similar
-- item in the same group. Low best-similarity sentences go to a human.
WITH sentences AS (
    SELECT s.run_id, s.period_start, s.sku, s.region_code, s.topic_l1,
           x.index AS sent_no, TRIM(x.value) AS sentence
    FROM VOC_THEME_SUMMARIES s,
         LATERAL SPLIT_TO_TABLE(REGEXP_REPLACE(s.summary_text, '([.!?])\\s+', '\\1\n'), '\n') x
    WHERE s.run_id = :run_id AND TRIM(x.value) <> ''
),
items AS (
    SELECT f.week_start, f.sku, f.region_code, f.topic_l1, f.feedback_id, emb.embedding
    FROM VOC_TOPIC_FACTS f
    JOIN VOC_EMBEDDINGS emb ON emb.feedback_id = f.feedback_id
    WHERE f.experiment_id = :experiment_id AND f.topic_sentiment IN ('negative', 'mixed')
)
SELECT s.period_start, s.sku, s.region_code, s.topic_l1, s.sent_no, s.sentence,
       MAX(VECTOR_COSINE_SIMILARITY(AI_EMBED(:embed_model, s.sentence), i.embedding)) AS best_support
FROM sentences s
JOIN items i
  ON i.week_start = s.period_start AND EQUAL_NULL(i.sku, s.sku)
 AND EQUAL_NULL(i.region_code, s.region_code) AND i.topic_l1 = s.topic_l1
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY best_support ASC
LIMIT 50;
```

`VOC_EMBEDDINGS` holds `AI_EMBED(<embed_model>, text_for_ai)` per included item (built in Phase 6 or
here). The embedding is computed once per sentence inside the aggregate; for large checks, embed the
sentences into a table first. Similarity is a screen, not a proof: a low score means "show a human",
and the human reads the example items. Report how many sentences were reviewed and how many were
unsupported.

### Personal data in summaries

If the posture is `outputs_only`, `display_text` must be redacted before it reaches `AI_AGG`. Even
with redaction, search the summaries for obvious leaks before sharing:

```sql
SELECT COUNT(*) AS suspicious
FROM VOC_THEME_SUMMARIES
WHERE run_id = :run_id
  AND REGEXP_LIKE(summary_text, '.*([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+|\\+?[0-9][0-9 ()-]{7,}[0-9]).*');
```

## 3. Incremental pipeline

### Plain SQL mode

Use a stream on each source table and a task graph. AI steps stay in tasks writing to tables,
because each step is incremental by its own `NOT EXISTS` filter and must log errors.

```sql
CREATE OR REPLACE STREAM VOC_SRC_REVIEWS_STREAM ON TABLE <reviews_table> APPEND_ONLY = TRUE;

CREATE OR REPLACE TASK VOC_T0_NORMALIZE
  WAREHOUSE = <warehouse>
  SCHEDULE = 'USING CRON 0 3 * * * UTC'
  WHEN SYSTEM$STREAM_HAS_DATA('VOC_SRC_REVIEWS_STREAM')
AS
  CALL VOC_NORMALIZE();       -- wraps the Phase 3 statements; derives run_id itself

CREATE OR REPLACE TASK VOC_T1_TOPICS     WAREHOUSE = <warehouse> AFTER VOC_T0_NORMALIZE AS CALL VOC_CLASSIFY_TOPICS();
CREATE OR REPLACE TASK VOC_T2_ASPECTS    WAREHOUSE = <warehouse> AFTER VOC_T0_NORMALIZE AS CALL VOC_ASPECT_SENTIMENT();
CREATE OR REPLACE TASK VOC_T3_ENRICH     WAREHOUSE = <warehouse> AFTER VOC_T1_TOPICS, VOC_T2_ASPECTS AS CALL VOC_BUILD_ENRICHED();
CREATE OR REPLACE TASK VOC_T4_THEMES     WAREHOUSE = <warehouse> AFTER VOC_T3_ENRICH AS CALL VOC_EMERGING_THEMES();
CREATE OR REPLACE TASK VOC_T5_SUMMARIES  WAREHOUSE = <warehouse> AFTER VOC_T3_ENRICH AS CALL VOC_THEME_SUMMARIES();
```

Rules for the task graph:

- The stream is consumed by the root task's DML; reading it in a `SELECT` without DML does not
  advance its offset. The normalize procedure must insert from the stream.
- Dedup still reads full history, not just the stream, so late syndicated copies collapse.
- Each procedure generates its own `run_id` from the task's scheduled time and stamps it on every row,
  so a task retry merges rather than duplicates.
- No `TEMPORARY` tables passed between tasks; fully qualify every object.
- Summaries should run weekly, after the week closes, not daily.
- Create tasks suspended, show the graph, and resume only after the user confirms.

Load the `snowflake-tasks` skill for task creation and monitoring details rather than improvising.

### Dynamic tables for the pure-SQL layers

`VOC_THEME_WEEKLY`, `VOC_THEME_WEEKLY_DENSE`, `VOC_THEME_SCORES` and `VOC_TOPIC_FACTS` contain no AI
calls and are natural dynamic tables with a target lag of a day. Keep every AI function out of
dynamic tables in this build: AI steps need explicit error logging, retry-on-error-only, and
per-experiment accumulation, which the task path provides. Load the `dynamic-tables` skill to create
them.

### dbt mode

See `DBT_MATERIALIZATION.md`; schedule `EXECUTE DBT PROJECT` from a task.

## 4. Semantic view

Governed definitions so every consumer, human or agent, computes "net sentiment" the same way.

```sql
CREATE OR REPLACE SEMANTIC VIEW VOC_SEMANTIC_VIEW
  TABLES (
    items  AS <db>.<schema>.VOC_FEEDBACK_ENRICHED PRIMARY KEY (feedback_id)
           WITH SYNONYMS = ('feedback', 'reviews', 'customer comments')
           COMMENT = 'One row per included, deduplicated customer feedback item.',
    topics AS <db>.<schema>.VOC_TOPIC_FACTS
           COMMENT = 'One row per feedback item and assigned taxonomy topic, with the topic''s aspect sentiment.',
    products AS <db>.<schema>.<product_dim> PRIMARY KEY (sku)
  )
  RELATIONSHIPS (
    topic_to_item    AS topics (feedback_id) REFERENCES items,
    item_to_product  AS items (sku) REFERENCES products
  )
  DIMENSIONS (
    items.week_start      AS items.week_start      COMMENT = 'Week the customer wrote the feedback.',
    items.source_channel  AS items.source_channel  WITH SYNONYMS = ('channel', 'source'),
    items.region_code     AS items.region_code     WITH SYNONYMS = ('region', 'market'),
    items.sku             AS items.sku,
    products.product_name AS products.<product_name_col> WITH SYNONYMS = ('product'),
    products.product_line AS products.<product_line_col>,
    topics.topic_l1       AS topics.topic_l1       WITH SYNONYMS = ('topic', 'theme', 'category'),
    topics.topic_l2       AS topics.topic_l2       WITH SYNONYMS = ('subtopic', 'issue'),
    topics.topic_sentiment AS topics.topic_sentiment
        COMMENT = 'Sentiment about this topic in this item: positive, negative, neutral, mixed, or unknown (not mentioned).',
    topics.business_owner AS topics.business_owner,
    topics.taxonomy_version AS topics.taxonomy_version
        COMMENT = 'Topic labels are only comparable within one taxonomy version.'
  )
  METRICS (
    items.feedback_items AS COUNT(DISTINCT items.feedback_id)
        COMMENT = 'Included, deduplicated feedback items.',
    topics.topic_mentions AS COUNT(DISTINCT IFF(topics.topic_sentiment <> 'unknown', topics.feedback_id, NULL))
        COMMENT = 'Items that mention the topic. Unknown sentiment means not mentioned and is excluded.',
    topics.negative_mentions AS COUNT(DISTINCT IFF(topics.topic_sentiment IN ('negative', 'mixed'), topics.feedback_id, NULL))
        COMMENT = 'Items with a complaint about the topic. Mixed counts as containing a complaint.',
    topics.net_sentiment AS
        (COUNT(DISTINCT IFF(topics.topic_sentiment = 'positive', topics.feedback_id, NULL))
       - COUNT(DISTINCT IFF(topics.topic_sentiment = 'negative', topics.feedback_id, NULL)))
       / NULLIF(COUNT(DISTINCT IFF(topics.topic_sentiment <> 'unknown', topics.feedback_id, NULL)), 0)
        COMMENT = 'Positive minus negative, over items that mention the topic. Range -1 to 1.',
    items.return_intent_items AS COUNT(DISTINCT IFF(items.has_return_intent, items.feedback_id, NULL))
        COMMENT = 'Items where the customer returned or plans to return the product.'
  )
  COMMENT = 'Voice of customer: topics, aspect sentiment and return intent over deduplicated customer feedback.'
  AI_SQL_GENERATION 'Always filter topics to a single taxonomy_version. Never use star rating as sentiment. Exclude unknown sentiment from sentiment metrics. For trends, group by week_start and exclude the current incomplete week.';
```

Load the `agent-studio` skill to validate the semantic view, add verified queries (for example,
"negative mentions of Product Quality by week for one SKU and region"), and test it with Cortex
Analyst. Do not expose `author_key`, original text, or any author identifier in the view.

## 5. Optional: search over verbatims

When users need to read what customers actually said, a Cortex Search service over **redacted**
`display_text` lets the agent retrieve quotes:

```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE VOC_VERBATIM_SEARCH
  ON display_text
  ATTRIBUTES sku, region_code, source_channel, week_start
  WAREHOUSE = <warehouse>
  TARGET_LAG = '1 day'
  AS (
    SELECT feedback_id, display_text, sku, region_code, source_channel, week_start
    FROM <db>.<schema>.VOC_FEEDBACK_ENRICHED
  );
```

Grant usage on it only to roles that may read verbatims (preflight section 9).

## 6. Cortex Agent

```sql
CREATE OR REPLACE AGENT VOC_AGENT
  COMMENT = 'Voice of customer analyst'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto
  instructions:
    response: "Answer with numbers from the semantic view first, then explain with theme summaries or customer quotes. State the taxonomy version and date range of every number. Never quote a customer name or handle."
    orchestration: "Use VoCAnalyst for counts, trends and sentiment. Use VoCVerbatims only to show example customer quotes after the numbers are established."
    sample_questions:
      - question: "Which product topics had the biggest rise in complaints in the last four weeks?"
      - question: "What are customers saying about delivery in the UK?"
      - question: "Show net sentiment by topic for the Fold headphones."
  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "VoCAnalyst"
        description: "Counts, trends and sentiment over customer feedback topics by product, SKU, region, channel and week."
    - tool_spec:
        type: "cortex_search"
        name: "VoCVerbatims"
        description: "Retrieves redacted customer feedback text to illustrate a theme."
  tool_resources:
    VoCAnalyst:
      semantic_view: "<db>.<schema>.VOC_SEMANTIC_VIEW"
    VoCVerbatims:
      search_service: "<db>.<schema>.VOC_VERBATIM_SEARCH"
      max_results: "5"
      id_column: "feedback_id"
  $$;
```

Load the `agent-studio` skill to configure the analyst tool's execution warehouse, evaluate the agent
on the sample questions, and publish it to CoWork. Theme summaries can be exposed as a further table
in the semantic view so the agent can cite them, with `item_count` beside every summary.

## Verification before declaring the phase done

1. `VOC_FEEDBACK_ENRICHED` row count equals included items in `VOC_FEEDBACK_STG`.
2. Summaries written, groups skipped below minimum support, and the citation check result.
3. The PII leak check returns zero.
4. Task graph shown (suspended until confirmed) or dbt project deployed.
5. Semantic view answers three sample questions with numbers that match direct SQL on
   `VOC_TOPIC_FACTS`.
6. The agent answers the sample questions with a number and a cited version and date range.

On the sandbox, the hinge summary for `SYN-SKU-HP-200` in `SYN-EU` should name the folding hinge and
the earcup; the citation check should find supporting items for every sentence of it.

Then `phases.summarize: done`, objects recorded.
