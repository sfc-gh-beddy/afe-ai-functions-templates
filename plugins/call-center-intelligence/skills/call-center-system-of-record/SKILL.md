---
name: call-center-system-of-record
description: "Preflight discovery for a call-center-intelligence build. Establishes what the account can run and what already exists before anything is created: Cortex AI function access via EXPLAIN_PRIVILEGES for AI_TRANSCRIBE, AI_REDACT, AI_SENTIMENT, AI_CLASSIFY, AI_EXTRACT, AI_COMPLETE and AI_COUNT_TOKENS; model lifecycle and region via SHOW CORTEX BASE MODELS; AI_TRANSCRIBE regional availability and CORTEX_ENABLED_CROSS_REGION; the audio stage and transcript table inventory; call metadata mapping and population; duration distribution that drives transcription tokens; stereo versus mono recordings; whether a vendor already redacts; human QA scores available for calibration; existing objects; and PII/PCI posture including stage grants and masking policies. Always loaded first by the call-center-intelligence router."
parent_skill: call-center-intelligence
---

# Preflight — what this account can run, and what is already here

Run before creating anything. It prevents four bad outcomes: building on a function or model the account
cannot call, mapping the wrong customer or agent column, promising a transcription cost the duration
profile will not deliver, and creating a scored table full of PII-derived text without a decision about
who reads it.

Report a compact summary, write settled values into `callcenter-project.yml`, create nothing. Every query
here returns counts or metadata. Do not select transcript text or play audio during preflight.

---

## 1. Cortex AI function access

`EXPLAIN_PRIVILEGES` analyzes without executing — no model calls, no credits.

```sql
SELECT
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_TRANSCRIBE(TO_FILE('@~/x.wav'))$$,               missing_only => true) AS ai_transcribe,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_REDACT('x')$$,                                     missing_only => true) AS ai_redact,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_SENTIMENT('x')$$,                                  missing_only => true) AS ai_sentiment,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_CLASSIFY('x', ['a','b'])$$,                        missing_only => true) AS ai_classify,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_EXTRACT(text => 'x', responseFormat => {'k':'q'})$$, missing_only => true) AS ai_extract,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COMPLETE('llama3.1-8b', 'x')$$,                    missing_only => true) AS ai_complete,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COUNT_TOKENS('ai_redact', 'x')$$,                  missing_only => true) AS ai_count_tokens;
```

| Function | Needed for | If unavailable |
|---|---|---|
| `AI_TRANSCRIBE` | audio input mode | hard stop for audio; transcript-only mode still works |
| `AI_REDACT` | default redaction | **stop and escalate.** Redaction is on by default for this play; do not proceed without it unless the customer records an explicit opt-out |
| `AI_CLASSIFY` | contact reasons | hard stop |
| `AI_COMPLETE` | speaker roles, QA scoring | hard stop for QA; reasons still work |
| `AI_SENTIMENT` | sentiment trajectory | degrade: omit sentiment, say so |
| `AI_EXTRACT` | save and upsell signals | degrade to AI_COMPLETE with a schema |
| `AI_COUNT_TOKENS` | estimates, redaction chunking | not a blocker for estimates; **is** a blocker for token-based chunking, fall back to a conservative character window and say so |

Remediation — surface it, do not work around it:

```sql
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <role>;
```

If the check itself errors, note access was not verified and continue; it is best-effort.

## 2. Region, cross-region, and AI_TRANSCRIBE availability

```sql
SELECT CURRENT_REGION() AS region, CURRENT_ACCOUNT() AS account;
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
```

AI_TRANSCRIBE is documented as available in a short list of regions (AWS US West 2, AWS US East 1, AWS EU
Central 1, Azure East US 2 at time of writing — re-check the function page, it changes). If the account is
elsewhere and the corpus includes audio:

- with `CORTEX_ENABLED_CROSS_REGION` set to an allowed value, transcription runs in another region. State
  that this moves audio processing across regions and that it is a data-residency decision for the
  customer's privacy or compliance owner;
- with it `DISABLED`, audio mode is unavailable. Offer transcript mode if vendor transcripts exist.

Never change this parameter in this plugin. Report it and let the account administrator decide.

## 3. Models — lifecycle and region

Only AI_COMPLETE stages pick a model (speaker role resolution, QA judge, and optionally signal reasoning).
The task-specific functions (AI_TRANSCRIBE, AI_REDACT, AI_SENTIMENT, AI_CLASSIFY, AI_EXTRACT) choose their
own models.

```sql
SHOW CORTEX BASE MODELS;

SELECT "name", "lifecycle_status", "legacy_date", "eol_date"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "lifecycle_status" = 'GA'
ORDER BY "name";
```

Do not pin a model whose `lifecycle_status` is `LEGACY`, `EOL` or blank. Pin into `models` with
`verified_on` set to today's date.

| Stage | Wants | Why |
|---|---|---|
| `qa_judge` | strong, GA | rubric reasoning with evidence citation is where QA quality lives |
| `signal_reasoner` | small to mid, GA | role resolution and fallback extraction are simple, run on every call |

Do not silently substitute. If the preferred model is unavailable, say which is used instead and why.

## 4. Find the calls

Look for candidates rather than asking for a fully qualified name.

```sql
SELECT table_catalog, table_schema, table_name, row_count,
       ROUND(bytes / POWER(1024, 3), 2) AS gb, last_altered
FROM information_schema.tables
WHERE table_type = 'BASE TABLE'
  AND (table_name ILIKE '%CALL%'       OR table_name ILIKE '%TRANSCRIPT%'
    OR table_name ILIKE '%CONTACT%'    OR table_name ILIKE '%INTERACTION%'
    OR table_name ILIKE '%CDR%'        OR table_name ILIKE '%CONVERSATION%'
    OR table_name ILIKE '%UTTERANCE%'  OR table_name ILIKE '%RECORDING%'
    OR table_name ILIKE '%QA%'         OR table_name ILIKE '%EVALUATION%')
ORDER BY row_count DESC NULLS LAST
LIMIT 40;
```

Repo-shared discovery for free-text columns: `shared/sql/discover_unstructured.sql`.

Audio:

```sql
SHOW STAGES;
-- For each candidate stage (directory table enabled is ideal):
SELECT COUNT(*) AS files,
       ROUND(SUM(size) / POWER(1024, 3), 2) AS gb,
       COUNT_IF(REGEXP_LIKE(relative_path, '.*\\.(wav|mp3|m4a|flac|ogg|webm|aac|mp4)$', 'i')) AS audio_files,
       MAX(size) AS max_bytes
FROM DIRECTORY(@<stage>);
```

If the directory table is not enabled, `LIST @<stage> PATTERN = '.*\\.(wav|mp3|m4a|flac|ogg|webm)'` gives
the same inventory. Files over 700 MB are reported as untranscribable as-is.

Set `calls.input_mode`: `audio` if only recordings exist, `transcript` if only text, `mixed` if both
(for example, a vendor transcribes one line of business and not another). In `mixed`, record which calls
come from which source; the same call must not be processed from both.

## 5. Map the metadata

Map columns into `calls` in the state file and confirm with the user. Required: call id, customer id, agent
id, start timestamp. Strongly wanted: handle seconds, hold seconds, transfer flag, queue, disposition. The
worst failure here is a wrong `customer_id_col`: repeat-contact detection then runs perfectly across the
wrong people.

```sql
SELECT
  COUNT(*)                                       AS calls,
  COUNT(DISTINCT <id_col>)                        AS distinct_call_ids,
  ROUND(100.0 * COUNT(<customer_id_col>)  / NULLIF(COUNT(*),0), 1) AS pct_customer_id,
  ROUND(100.0 * COUNT(<agent_id_col>)     / NULLIF(COUNT(*),0), 1) AS pct_agent_id,
  ROUND(100.0 * COUNT(<handle_seconds_col>) / NULLIF(COUNT(*),0), 1) AS pct_handle,
  ROUND(100.0 * COUNT(<transfer_flag_col>)  / NULLIF(COUNT(*),0), 1) AS pct_transfer,
  ROUND(100.0 * COUNT(<disposition_col>)    / NULLIF(COUNT(*),0), 1) AS pct_disposition,
  COUNT(DISTINCT <disposition_col>)               AS distinct_dispositions,
  MIN(<start_col>) AS first_call, MAX(<start_col>) AS last_call
FROM <metadata_table>;
```

- `distinct_call_ids < calls` means legs or duplicates: set `calls.leg_col` or plan dedup.
- `pct_customer_id` low means repeat-contact detection is limited to identified callers. Say so; the
  repeat rate will be a floor.
- A disposition distribution dominated by one or two generic codes is itself a finding for the readout.

```sql
SELECT <disposition_col>, COUNT(*) AS calls,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM <metadata_table>
GROUP BY 1 ORDER BY 2 DESC LIMIT 30;
```

## 6. Duration profile — this is the transcription bill

```sql
SELECT
  COUNT(*)                                                    AS calls,
  ROUND(SUM(<duration_seconds>) / 3600, 1)                    AS audio_hours,
  COUNT_IF(<duration_seconds> < 10)                           AS under_10s,
  COUNT_IF(<duration_seconds> < :min_call_seconds)            AS under_min,
  COUNT_IF(<duration_seconds> > 3600)                         AS over_60m,
  COUNT_IF(<duration_seconds> > 7200)                         AS over_120m,
  APPROX_PERCENTILE(<duration_seconds>, 0.5)                  AS p50_s,
  APPROX_PERCENTILE(<duration_seconds>, 0.9)                  AS p90_s,
  -- AI_TRANSCRIBE: 50 tokens/second, 10-second minimum per file.
  SUM(GREATEST(<duration_seconds>, 10)) * 50                  AS est_transcribe_tokens
FROM <metadata_table>
WHERE <start_col> >= DATEADD(day, -30, CURRENT_DATE());
```

Use recording duration if the metadata has it; otherwise handle seconds plus hold is a rough proxy and
must be labeled as one. Report:

- monthly audio hours and estimated transcription tokens (tokens, never currency);
- how many calls fall under the minimum and will be excluded;
- how many exceed 60 minutes and cannot use speaker timestamps (best-practices A3).

## 7. Channel layout and leading silence

Ask the customer, because it cannot be read reliably from metadata:

- Are recordings **stereo with agent and customer on separate channels**? If yes,
  `audio_channel_layout: stereo_split`, and discuss splitting channels upstream (best-practices A4).
- Do recordings begin with IVR prompts, music or silence? If yes, flag the 5-second language detection
  constraint and test on the sandbox corpus before the real run.
- Is recording paused during payment capture? Record the answer; it changes PCI exposure.

## 8. Transcripts — grain, speaker labels, vendor redaction

```sql
SELECT
  COUNT(DISTINCT <call_id>)                                   AS calls_with_text,
  COUNT(*)                                                    AS rows,
  ROUND(COUNT(*) / NULLIF(COUNT(DISTINCT <call_id>),0), 1)    AS rows_per_call,
  COUNT(DISTINCT <speaker_col>)                               AS distinct_speaker_values,
  ROUND(100.0 * COUNT(<speaker_col>) / NULLIF(COUNT(*),0), 1) AS pct_speaker_labeled,
  ROUND(AVG(LENGTH(<text_col>)), 0)                           AS avg_chars_per_row
FROM <transcript_table>;

SELECT <speaker_col>, COUNT(*) FROM <transcript_table> GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
```

`rows_per_call` near 1 means full-text grain (`transcript_grain: full_text`). Speaker values like
`AGENT`/`CUSTOMER` mean the vendor separated channels and roles come free.

Vendor redaction: do not take "the vendor redacts" on faith. Count without reading text:

```sql
SELECT
  COUNT(*)                                                         AS rows,
  COUNT_IF(REGEXP_LIKE(<text_col>, '.*\\d{4}[ -]?\\d{4}[ -]?\\d{4}[ -]?\\d{4}.*')) AS card_like_digit_runs,
  COUNT_IF(REGEXP_LIKE(<text_col>, '.*\\d{3}[ -.]?\\d{3}[ -.]?\\d{4}.*'))          AS phone_like_digit_runs,
  COUNT_IF(REGEXP_LIKE(<text_col>, '.*(\\[|<|\\*{3,}|#{3,}).*'))                      AS rows_with_mask_markers
FROM <transcript_table> SAMPLE (10000 ROWS);
```

Non-zero digit-run counts mean raw numbers are present: `transcript_vendor_redacted: false`, regardless
of what anyone believes. Masking markers with zero digit runs is evidence (not proof) of upstream
redaction. Spoken numbers ("four one one one") are not caught by this check; AI_REDACT still runs by
default.

If the customer wants to opt out of AI_REDACT because of vendor redaction, record the opt-out with the
three required keys and the result of this check in `opt_out_reason`.

## 9. Language mix

```sql
SELECT <language_col>, COUNT(*) FROM <metadata_table> GROUP BY 1 ORDER BY 2 DESC;
```

If no language column exists, say the mix is unknown until transcription. AI_SENTIMENT supports a
narrower language set than AI_TRANSCRIBE, and AI_CLASSIFY and AI_REDACT work best in English. A
materially non-English corpus changes what this pipeline can promise.

## 10. Human QA scores and outcome data

Look for existing QA evaluations, retention outcomes and orders:

```sql
SELECT table_schema, table_name, row_count
FROM information_schema.tables
WHERE table_name ILIKE '%QA%' OR table_name ILIKE '%SCORECARD%' OR table_name ILIKE '%EVALUATION%'
   OR table_name ILIKE '%CANCEL%' OR table_name ILIKE '%CHURN%' OR table_name ILIKE '%RETENTION%'
   OR table_name ILIKE '%ORDER%'  OR table_name ILIKE '%SUBSCRIPTION%'
ORDER BY row_count DESC NULLS LAST LIMIT 30;
```

- Human QA scores with call ids are the calibration set for Phase 6. Record `qa.human_qa_table` and the
  form's criteria; if the customer's form differs from the generic rubric, that is the trigger for a
  rubric override.
- Cancellation and order tables let the value readout use **observed** save and conversion rates rather
  than assumed ones. Without them, those rates are customer-supplied inputs and are labeled as such.

## 11. Existing pipeline objects

```sql
SELECT table_schema, table_name, row_count, created
FROM information_schema.tables
WHERE table_name ILIKE '%SEGMENT%' OR table_name ILIKE '%REDACT%'
   OR table_name ILIKE '%CONTACT_REASON%' OR table_name ILIKE '%QA_SCORE%'
ORDER BY created DESC;
SHOW SEMANTIC VIEWS;
SHOW AGENTS;
SHOW TASKS;
```

Surface anything found with row count and creation date, and ask: reuse, rename, or replace.

## 12. PII and PCI posture

```sql
SELECT policy_name, policy_kind, ref_entity_name, ref_column_name
FROM TABLE(information_schema.policy_references(
    ref_entity_name => '<fully_qualified_transcript_or_metadata_table>',
    ref_entity_domain => 'TABLE'));

SHOW GRANTS ON TABLE <fully_qualified_transcript_table>;
SHOW GRANTS ON STAGE <fully_qualified_audio_stage>;
```

Report:

- masking and row access policies on the sources, and whether the redacted outputs should carry
  equivalent policies (agent-level QA scores are HR-sensitive even with no customer PII in them);
- who can read the audio stage. Redaction does not touch audio;
- which roles should read QA scores (supervisors, QA team) versus contact reasons (operations, product)
  versus raw segments (ideally no one beyond the pipeline role, and only if `keep_raw_segments` is true).

Do not create policies here. Surface the gaps, record decisions, and honour them when tables are created.

## 13. Warehouse

```sql
SHOW WAREHOUSES LIKE '<candidate>';
```

AI function throughput is dominated by the inference service; a small or medium warehouse with a short
auto-suspend is usually right. Note if the chosen one is far larger.

## 14. Business definitions

Ask once and record in `definitions`: the repeat-contact window, whether a repeat must share the reason,
what counts as an escalation, and the minimum call length. These change headline numbers and must be the
customer's definitions, not defaults chosen silently.

---

## Output of this phase

A short summary: functions available, region and cross-region status, models pinned, input mode, call
volume and audio hours per month with estimated transcription tokens, metadata mapping and population,
channel layout, transcript grain and vendor-redaction evidence, language mix, calibration and outcome data
available, existing objects, PII/PCI posture, and the business definitions. Then the settled values written
into `callcenter-project.yml`, `redaction` confirmed (default on, or an attributed opt-out), and
`phases.preflight: done`. Anything unresolved stays absent.
