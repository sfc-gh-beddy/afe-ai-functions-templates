---
name: detect-emerging-themes
description: "Detect emerging customer themes over time, including themes the taxonomy does not yet contain. Builds weekly topic series by SKU, region and channel on deduplicated, included feedback, tests theme share (not raw counts) against a rolling baseline with a variance floor, minimum mentions, persistence and multiple-comparison accounting, excludes the incomplete current week, and rolls series across taxonomy versions through the version map. Zooms into rising or Other Feedback slices to discover specific sub-themes with AI_COMPLETE structured output grounded in supplied item ids, counts and dates them with AI_CLASSIFY, checks novelty against taxonomy nodes with AI_EMBED similarity, and emits governed proposals for the taxonomy owner with onset week, concentration and example ids. Optionally joins themes to returns and support-contact outcomes. Phase 6 of the voice-of-customer build."
parent_skill: voice-of-customer
---

# Detect emerging themes

The most valuable output of a VoC program is usually not the steady-state topic mix. It is the week
a new problem starts, on one product in one market, before it shows up in returns or churn. This
phase finds two kinds of emergence:

1. **A known topic rising**: an existing taxonomy node's share grows beyond its baseline for some
   SKU, region or channel.
2. **A new subject appearing**: something the taxonomy has no node for, hiding inside a broad node
   or in Other Feedback.

The sandbox plants one of each kind of difficulty. The hinge theme rises inside Product Quality >
Durability on one SKU in one region; at the Durability level across the whole portfolio it is
diluted. The subscription theme rises inside Price and Value > Too Expensive on social only. Neither
has its own v1 node.

## Inputs

- `VOC_FEEDBACK_STG` (included rows only), `VOC_TOPICS`, `VOC_TOPIC_SENTIMENT`.
- Parameters from `emerging` in `voc-project.yml`. Present them at the gate as starting points, and
  show what changes when they move; they are not universal constants.

## 1. Weekly series on share

```sql
CREATE OR REPLACE TABLE VOC_THEME_WEEKLY AS
WITH base AS (
    SELECT f.feedback_id, f.week_start, f.source_channel,
           COALESCE(f.sku, 'UNRESOLVED') AS sku,
           COALESCE(f.region_code, 'UNKNOWN') AS region_code,
           f.is_campaign
    FROM VOC_FEEDBACK_STG f
    WHERE f.is_included
      -- Exclude the incomplete current week: late-arriving feedback makes it
      -- look low, and a detector reading it fires on the previous week's drop.
      AND f.week_start < DATE_TRUNC('WEEK', CURRENT_DATE())
),
topic_items AS (
    SELECT b.*, ts.topic_l1, COALESCE(ts.topic_l2, '(L1 only)') AS topic_l2,
           ts.topic_sentiment
    FROM base b
    JOIN VOC_TOPIC_SENTIMENT ts
      ON ts.feedback_id = b.feedback_id AND ts.experiment_id = :experiment_id
),
denominators AS (
    -- Total included items per slice and week, at every grouping the series uses.
    SELECT week_start, sku, region_code, source_channel,
           GROUPING_ID(sku, region_code, source_channel) AS gid,
           COUNT(DISTINCT feedback_id) AS total_items
    FROM base
    GROUP BY GROUPING SETS (
        (week_start, sku, region_code, source_channel),
        (week_start, sku, region_code),
        (week_start, sku),
        (week_start, region_code),
        (week_start, source_channel),
        (week_start))
),
numerators AS (
    SELECT week_start, topic_l1, topic_l2, sku, region_code, source_channel,
           GROUPING_ID(sku, region_code, source_channel) AS gid,
           COUNT(DISTINCT feedback_id)                                           AS mentions,
           COUNT(DISTINCT IFF(topic_sentiment IN ('negative', 'mixed'), feedback_id, NULL)) AS negative_mentions,
           -- Campaign members count once per campaign, not once per author.
           COUNT(DISTINCT IFF(is_campaign, NULL, feedback_id))
             + IFF(COUNT_IF(is_campaign) > 0, 1, 0)                              AS independent_mentions
    FROM topic_items
    GROUP BY GROUPING SETS (
        (week_start, topic_l1, topic_l2, sku, region_code, source_channel),
        (week_start, topic_l1, topic_l2, sku, region_code),
        (week_start, topic_l1, topic_l2, sku),
        (week_start, topic_l1, topic_l2, region_code),
        (week_start, topic_l1, topic_l2, source_channel),
        (week_start, topic_l1, topic_l2))
)
SELECT n.*, d.total_items,
       n.negative_mentions / NULLIF(d.total_items, 0) AS negative_share,
       :experiment_id   AS experiment_id,
       :taxonomy_version AS taxonomy_version
FROM numerators n
JOIN denominators d
  ON d.week_start = n.week_start AND d.gid = n.gid
 AND EQUAL_NULL(d.sku, n.sku)
 AND EQUAL_NULL(d.region_code, n.region_code)
 AND EQUAL_NULL(d.source_channel, n.source_channel);
```

`EQUAL_NULL` on the join: at a coarser grouping the rolled-up dimension is `NULL` on both sides, and
a plain `=` drops exactly those rows.

Weeks with zero mentions for a series are absent from this table. The baseline must treat them as
zeros, not skip them, or a rare theme's baseline is computed only over the weeks it appeared and
looks permanently high. Densify before scoring:

```sql
CREATE OR REPLACE TABLE VOC_THEME_WEEKLY_DENSE AS
WITH series AS (
    SELECT DISTINCT topic_l1, topic_l2, sku, region_code, source_channel, gid FROM VOC_THEME_WEEKLY
),
weeks AS (
    SELECT DISTINCT week_start, sku, region_code, source_channel, gid, total_items
    FROM (SELECT week_start, sku, region_code, source_channel, gid, total_items FROM VOC_THEME_WEEKLY)
)
SELECT s.topic_l1, s.topic_l2, s.sku, s.region_code, s.source_channel, s.gid,
       w.week_start, w.total_items,
       COALESCE(t.negative_mentions, 0) AS negative_mentions,
       COALESCE(t.mentions, 0)          AS mentions,
       COALESCE(t.negative_mentions, 0) / NULLIF(w.total_items, 0) AS negative_share
FROM series s
JOIN weeks w
  ON w.gid = s.gid
 AND EQUAL_NULL(w.sku, s.sku)
 AND EQUAL_NULL(w.region_code, s.region_code)
 AND EQUAL_NULL(w.source_channel, s.source_channel)
LEFT JOIN VOC_THEME_WEEKLY t
  ON t.topic_l1 = s.topic_l1 AND t.topic_l2 = s.topic_l2 AND t.gid = s.gid
 AND EQUAL_NULL(t.sku, s.sku) AND EQUAL_NULL(t.region_code, s.region_code)
 AND EQUAL_NULL(t.source_channel, s.source_channel)
 AND t.week_start = w.week_start;
```

The `weeks` set above only contains weeks in which the slice had any feedback. If a slice can go a
week with no feedback at all, generate the calendar from a date spine instead.

## 2. Score against a rolling baseline

```sql
CREATE OR REPLACE TABLE VOC_THEME_SCORES AS
WITH b AS (
    -- Explicit OVER clauses: Snowflake has no named WINDOW clause.
    -- The frame ends one row before the current week, so the current week
    -- never contributes to its own baseline.
    SELECT d.*,
           AVG(negative_share) OVER (
               PARTITION BY topic_l1, topic_l2, gid, sku, region_code, source_channel
               ORDER BY week_start
               ROWS BETWEEN :baseline_weeks PRECEDING AND 1 PRECEDING)  AS baseline_mean,
           STDDEV_SAMP(negative_share) OVER (
               PARTITION BY topic_l1, topic_l2, gid, sku, region_code, source_channel
               ORDER BY week_start
               ROWS BETWEEN :baseline_weeks PRECEDING AND 1 PRECEDING)  AS baseline_stddev,
           COUNT(*) OVER (
               PARTITION BY topic_l1, topic_l2, gid, sku, region_code, source_channel
               ORDER BY week_start
               ROWS BETWEEN :baseline_weeks PRECEDING AND 1 PRECEDING)  AS baseline_weeks_available
    FROM VOC_THEME_WEEKLY_DENSE d
),
z AS (
    SELECT b.*,
           -- Variance floor: a near-zero baseline stddev turns one mention into
           -- an enormous z. The floor is the share one extra mention would add.
           (negative_share - baseline_mean)
             / GREATEST(COALESCE(baseline_stddev, 0), 1.0 / NULLIF(total_items, 0)) AS z_score
    FROM b
),
t AS (
    SELECT z.*,
           (z_score >= :z_threshold
            AND negative_mentions >= :min_weekly_mentions
            AND baseline_weeks_available >= :baseline_weeks)                  AS over_threshold
    FROM z
)
SELECT t.*,
       -- Persistence: two consecutive weeks over threshold before anything pages a human.
       (over_threshold AND LAG(over_threshold) OVER (
            PARTITION BY topic_l1, topic_l2, gid, sku, region_code, source_channel
            ORDER BY week_start))                                              AS is_candidate
FROM t;
```

Bind variables are not accepted inside a window frame on every client; if `:baseline_weeks` is
rejected there, substitute the literal from `voc-project.yml` when generating the statement.

### Say how many alarms to expect

```sql
SELECT week_start,
       COUNT(*)                     AS series_tested,
       COUNT_IF(over_threshold)     AS over_threshold,
       COUNT_IF(is_candidate)       AS persistent_candidates
FROM VOC_THEME_SCORES
WHERE baseline_weeks_available >= :baseline_weeks
GROUP BY 1 ORDER BY 1;
```

Hundreds of series tested every week at a fixed threshold produce some over-threshold weeks by
chance. Present the candidate count with the number of series tested, and lean on persistence and
concentration (one SKU in one region is more credible than a scatter) when ranking.

### Across a taxonomy version change

If `taxonomy_version` changed inside the window, build the series from the roll-up view
(`VOC_TOPICS_IN_V1_TERMS`, see `build-voc-taxonomy`) so the baseline and the current week are in the
same terms. A split node otherwise shows as a sudden drop in the parent and a sudden "emergence" of
the child on the adoption date.

## 3. Zoom in: discover specific sub-themes in rising or unexplained slices

A rising Durability series says "something is breaking". The business needs "the fold hinge on the
Fold headphones in Europe". Discovery runs on a small number of candidate slices, not the corpus.

**Candidate slices:**

- persistent candidates from step 2 at the finest grain that has enough items;
- Other Feedback by product line, when the Other rate exceeds `taxonomy.other_rate_threshold`;
- the fastest-growing L2 per SKU by recent-to-baseline negative share ratio, even below threshold,
  capped at a handful per run (this is how a slow-building theme is caught before it is loud).

**Discovery with grounded structured output.** For each slice, sample up to 60 recent negative or
mixed items, supply them with their ids, and ask for distinct specific issues, each citing ids from
the supplied set:

```sql
CREATE TABLE IF NOT EXISTS VOC_THEME_DISCOVERY (
    run_id VARCHAR, slice_key VARCHAR, supplied_ids ARRAY, response VARIANT, discovered_at TIMESTAMP_NTZ
);

INSERT INTO VOC_THEME_DISCOVERY
WITH items AS (
    SELECT :slice_key AS slice_key, f.feedback_id, f.text_for_ai
    FROM VOC_FEEDBACK_STG f
    JOIN VOC_TOPIC_SENTIMENT ts ON ts.feedback_id = f.feedback_id AND ts.experiment_id = :experiment_id
    WHERE f.is_included
      AND ts.topic_l1 = :slice_topic_l1
      AND EQUAL_NULL(ts.topic_l2, :slice_topic_l2)
      AND (:slice_sku IS NULL OR f.sku = :slice_sku)
      AND (:slice_region IS NULL OR f.region_code = :slice_region)
      AND ts.topic_sentiment IN ('negative', 'mixed')
      AND f.week_start >= DATEADD(WEEK, -4, DATE_TRUNC('WEEK', CURRENT_DATE()))
    QUALIFY ROW_NUMBER() OVER (ORDER BY RANDOM()) <= 60
),
bundle AS (
    SELECT slice_key,
           ARRAY_AGG(feedback_id) AS supplied_ids,
           LISTAGG('[' || feedback_id || '] ' || LEFT(text_for_ai, 600), '\n') AS block
    FROM items GROUP BY slice_key
)
SELECT :run_id, slice_key, supplied_ids,
       AI_COMPLETE(
           model => :label_model,
           prompt => 'These are recent customer complaints in one product area. Identify up to five '
                  || 'distinct, specific issues (a specific part, behaviour, policy or charge, not a general '
                  || 'category). For each, give a short plain-English label, a description of at most 25 words, '
                  || 'and the ids of complaints that describe it, using only ids shown in square brackets. '
                  || 'Respond in JSON.\n\n' || block,
           model_parameters => {'temperature': 0},
           response_format => {
               'type': 'json',
               'schema': {
                   'type': 'object',
                   'properties': {
                       'issues': {
                           'type': 'array',
                           'items': {
                               'type': 'object',
                               'properties': {
                                   'label':       {'type': 'string'},
                                   'description': {'type': 'string'},
                                   'example_ids': {'type': 'array', 'items': {'type': 'string'}}
                               },
                               'required': ['label', 'description', 'example_ids']
                           }
                       }
                   },
                   'required': ['issues']
               }
           },
           show_details => TRUE),
       CURRENT_TIMESTAMP()
FROM bundle;
```

Then **verify grounding in SQL**: every `example_ids` entry must be in `supplied_ids`. Drop proposals
whose cited ids are not in the set and log them; a proposal that cites invented ids is not grounded.
A JSON schema cannot express "at least one id", so also drop proposals with an empty `example_ids`.

`AI_AGG` is a reasonable alternative for open-ended discovery on a very large slice, since it handles
inputs larger than a context window. It returns free text, so it cannot be grounding-checked the same
way. Prefer the structured form for anything that becomes a proposal.

## 4. Count and date each sub-theme

A proposal from a sample is a hypothesis. Count it on every item in the slice, across the baseline
and recent windows, with `AI_CLASSIFY` against the proposals plus a none option:

```sql
CREATE OR REPLACE TABLE VOC_SUBTHEME_ASSIGNMENTS AS
WITH cats AS (
    SELECT slice_key,
           ARRAY_APPEND(
               ARRAY_AGG(OBJECT_CONSTRUCT('label', i.value:label::STRING,
                                          'description', i.value:description::STRING)),
               OBJECT_CONSTRUCT('label', 'None of these',
                                'description', 'The complaint is about something other than the listed issues.')) AS categories
    FROM VOC_THEME_DISCOVERY d, LATERAL FLATTEN(input => d.response:structured_output[0]:raw_message:issues) i
    WHERE d.run_id = :run_id AND d.slice_key = :slice_key
    GROUP BY slice_key
)
SELECT :run_id AS run_id, c.slice_key, f.feedback_id, f.week_start, f.sku, f.region_code, f.source_channel,
       AI_CLASSIFY(f.text_for_ai, c.categories,
                   {'task_description': 'Which of these specific issues does the complaint describe?',
                    'output_mode': 'multi'}, TRUE) AS raw_response
FROM cats c
JOIN VOC_TOPIC_SENTIMENT ts ON ts.experiment_id = :experiment_id
     AND ts.topic_l1 = :slice_topic_l1 AND EQUAL_NULL(ts.topic_l2, :slice_topic_l2)
     AND ts.topic_sentiment IN ('negative', 'mixed')
JOIN VOC_FEEDBACK_STG f ON f.feedback_id = ts.feedback_id AND f.is_included
WHERE f.week_start >= DATEADD(WEEK, -(:baseline_weeks + 4), DATE_TRUNC('WEEK', CURRENT_DATE()));
```

The path into the `AI_COMPLETE` response (`structured_output[0]:raw_message`) is the shape returned
with `show_details => TRUE` and a `response_format`; confirm it on one row before relying on it, and
fall back to `PARSE_JSON` of the message text if this account returns the JSON as a string.

From the assignments, compute each sub-theme's weekly count, the first week it reached
`min_weekly_mentions` (onset), its growth, and its concentration (share of its mentions in its top SKU
and top region).

## 5. Item embeddings

Embed every included item once per embedding model. Phase 7's citation check reads this table too.

```sql
CREATE TABLE IF NOT EXISTS VOC_EMBEDDINGS (
    feedback_id VARCHAR, embed_model VARCHAR, embedding VECTOR(FLOAT, 1024), embedded_at TIMESTAMP_NTZ
);

INSERT INTO VOC_EMBEDDINGS
SELECT f.feedback_id, :embed_model, AI_EMBED(:embed_model, f.text_for_ai), CURRENT_TIMESTAMP()
FROM VOC_FEEDBACK_STG f
WHERE f.is_included
  AND NOT EXISTS (SELECT 1 FROM VOC_EMBEDDINGS e
                  WHERE e.feedback_id = f.feedback_id AND e.embed_model = :embed_model);
```

Estimate first with `AI_COUNT_TOKENS('ai_embed', :embed_model, text)` on a sample, if this account's
`AI_COUNT_TOKENS` supports `ai_embed`; otherwise state the estimate is unavailable. Embeddings are
optional for detection (steps 3 and 4 work without them) and required for step 6 and the Phase 7
citation check.

## 6. Is it new, or a synonym of an existing node?

```sql
-- Embed taxonomy nodes once per version (label plus description), and each
-- proposal the same way. Same model for both, or the vectors are not comparable.
CREATE TABLE IF NOT EXISTS VOC_TAXONOMY_EMBEDDINGS (
    taxonomy_version VARCHAR, topic_l1 VARCHAR, topic_l2 VARCHAR, embed_model VARCHAR,
    embedding VECTOR(FLOAT, 1024)
);

INSERT INTO VOC_TAXONOMY_EMBEDDINGS
SELECT taxonomy_version, topic_l1, topic_l2, :embed_model,
       AI_EMBED(:embed_model, topic_l1 || ': ' || topic_l2 || '. ' || topic_l2_desc)
FROM VOC_TAXONOMY
WHERE taxonomy_version = :taxonomy_version
  AND NOT EXISTS (SELECT 1 FROM VOC_TAXONOMY_EMBEDDINGS e
                  WHERE e.taxonomy_version = VOC_TAXONOMY.taxonomy_version
                    AND e.topic_l2 = VOC_TAXONOMY.topic_l2 AND e.embed_model = :embed_model);

-- Nearest existing node for each proposal.
SELECT p.slice_key, p.label,
       t.topic_l1, t.topic_l2,
       VECTOR_COSINE_SIMILARITY(AI_EMBED(:embed_model, p.label || '. ' || p.description), t.embedding) AS similarity
FROM <proposals_flat> p
CROSS JOIN VOC_TAXONOMY_EMBEDDINGS t
WHERE t.taxonomy_version = :taxonomy_version AND t.embed_model = :embed_model
QUALIFY ROW_NUMBER() OVER (PARTITION BY p.slice_key, p.label ORDER BY similarity DESC) = 1;
```

`VECTOR(FLOAT, 1024)` matches the dimension recorded at preflight (`models.embed_dims`); change both
together. Interpret the similarity with care:

- **Above `emerging.novelty_similarity_max`**: the proposal reads like an existing node. Either it is
  a spike in that node (report it as a known topic rising), or the node is broad enough to hide it
  (the hinge case inside Durability, which is a split candidate).
- **Below it**: a candidate new node.

The threshold is not universal; calibrate it on the sandbox, where the two planted themes have known
nearest nodes, and say that it was calibrated there.

## 7. Emit proposals, never taxonomy changes

```sql
CREATE TABLE IF NOT EXISTS VOC_EMERGING_THEMES (
    run_id               VARCHAR,
    detected_on          DATE,
    slice_key            VARCHAR,
    proposed_label       VARCHAR,
    proposed_description VARCHAR,
    nearest_topic_l1     VARCHAR,
    nearest_topic_l2     VARCHAR,
    nearest_similarity   FLOAT,
    proposal_kind        VARCHAR,    -- KNOWN_TOPIC_RISING | SPLIT_CANDIDATE | NEW_NODE_CANDIDATE
    onset_week           DATE,
    recent_mentions      INT,
    baseline_mentions    INT,
    top_sku              VARCHAR,
    top_sku_share        FLOAT,
    top_region           VARCHAR,
    top_region_share     FLOAT,
    example_ids          ARRAY,
    status               VARCHAR     -- PROPOSED | ACCEPTED | REJECTED | MONITOR
);
```

Each proposal goes to the taxonomy owner with its counts, onset, concentration and example ids.
Acceptance happens in `build-voc-taxonomy` as a new version. Proposed labels are never classified
against in the main pipeline until then.

## 8. Optional: join to operational outcomes

If `outcomes.table` is set (returns, contacts by SKU, region and week), show the theme series next
to the outcome series for the same slice. This is **correlation for a human to read**, not
attribution: a rising hinge complaint series next to rising returns on that SKU in that region is a
strong lead, not proof. In the sandbox, `SYNTH_SKU_WEEKLY` is synthetic and labeled as such.

```sql
SELECT s.week_start, s.negative_mentions, s.negative_share,
       o.units_sold, o.units_returned,
       o.units_returned / NULLIF(o.units_sold, 0) AS return_rate
FROM VOC_THEME_SCORES s
JOIN <outcomes_table> o
  ON o.sku = s.sku AND o.region_code = s.region_code AND o.week_start = s.week_start
WHERE s.topic_l1 = :topic_l1 AND s.topic_l2 = :topic_l2
  AND s.sku = :sku AND s.region_code = :region AND s.source_channel IS NULL
ORDER BY s.week_start;
```

Value attribution, if any, is done in `voc-value-readout` with the customer's own numbers and stated
assumptions.

## Verification before declaring the phase done

1. Series row count and slices tested, per week.
2. Persistent candidates with their baseline mean, stddev, z and mentions.
3. Discovery: proposals per slice, and proposals dropped for ungrounded ids (expected zero; any
   non-zero count is shown).
4. Sub-theme counts by week for each accepted-for-review proposal.
5. Nearest-node table with similarities.

On the sandbox, the expected outcome is: the hinge theme surfaces as a `SPLIT_CANDIDATE` under
Durability concentrated on `SYN-SKU-HP-200` in `SYN-EU` within one to three weeks of onset; the
subscription theme surfaces under Too Expensive concentrated in the social channel; the single
hinge precursor in week 2 does not fire. `evaluate-voc-accuracy` measures the lag.

Then `phases.emerging: done`, objects recorded.
