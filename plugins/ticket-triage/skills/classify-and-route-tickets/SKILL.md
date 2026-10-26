---
name: classify-and-route-tickets
description: "Normalize tickets and produce per-ticket triage labels: category, impact, urgency, derived priority, resolver queue, multi-intent flag, and extracted product, version, error code, error message, asset id and affected-user count. Thread normalization (quoted replies, signatures, disclaimers, pre-assignment comment cut to prevent label leakage), optional AI_REDACT, token windowing, AI_CLASSIFY against versioned label sets with descriptions and few-shot examples, priority from the customer's impact x urgency matrix in SQL, rules-first queue derivation with candidate-queue classification, AI_EXTRACT entities with product canonicalization, an AI_COMPLETE structured-output fallback for the low-confidence residue, derived confidence bands with their basis, explicit UNCLASSIFIED handling, and run identity on every row. Phase 4 of the ticket-triage build. Triggers: classify tickets, route tickets, predict assignment group, predict priority, extract error codes, ticket entity extraction."
parent_skill: ticket-triage
---

# Classify and route tickets

This is the phase that produces the routing decision. It runs in four steps, each its own gate when run over
a full table: normalize, classify, extract, fallback. The output is `TICKET_CLASSIFICATION` and
`TICKET_ENTITIES`, keyed on `run_id` + `ticket_id`, accumulating across experiments.

Read before starting: `triage-project.yml` (`tickets`, `taxonomy`, `models`, `thresholds`, `experiment`),
and best-practices rules 1-8, 14-16 and 26. Set `QUERY_TAG` to the `run_id` for the session so cost
attributes to this run:

```sql
ALTER SESSION SET QUERY_TAG = '<run_id>';
```

## What gets created

| Object | Type | Grain |
|---|---|---|
| `TICKETS_NORMALIZED` | table | one row per ticket (not per run — normalization is deterministic for a given rule version) |
| `TICKET_CLASSIFICATION` | table, accumulating | `run_id` x `ticket_id` |
| `TICKET_ENTITIES` | table, accumulating | `run_id` x `ticket_id` |

In `dbt` mode these are the `normalize/` and `classify/` models in `DBT_MATERIALIZATION.md`; the SQL below is
the model body.

---

## Step 1 — Normalize

Three inputs are built per ticket, because different stages may see different text:

| Column | Contents | Used by |
|---|---|---|
| `classify_text` | subject + description (stripped) + **requester** comments timestamped **before first assignment** | classification, entities, linking |
| `full_text` | subject + stripped description + all requester comments | suggestions (phase 6) |
| `raw_text` | as stored | token accounting only |

`classify_text` must never contain agent work notes, any comment after first assignment, resolution or close
notes, or any historical label field. This is the single most important leakage control (rule 1). For new,
unassigned tickets in production the cut is "everything so far", which is the same rule.

This step needs three columns beyond the basic mapping, recorded in `triage-project.yml` under `tickets`:
`first_assigned_at_col` (when the ticket first reached a queue), and on the comments table
`comments_at_col` and `comments_author_type_col` (requester versus agent). Without them the pre-assignment
cut cannot be made; in that case use subject and description only and say so.

Stripping patterns are **tuned to this mail system**. The defaults below match the sandbox and common
formats; show the user, on a sample, how many characters each pattern removes before committing it.

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.TICKETS_NORMALIZED (
    ticket_id         VARCHAR,
    created_at        TIMESTAMP_NTZ,
    channel           VARCHAR,
    requester_id      VARCHAR,
    classify_text     VARCHAR,
    full_text         VARCHAR,
    raw_chars         NUMBER,
    clean_chars       NUMBER,
    raw_tokens        NUMBER,
    clean_tokens      NUMBER,
    was_truncated     BOOLEAN,
    redacted          BOOLEAN,
    normalize_version VARCHAR,
    normalized_at     TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

```sql
INSERT INTO <db>.<schema>.TICKETS_NORMALIZED
    (ticket_id, created_at, channel, requester_id, classify_text, full_text,
     raw_chars, clean_chars, was_truncated, redacted, normalize_version)
WITH pre_assign AS (
    -- Requester comments made before the ticket was first assigned. Agent notes
    -- and anything later are excluded: they contain the answer.
    SELECT c.<comments_ticket_id_col> AS ticket_id,
           LISTAGG(c.<comments_text_col>, '\n') WITHIN GROUP (ORDER BY c.<comments_at_col>) AS pre_text
    FROM <comments_table> c
    JOIN <source_table> t ON t.<id_col> = c.<comments_ticket_id_col>
    WHERE c.<comments_author_type_col> = 'REQUESTER'
      AND (t.<first_assigned_at_col> IS NULL OR c.<comments_at_col> < t.<first_assigned_at_col>)
    GROUP BY 1
),
all_req AS (
    SELECT c.<comments_ticket_id_col> AS ticket_id,
           LISTAGG(c.<comments_text_col>, '\n') WITHIN GROUP (ORDER BY c.<comments_at_col>) AS req_text
    FROM <comments_table> c
    WHERE c.<comments_author_type_col> = 'REQUESTER'
    GROUP BY 1
),
stripped AS (
    SELECT
        t.<id_col>          AS ticket_id,
        t.<created_at_col>  AS created_at,
        t.<channel_col>     AS channel,
        t.<requester_col>   AS requester_id,
        t.<subject_col>     AS subject,
        t.<body_col>        AS raw_body,
        -- 1. Cut the quoted reply chain: everything from the first quote header.
        -- 2. Drop confidentiality footers (paragraph-level).
        -- 3. Drop '>'-quoted lines that survived.
        -- 4. Collapse whitespace.
        TRIM(REGEXP_REPLACE(
          REGEXP_REPLACE(
            REGEXP_REPLACE(
              REGEXP_REPLACE(COALESCE(t.<body_col>, ''),
                '(-----Original Message-----|\\nOn [^\\n]{0,200} wrote:|\\nFrom: [^\\n]+\\nSent: ).*$', '', 1, 1, 's'),
              'CONFIDENTIALITY NOTICE:[^\\n]*(\\n[^\\n]+)*', '', 1, 0),
            '\\n>[^\\n]*', ''),
          '\\s+', ' '))       AS body_clean
    FROM <source_table> t
    WHERE NOT EXISTS (SELECT 1 FROM <db>.<schema>.TICKETS_NORMALIZED n WHERE n.ticket_id = t.<id_col>)
)
SELECT
    s.ticket_id, s.created_at, s.channel, s.requester_id,
    -- CONCAT_WS skips NULLs; CONCAT would return NULL for subject-only tickets.
    LEFT(CONCAT_WS('\n', s.subject, NULLIF(s.body_clean, ''), p.pre_text), 6000)  AS classify_text,
    LEFT(CONCAT_WS('\n', s.subject, NULLIF(s.body_clean, ''), r.req_text), 12000) AS full_text,
    LENGTH(COALESCE(s.raw_body, '')) + LENGTH(COALESCE(s.subject, ''))            AS raw_chars,
    LENGTH(CONCAT_WS('\n', s.subject, NULLIF(s.body_clean, ''), p.pre_text))      AS clean_chars,
    LENGTH(CONCAT_WS('\n', s.subject, NULLIF(s.body_clean, ''), p.pre_text)) > 6000 AS was_truncated,
    FALSE                                                                          AS redacted,
    'norm_v1'                                                                      AS normalize_version
FROM stripped s
LEFT JOIN pre_assign p ON p.ticket_id = s.ticket_id
LEFT JOIN all_req   r ON r.ticket_id = s.ticket_id;
```

The `LEFT(..., 6000)` is a character backstop, not the budget. Tickets are front-loaded — the problem
statement is at the start — so truncating the tail is the right direction here (the opposite of clinical
charts). Fill the token columns on the normalized table and confirm the budget against the fallback model:

```sql
UPDATE <db>.<schema>.TICKETS_NORMALIZED n
SET raw_tokens   = AI_COUNT_TOKENS('ai_complete', '<classify_fallback_model>',
                       LEFT(CONCAT_WS('\n', t.<subject_col>, t.<body_col>), 50000)),
    clean_tokens = AI_COUNT_TOKENS('ai_complete', '<classify_fallback_model>', n.classify_text)
FROM <source_table> t
WHERE t.<id_col> = n.ticket_id
  AND n.clean_tokens IS NULL;
```

The regular expressions above avoid non-greedy quantifiers (`.*?`): Snowflake's regex functions follow POSIX
extended syntax, so write patterns that do not depend on lazy matching.

Run that update on a sample first if the table is large (it is an AI function call per row, cheap but not
free), and report the normalization reduction — on email-heavy corpora it is often the largest single cost
lever, and phase 7 reports the measured figure.

**Redaction.** If preflight decided ticket text must be redacted before it reaches a generative prompt, apply
`AI_REDACT` to `full_text` (the suggestion input) and set `redacted = TRUE`. Classification with
`AI_CLASSIFY` is not generative and can usually run on unredacted `classify_text`; that is the customer's
decision, recorded in state. Redaction on `classify_text` can remove signal (product names inside
hostnames, asset tags) — measure before and after if it is applied.

**Language.** If preflight found a material non-English share, add an `AI_TRANSLATE` step to English for
`classify_text` (the `AI_CLASSIFY` docs recommend English input) and record `source_language`. The sandbox's
`NON_ENGLISH` scenario (S23) measures whether this was needed.

## Step 2 — Classify category, impact and urgency

Label arrays and configs are built **from the versioned label tables**, in one row, then cross-joined —
never typed as literals in the SQL. The serialized arrays plus prompt text are what `prompt_hash` covers.

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.TICKET_CLASSIFICATION (
    run_id               VARCHAR,
    experiment_id        VARCHAR,
    experiment_name      VARCHAR,
    prompt_version       VARCHAR,
    prompt_hash          VARCHAR,
    taxonomy_version     VARCHAR,
    ticket_id            VARCHAR,
    pred_category        VARCHAR,
    category_source      VARCHAR,   -- RULE | AI_CLASSIFY | AI_COMPLETE | ERROR
    pred_impact          VARCHAR,
    pred_urgency         VARCHAR,
    pred_priority        VARCHAR,
    priority_source      VARCHAR,   -- MATRIX | MATRIX+RAISE | AI_COMPLETE | ERROR
    pred_queue           VARCHAR,
    queue_source         VARCHAR,   -- RULE | AI_CLASSIFY | AI_COMPLETE | ERROR | NO_MATCH
    is_multi_intent      BOOLEAN,
    confidence_band      VARCHAR,   -- HIGH | MEDIUM | LOW
    confidence_basis     VARCHAR,   -- why the band was assigned
    fallback_used        BOOLEAN,
    fallback_confidence  NUMBER,    -- self-reported 1-10, AI_COMPLETE only; not calibrated
    parse_ok             BOOLEAN,
    raw_category         VARIANT,
    raw_impact           VARIANT,
    raw_urgency          VARIANT,
    raw_queue            VARIANT,
    raw_fallback         VARIANT,
    fallback_model       VARCHAR,
    classified_at        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
```

Estimate before running over the table. `AI_COUNT_TOKENS` has an `ai_classify` form that takes the
categories, which counts the label descriptions that are paid on every row:

```sql
WITH cfg AS (
    SELECT ARRAY_AGG(OBJECT_CONSTRUCT('label', label, 'description', description))
             WITHIN GROUP (ORDER BY label) AS cats
    FROM <db>.<schema>.TAXONOMY_LABELS
    WHERE taxonomy_version = :taxonomy_version AND dimension = 'category' AND active
)
SELECT COUNT(*) AS tickets,
       SUM(AI_COUNT_TOKENS('ai_classify', n.classify_text, cfg.cats)) AS category_input_tokens_floor
FROM (SELECT classify_text FROM <db>.<schema>.TICKETS_NORMALIZED SAMPLE (500 ROWS)) n
CROSS JOIN cfg;
```

Scale the sample to the table, multiply by three for category, impact and urgency (and add the queue step
for categories that need it), and present it as a floor in tokens. Gate.

```sql
INSERT INTO <db>.<schema>.TICKET_CLASSIFICATION
    (run_id, experiment_id, experiment_name, prompt_version, prompt_hash, taxonomy_version, ticket_id,
     raw_category, raw_impact, raw_urgency, is_multi_intent, fallback_used, parse_ok)
WITH labels AS (
    SELECT dimension,
           ARRAY_AGG(OBJECT_CONSTRUCT('label', label, 'description', description))
             WITHIN GROUP (ORDER BY label) AS cats
    FROM <db>.<schema>.TAXONOMY_LABELS
    WHERE taxonomy_version = :taxonomy_version AND active
      AND dimension IN ('category', 'impact', 'urgency')
    GROUP BY dimension
),
examples AS (
    SELECT dimension,
           ARRAY_AGG(OBJECT_CONSTRUCT('input', input, 'labels', labels, 'explanation', explanation)) AS ex
    FROM <db>.<schema>.TAXONOMY_EXAMPLES
    WHERE taxonomy_version = :taxonomy_version
    GROUP BY dimension
),
cfg AS (
    SELECT
        MAX(IFF(l.dimension = 'category', l.cats, NULL)) AS cat_labels,
        MAX(IFF(l.dimension = 'impact',   l.cats, NULL)) AS imp_labels,
        MAX(IFF(l.dimension = 'urgency',  l.cats, NULL)) AS urg_labels,
        OBJECT_CONSTRUCT(
            'task_description', 'Classify an internal IT support ticket by the kind of problem or request it describes.',
            'examples', COALESCE(MAX(IFF(e.dimension = 'category', e.ex, NULL)), ARRAY_CONSTRUCT())) AS cat_cfg,
        OBJECT_CONSTRUCT(
            'task_description', 'Classify how widely a support ticket problem affects users or customers. Judge scope only.',
            'examples', COALESCE(MAX(IFF(e.dimension = 'impact', e.ex, NULL)), ARRAY_CONSTRUCT())) AS imp_cfg,
        OBJECT_CONSTRUCT(
            'task_description', 'Classify how quickly business harm occurs. Ignore requester tone, capital letters and the word urgent.',
            'examples', COALESCE(MAX(IFF(e.dimension = 'urgency', e.ex, NULL)), ARRAY_CONSTRUCT())) AS urg_cfg
    FROM labels l
    LEFT JOIN examples e ON e.dimension = l.dimension
)
SELECT
    :run_id, :experiment_id, :experiment_name, :prompt_version,
    SHA2(TO_JSON(OBJECT_CONSTRUCT('cat', cfg.cat_labels, 'imp', cfg.imp_labels, 'urg', cfg.urg_labels,
                                  'catcfg', cfg.cat_cfg, 'impcfg', cfg.imp_cfg, 'urgcfg', cfg.urg_cfg,
                                  'normalize', n.normalize_version)), 256) AS prompt_hash,
    :taxonomy_version,
    n.ticket_id,
    AI_CLASSIFY(n.classify_text, cfg.cat_labels, cfg.cat_cfg, TRUE) AS raw_category,
    AI_CLASSIFY(n.classify_text, cfg.imp_labels, cfg.imp_cfg, TRUE) AS raw_impact,
    AI_CLASSIFY(n.classify_text, cfg.urg_labels, cfg.urg_cfg, TRUE) AS raw_urgency,
    AI_FILTER(PROMPT(
        'This IT ticket contains two or more unrelated requests that different teams would handle: {0}',
        n.classify_text))                                            AS is_multi_intent,
    FALSE, TRUE
FROM <db>.<schema>.TICKETS_NORMALIZED n
CROSS JOIN cfg
WHERE NOT EXISTS (
    SELECT 1 FROM <db>.<schema>.TICKET_CLASSIFICATION c
    WHERE c.run_id = :run_id AND c.ticket_id = n.ticket_id);
```

Notes on this statement:

- `return_error_details` is the fourth positional argument (`TRUE`), so each `raw_*` is an object with
  `value` and `error`. The label is `raw_category:value:labels[0]::STRING`. Keeping the object is what makes
  rule 4's null accounting possible.
- `task_description` strings must stay at 50 words or fewer; descriptions at 25 or fewer (validated in the
  taxonomy phase).
- If the customer chose multi-label categories, add `'output_mode', 'multi'` to `cat_cfg` and keep the
  full `labels` array; queue stays single.
- An empty `examples` array is passed when none exist; verify on a one-row test that the account accepts it,
  and omit the key instead if not.
- `AI_FILTER` on the multi-intent check costs one call per ticket. If the budget is tight, skip it here and
  take `is_multi_intent` from the fallback schema only.

Then unpack labels, validate membership (rule 3), derive priority from the matrix, and mark errors:

```sql
UPDATE <db>.<schema>.TICKET_CLASSIFICATION c
SET pred_category   = COALESCE(v.cat, 'UNCLASSIFIED'),
    category_source = IFF(v.cat IS NULL, 'ERROR', 'AI_CLASSIFY'),
    pred_impact     = v.imp,
    pred_urgency    = v.urg,
    pred_priority   = m.priority,
    priority_source = IFF(m.priority IS NULL, 'ERROR', 'MATRIX')
FROM (
    SELECT c2.run_id, c2.ticket_id,
           -- Membership check: a returned label not in the active set is treated as no label.
           IFF(tc.label IS NOT NULL, c2.raw_category:value:labels[0]::STRING, NULL) AS cat,
           IFF(ti.label IS NOT NULL, c2.raw_impact:value:labels[0]::STRING,   NULL) AS imp,
           IFF(tu.label IS NOT NULL, c2.raw_urgency:value:labels[0]::STRING,  NULL) AS urg
    FROM <db>.<schema>.TICKET_CLASSIFICATION c2
    LEFT JOIN <db>.<schema>.TAXONOMY_LABELS tc
      ON tc.taxonomy_version = c2.taxonomy_version AND tc.dimension = 'category' AND tc.active
     AND tc.label = c2.raw_category:value:labels[0]::STRING
    LEFT JOIN <db>.<schema>.TAXONOMY_LABELS ti
      ON ti.taxonomy_version = c2.taxonomy_version AND ti.dimension = 'impact' AND ti.active
     AND ti.label = c2.raw_impact:value:labels[0]::STRING
    LEFT JOIN <db>.<schema>.TAXONOMY_LABELS tu
      ON tu.taxonomy_version = c2.taxonomy_version AND tu.dimension = 'urgency' AND tu.active
     AND tu.label = c2.raw_urgency:value:labels[0]::STRING
    WHERE c2.run_id = :run_id
) v
LEFT JOIN <db>.<schema>.PRIORITY_MATRIX m
  ON m.taxonomy_version = :taxonomy_version AND m.impact = v.imp AND m.urgency = v.urg
WHERE c.run_id = v.run_id AND c.ticket_id = v.ticket_id;
```

### Priority raises, by rule only

Raise priority deterministically on observable major-incident signals — never on requester tone (rule 6):

- the ticket is later linked (phase 5) to a duplicate cluster above a size the customer sets — a cluster of
  ten "VPN unreachable" tickets is a major incident whatever each one says;
- the channel is a monitoring integration the customer designates;
- the extracted `affected_users` exceeds a customer-set threshold.

Raises set `priority_source = 'MATRIX+RAISE'` and are applied after phase 5 so the cluster signal exists.
Record the raise rules in state; they are policy.

## Step 3 — Queue: rules first, then candidate classification

```sql
-- 3a. Deterministic rules from CATEGORY_QUEUE_MAP.
UPDATE <db>.<schema>.TICKET_CLASSIFICATION c
SET pred_queue = m.queue, queue_source = 'RULE'
FROM <db>.<schema>.CATEGORY_QUEUE_MAP m
WHERE c.run_id = :run_id
  AND m.taxonomy_version = c.taxonomy_version
  AND m.category = c.pred_category
  AND m.queue IS NOT NULL
  AND m.product IS NULL
  AND c.pred_queue IS NULL;
```

```sql
-- 3b. Categories with several candidate queues: classify among ONLY those.
--     Smaller label sets are cheaper and more accurate than choosing among all queues.
UPDATE <db>.<schema>.TICKET_CLASSIFICATION c
SET raw_queue = x.raw_queue
FROM (
    SELECT c2.run_id, c2.ticket_id,
           AI_CLASSIFY(n.classify_text, q.cand_labels,
                       {'task_description': 'Choose the team that should first work this IT ticket.'},
                       TRUE) AS raw_queue
    FROM <db>.<schema>.TICKET_CLASSIFICATION c2
    JOIN <db>.<schema>.TICKETS_NORMALIZED n ON n.ticket_id = c2.ticket_id
    JOIN (
        SELECT m.category,
               ARRAY_AGG(OBJECT_CONSTRUCT('label', t.label, 'description', t.description))
                 WITHIN GROUP (ORDER BY t.label) AS cand_labels
        FROM <db>.<schema>.CATEGORY_QUEUE_MAP m,
             LATERAL FLATTEN(input => m.candidate_queues) f,
             <db>.<schema>.TAXONOMY_LABELS t
        WHERE t.taxonomy_version = :taxonomy_version AND t.dimension = 'queue' AND t.active
          AND t.label = f.value::STRING
          AND m.taxonomy_version = :taxonomy_version AND m.queue IS NULL
        GROUP BY m.category
    ) q ON q.category = c2.pred_category
    WHERE c2.run_id = :run_id AND c2.pred_queue IS NULL
) x
WHERE c.run_id = x.run_id AND c.ticket_id = x.ticket_id;

UPDATE <db>.<schema>.TICKET_CLASSIFICATION c
SET pred_queue   = t.label,
    queue_source = 'AI_CLASSIFY'
FROM <db>.<schema>.TAXONOMY_LABELS t
WHERE c.run_id = :run_id AND c.pred_queue IS NULL
  AND t.taxonomy_version = c.taxonomy_version AND t.dimension = 'queue' AND t.active
  AND t.label = c.raw_queue:value:labels[0]::STRING;
```

The label table is comma-joined with the condition in `WHERE`: Snowflake rejects a `LATERAL FLATTEN` on the
left side of an explicit `JOIN` ("Lateral View cannot be on the left side of join"). Put the flatten in a
derived table, or comma-join and filter, as here.

If `AI_CLASSIFY` rejects a per-row (non-constant) category array in this account, the fallback is one
statement per multi-queue category with that category's candidate array as a constant — generated from
`CATEGORY_QUEUE_MAP` and executed in a loop. Compile and run a ten-row test before the full table.

## Step 4 — Entities

`AI_EXTRACT` with a JSON schema. Each property's `description` is the question; keep them specific so the
model does not invent a value when none is stated.

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.TICKET_ENTITIES (
    run_id            VARCHAR,
    ticket_id         VARCHAR,
    product_raw       VARCHAR,
    product           VARCHAR,     -- canonicalized
    product_version   VARCHAR,
    error_code        VARCHAR,
    error_message     VARCHAR,
    asset_id          VARCHAR,
    affected_users    VARCHAR,     -- as stated; parsed downstream, never coerced at insert
    raw_extract       VARIANT,
    extract_ok        BOOLEAN,
    extracted_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO <db>.<schema>.TICKET_ENTITIES (run_id, ticket_id, raw_extract)
SELECT :run_id, n.ticket_id,
       AI_EXTRACT(
         text => n.classify_text,
         responseFormat => {
           'schema': {
             'type': 'object',
             'properties': {
               'product':         {'type': 'string', 'description': 'Name of the software, service or device that has the problem, exactly as written. Empty if none is named.'},
               'product_version': {'type': 'string', 'description': 'Version number of that product if stated, for example 5.2. Empty if not stated.'},
               'error_code':      {'type': 'string', 'description': 'Error code exactly as written, for example VPN-809, FI-204 or 0x800CCC0E. Empty if none.'},
               'error_message':   {'type': 'string', 'description': 'The error message text the user saw, if quoted. Empty if none.'},
               'asset_id':        {'type': 'string', 'description': 'Asset tag of the laptop, printer or device, for example SYN-LT-12345. Empty if none.'},
               'affected_users':  {'type': 'string', 'description': 'How many people are affected, as stated: one, my team, everyone, a number. Empty if not stated.'}
             }
           }
         })
FROM <db>.<schema>.TICKETS_NORMALIZED n
WHERE NOT EXISTS (SELECT 1 FROM <db>.<schema>.TICKET_ENTITIES e
                  WHERE e.run_id = :run_id AND e.ticket_id = n.ticket_id);

UPDATE <db>.<schema>.TICKET_ENTITIES
SET product_raw     = NULLIF(TRIM(raw_extract:response:product::STRING), ''),
    product_version = NULLIF(TRIM(raw_extract:response:product_version::STRING), ''),
    error_code      = NULLIF(UPPER(TRIM(raw_extract:response:error_code::STRING)), ''),
    error_message   = NULLIF(TRIM(raw_extract:response:error_message::STRING), ''),
    asset_id        = NULLIF(UPPER(TRIM(raw_extract:response:asset_id::STRING)), ''),
    affected_users  = NULLIF(TRIM(raw_extract:response:affected_users::STRING), ''),
    extract_ok      = raw_extract IS NOT NULL AND raw_extract:error IS NULL
WHERE run_id = :run_id;
```

The response shape is `{"error": ..., "response": {...}}` per the `AI_EXTRACT` docs. Error codes are
uppercased for matching but hex codes like `0x800CCC0E` become `0X800CCC0E`; normalize the known-issue table
the same way (one expression on both sides — the reference play's harness lesson applies to joins too).

Deterministic regex is still the better extractor for strongly formatted identifiers. If the customer's asset
tags follow a pattern, use `REGEXP_SUBSTR` first and `AI_EXTRACT` only where it finds nothing; record which.

### Product canonicalization

The search filter (phase 6) and duplicate blocking (phase 5) need one product string per product. Extracted
names vary ("Outlook", "MS Outlook", "Microsoft Outlook desktop"). Map to the canonical list (KB products plus
known-issue products) with `AI_CLASSIFY` over that list plus `Other`, only where `product_raw` is not null:

```sql
UPDATE <db>.<schema>.TICKET_ENTITIES e
SET product = IFF(x.p = 'Other', NULL, x.p)
FROM (
    SELECT e2.run_id, e2.ticket_id,
           AI_CLASSIFY(e2.product_raw, cp.products):labels[0]::STRING AS p
    FROM <db>.<schema>.TICKET_ENTITIES e2
    CROSS JOIN (
        SELECT ARRAY_APPEND(ARRAY_AGG(DISTINCT product), 'Other') AS products
        FROM <db>.<schema>.KB_CHUNKS WHERE product IS NOT NULL
    ) cp
    WHERE e2.run_id = :run_id AND e2.product_raw IS NOT NULL
) x
WHERE e.run_id = x.run_id AND e.ticket_id = x.ticket_id;
```

Product strings are short; this is cheap. A static alias table maintained by the customer is cheaper still
and preferred once the alias set stabilizes.

## Step 5 — Confidence band and the fallback

Derive the band from observable agreement, and record the basis (rule 5):

```sql
UPDATE <db>.<schema>.TICKET_CLASSIFICATION c
SET confidence_band = b.band, confidence_basis = b.basis
FROM (
    SELECT c2.run_id, c2.ticket_id,
           CASE
             WHEN c2.pred_category = 'UNCLASSIFIED' OR c2.pred_queue IS NULL
                  OR c2.pred_priority IS NULL                                   THEN 'LOW'
             WHEN c2.queue_source = 'RULE'                                      THEN 'HIGH'
             WHEN pq.queue IS NOT NULL AND pq.queue = c2.pred_queue             THEN 'HIGH'
             WHEN c2.is_multi_intent                                            THEN 'LOW'
             ELSE 'MEDIUM'
           END AS band,
           CASE
             WHEN c2.pred_category = 'UNCLASSIFIED' OR c2.pred_queue IS NULL
                  OR c2.pred_priority IS NULL                                   THEN 'missing label'
             WHEN c2.queue_source = 'RULE'                                      THEN 'category rule'
             WHEN pq.queue IS NOT NULL AND pq.queue = c2.pred_queue             THEN 'queue agrees with product owner'
             WHEN c2.is_multi_intent                                            THEN 'multi-intent'
             ELSE 'classifier only'
           END AS basis
    FROM <db>.<schema>.TICKET_CLASSIFICATION c2
    LEFT JOIN <db>.<schema>.TICKET_ENTITIES e ON e.run_id = c2.run_id AND e.ticket_id = c2.ticket_id
    -- Optional: product -> owning queue, from CATEGORY_QUEUE_MAP rows that carry a product.
    LEFT JOIN <db>.<schema>.CATEGORY_QUEUE_MAP pq
      ON pq.taxonomy_version = c2.taxonomy_version AND pq.product = e.product AND pq.queue IS NOT NULL
    WHERE c2.run_id = :run_id
) b
WHERE c.run_id = b.run_id AND c.ticket_id = b.ticket_id;
```

The bands are a hypothesis until phase 7's reliability table shows precision actually differs by band.

Run the `AI_COMPLETE` fallback on `LOW` only (or below `thresholds.classify_confidence_floor`). The schema
uses `enum` built from the active label set so the model cannot invent a queue. Assemble the prompt and
schema **once** as text, hash that text, and bind the same text into the call.

```sql
-- Shown with the sandbox labels inline for readability. Generate the enum arrays
-- from TAXONOMY_LABELS when assembling the statement; never hand-edit them.
UPDATE <db>.<schema>.TICKET_CLASSIFICATION c
SET raw_fallback = x.resp, fallback_used = TRUE, fallback_model = '<classify_fallback_model>'
FROM (
    SELECT c2.run_id, c2.ticket_id,
           AI_COMPLETE(
             model => '<classify_fallback_model>',
             prompt => 'You route internal IT support tickets. Read the ticket and choose the category, '
                    || 'impact, urgency and first resolver queue from the allowed values. Impact is scope '
                    || 'of effect. Urgency is how fast harm occurs; ignore tone and capital letters. If the '
                    || 'ticket contains two unrelated requests, route on the first and set multi_intent. '
                    || 'Respond in JSON.\n\nTicket:\n' || n.classify_text,
             model_parameters => {'temperature': 0, 'max_tokens': 400},
             response_format => {
               'type': 'json',
               'schema': {
                 'type': 'object',
                 'properties': {
                   'category':     {'type': 'string', 'enum': ['Access and Identity','Network and VPN','Hardware','Software and Applications','Email and Collaboration','Business Applications','Printing','Security']},
                   'impact':       {'type': 'string', 'enum': ['HIGH','MEDIUM','LOW']},
                   'urgency':      {'type': 'string', 'enum': ['HIGH','MEDIUM','LOW']},
                   'queue':        {'type': 'string', 'enum': ['SERVICE_DESK','IDENTITY_ACCESS','NETWORK_OPS','END_USER_COMPUTING','MESSAGING_COLLAB','BUSINESS_APPS','SECURITY_OPS']},
                   'multi_intent': {'type': 'boolean'},
                   'confidence':   {'type': 'number', 'description': 'Integer 1-10: how clearly the ticket text supports this routing.'},
                   'reasoning':    {'type': 'string', 'description': 'One sentence citing the words in the ticket that decided the queue.'}
                 },
                 'required': ['category','impact','urgency','queue','multi_intent','confidence']
               }
             },
             show_details => TRUE) AS resp
    FROM <db>.<schema>.TICKET_CLASSIFICATION c2
    JOIN <db>.<schema>.TICKETS_NORMALIZED n ON n.ticket_id = c2.ticket_id
    WHERE c2.run_id = :run_id AND c2.confidence_band = 'LOW' AND NOT c2.fallback_used
) x
WHERE c.run_id = x.run_id AND c.ticket_id = x.ticket_id;
```

With `show_details => TRUE` and a `response_format`, the docs describe the result as an object whose
`structured_output` key holds the JSON and whose `usage` key holds token counts. Confirm the exact path on one
row before writing the unpack (`SELECT raw_fallback FROM ... LIMIT 1`), then:

```sql
UPDATE <db>.<schema>.TICKET_CLASSIFICATION c
SET parse_ok            = (so.v:queue IS NOT NULL),
    pred_category       = COALESCE(so.v:category::STRING, c.pred_category),
    category_source     = IFF(so.v:category IS NOT NULL, 'AI_COMPLETE', c.category_source),
    pred_impact         = COALESCE(so.v:impact::STRING,  c.pred_impact),
    pred_urgency        = COALESCE(so.v:urgency::STRING, c.pred_urgency),
    pred_queue          = COALESCE(so.v:queue::STRING,   c.pred_queue),
    queue_source        = IFF(so.v:queue IS NOT NULL, 'AI_COMPLETE', COALESCE(c.queue_source, 'ERROR')),
    is_multi_intent     = COALESCE(so.v:multi_intent::BOOLEAN, c.is_multi_intent),
    fallback_confidence = so.v:confidence::NUMBER
FROM (
    SELECT run_id, ticket_id, raw_fallback:structured_output AS v
    FROM <db>.<schema>.TICKET_CLASSIFICATION
    WHERE run_id = :run_id AND fallback_used
) so
WHERE c.run_id = so.run_id AND c.ticket_id = so.ticket_id;

-- Re-derive priority for fallback rows from the matrix (the matrix stays the policy).
UPDATE <db>.<schema>.TICKET_CLASSIFICATION c
SET pred_priority = m.priority, priority_source = 'MATRIX'
FROM <db>.<schema>.PRIORITY_MATRIX m
WHERE c.run_id = :run_id AND c.fallback_used
  AND m.taxonomy_version = c.taxonomy_version
  AND m.impact = c.pred_impact AND m.urgency = c.pred_urgency;

-- Anything still without a queue is explicitly UNCLASSIFIED, never defaulted.
UPDATE <db>.<schema>.TICKET_CLASSIFICATION
SET pred_queue = 'UNCLASSIFIED', queue_source = COALESCE(queue_source, 'NO_MATCH'),
    confidence_band = 'LOW', confidence_basis = 'no queue after fallback'
WHERE run_id = :run_id AND pred_queue IS NULL;
```

Fallback rows keep `confidence_band = 'LOW'`: the fallback resolving a ticket does not make it confident. The
self-reported `fallback_confidence` is stored separately and evaluated for calibration in phase 7.

Gate the fallback separately: count `LOW` rows, estimate with `AI_COUNT_TOKENS('ai_complete', model, prompt)`
on a sample, add that the schema adds billed input not counted by the estimate, and confirm.

---

## Verification before declaring the phase done

```sql
-- 1. Coverage: every normalized ticket classified exactly once in this run.
SELECT (SELECT COUNT(*) FROM <db>.<schema>.TICKETS_NORMALIZED)                              AS tickets,
       (SELECT COUNT(*) FROM <db>.<schema>.TICKET_CLASSIFICATION WHERE run_id = :run_id)   AS classified,
       (SELECT COUNT(*) FROM (SELECT ticket_id FROM <db>.<schema>.TICKET_CLASSIFICATION
                              WHERE run_id = :run_id GROUP BY 1 HAVING COUNT(*) > 1))      AS duplicates;
```

```sql
-- 2. Path and failure accounting (rule 4). Investigate every non-zero error column.
SELECT
    COUNT(*)                                                  AS tickets,
    COUNT_IF(raw_category:error IS NOT NULL)                  AS category_errors,
    COUNT_IF(raw_impact:error IS NOT NULL)                    AS impact_errors,
    COUNT_IF(raw_urgency:error IS NOT NULL)                   AS urgency_errors,
    COUNT_IF(is_multi_intent IS NULL)                         AS multi_intent_null,
    COUNT_IF(fallback_used)                                   AS fallback_rows,
    COUNT_IF(fallback_used AND NOT parse_ok)                  AS fallback_unparsed,
    COUNT_IF(pred_queue = 'UNCLASSIFIED')                     AS unclassified_queue,
    COUNT_IF(confidence_band IS NULL)                         AS null_band          -- must be zero
FROM <db>.<schema>.TICKET_CLASSIFICATION WHERE run_id = :run_id;
```

```sql
-- 3. Predicted queue mix next to historical mix. Large divergence is a question,
--    not automatically an error: history includes mis-routing.
WITH p AS (
  SELECT pred_queue AS queue, COUNT(*) AS predicted FROM <db>.<schema>.TICKET_CLASSIFICATION
  WHERE run_id = :run_id GROUP BY 1),
h AS (
  SELECT <hist_queue_col> AS queue, COUNT(*) AS historical FROM <source_table> GROUP BY 1)
SELECT COALESCE(p.queue, h.queue) AS queue, p.predicted, h.historical
FROM p FULL OUTER JOIN h ON h.queue = p.queue
ORDER BY COALESCE(p.predicted, 0) DESC;

-- Source of each decision.
SELECT queue_source, confidence_band, COUNT(*) FROM <db>.<schema>.TICKET_CLASSIFICATION
WHERE run_id = :run_id GROUP BY 1, 2 ORDER BY 1, 2;
```

```sql
-- 4. Priority distribution. A near-empty P1/P2 on a corpus with known outages
--    is the "asked directly" symptom; check the urgency descriptions.
SELECT pred_priority, priority_source, COUNT(*) FROM <db>.<schema>.TICKET_CLASSIFICATION
WHERE run_id = :run_id GROUP BY 1, 2 ORDER BY 1;
```

```sql
-- 5. Entity extraction health.
SELECT COUNT(*) AS tickets,
       COUNT_IF(NOT extract_ok) AS extract_failed,
       COUNT_IF(product IS NOT NULL) AS with_product,
       COUNT_IF(product_raw IS NOT NULL AND product IS NULL) AS product_not_canonical,
       COUNT_IF(error_code IS NOT NULL) AS with_error_code,
       COUNT_IF(asset_id IS NOT NULL) AS with_asset
FROM <db>.<schema>.TICKET_ENTITIES WHERE run_id = :run_id;
```

```sql
-- 6. Leakage smoke test: classifier input must not contain post-assignment notes.
SELECT COUNT(*) AS leaky_inputs
FROM <db>.<schema>.TICKETS_NORMALIZED
WHERE classify_text ILIKE '%reassigning to%' OR classify_text ILIKE '%workaround applied by%';
-- Expect zero. In the sandbox, a non-zero count means the pre-assignment cut is broken.
```

Then `phases.classify: done`, created tables in `created_objects`, and the run identity recorded. Do **not**
report accuracy here — that is phase 7, against the answer key.
