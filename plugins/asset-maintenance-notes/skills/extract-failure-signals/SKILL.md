---
name: extract-failure-signals
description: "Phase 3 of the asset-maintenance-notes build. Turns work order notes, technician free text and inspection reports into normalized maintenance signals: asset-scoped deduplication, AI_CLASSIFY triage to exit boilerplate and admin text before the expensive call, then AI_COMPLETE with a per-asset-class JSON schema whose enums come from the pinned taxonomy -- component, assembly, failure mode (observed effect), polarity (OBSERVED / RULED_OUT / ACTION_ONLY / UNCLEAR), severity, measured value, cause, action, and a verbatim evidence span verified against the source. Handles file-based inspections via AI_PARSE_DOCUMENT or AI_EXTRACT first, segments long logs instead of truncating, logs errors and parse failures, and exposes MAINT_SIGNALS_OBSERVED as the only view downstream may read. Use for failure mode extraction, component extraction, failure code cleanup, or reading technician notes."
parent_skill: asset-maintenance-notes
---

# Extract failure signals

This phase produces the table everything else is built on. Its contract:

- one row per **signal** (a component finding), not per note -- a note can have several;
- every row has a polarity, and only `OBSERVED` rows count as failures downstream;
- every row cites a verbatim `evidence_span` that is checked against the source text;
- every component and failure-mode code is from the pinned taxonomy for the asset's class, or
  `OTHER`;
- every row carries `run_id`, `experiment_id`, `prompt_version`, `prompt_hash`, `taxonomy_version`,
  `taxonomy_hash` and `extract_model`.

`sql/10_triage_and_extract.sql` is the runnable implementation for plain-SQL mode, written against
the sandbox tables. For dbt mode, split it into the models listed in `DBT_MATERIALIZATION.md`.

## Prerequisites

- `phases.taxonomy: done`, with `TAX_CLASS_CONTEXT` populated for `taxonomy.version`.
- `models.extract` pinned and verified at preflight.
- `experiment.*` set; a fresh `run_id`.

## Pipeline

```
MAINT_SOURCE_TEXT        unified notes + inspections; asset from the record; note-level timestamp
   |  asset-scoped MD5 of normalized text
MAINT_SOURCE_DISTINCT    one representative per (asset, text) -- billed once
   |  AI_CLASSIFY
MAINT_TRIAGE             MAINTENANCE_FINDING | ADMIN_ONLY | CLOSEOUT_BOILERPLATE
   |  prompt assembled once per row (hashed), class enums attached
MAINT_SIGNAL_RAW         full AI_COMPLETE response with value/error and usage
   |  FLATTEN, validate, fan out to every source with the same hash
MAINT_SIGNALS            one row per signal per source
   |  polarity = OBSERVED AND evidence found AND codes valid
MAINT_SIGNALS_OBSERVED   the only view clustering, precursors, the semantic view and the agent read
```

## Step 1. Gate: estimate before running

Run on a sample first (`SET sample_limit = 500`), then the full corpus only after the user has seen
the sample output and the measured cost.

The estimate has two parts, and the second is the larger one for maintenance text:

```sql
-- (a) note text, as AI_COUNT_TOKENS sees it
SELECT COUNT(*) AS distinct_texts,
       SUM(AI_COUNT_TOKENS('ai_complete', $extract_model, source_text)) AS text_tokens
FROM MAINT_SOURCE_DISTINCT;

-- (b) measured per-call overhead: instructions + taxonomy + glossary + schema.
--     Run step 5 on five representative rows, then read billed prompt tokens.
SELECT AVG(response:value:usage:prompt_tokens::INT)     AS avg_prompt_tokens_per_call,
       AVG(response:value:usage:completion_tokens::INT) AS avg_completion_tokens_per_call
FROM MAINT_SIGNAL_RAW
WHERE run_id = $run_id;
```

Present: distinct texts x (average billed prompt tokens per call) as the input-token floor for the
full run, plus completion tokens on top. While building this plugin, a one-line note estimated at 36
tokens by `AI_COUNT_TOKENS` billed 750 prompt tokens once the structured-output schema was attached
(best-practices rule 33). Do not present the note-text sum alone.

Report the triage exit share from the sample too: each exited note avoids one whole call.

## Step 2. Deduplicate before anything is billed

`MAINT_SOURCE_DISTINCT` keeps one row per `MD5(asset_id || '::' || normalized_text)`. Show:

```sql
SELECT (SELECT COUNT(*) FROM MAINT_SOURCE_TEXT)     AS sources,
       (SELECT COUNT(*) FROM MAINT_SOURCE_DISTINCT) AS distinct_texts;
```

The hash is asset-scoped on purpose (best-practices rule 18). Fleet-wide dedup of "replaced filter
per PM" would attribute one extraction to one asset and silently drop the rest.

## Step 3. Triage

`AI_CLASSIFY` with three described categories. Two rules govern it:

- **A failed or null triage is not an exit.** The prompt step uses
  `COALESCE(triage_label, 'MAINTENANCE_FINDING')`, so an error sends the note to extraction rather
  than dropping it.
- **Triage false negatives cap recall.** On the sandbox, measure how many labeled sources with
  `OBSERVED` signals were exited:

```sql
SELECT COUNT(DISTINCT k.source_id) AS observed_sources_exited_by_triage
FROM <EVAL_SCHEMA>.ANSWER_KEY_SIGNALS k
JOIN MAINT_SOURCE_TEXT s ON s.source_type = k.source_type AND s.source_id = k.source_id
JOIN MAINT_TRIAGE t ON t.text_hash = s.text_hash AND t.run_id = $run_id
WHERE k.polarity = 'OBSERVED' AND t.triage_label <> 'MAINTENANCE_FINDING';
```

(This query reads the answer key, so it belongs to the evaluation phase; run it from the harness,
not from the pipeline.) If it is non-zero, add the customer's own phrasing to the
`MAINTENANCE_FINDING` description, or drop triage for that source type.

Do not add many categories to triage to "pre-classify" failure modes. Triage is a cheap gate, not
the extractor; classification accuracy falls as categories grow, and the extractor does that job
with the full taxonomy and polarity rules.

## Step 4. The prompt

Assembled once per row in `TMP_EXTRACT_PROMPTS.prompt`, hashed with `SHA2(prompt, 256)` from the same
column, and bound into `AI_COMPLETE` from that column. Its parts, in order:

1. role and context: source type, asset class, work-order type (context, not a rule);
2. the eight rules -- empty array allowed; polarity definitions with examples; replacement is not
   failure; failure mode is effect, not cause or action; component from the class list, `OTHER`
   with mention; verbatim evidence; cause and action only when stated; use the glossary;
3. the class component list with assemblies and synonyms, from `TAX_CLASS_CONTEXT.component_text`;
4. failure-mode definitions from `mode_text`;
5. glossary from `glossary_text`;
6. the text, fenced with `<<<` `>>>`;
7. "Respond in JSON."

Tune the polarity examples to the customer's checklist wording during the production pilot (for
example "Sat/Unsat", "Pass/Fail", "Y/N", "Nil"). Every wording change bumps `prompt_version`.

### Polarity is decided in context, not by keyword

Do not "help" the model with a SQL pre-pass that strips negations or flags "no " phrases. "No leaks
at seal, but DE brg running warm" contains a negation and a finding; keyword rules get one of them
wrong. The schema carries one polarity per signal so the model handles each finding separately.

## Step 5. The call

```sql
AI_COMPLETE(
    model            => $extract_model,
    prompt           => p.prompt,
    model_parameters => {'temperature': 0, 'max_tokens': 2048},
    response_format  => OBJECT_CONSTRUCT('type', 'json', 'schema', ...),   -- enums from p.component_enum, p.mode_enum
    show_details         => TRUE,
    return_error_details => TRUE
)
```

The schema is built **per row** with `OBJECT_CONSTRUCT`, using the class's `component_enum` and the
`mode_enum` arrays from `TAX_CLASS_CONTEXT`. Verified while building this plugin: a per-row
`response_format` with a column-sourced `enum` executes and returns schema-conforming output, with
the shape

```json
{"value": {"structured_output": [{"raw_message": {"signals": [...]}, "type": "json"}],
           "usage": {"prompt_tokens": ..., "completion_tokens": ..., "total_tokens": ...}},
 "error": null}
```

Read signals at `response:value:structured_output[0]:raw_message:signals`. Test errors with
`response:error::STRING IS NOT NULL` -- `"error": null` is a JSON null and `response:error IS NULL`
is FALSE for it.

Schema rules that will error if violated: no `minItems`, `maxItems`, `minimum`, `maximum`,
`minLength`, `maxLength`, `format`; property names letters, digits, hyphen, underscore only.

### Batching short notes (optional, measure first)

Because per-call overhead dominates, batching several short notes of the same asset class into one
call can cut input tokens substantially. If you do it:

- the schema becomes `{'results': [{'source_ref': ..., 'signals': [...]}]}` with `source_ref` an
  enum of the batch's text hashes (or short ids you supply), `required`;
- the prompt fences each note with its `source_ref`;
- validate that every `source_ref` in the batch came back exactly once, and that no evidence span is
  attributed to a different note's text -- cross-note bleed is the batching failure mode;
- evaluate batched and unbatched as separate experiments before switching.

## Step 6. Long texts: segment, never truncate

`TMP_EXTRACT_PROMPTS.text_tokens` flags texts over `extraction.max_input_tokens`. Split them on entry
or paragraph boundaries, extract each segment, and union signals under the same `source_id`:

```sql
CREATE OR REPLACE TEMPORARY TABLE TMP_SEGMENTS AS
WITH lines AS (
    SELECT d.text_hash, d.source_type, d.source_id, d.asset_class, d.wo_type,
           s.index AS line_no, s.value::STRING AS line_text,
           AI_COUNT_TOKENS('ai_complete', $extract_model, s.value::STRING) AS line_tokens
    FROM MAINT_SOURCE_DISTINCT d,
         LATERAL FLATTEN(input => SPLIT(d.source_text, '\n')) s
    WHERE AI_COUNT_TOKENS('ai_complete', $extract_model, d.source_text) > $max_input_tokens
), running AS (
    SELECT *, SUM(line_tokens) OVER (PARTITION BY text_hash ORDER BY line_no) AS cum_tokens
    FROM lines
)
SELECT text_hash, source_type, source_id, asset_class, wo_type,
       FLOOR(cum_tokens / ($max_input_tokens * 0.8)) AS segment_no,
       LISTAGG(line_text, '\n') WITHIN GROUP (ORDER BY line_no) AS segment_text
FROM running
GROUP BY 1, 2, 3, 4, 5, 6;
```

Feed `segment_text` through the same prompt and call; carry `segment_no` into `MAINT_SIGNAL_RAW`.
Record the number of segmented sources in the quality log.

## Step 7. Files (inspection PDFs, scans, photos)

Two steps, never one multimodal call -- the prompt-object form of `AI_COMPLETE` (the one that accepts
files) has no `response_format`, so it would lose the taxonomy enums and polarity contract:

```sql
-- 7a. File to text. LAYOUT keeps checklist tables as markdown, which keeps "Casing leaks | N" together.
SELECT relative_path,
       PARSE_JSON(TO_VARCHAR(AI_PARSE_DOCUMENT(
           TO_FILE('@<stage>', relative_path), {'mode': 'LAYOUT'}))):content::STRING AS report_text
FROM DIRECTORY(@<stage>);
```

```sql
-- 7b. Optional: standard form fields that must be verbatim (readings, part numbers).
--     AI_EXTRACT returns {"error": ..., "response": {...}} -- read :response.
SELECT relative_path,
       AI_EXTRACT(
           file => TO_FILE('@<stage>', relative_path),
           responseFormat => {
               'asset_tag':       'What is the asset tag or equipment number on the form?',
               'inspection_date': 'What is the inspection date?',
               'vibration_reading':'What vibration reading is recorded, with units?',
               'temperature_reading':'What temperature reading is recorded, with units?'
           }
       ):response AS form_fields
FROM DIRECTORY(@<stage>);
```

Then the parsed `report_text` enters `MAINT_SOURCE_TEXT` as `source_type = 'INSPECTION_FILE'`, with
`asset_id` from the inspection record that references the file -- not from the `asset_tag` read off
the form (best-practices rule 16). A mismatch between the two is worth reporting as a data-quality
finding, not resolving silently.

Stages used by AI functions must not use `SNOWFLAKE_FULL` encryption, and user or table stages are
not supported.

## Step 8. Validation and fan-out

`MAINT_SIGNALS` is populated by flattening each response and joining back to **every**
`MAINT_SOURCE_TEXT` row with the same `text_hash`. Each row is checked:

| Column | Check | Failure means |
|---|---|---|
| `evidence_found_in_source` | normalized span is contained in normalized source text | paraphrase (soft) or hallucinated span (hard) |
| `component_in_taxonomy` | code exists for this class and version | the enum was not applied, or the class mapping is wrong |
| `mode_in_taxonomy` | code exists for this version | same |

Rows failing any check stay in `MAINT_SIGNALS` (inspectable), and are excluded by the
`MAINT_SIGNALS_OBSERVED` view. With the enum schema, the taxonomy checks should always pass; a
non-zero count means the schema did not reach the call.

## Gate verification

Show these results, from the run:

```sql
-- Quality log for this run.
SELECT stage, metric, value FROM PIPELINE_QUALITY_LOG WHERE run_id = $run_id ORDER BY 1, 2;

-- Polarity mix by source type: inspections should be mostly RULED_OUT, PM mostly ACTION_ONLY.
SELECT source_type, COALESCE(wo_type, '-') AS wo_type, polarity, COUNT(*) AS signals
FROM MAINT_SIGNALS WHERE run_id = $run_id
GROUP BY 1, 2, 3 ORDER BY 1, 2, 4 DESC;

-- Top observed component x failure mode per class.
SELECT asset_class, component_code, failure_mode_code, COUNT(*) AS signals
FROM MAINT_SIGNALS_OBSERVED WHERE run_id = $run_id
GROUP BY 1, 2, 3
QUALIFY ROW_NUMBER() OVER (PARTITION BY asset_class ORDER BY COUNT(*) DESC) <= 5
ORDER BY 1, 4 DESC;

-- Agreement with the CMMS failure code (comparison, not accuracy).
SELECT w.failure_code, s.failure_mode_code, COUNT(*) AS signals
FROM MAINT_SIGNALS_OBSERVED s
JOIN <work_orders> w ON w.wo_id = s.wo_id
WHERE s.run_id = $run_id AND w.wo_type IN ('CM', 'EMERGENCY')
GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 20;
```

Must be zero or explained: `errored`, `unparseable`, `evidence_not_found`,
`component_not_in_taxonomy`, `mode_not_in_taxonomy`. Show `component_other` as a share and, if high,
route to the taxonomy gap review.

Show three sample signals with their evidence spans only if the user asks, and prefer sandbox rows.

Record created tables, `phases.extract: done`, and leave `experiment.run_id` in place for the
evaluation phase to read.

## Scheduling

This script uses a temporary table and session variables, which is right for an interactive build
and wrong for a scheduled task (best-practices rule 38). For continuous operation use the dynamic
tables in `operationalize-maintenance-intelligence`, after evaluation has passed.
