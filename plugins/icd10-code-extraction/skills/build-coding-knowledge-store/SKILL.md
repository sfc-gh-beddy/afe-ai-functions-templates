---
name: build-coding-knowledge-store
description: "Ground ICD-10 coding decisions in real coding guidance rather than model training data. Default path builds a Cortex Search service over staged CMS coding guidelines, ICD-10 rules, and internal coding materials, chunked with condition and code-range metadata, with a retrieval verification step before it is wired into the coder prompt. Fallback path populates curated clinical-criteria and coder-specificity guideline tables in lockstep for a fixed condition set. Phase 3 of the icd10-extraction build."
parent_skill: icd10-extraction
---

# Build the coding knowledge store

A model asked to assign an ICD-10 code from training data alone will produce a plausible code at the
wrong specificity. That is the single most common reason a coder rejects an otherwise correct suspect:
the condition was right, the code was `I50.9` when the documentation supported `I50.22`.

Grounding fixes this. The coder prompt receives the actual clinical criteria for the condition and the
actual specificity rules for its code family, retrieved at query time.

## Two modes, and how to choose

| | `cortex_search` (default) | `guideline_tables` |
|---|---|---|
| Source | Staged guidance documents | Hand-curated table rows |
| Scales to | Full published rule sets | A fixed condition list |
| Setup effort | Stage and index documents | Author criteria per condition |
| Auditability | Retrieved chunk is the citation | Row is the citation |
| Fails by | Retrieving nothing relevant | A condition missing from one table |

Use `cortex_search` when the organization has coding guidance documents — published CMS guidance,
ICD-10-CM official guidelines, internal coding policy, payer-specific documentation standards. Use
`guideline_tables` when the target list is small and fixed and the criteria are better expressed as
curated rules than retrieved prose.

They are not exclusive. A common shape is curated tables for the priority conditions plus retrieval
for everything else. Record whichever is chosen in `knowledge.mode`.

## Mode A — Cortex Search over coding guidance

### 1. Stage the guidance

```sql
CREATE OR REPLACE STAGE CODING_GUIDANCE
    DIRECTORY = (ENABLE = TRUE)
    ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
```

Server-side encryption matters here — `AI_PARSE_DOCUMENT` requires it for the parse step below.

What belongs in the stage:

- Official ICD-10-CM guidelines for the pinned model year
- CMS risk-adjustment model documentation for that model year
- Internal coding policy and documentation standards
- Payer-specific documentation requirements the organization must meet

What does **not** belong: the answer key, any patient documents, and anything the organization is not
licensed to index. Coding guidance is frequently licensed content — confirm with the customer before
staging third-party material rather than assuming.

### 2. Parse and chunk with metadata that makes retrieval targetable

Chunking is where this succeeds or fails. Chunks need enough context to be useful and enough metadata
to be filterable, because unfiltered semantic retrieval over a whole guideline corpus returns
plausible-but-wrong-condition guidance surprisingly often.

```sql
CREATE OR REPLACE TABLE CODING_GUIDANCE_PARSED AS
SELECT
    RELATIVE_PATH AS source_file,
    -- TO_VARCHAR before PARSE_JSON: the function is documented as returning a
    -- JSON string but returns an OBJECT on some accounts, and PARSE_JSON(OBJECT)
    -- is a compile error. TO_VARCHAR handles both.
    PARSE_JSON(TO_VARCHAR(
        AI_PARSE_DOCUMENT(
            TO_FILE('@CODING_GUIDANCE', RELATIVE_PATH),
            {'mode': 'LAYOUT', 'page_split': TRUE}
        )
    )) AS parsed
FROM DIRECTORY(@CODING_GUIDANCE);
```

`LAYOUT` mode rather than `OCR`, because coding guidance is dense with tables and code ranges, and
`LAYOUT` preserves table structure as Markdown. A code range table flattened into unstructured text is
close to useless for retrieval. Here `page_split` is correct and wanted — every page is genuinely
needed, unlike the routing step where only the first pages mattered.

```sql
CREATE OR REPLACE TABLE CODING_GUIDANCE_CHUNKS AS
WITH pages AS (
    SELECT p.source_file,
           f.value:index::INT    AS page_index,
           f.value:content::STRING AS page_text
    FROM CODING_GUIDANCE_PARSED p,
         LATERAL FLATTEN(input => p.parsed:pages) f
)
SELECT
    SHA2(source_file || '::' || page_index::STRING || '::' || chunk_index::STRING) AS chunk_id,
    source_file,
    page_index,
    chunk_index,
    chunk_text,
    -- Metadata that makes retrieval filterable. MUST stay ARRAY-typed:
    -- the @contains filter operator only works on ARRAY attributes, and
    -- ARRAY_TO_STRING here produces TEXT that the filter rejects at query
    -- time with "@contains can only be used on ARRAY types".
    ARRAY_DISTINCT(
        REGEXP_EXTRACT_ALL(chunk_text, '[A-TV-Z][0-9][0-9AB]\\.[0-9A-Z]{1,4}')) AS icd10_codes_mentioned,
    ARRAY_DISTINCT(
        REGEXP_EXTRACT_ALL(chunk_text, 'HCC[ -]?[0-9]{1,3}'))                   AS hcc_mentioned,
    '<model_year>'                                                             AS model_year
FROM pages,
     LATERAL (
         SELECT INDEX AS chunk_index, VALUE::STRING AS chunk_text
         FROM TABLE(FLATTEN(input =>
             SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(page_text, 'markdown', 1800, 300)))
     );
```

Two notes on the regex, both verified against a live account:

- Snowflake's regex engine **rejects non-capturing groups** — `(?:...)` fails with "no argument for
  repetition operator". The pattern above avoids them.
- Match the **decimal form** (`I50.22`), not the bare category form (`I50`). A bare
  `[A-TV-Z][0-9][0-9AB]` pattern extracts `C85` out of the string `HCC85`, silently poisoning the code
  metadata with codes the chunk never mentioned.

Chunk sizing guidance, which is worth tuning rather than accepting:

- **Around 1,800 characters with 300 overlap** is a reasonable start for guidance prose. The overlap
  matters more than usual here because a criterion and its exception are frequently adjacent, and a
  chunk boundary between them produces retrieval that states a rule without its exception. The same
  effect severs a code list from the condition it belongs to — in testing, one chunk held the ICD-10
  codes while the *next* chunk held the sentence naming the condition they apply to.
- **Do not split a code range table across chunks** if you can avoid it. Check for it.
- Use the `markdown` splitter so `LAYOUT` structure is respected.

### 3. Create the search service

```sql
CREATE OR REPLACE CORTEX SEARCH SERVICE CODING_GUIDANCE_SEARCH
    ON chunk_text
    ATTRIBUTES icd10_codes_mentioned, hcc_mentioned, source_file, model_year
    WAREHOUSE = <warehouse>
    TARGET_LAG = '7 days'
    AS SELECT chunk_id, chunk_text, icd10_codes_mentioned, hcc_mentioned,
              source_file, page_index, model_year
       FROM CODING_GUIDANCE_CHUNKS;
```

`TARGET_LAG` can be long — coding guidance changes on a publication cycle, not continuously. A short
lag here just spends credits refreshing an index over static content.

### 4. Verify retrieval before wiring it into anything

**Do not skip this.** A search service that returns irrelevant chunks produces a coder that is
grounded in noise, which is worse than ungrounded because it looks authoritative. Test against
conditions where the right answer is known:

```sql
WITH r AS (
    SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'CODING_GUIDANCE_SEARCH',
        '{"query": "heart failure documentation requirements systolic versus diastolic specificity",
          "columns": ["chunk_text","source_file","icd10_codes_mentioned"],
          "filter": {"@and": [{"@contains": {"hcc_mentioned": "HCC85"}},
                              {"@eq": {"model_year": "v28"}}]},
          "limit": 4}'
    )):results AS results
)
SELECT f.index AS rank,
       f.value:source_file::STRING           AS source_file,
       f.value:icd10_codes_mentioned         AS codes,
       LEFT(f.value:chunk_text::STRING, 300) AS chunk_preview
FROM r, LATERAL FLATTEN(input => r.results) f;
```

Run one of these per target condition and **read the output**. The questions to answer:

- Does the retrieved guidance actually concern this condition, or a superficially similar one?
- Does it contain specificity rules, or only a code list? A code list without rules does not solve the
  specificity problem, which is the reason this phase exists.
- Is the pinned model year's guidance being retrieved, rather than a superseded year's?
- For a condition with a known documentation requirement, is that requirement present in the chunks?

If retrieval is poor, fix it here rather than compensating in the coder prompt. Usual causes, in order
of likelihood: chunks too small so rules are severed from their context; wrong splitter so tables are
mangled; the guidance genuinely does not cover this condition; or the query phrasing in the coder
prompt does not match the vocabulary of the source documents.

### 5. Materialize retrieval once per condition, not once per patient

**`SEARCH_PREVIEW` requires a literal string constant** for its query argument. A computed expression
— `OBJECT_CONSTRUCT(...)::STRING`, `TO_JSON(OBJECT_CONSTRUCT(...))`, or a column reference — is
rejected at compile time with `unexpected argument [SYSTEM$CORTEX_SEARCH_QUERY]`. This is verified,
and it rules out building a per-row retrieval query inside a set-based `SELECT`.

That constraint pushes the design somewhere better anyway. Coding guidance depends only on the
condition, not on the patient, so retrieve **once per target condition** into a context table and join
that into the coder fan-out:

```sql
CREATE OR REPLACE TABLE GUIDELINE_CONTEXT (
    hcc_code      VARCHAR(10),
    hcc_category  VARCHAR(100),
    guidance_text VARCHAR(16777216),
    source_files  ARRAY,
    model_year    VARCHAR(10),
    retrieved_at  TIMESTAMP_LTZ
);

-- One INSERT per target condition, each with a literal query. With a target
-- list of five to ten conditions this is a short, reviewable block -- and it is
-- a handful of retrievals per run rather than one per patient-condition pair,
-- which is a large cost difference at panel scale.
INSERT INTO GUIDELINE_CONTEXT
WITH r AS (
    SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'CODING_GUIDANCE_SEARCH',
        '{"query": "heart failure diagnostic criteria and ICD-10 coding specificity",
          "columns": ["chunk_text","source_file"],
          "filter": {"@and": [{"@contains": {"hcc_mentioned": "HCC85"}},
                              {"@eq": {"model_year": "v28"}}]},
          "limit": 4}'
    )):results AS results
)
SELECT 'HCC85', 'Congestive Heart Failure',
       ARRAY_TO_STRING(ARRAY_AGG(f.value:chunk_text::STRING), '\n\n---\n\n'),
       ARRAY_DISTINCT(ARRAY_AGG(f.value:source_file::STRING)),
       'v28', CURRENT_TIMESTAMP()
FROM r, LATERAL FLATTEN(input => r.results) f;
```

Phase 5 joins `GUIDELINE_CONTEXT` on `hcc_code`. Verify every target condition produced a row with
non-empty guidance before moving on — a condition with empty `guidance_text` gets coded from training
data alone, which is the exact failure this phase exists to prevent:

```sql
SELECT t.hcc_code,
       g.hcc_code IS NOT NULL          AS has_context,
       LENGTH(g.guidance_text)         AS guidance_chars,
       ARRAY_SIZE(g.source_files)      AS source_count
FROM <target_conditions> t
LEFT JOIN GUIDELINE_CONTEXT g ON g.hcc_code = t.hcc_code
WHERE g.hcc_code IS NULL OR LENGTH(COALESCE(g.guidance_text, '')) < 200;
-- Investigate anything returned.
```

Keep `limit` low. Four good chunks beat twelve mediocre ones: retrieved guidance is charged as input
tokens on every coder call, and diluting the prompt with marginally relevant guidance measurably
degrades reasoning.

## Mode B — Curated guideline tables

Two tables, and **they must be populated in lockstep**. The coder fan-out inner-joins them, so a
condition present in only one table silently disappears from the pipeline entirely — which surfaces
much later as a missing condition and looks like a model failure.

```sql
CREATE OR REPLACE TABLE CLINICAL_CRITERIA (
    hcc_code                    VARCHAR(10),
    hcc_category                VARCHAR(100),
    suspect_criteria            VARCHAR(5000),  -- evidence sufficient to assert
    eval_criteria               VARCHAR(5000),  -- evidence warranting review only
    reject_criteria             VARCHAR(2000),  -- patterns that must NOT be flagged
    documentation_requirements  VARCHAR(3000),  -- what a provider must document
    model_year                  VARCHAR(10)
);

CREATE OR REPLACE TABLE CODER_RULES (
    hcc_code                 VARCHAR(10),
    hcc_category             VARCHAR(100),
    primary_icd10_codes      VARCHAR(2000),
    coding_specificity_rules VARCHAR(3000),
    common_coding_errors     VARCHAR(2000),
    model_year               VARCHAR(10)
);
```

### The three-way criteria split is the important design

Most of the accuracy of the pipeline comes from getting these right:

- **`suspect_criteria`** — evidence sufficient to assert the condition. Objective findings with
  thresholds, not vague description. "Ejection fraction below 40 percent with symptoms" is usable;
  "reduced cardiac function" is not.
- **`eval_criteria`** — evidence that warrants review but does not support asserting the diagnosis.
  This field is what stops the pipeline manufacturing false positives out of genuine uncertainty.
  Omitting it forces every borderline case into a binary it does not fit.
- **`reject_criteria`** — patterns that must **not** be flagged. This is the highest-value field and
  the one most often skipped. It is where precision comes from. Include the alternative explanations
  that actually recur: a finding with a documented non-cardiac cause, a condition documented as
  resolved, medication use without supporting clinical evidence.

`reject_criteria` deserves particular attention because medication-only inference is a classic coding
error. A patient on a diuretic and a beta blocker looks like heart failure to a model and is
frequently neither.

### Verify lockstep population

```sql
-- Any target condition missing from either table can never be surfaced.
SELECT t.hcc_code,
       cc.hcc_code IS NOT NULL AS has_clinical_criteria,
       cr.hcc_code IS NOT NULL AS has_coder_rules
FROM <target_conditions> t
LEFT JOIN CLINICAL_CRITERIA cc ON cc.hcc_code = t.hcc_code AND cc.model_year = '<model_year>'
LEFT JOIN CODER_RULES       cr ON cr.hcc_code = t.hcc_code AND cr.model_year = '<model_year>'
WHERE cc.hcc_code IS NULL OR cr.hcc_code IS NULL;
-- Must be zero rows.
```

```sql
-- reject_criteria is the precision lever. Empty means over-calling is likely.
SELECT hcc_code, hcc_category
FROM CLINICAL_CRITERIA
WHERE reject_criteria IS NULL OR LENGTH(TRIM(reject_criteria)) < 40;
-- Investigate anything returned.
```

```sql
-- eval_criteria absent forces borderline evidence into a binary it does not fit.
SELECT hcc_code, hcc_category
FROM CLINICAL_CRITERIA
WHERE eval_criteria IS NULL OR LENGTH(TRIM(eval_criteria)) < 40;
```

## Pin the model year, and carry it everywhere

RAF factors and HCC numbering change between CMS model years. Both tables and the search chunks carry
`model_year`, every query filters on it, and the value comes from `cms.model_year` in
`icd10-project.yml`. An unpinned knowledge store produces codes that look right and revenue figures
that are wrong, with nothing in the output indicating it.

When guidance for two model years is staged together, the `model_year` attribute is what stops the
coder being handed superseded rules. Verify it is populated on every chunk, not most of them.

## Verification at the gate

Show the user:

1. Which mode was chosen, and why.
2. For `cortex_search`: chunk count, source file count, and the **actual retrieved output** for two
   known conditions — not a claim that retrieval works.
3. For `guideline_tables`: the lockstep check returning zero rows, and the `reject_criteria` and
   `eval_criteria` coverage checks.
4. The pinned model year, and confirmation it is populated on every row or chunk.
5. Any target condition the knowledge store cannot support, stated plainly. That condition will
   produce nothing in Phase 5, and it is far better to know now than to read it as a recall failure
   later.

Then record the service or table names in `created_objects` and set `phases.knowledge: done`.

## Do not put the answer key here

If Phase 1 created a sandbox, its answer key must never be staged, chunked, indexed, or added to a
guideline table. A pipeline that can retrieve its own answers reports meaningless accuracy, and this
is an easy leak to introduce — one over-broad `DIRECTORY` scan or `SELECT *` is enough. Check the
staged file list before indexing.
