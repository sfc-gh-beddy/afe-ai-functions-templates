---
name: normalize-voc-feedback
description: "Turn raw reviews, social posts, survey open-ends and other feedback into one clean staging table before any classification runs. Unions sources into one shape, deduplicates with the correct scope (collapses review syndication, keeps template collisions from different customers, flags copy-paste campaigns), excludes near-empty items, resolves language per item rather than trusting the source and translates with AI_TRANSLATE, gates relevance with AI_CLASSIFY so spam and off-topic items never reach the taxonomy, redacts personal data with AI_REDACT according to the preflight posture, links SKUs from text by constrained choice over the product dimension, and measures AI_SENTIMENT window fit with AI_COUNT_TOKENS. Every exclusion carries a reason. Phase 3 of the voice-of-customer build."
parent_skill: voice-of-customer
---

# Normalize feedback

Classification quality and cost are both decided here. Every row removed in this phase is a row that
is not billed four more times downstream, and every duplicate left in is a customer counted twice.

**Nothing is deleted.** Every source row reaches `VOC_FEEDBACK_STG` with `is_included` and, when
excluded, an `exclusion_reason`. The gate verification is "rows in by reason", and an exclusion that
cannot be explained is a bug.

## Output contract: `VOC_FEEDBACK_STG`

| Column | Notes |
|---|---|
| `feedback_id` | source id, prefixed with the source name if ids can collide across sources |
| `canonical_feedback_id` | the surviving id for a syndicated group; equals `feedback_id` otherwise |
| `source_name`, `source_channel`, `source_system` | provenance |
| `created_at`, `week_start` | customer-written time, never ingestion time |
| `author_key` | hashed author id, for dedup scope only; never exposed downstream |
| `sku`, `sku_source` | `source`, `linked`, or `unresolved` |
| `product_line`, `region_code` | for grouping |
| `star_rating`, `nps_score` | context only |
| `original_text`, `original_language`, `reported_language` | as received, plus resolved language |
| `text_for_ai` | translated (if needed) and redacted (if required) text that every AI call reads |
| `was_translated`, `was_redacted` | flags |
| `sentiment_tokens`, `over_sentiment_window` | from `AI_COUNT_TOKENS('ai_sentiment', ...)` |
| `is_campaign` | same text from many authors in a short window |
| `is_included`, `exclusion_reason` | `DUPLICATE`, `NEAR_EMPTY`, `NOT_FEEDBACK`, `UNSUPPORTED_LANGUAGE`, `AI_ERROR` |
| `run_id`, `normalized_at` | lineage |

## Step order, and why

1. **Union** (no AI): one shape for every source.
2. **Dedup** (no AI): free, and it removes rows before any billed call.
3. **Near-empty** (no AI): "ok", "5", "." carry no topic.
4. **Redact** (`AI_REDACT`), first AI call when `normalize.redact_pii` requires redaction before any
   other AI processing.
5. **Language** (`AI_CLASSIFY`) and **translate** (`AI_TRANSLATE`).
6. **Relevance gate** (`AI_CLASSIFY` binary), on the English text.
7. **SKU linking** (`AI_CLASSIFY` over candidate product names), only where SKU is missing.
8. **Window measurement** (`AI_COUNT_TOKENS`, which bills nothing beyond the count call).

At the gate, estimate each AI step separately with `AI_COUNT_TOKENS` on a sample, because the gate
and linking steps run only on the rows that survive the free steps.

## 1. Union

```sql
CREATE OR REPLACE VIEW VOC_STG_UNION AS
SELECT
    'reviews'                                   AS source_name,
    'REVIEW'                                    AS source_channel,
    r.<source_system_col>                       AS source_system,
    'reviews:' || r.<id_col>                    AS feedback_id,
    r.<created_col>::TIMESTAMP_NTZ              AS created_at,
    SHA2(COALESCE(r.<author_col>::STRING, 'anon:' || r.<id_col>), 256) AS author_key,
    r.<sku_col>                                 AS sku,
    r.<region_col>                              AS region_code,
    r.<language_col>                            AS reported_language,
    r.<rating_col>                              AS star_rating,
    NULL::INT                                   AS nps_score,
    r.<text_col>::STRING                        AS original_text
FROM <reviews_table> r
UNION ALL
SELECT 'survey', 'SURVEY', ... FROM <survey_table> s
UNION ALL
SELECT 'social', 'SOCIAL', ... FROM <social_table> m;
```

Notes:

- **Author key with no author.** Anonymous items get a key unique to the item, so they can never
  collapse into each other. Collapsing all anonymous items with the same text would reintroduce the
  text-only dedup bug.
- **Hash the author id** here and never select the raw id downstream.
- **Social VARIANT payloads.** Pull text with an explicit path (`raw:text::STRING`) and confirm it is
  the post body, not the author bio or a quoted post.

For the sandbox the union is a single `SELECT` over `SYNTH_FEEDBACK` with `feedback_id` as is.

## 2. Dedup with the correct scope

```sql
CREATE OR REPLACE TABLE VOC_STG_DEDUP AS
WITH n AS (
    SELECT u.*,
           MD5(LOWER(REGEXP_REPLACE(TRIM(original_text), '\\s+', ' '))) AS text_hash,
           LENGTH(TRIM(original_text))                                  AS text_len
    FROM VOC_STG_UNION u
),
canon AS (
    -- Syndication: same author, same text. Keep the earliest; ties broken by id
    -- so the canonical choice is deterministic across runs.
    SELECT n.*,
           FIRST_VALUE(feedback_id) OVER (
               PARTITION BY author_key, text_hash
               ORDER BY created_at, feedback_id) AS canonical_feedback_id
    FROM n
),
campaign AS (
    -- Same text from 3+ distinct authors inside 48 hours, and long enough that
    -- a coincidence is implausible. "Great product, fast shipping." is not a
    -- campaign; a repeated 80-character promo is.
    SELECT text_hash
    FROM n
    WHERE text_len >= 40
    GROUP BY text_hash
    HAVING COUNT(DISTINCT author_key) >= 3
       AND DATEDIFF(HOUR, MIN(created_at), MAX(created_at)) <= 48
)
SELECT c.*,
       (cp.text_hash IS NOT NULL)                     AS is_campaign,
       CASE WHEN c.feedback_id <> c.canonical_feedback_id THEN 'DUPLICATE'
            WHEN c.original_text IS NULL OR c.text_len < 15 THEN 'NEAR_EMPTY'
       END                                            AS pre_ai_exclusion
FROM canon c
LEFT JOIN campaign cp ON cp.text_hash = c.text_hash;
```

Campaign members are **not** excluded here. If the relevance gate says they are not feedback (promo
spam), they are excluded there. If they are on-topic (a coordinated complaint), keep one per
`text_hash` for classification and carry `is_campaign` so trend and value calculations can count the
campaign once rather than once per author. Show the user the campaigns found, with sizes, at the gate.

Tune the 15-character near-empty threshold and the 40-character campaign threshold on the customer's
data, showing counts excluded at each candidate value before committing.

## 3. Redaction

If `normalize.redact_pii` is `before_ai`:

```sql
-- AI_REDACT( <input> [, <categories> ] [, <return_error_details> ] [, <mode> ] ).
-- Default categories unless the governance owner specified a list.
CREATE OR REPLACE TABLE VOC_STG_REDACTED AS
SELECT d.*,
       AI_REDACT(d.original_text, TRUE) AS redact_raw
FROM VOC_STG_DEDUP d
WHERE d.pre_ai_exclusion IS NULL;
```

Verify the positional form for `return_error_details` against the `AI_REDACT` reference on this
account before running at scale; the argument order includes optional `categories` first. If the
customer specified categories, pass them explicitly in the second position.

Derive `redacted_text` from `redact_raw:value` and log `redact_raw:error`. Show five before/after
pairs from the sandbox or from the user's own sample, in session only.

If the posture is `outputs_only`, skip this step here and apply `AI_REDACT` to the text feeding
summaries in Phase 7. If `none`, record the reason the user gave.

## 4. Language

Do not trust `reported_language`; the sandbox has a German review reported as English and a French
review with no language at all. Detect on every included item unless preflight showed the reported
language agreeing with detection on at least 99 percent of a sample, in which case detect only where
it is missing.

```sql
CREATE OR REPLACE TABLE VOC_STG_LANG AS
SELECT r.*,
       AI_CLASSIFY(LEFT(COALESCE(r.redacted_text, r.original_text), 600),
                   ['English', 'Spanish', 'French', 'German', 'Portuguese', 'Italian', 'Hindi', 'Other language'],
                   {'task_description': 'Identify the language the customer text is written in.'},
                   TRUE) AS lang_raw
FROM VOC_STG_REDACTED r;
```

Map the label to a code (`English` to `en`, and so on). Then translate anything not English:

```sql
SELECT l.*,
       IFF(l.lang_raw:value:labels[0]::STRING = 'English',
           NULL,
           AI_TRANSLATE(COALESCE(l.redacted_text, l.original_text), '', 'en', TRUE)) AS translate_raw
FROM VOC_STG_LANG l;
```

An empty source language makes `AI_TRANSLATE` auto-detect. Items in `Other language` that are also
outside the `AI_TRANSLATE` supported list are excluded with `UNSUPPORTED_LANGUAGE`, and counted. If
that count is material, raise it: those customers are invisible to the pipeline.

`text_for_ai` is the translation when one exists, otherwise the (redacted) original.

## 5. Relevance gate

```sql
CREATE OR REPLACE TABLE VOC_STG_GATED AS
SELECT t.*,
       AI_CLASSIFY(t.text_for_ai,
           [{'label': 'Customer feedback',
             'description': 'An opinion or experience about a product, purchase, delivery, price, support, returns, or the brand.'},
            {'label': 'Not customer feedback',
             'description': 'Spam, promotions, store hours, job posts, questions before buying, or text with no opinion or experience.'}],
           {'task_description': 'Decide whether this text is a customer giving feedback about their experience.'},
           TRUE) AS gate_raw
FROM VOC_STG_TRANSLATED t;
```

Pre-sales questions ("is it compatible with...") are excluded by this description. Some programs want
them, as a product-information signal. If so, add a third label and route them to their own table;
do not let them into the topic classification.

`AI_FILTER` is an alternative when the gate needs no description nuance. `AI_CLASSIFY` with two
described labels is preferred here because the descriptions make the boundary explicit and
reviewable.

## 6. SKU linking

Only for rows with no source SKU. Never ask a generative model to "extract the SKU".

**Small catalogues (up to roughly 20 candidates in scope):** classify over product names, constrained
by product line when the text or source gives a hint:

```sql
WITH candidates AS (
    SELECT product_line,
           ARRAY_APPEND(
               ARRAY_AGG(OBJECT_CONSTRUCT('label', product_name)) WITHIN GROUP (ORDER BY product_name),
               OBJECT_CONSTRUCT('label', 'No specific product',
                                'description', 'The text does not identify one specific product.')) AS cats
    FROM <product_dim>
    GROUP BY product_line
)
SELECT g.feedback_id,
       AI_CLASSIFY(g.text_for_ai, c.cats,
                   {'task_description': 'Which product is this customer talking about?'}, TRUE) AS link_raw
FROM VOC_STG_GATED g
JOIN candidates c ON c.product_line = g.product_line_hint
WHERE g.sku IS NULL AND g.gate_raw:value:labels[0]::STRING = 'Customer feedback';
```

Then join the chosen `product_name` back to the dimension to get the SKU. A name that does not join is
`unresolved`, never a guessed SKU.

**Large catalogues:** shortlist first, then choose. Embed product names once
(`AI_EMBED(<embed_model>, product_name)`), embed the feedback, take the top ten by
`VECTOR_COSINE_SIMILARITY`, and run `AI_CLASSIFY` over that shortlist plus "No specific product".
Report linking precision on the sandbox `SKU_FROM_TEXT` cases and on a labeled real sample.

Rows that stay unresolved still count toward brand-level and product-line-level themes; they only
drop out of SKU-level views. Report the unresolved share per channel.

## 7. Window measurement and final assembly

```sql
CREATE OR REPLACE TABLE VOC_FEEDBACK_STG AS
SELECT
    g.feedback_id, g.canonical_feedback_id, g.source_name, g.source_channel, g.source_system,
    g.created_at, DATE_TRUNC('WEEK', g.created_at)::DATE AS week_start,
    g.author_key,
    COALESCE(g.sku, l.linked_sku)                          AS sku,
    CASE WHEN g.sku IS NOT NULL THEN 'source'
         WHEN l.linked_sku IS NOT NULL THEN 'linked'
         ELSE 'unresolved' END                             AS sku_source,
    p.product_line, g.region_code, g.star_rating, g.nps_score,
    g.original_text, g.original_language, g.reported_language,
    g.text_for_ai, g.was_translated, g.was_redacted,
    AI_COUNT_TOKENS('ai_sentiment', g.text_for_ai)         AS sentiment_tokens,
    AI_COUNT_TOKENS('ai_sentiment', g.text_for_ai) > 2048  AS over_sentiment_window,
    g.is_campaign,
    (g.exclusion_reason IS NULL)                           AS is_included,
    g.exclusion_reason,
    :run_id                                                AS run_id,
    CURRENT_TIMESTAMP()                                    AS normalized_at
FROM <gated_with_reasons> g
LEFT JOIN <linked> l ON l.feedback_id = g.feedback_id
LEFT JOIN <product_dim> p ON p.sku = COALESCE(g.sku, l.linked_sku);
```

`exclusion_reason` is assigned in precedence order: `DUPLICATE`, `NEAR_EMPTY`, `AI_ERROR` (any step's
`error` non-NULL), `UNSUPPORTED_LANGUAGE`, `NOT_FEEDBACK`. `AI_ERROR` rows are retried on the next run
rather than silently dropped. Excluded rows keep their row so the reconciliation balances.

For the incremental path, process only `feedback_id`s not already in `VOC_FEEDBACK_STG` and those with
`exclusion_reason = 'AI_ERROR'`. Note that dedup must still see the full history: a syndicated copy
arriving today must collapse into a canonical item from last month.

## Non-text feedback

Scanned comment cards, PDF survey exports and screenshots are ingestion, not normalization. Convert
them with `AI_PARSE_DOCUMENT` (wrap the result as `PARSE_JSON(TO_VARCHAR(...))`, since the return type
can differ across accounts) into a text table first, then add that table as a source here.

## Verification before declaring the phase done

```sql
-- 1. Reconciliation: every source row accounted for, by reason.
SELECT source_channel, COALESCE(exclusion_reason, 'INCLUDED') AS outcome, COUNT(*) AS items
FROM VOC_FEEDBACK_STG GROUP BY 1, 2 ORDER BY 1, 3 DESC;

-- 2. No double counting among included rows.
SELECT canonical_feedback_id, COUNT(*) AS n
FROM VOC_FEEDBACK_STG WHERE is_included
GROUP BY 1 HAVING COUNT(*) > 1;
-- Expect 0 rows.

-- 3. Language and translation.
SELECT original_language, was_translated, COUNT(*) AS items
FROM VOC_FEEDBACK_STG WHERE is_included GROUP BY 1, 2 ORDER BY 3 DESC;

-- 4. SKU linking.
SELECT source_channel, sku_source, COUNT(*) AS items
FROM VOC_FEEDBACK_STG WHERE is_included GROUP BY 1, 2 ORDER BY 1, 2;

-- 5. Window fit.
SELECT COUNT_IF(over_sentiment_window) AS over_window, COUNT(*) AS included
FROM VOC_FEEDBACK_STG WHERE is_included;

-- 6. Errors logged.
SELECT stage, COUNT(*) FROM VOC_QUALITY_LOG WHERE run_id = :run_id GROUP BY 1;
```

On the sandbox: the three syndicated rows collapse to one; the three template-collision rows all
survive; the three spam rows are campaign-flagged and excluded as not feedback; the store-hours and
compatibility questions are excluded; the Spanish, French and German items are translated; the long
survey answer is flagged over-window; and the two `SKU_FROM_TEXT` posts link to the right SKUs.

Then `phases.normalize: done`, objects recorded.
