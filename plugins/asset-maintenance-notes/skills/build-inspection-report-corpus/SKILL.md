---
name: build-inspection-report-corpus
description: "Optional Phase 1b. Render the synthetic inspection reports into real files on a Snowflake stage -- typed PDF checklist forms, and degraded scanned-image versions -- so the file path of the extraction pipeline (AI_PARSE_DOCUMENT layout/OCR to text, AI_EXTRACT for checklist fields, then taxonomy-constrained AI_COMPLETE) is exercised rather than simulated. Use when the customer's inspection reports, condition surveys, or field service reports arrive as PDFs, photos or scans rather than text columns. Synthetic data only; never renders customer text locally. Part of the asset-maintenance-notes build."
parent_skill: asset-maintenance-notes
---

# Build an inspection report file corpus

Text in a table cannot test the file path. If preflight found inspections stored as files
(`sources.inspections.file_col` set), run this phase so the parse, checklist and extraction steps
actually execute against PDFs and images with the same labels as the text sandbox.

## Hard rule: synthetic only

The renderer runs on the local machine. It must only ever receive rows from `SYNTH_INSPECTION_REPORTS`
in the sandbox schema. Never export customer inspection text, photos or forms to the local machine
to render, convert or "clean" them -- customer files are processed in place on their stage. Refuse
and explain if asked.

## What it produces

For each synthetic inspection report:

| Variant | File | What it exercises |
|---|---|---|
| `typed` | `<report_id>_typed.pdf` | text-layer PDF; `AI_PARSE_DOCUMENT` in `LAYOUT` mode returns clean text and table structure |
| `scan_clean` | `<report_id>_scan_clean.png` | image at 200 DPI equivalent; OCR path |
| `scan_degraded` | `<report_id>_scan_degraded.png` | rotation, noise, contrast loss, JPEG artefacts; OCR robustness |

Checklist lines ("Casing leaks: N") are rendered as a two-column table with tick boxes, because that
is the layout real inspection forms use and the one where negation is easiest to lose: a parser that
flattens the table can separate "Casing leaks" from its "N".

A manifest (`manifest.csv`: `report_id, variant, relative_path`) maps every file back to the
`report_id` in the answer key, so the harness grades file-derived signals against the same labels.

## Steps

### 1. Export the synthetic inspections (sandbox only)

```bash
snow sql -q "SELECT report_id, asset_id, inspection_ts, report_text
             FROM <DB>.<SANDBOX_SCHEMA>.SYNTH_INSPECTION_REPORTS
             ORDER BY report_id" --format csv > /tmp/synth_inspections.csv
```

Confirm the schema in the command is the sandbox schema before running it.

### 2. Render

```bash
python3 scripts/render_inspections.py \
    --input /tmp/synth_inspections.csv \
    --out /tmp/inspection_corpus \
    --variants typed,scan_clean,scan_degraded \
    --limit 300
```

Dependencies: `reportlab` (PDF) and `Pillow` (image variants). The script exits with a clear
message if either is missing. `--limit` keeps the file count proportional; 300 reports covers every
template several times.

### 3. Stage

Create a stage with server-side encryption. AI functions do not read files from stages with
`SNOWFLAKE_FULL` encryption, user stages, table stages, or stages with double-quoted names.

```sql
CREATE STAGE IF NOT EXISTS <DB>.<SANDBOX_SCHEMA>.INSPECTION_FILES
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE');
```

```bash
snow stage copy /tmp/inspection_corpus "@<DB>.<SANDBOX_SCHEMA>.INSPECTION_FILES" --recursive
```

```sql
ALTER STAGE <DB>.<SANDBOX_SCHEMA>.INSPECTION_FILES REFRESH;

CREATE OR REPLACE TABLE <DB>.<SANDBOX_SCHEMA>.SYNTH_INSPECTION_FILES AS
SELECT SPLIT_PART(relative_path, '_', 1) AS report_id_guess,
       relative_path, size, last_modified
FROM DIRECTORY(@<DB>.<SANDBOX_SCHEMA>.INSPECTION_FILES);
```

Prefer loading `manifest.csv` into a table and joining on `relative_path` over parsing ids out of
file names; the line above is only a sanity check.

### 4. Gate verification

```sql
-- File count matches the manifest.
SELECT COUNT(*) FROM DIRECTORY(@<DB>.<SANDBOX_SCHEMA>.INSPECTION_FILES);

-- Parse one file per variant. Read whether the checklist answers (Y/N, OK) survived next to their
-- labels -- not just whether text came back.
SELECT relative_path,
       PARSE_JSON(TO_VARCHAR(AI_PARSE_DOCUMENT(
           TO_FILE('@<DB>.<SANDBOX_SCHEMA>.INSPECTION_FILES', relative_path),
           {'mode': 'LAYOUT'}))):content::STRING AS parsed
FROM DIRECTORY(@<DB>.<SANDBOX_SCHEMA>.INSPECTION_FILES)
WHERE relative_path ILIKE '%_typed.pdf' OR relative_path ILIKE '%_scan_degraded.png'
LIMIT 4;
```

`PARSE_JSON(TO_VARCHAR(...))` is deliberate: the return type has been observed as either a JSON
string or an OBJECT depending on account, and `PARSE_JSON` on an OBJECT is a compile error. The
wrapper works either way.

Show the user one parsed checklist and point at the negation: if "Casing leaks" and "N" are on
different lines or in different cells with no association, the extraction prompt for the file path
must be told the content is a two-column checklist.

## How the file path is extracted downstream

`extract-failure-signals` handles files in two steps, never one:

1. `AI_PARSE_DOCUMENT(..., {'mode': 'LAYOUT'})` to text (markdown tables preserved), or
   `AI_EXTRACT(file => ..., responseFormat => ...)` for named checklist fields when the form is
   standard.
2. The resulting text goes through the same taxonomy-constrained `AI_COMPLETE` call as notes.

A single multimodal `AI_COMPLETE` call on the file cannot carry the taxonomy `response_format`
schema (structured output is supported only for the single-string prompt form), so it would lose
the enum constraint and the polarity contract.

## Record and finish

Add the stage and `SYNTH_INSPECTION_FILES` to `created_objects`, set
`sources.inspections.file_col` / `stage` for the sandbox run, and `phases.corpus: done`.
