---
name: transcribe-and-redact-calls
description: "Phase 2 of the call-center-intelligence build. Turns audio recordings and vendor transcripts into one normalized, speaker-attributed, PII-redacted segment table that every later phase reads. Scopes calls by duration and counts exclusions; transcribes audio with AI_TRANSCRIBE using speaker timestamps where the 60-minute limit allows, with return_error_details so failures are counted rather than lost; normalizes AI_TRANSCRIBE segments, vendor segment exports and full-text blobs to one grain; redacts every segment with AI_REDACT by default, chunked under the 1,024-token output limit with the fail-on-error session parameter disabled and no raw-text fallback; honours an explicit, attributed opt-out; resolves SPEAKER_nn labels to AGENT, CUSTOMER and IVR roles with a schema-constrained AI_COMPLETE call over redacted text; and verifies leakage against planted PII. Use for: transcribe calls, AI_TRANSCRIBE, redact transcripts, AI_REDACT, PII in calls, PCI, speaker diarization, agent vs customer, normalize transcripts."
parent_skill: call-center-intelligence
---

# Transcribe, normalize, redact, and attribute speakers

Output of this phase: **`CALL_SEGMENTS_REDACTED`**, one row per conversational turn, with a role, a
confidence, redacted text, and provenance. Every later phase reads it and nothing else. The order inside
this phase is fixed:

```
scope -> transcribe (audio only) -> normalize -> REDACT -> resolve speaker roles -> verify
```

Roles are resolved **after** redaction because role resolution calls a model, and redaction runs before
any model other than AI_TRANSCRIBE and AI_REDACT sees transcript text.

Read `redaction` and `calls` from `callcenter-project.yml` first. If `redaction.enabled` is `false`,
confirm the three opt-out keys are present; if any is missing, stop and ask.

Object names below are defaults. Use the names recorded in `created_objects` if they differ, and use
`materialization.mode` to emit dbt models or plain SQL (see `../call-center-intelligence/DBT_MATERIALIZATION.md`).

---

## Step 1 — Scope the calls, and count what is excluded

```sql
CREATE OR REPLACE TABLE CALLS_IN_SCOPE AS
SELECT d.<id_col>                AS call_id,
       d.<customer_id_col>       AS customer_id,
       d.<agent_id_col>          AS agent_id,
       d.<queue_col>             AS queue_name,
       d.<start_col>             AS call_start_ts,
       d.<handle_seconds_col>    AS handle_seconds,
       d.<hold_seconds_col>      AS hold_seconds,
       d.<transfer_flag_col>     AS was_transferred,
       d.<disposition_col>       AS disposition_code,
       d.<audio_path_col>        AS recording_path,
       d.<recording_seconds_col> AS recording_seconds,
       CASE
         WHEN d.<recording_seconds_col> < :min_call_seconds          THEN 'EXCLUDED_TOO_SHORT'
         WHEN t.call_id IS NOT NULL                                   THEN 'TRANSCRIPT'
         WHEN d.<audio_path_col> IS NOT NULL                          THEN 'AUDIO'
         ELSE 'EXCLUDED_NO_SOURCE'
       END                       AS source_route,
       CASE
         WHEN t.call_id IS NULL AND d.<recording_seconds_col> > 3600 THEN 'none'     -- best-practices A3
         WHEN t.call_id IS NULL                                       THEN 'speaker'
       END                       AS timestamp_granularity
FROM <metadata_table> d
LEFT JOIN (SELECT DISTINCT <call_id> AS call_id FROM <transcript_table>) t
  ON t.call_id = d.<id_col>
WHERE d.<start_col> >= :window_start;
```

The `TRANSCRIPT` route wins when both exist, so a call is never processed twice in `mixed` mode. If the
customer prefers AI_TRANSCRIBE over their vendor's transcript for quality reasons, invert the precedence
deliberately and record it.

Gate output:

```sql
SELECT source_route, COUNT(*) AS calls,
       ROUND(SUM(recording_seconds) / 3600, 1) AS hours
FROM CALLS_IN_SCOPE GROUP BY 1 ORDER BY 2 DESC;
```

Exclusions are reported, never silently dropped.

## Step 2 — Transcribe audio

Gate first: estimate tokens from duration (50 tokens per second, 10-second minimum per file) and confirm.

```sql
SELECT COUNT(*) AS files,
       SUM(GREATEST(recording_seconds, 10)) * 50 AS est_transcribe_tokens,
       COUNT_IF(timestamp_granularity = 'none') AS without_speaker_timestamps
FROM CALLS_IN_SCOPE WHERE source_route = 'AUDIO'
  AND call_id NOT IN (SELECT call_id FROM TRANSCRIBE_RAW WHERE error IS NULL);   -- only new work
```

Offer a sample first (e.g. 50 calls across queues) before the full run.

```sql
CREATE TABLE IF NOT EXISTS TRANSCRIBE_RAW (
    call_id                VARCHAR,
    recording_path         VARCHAR,
    timestamp_granularity  VARCHAR,
    tx_value               VARIANT,     -- parsed transcription JSON
    error                  VARCHAR,
    run_id                 VARCHAR,
    transcribed_at         TIMESTAMP_LTZ
);

INSERT INTO TRANSCRIBE_RAW
SELECT call_id, recording_path, timestamp_granularity,
       TRY_PARSE_JSON(TO_VARCHAR(r:value)) AS tx_value,
       r:error::STRING                     AS error,
       :run_id, CURRENT_TIMESTAMP()
FROM (
    SELECT c.call_id, c.recording_path, c.timestamp_granularity,
           IFF(c.timestamp_granularity = 'speaker',
               AI_TRANSCRIBE(TO_FILE('@' || :audio_stage, c.recording_path),
                             {'timestamp_granularity': 'speaker'}, TRUE),
               AI_TRANSCRIBE(TO_FILE('@' || :audio_stage, c.recording_path),
                             {}, TRUE)) AS r
    FROM CALLS_IN_SCOPE c
    WHERE c.source_route = 'AUDIO'
      AND NOT EXISTS (SELECT 1 FROM TRANSCRIBE_RAW t
                      WHERE t.call_id = c.call_id AND t.error IS NULL)
);
```

Notes:

- `return_error_details` is the third argument, so an empty options object is passed when no timestamps
  are wanted.
- `TO_FILE('@stage', relative_path)` takes the stage and the stage-relative path separately. A
  `recording_path` that already starts with the stage name double-prefixes and every row errors; check one
  row first.
- `TRANSCRIBE_RAW` holds **unredacted** text. It is PII. Grant it to the pipeline role only. It is kept so
  redaction can be re-run without paying for transcription again; if the customer does not want raw
  transcripts persisted, truncate it after Step 4 succeeds and record that re-redaction then requires
  re-transcription.

Verify:

```sql
SELECT COUNT(*) AS attempted,
       COUNT_IF(error IS NOT NULL)                         AS errored,
       COUNT_IF(error IS NULL AND tx_value IS NULL)        AS unparseable,
       COUNT_IF(error IS NULL AND COALESCE(ARRAY_SIZE(tx_value:segments), 0) = 0
                AND COALESCE(LENGTH(tx_value:text::STRING), 0) < 20) AS near_empty,
       ROUND(SUM(tx_value:audio_duration::FLOAT) / 3600, 2) AS audio_hours
FROM TRANSCRIBE_RAW WHERE run_id = :run_id;

SELECT error, COUNT(*) FROM TRANSCRIBE_RAW WHERE run_id = :run_id AND error IS NOT NULL
GROUP BY 1 ORDER BY 2 DESC LIMIT 10;
```

`near_empty` with no error is the leading-silence and wrong-language signature. Investigate before
continuing; on the sandbox, compare by `variant`.

## Step 3 — Normalize to one segment grain

All three sources land in `CALL_SEGMENTS_RAW` (restricted, unredacted):

```sql
CREATE OR REPLACE TRANSIENT TABLE CALL_SEGMENTS_RAW AS
-- (a) AI_TRANSCRIBE with speaker timestamps
SELECT t.call_id, s.index + 1 AS seq,
       s.value:start::FLOAT AS start_s, s.value:end::FLOAT AS end_s,
       s.value:speaker_label::STRING AS speaker_label,
       NULL::VARCHAR AS vendor_role,
       s.value:text::STRING AS text_raw,
       'AI_TRANSCRIBE' AS source
FROM TRANSCRIBE_RAW t, LATERAL FLATTEN(input => t.tx_value:segments) s
WHERE t.error IS NULL AND t.timestamp_granularity = 'speaker'
QUALIFY ROW_NUMBER() OVER (PARTITION BY t.call_id, s.index ORDER BY t.transcribed_at DESC) = 1

UNION ALL
-- (b) AI_TRANSCRIBE without timestamps: one segment, no speaker
SELECT t.call_id, 1, 0, t.tx_value:audio_duration::FLOAT, NULL, NULL,
       t.tx_value:text::STRING, 'AI_TRANSCRIBE_NO_TS'
FROM TRANSCRIBE_RAW t
WHERE t.error IS NULL AND t.timestamp_granularity = 'none'
QUALIFY ROW_NUMBER() OVER (PARTITION BY t.call_id ORDER BY t.transcribed_at DESC) = 1

UNION ALL
-- (c) vendor segment grain
SELECT v.<call_id>, v.<seq_col>, NULL, NULL, NULL,
       UPPER(v.<speaker_col>), v.<text_col>, 'VENDOR_SEGMENT'
FROM <transcript_table> v
WHERE v.<seq_col> > 0 OR v.<speaker_col> IS NOT NULL

UNION ALL
-- (d) vendor full-text blob with inline "Role: text" markers, split into turns
SELECT v.<call_id>, l.index + 1, NULL, NULL, NULL,
       UPPER(REGEXP_SUBSTR(l.value::STRING, '^\\s*(Agent|Customer|System|Ivr|Rep|Caller)\\s*:', 1, 1, 'ie', 1)),
       TRIM(REGEXP_REPLACE(l.value::STRING, '^\\s*(Agent|Customer|System|Ivr|Rep|Caller)\\s*:\\s*', '', 1, 1, 'i')),
       'VENDOR_FULLTEXT'
FROM <transcript_table> v,
     LATERAL FLATTEN(input => SPLIT(v.<text_col>, '\n')) l
WHERE v.<seq_col> = 0 AND v.<speaker_col> IS NULL
  AND TRIM(l.value::STRING) <> '';
```

Adapt (c) and (d) to the vendor's real shape found at preflight; the marker vocabulary in (d) is an example.
A blob with no recognizable markers yields segments with `NULL` vendor role; those calls are flagged
ineligible for role-dependent outputs in Step 5, not guessed.

Normalize vendor roles: `REP`, `AGENT` -> `AGENT`; `CALLER`, `CUSTOMER` -> `CUSTOMER`; `SYSTEM`, `IVR` ->
`IVR`. Anything else stays `NULL` for Step 5.

Transient because it is reconstructable and PII-bearing; it should not accumulate Time Travel history.

## Step 4 — Redact (default on)

### 4a. Session setup

```sql
-- AI_REDACT fails the whole statement on one bad row by default (best-practices R1).
ALTER SESSION SET AI_SQL_ERROR_HANDLING_USE_FAIL_ON_ERROR = FALSE;
```

Inside a scheduled task, put this statement in the task body (a stored procedure or a multi-statement
task) — an interactive session setting does not carry over.

### 4b. Chunk under the output limit

AI_REDACT allows 4,096 tokens input plus output, and **1,024 output tokens**. Redacted output is about as
long as the input, so the output limit binds. Most segments are one conversational turn and far under it;
long monologues and full-text blobs without markers are not.

```sql
CREATE OR REPLACE TRANSIENT TABLE REDACT_CHUNKS AS
WITH sized AS (
    SELECT r.*,
           -- Cheap pre-filter: only count tokens where a segment could plausibly exceed the target.
           IFF(LENGTH(text_raw) > :chunk_target_tokens * 3,
               AI_COUNT_TOKENS('ai_redact', text_raw), NULL) AS est_tokens
    FROM CALL_SEGMENTS_RAW r
)
SELECT call_id, seq, 0 AS chunk_no, text_raw AS chunk_text
FROM sized
WHERE est_tokens IS NULL OR est_tokens <= :chunk_target_tokens
UNION ALL
SELECT s.call_id, s.seq, c.index AS chunk_no, c.value::STRING AS chunk_text
FROM sized s,
     LATERAL FLATTEN(input => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
         s.text_raw, 'none',
         :chunk_target_tokens * 3,          -- chunk_size is in CHARACTERS; ~3 chars/token is conservative
         0,
         ['. ', ', ', ' '])) c
WHERE s.est_tokens > :chunk_target_tokens;
```

Overlap is `0` deliberately: overlapping chunks would duplicate text when reassembled. The cost is that a
value split across a chunk boundary (rare at sentence separators) may escape detection; the leak check
below is what catches it.

### 4c. Redact, with status and no raw fallback

```sql
CREATE TABLE IF NOT EXISTS REDACT_RESULTS (
    call_id VARCHAR, seq INT, chunk_no INT,
    redacted_text VARCHAR, redaction_error VARCHAR,
    input_chars INT, output_chars INT,
    run_id VARCHAR, redacted_at TIMESTAMP_LTZ
);

INSERT INTO REDACT_RESULTS
SELECT call_id, seq, chunk_no,
       r:value::STRING, r:error::STRING,
       LENGTH(chunk_text), LENGTH(r:value::STRING),
       :run_id, CURRENT_TIMESTAMP()
FROM (
    SELECT c.*,
           AI_REDACT(c.chunk_text, :categories_or_null, TRUE) AS r
    FROM REDACT_CHUNKS c
    WHERE NOT EXISTS (SELECT 1 FROM REDACT_RESULTS x
                      WHERE x.call_id = c.call_id AND x.seq = c.seq AND x.chunk_no = c.chunk_no
                        AND x.redaction_error IS NULL AND x.redacted_text IS NOT NULL)
);
```

When `redaction.categories` is null, prefer the named form `AI_REDACT(input => c.chunk_text,
return_error_details => TRUE)`, which the documentation defines as "all supported categories". The
positional form with a `NULL` categories argument compiles, but the documentation does not say that `NULL`
means "all"; if you use it, verify on one row containing a known name and phone number before the batch.

Estimate first and gate: `SUM(AI_COUNT_TOKENS('ai_redact', chunk_text))` over a sample, reported as
a floor — billed AI_REDACT tokens include the generated text (documented), so the bill is roughly double
the input estimate.

### 4d. Truncation guard

Whether over-length output errors or truncates is not stated precisely. Flag any chunk whose output is much
shorter than its input:

```sql
SELECT COUNT(*) AS suspicious_short
FROM REDACT_RESULTS
WHERE run_id = :run_id AND redacted_text IS NOT NULL
  AND output_chars < input_chars * 0.6;
```

Placeholders like `[PAYMENT_CARD_DATA]` are usually longer than the value they replace, so a real redaction
rarely shortens a chunk by 40 percent. Inspect any hits (redacted text only) and re-chunk smaller.

### 4e. Assemble `CALL_SEGMENTS_REDACTED` (pre-role)

```sql
CREATE OR REPLACE TABLE CALL_SEGMENTS_REDACTED_STAGE AS
WITH latest AS (
    -- Latest attempt per chunk, so a successful retry supersedes a failure.
    SELECT * FROM REDACT_RESULTS
    QUALIFY ROW_NUMBER() OVER (PARTITION BY call_id, seq, chunk_no ORDER BY redacted_at DESC) = 1
),
expected AS (
    SELECT call_id, seq, COUNT(*) AS expected_chunks FROM REDACT_CHUNKS GROUP BY 1, 2
),
chunks AS (
    SELECT l.call_id, l.seq,
           LISTAGG(l.redacted_text, ' ') WITHIN GROUP (ORDER BY l.chunk_no) AS text_redacted,
           COUNT(*)                                                        AS chunks,
           COUNT_IF(l.redacted_text IS NULL)
             + MAX(e.expected_chunks) - COUNT(*)                           AS failed_chunks
    FROM latest l
    JOIN expected e ON e.call_id = l.call_id AND e.seq = l.seq
    GROUP BY l.call_id, l.seq
)
SELECT r.call_id, r.seq, r.start_s, r.end_s, r.speaker_label, r.vendor_role, r.source,
       IFF(ch.failed_chunks = 0, ch.text_redacted, NULL)               AS text_redacted,
       CASE WHEN ch.call_id IS NULL     THEN 'MISSING'
            WHEN ch.failed_chunks > 0   THEN 'FAILED'
            ELSE 'REDACTED' END                                         AS redaction_status
FROM CALL_SEGMENTS_RAW r
LEFT JOIN chunks ch ON ch.call_id = r.call_id AND ch.seq = r.seq;
```

`failed_chunks` also counts chunks that were never attempted, so a partially redacted segment cannot
assemble into something that looks complete.

A segment with any failed chunk is `NULL`, never raw (best-practices R3). Downstream phases filter on
`redaction_status = 'REDACTED'` and count the rest.

### 4f. Opt-out path

When `redaction.enabled` is `false`, skip 4b–4d and set
`text_redacted = text_raw, redaction_status = 'OPTED_OUT'`. Name the column the same so downstream SQL is
unchanged, but every report reads `redaction_status` and prints the opt-out in its header.

## Step 5 — Resolve speaker roles

Vendor roles are taken as given when present (validate a sample in Phase 6). For `AI_TRANSCRIBE` segments
and unmarked blobs, resolve per call with one structured call over the first turns, using **redacted** text:

```sql
CREATE OR REPLACE TABLE SPEAKER_ROLE_MAP AS
WITH opening AS (
    SELECT call_id,
           LISTAGG('[' || seq || '] ' || COALESCE(speaker_label, 'UNLABELED') || ': '
                   || LEFT(text_redacted, 400), '\n') WITHIN GROUP (ORDER BY seq) AS opening_text,
           ARRAY_AGG(DISTINCT speaker_label)                                          AS labels
    FROM CALL_SEGMENTS_REDACTED_STAGE
    WHERE source = 'AI_TRANSCRIBE' AND redaction_status = 'REDACTED' AND seq <= 12
    GROUP BY call_id
),
prompted AS (
    SELECT call_id, labels,
           'You are labeling speakers in a customer service phone call transcript. '
        || 'Speaker labels such as SPEAKER_00 were assigned in order of first detection and do not indicate role. '
        || 'Bracketed tokens like [NAME] are redaction placeholders. '
        || 'For each speaker label, decide whether it is the AGENT (company representative), the CUSTOMER (caller), '
        || 'or IVR (recorded system prompt). A call can have more than one AGENT after a transfer. '
        || 'Use UNKNOWN only when the opening gives no basis to decide. Respond in JSON.\n\nOpening turns:\n'
        || opening_text AS prompt
    FROM opening
)
SELECT call_id, labels, SHA2(prompt) AS prompt_hash,
       AI_COMPLETE(
         model => :signal_reasoner_model,
         prompt => prompt,
         model_parameters => {'temperature': 0, 'max_tokens': 600},
         response_format => {
           'type': 'json',
           'schema': {
             'type': 'object',
             'properties': {
               'speakers': {'type': 'array', 'items': {
                 'type': 'object',
                 'properties': {
                   'speaker_label': {'type': 'string'},
                   'role':          {'type': 'string', 'enum': ['AGENT', 'CUSTOMER', 'IVR', 'UNKNOWN']},
                   'confidence':    {'type': 'number', 'description': 'Between 0 and 1'},
                   'basis':         {'type': 'string', 'description': 'Short reason, e.g. greets on behalf of company'}
                 },
                 'required': ['speaker_label', 'role', 'confidence']
               }}
             },
             'required': ['speakers']
           }
         },
         show_details => TRUE
       ) AS resp,
       :run_id AS run_id
FROM prompted;
```

Then apply:

```sql
CREATE OR REPLACE TABLE CALL_SEGMENTS_REDACTED AS
WITH mapped AS (
    SELECT m.call_id, sp.value:speaker_label::STRING AS speaker_label,
           sp.value:role::STRING AS role,
           LEAST(GREATEST(sp.value:confidence::FLOAT, 0), 1) AS confidence
    FROM SPEAKER_ROLE_MAP m,
         LATERAL FLATTEN(input => m.resp:structured_output[0]:raw_message:speakers) sp
)
SELECT s.call_id, s.seq, s.start_s, s.end_s, s.speaker_label, s.source,
       COALESCE(CASE s.vendor_role WHEN 'REP' THEN 'AGENT' WHEN 'AGENT' THEN 'AGENT'
                                   WHEN 'CALLER' THEN 'CUSTOMER' WHEN 'CUSTOMER' THEN 'CUSTOMER'
                                   WHEN 'SYSTEM' THEN 'IVR' WHEN 'IVR' THEN 'IVR' END,
                m.role, 'UNKNOWN')                                   AS speaker_role,
       IFF(s.vendor_role IS NOT NULL, 1.0, COALESCE(m.confidence, 0)) AS role_confidence,
       IFF(s.vendor_role IS NOT NULL, 'VENDOR', IFF(m.role IS NOT NULL, 'MODEL', 'NONE')) AS role_source,
       s.text_redacted,
       s.redaction_status,
       :run_id AS run_id
FROM CALL_SEGMENTS_REDACTED_STAGE s
LEFT JOIN mapped m ON m.call_id = s.call_id AND m.speaker_label = s.speaker_label;
```

Check the response path on the first row: with `show_details => TRUE` and a schema, the parsed object is at
`resp:structured_output[0]:raw_message`. If that path is `NULL` on a non-null response, inspect the
response shape before running the batch rather than assuming the call failed.

Call-level eligibility, used by Phases 4 and 5:

```sql
CREATE OR REPLACE VIEW CALL_ELIGIBILITY AS
SELECT call_id,
       COUNT(*)                                             AS segments,
       COUNT_IF(redaction_status NOT IN ('REDACTED','OPTED_OUT')) AS unredacted_segments,
       COUNT_IF(speaker_role = 'AGENT')                     AS agent_segments,
       COUNT_IF(speaker_role = 'CUSTOMER')                  AS customer_segments,
       COUNT_IF(speaker_role = 'UNKNOWN')                   AS unknown_segments,
       MIN(role_confidence)                                 AS min_role_confidence,
       unredacted_segments = 0                              AS text_eligible,
       unredacted_segments = 0 AND agent_segments > 0 AND customer_segments > 0
         AND unknown_segments = 0 AND MIN(role_confidence) >= :min_role_confidence AS role_eligible  -- definitions.min_role_confidence
FROM CALL_SEGMENTS_REDACTED
GROUP BY call_id;
```

A view is fine here: it calls no model.

## Step 6 — Verify at the gate

```sql
-- Coverage: from scope to usable segments.
SELECT c.source_route,
       COUNT(DISTINCT c.call_id)                                           AS calls,
       COUNT(DISTINCT s.call_id)                                           AS with_segments,
       COUNT(DISTINCT IFF(e.text_eligible, e.call_id, NULL))               AS text_eligible,
       COUNT(DISTINCT IFF(e.role_eligible, e.call_id, NULL))               AS role_eligible
FROM CALLS_IN_SCOPE c
LEFT JOIN CALL_SEGMENTS_REDACTED s ON s.call_id = c.call_id
LEFT JOIN CALL_ELIGIBILITY e        ON e.call_id = c.call_id
GROUP BY 1;

-- Redaction status.
SELECT redaction_status, COUNT(*) FROM CALL_SEGMENTS_REDACTED GROUP BY 1;

-- Role mix and confidence.
SELECT role_source, speaker_role, COUNT(*), ROUND(AVG(role_confidence), 2)
FROM CALL_SEGMENTS_REDACTED GROUP BY 1, 2 ORDER BY 1, 2;
```

On the sandbox, also run the leak check (planted values found in redacted text). This query reads the eval
schema and is the one place in this phase where that is allowed, because it is a verification, not a
pipeline step:

```sql
SELECT pk.category, pk.form,
       COUNT(*) AS planted,
       COUNT_IF(CONTAINS(LOWER(s.text_redacted), LOWER(pk.planted_value))
                OR (pk.planted_digits IS NOT NULL
                    AND CONTAINS(REGEXP_REPLACE(s.text_redacted, '[^0-9]', ''), pk.planted_digits))) AS leaked
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_PII pk
JOIN CALL_SEGMENTS_REDACTED s
  ON s.call_id = pk.call_id AND s.source LIKE 'VENDOR%' AND s.seq = pk.seq
WHERE s.redaction_status = 'REDACTED'
GROUP BY 1, 2 ORDER BY leaked DESC;
```

For AI_TRANSCRIBE calls, segment numbers do not align with the source, so Phase 6 matches on the whole call.
Report any leak as a finding, by category and form. Do not proceed to Phase 3 with leaks on
`PAYMENT_CARD_DATA` or `NATIONAL_ID` without the user acknowledging them explicitly.

Then: `phases.transcribe_redact: done`, record `TRANSCRIBE_RAW`, `CALL_SEGMENTS_RAW`, `REDACT_CHUNKS`,
`REDACT_RESULTS`, `CALL_SEGMENTS_REDACTED_STAGE`, `SPEAKER_ROLE_MAP`, `CALL_SEGMENTS_REDACTED`,
`CALL_ELIGIBILITY`, `CALLS_IN_SCOPE` in `created_objects`.

## Grants

Apply the decisions recorded at preflight:

- `TRANSCRIBE_RAW`, `CALL_SEGMENTS_RAW`, `REDACT_CHUNKS`: pipeline role only.
- `CALL_SEGMENTS_REDACTED`: pipeline role and analysts who need to read conversations.
- The Cortex Agent in Phase 7 never gets access to raw tables.

## Idempotency

Transcription and redaction are the two most expensive steps and both are keyed so a retry does only new
work: `TRANSCRIBE_RAW` skips calls already transcribed without error; `REDACT_RESULTS` skips chunks already
redacted. Re-running normalization and assembly is free of model calls.
