---
name: build-call-test-corpus
description: "Render the sandbox's synthetic call transcripts into real audio files on a Snowflake stage so the AI_TRANSCRIBE path, speaker diarization, role resolution, and the audio-to-redaction hand-off are genuinely exercised rather than simulated. Produces WAV files with distinct synthetic voices per role and graded conditions (clean, telephony 8 kHz, noisy, 8 seconds of leading silence to test the 5-second language-detection rule, stereo channel-split to test the documented mono downmix), a render manifest for per-condition accuracy, and a stage with a directory table. Also covers using a customer's own small set of consented test recordings and why public audio corpora rarely fit. Phase 1b of the call-center-intelligence build; needed whenever input_mode is audio or mixed."
parent_skill: call-center-intelligence
---

# Build a call audio test corpus

Decided for this play: the test corpus supports **both** transcript text and audio. The sandbox
(`seed-call-center-sandbox`) produces transcript text plus an audio-only subset of calls that have no
vendor transcript. This skill turns those calls into audio, so the audio path runs end to end.

A text-only sandbox cannot test the things most likely to go wrong in an audio build:

- AI_TRANSCRIBE returning `NULL` per row on files it cannot process;
- `SPEAKER_00` being the IVR or the customer rather than the agent;
- leading silence defeating language detection;
- stereo recordings losing their channel separation;
- spoken numbers coming back transcribed in a form redaction does not catch.

## When you need this

- `calls.input_mode` is `audio` or `mixed`: required.
- `calls.input_mode` is `transcript`: skip, and mark `phases.corpus: skipped`.

## The design — labels from the sandbox, voices from TTS

Audio is rendered from `{{EVAL_SCHEMA}}.SYNTH_TRUE_SEGMENTS`, so every file has a known transcript, known
speaker roles per segment, and known planted PII. Each role gets a different synthetic voice so
diarization has distinct speakers to separate. That gives ground truth for:

- transcription quality (word error rate against the source text);
- diarization and role resolution (true role per segment);
- redaction after transcription (planted PII, including how a spoken card number comes back).

Be honest about the limit: TTS audio is cleaner and more regular than real customer speech. It exercises
the plumbing and the failure modes; it does **not** predict word error rate on the customer's real calls.
Say that whenever a transcription metric from this corpus is shown.

## Conditions are graded, assigned per call

The script assigns each call one variant deterministically (hash of `call_id`), roughly one fifth each:

| Variant | What it tests |
|---|---|
| `clean` | baseline |
| `telephony` | 8 kHz band-limited PSTN audio, the normal case for a contact center |
| `noisy` | telephony plus background noise |
| `lead_silence` | 8 seconds of silence before speech. The documentation says language detection requires speech within the first five seconds; this variant measures what happens when it does not |
| `stereo_split` | agent on the left channel, customer on the right. AI_TRANSCRIBE converts to mono internally, so this measures whether roles survive without channel information |

The variant is written to `render_manifest.csv`, uploaded alongside the audio and loaded into a table, so
Phase 6 can report every metric by variant. A flat metric across variants is fine; a collapse on one
variant is the finding.

## Render

Prerequisites: `ffmpeg`/`ffprobe`, and either macOS `say` or `espeak-ng`. The script renders synthetic
sandbox rows only. Never point it at a real transcript export; it writes text-derived audio to local disk.

1. Export the manifest for audio-only calls (synthetic data; local export is acceptable for the
   sandbox only):

   ```bash
   snow sql -c <connection> --format csv -q "
     SELECT call_id, recording_path, audio_only, seq, true_role, text
     FROM {{DB}}.{{EVAL_SCHEMA}}.SYNTH_AUDIO_RENDER_MANIFEST
     WHERE audio_only
     ORDER BY call_id, seq" > /tmp/cci_render_manifest.csv
   ```

2. Create the stage. Server-side encryption and a directory table:

   ```sql
   CREATE STAGE IF NOT EXISTS {{DB}}.{{SCHEMA}}.SYNTH_CALL_AUDIO
     ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
     DIRECTORY = (ENABLE = TRUE);
   ```

   Server-side encryption matters: AI functions that read staged files expect it on internal stages. Do
   not create the stage with client-side encryption.

3. Render a small batch first and listen to two files before rendering everything:

   ```bash
   python3 scripts/render_call_audio.py \
     --manifest /tmp/cci_render_manifest.csv \
     --out-dir /tmp/cci_audio --only-audio-only --limit 5
   ```

4. Render all, and upload:

   ```bash
   python3 scripts/render_call_audio.py \
     --manifest /tmp/cci_render_manifest.csv \
     --out-dir /tmp/cci_audio --only-audio-only \
     --stage {{DB}}.{{SCHEMA}}.SYNTH_CALL_AUDIO --upload --connection <connection>
   ```

   Without `--upload` the script prints the `PUT` statements instead.

5. Refresh the directory table and load the render manifest:

   ```sql
   ALTER STAGE {{DB}}.{{SCHEMA}}.SYNTH_CALL_AUDIO REFRESH;

   CREATE OR REPLACE TABLE {{DB}}.{{EVAL_SCHEMA}}.SYNTH_AUDIO_RENDER_RESULTS (
       call_id VARCHAR, recording_path VARCHAR, variant VARCHAR,
       rendered_seconds FLOAT, status VARCHAR, error VARCHAR);

   COPY INTO {{DB}}.{{EVAL_SCHEMA}}.SYNTH_AUDIO_RENDER_RESULTS
   FROM @{{DB}}.{{SCHEMA}}.SYNTH_CALL_AUDIO/manifest/render_manifest.csv
   FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"');
   ```

   The results table goes in the eval schema because `variant` lets you infer the stereo calls, which is
   a test condition the pipeline should discover on its own.

6. Point the pipeline at the stage: set `calls.audio_stage` to the stage and `calls.audio_path_col` to
   `RECORDING_PATH` in `callcenter-project.yml`.

7. Clean up local files: `rm -rf /tmp/cci_audio /tmp/cci_render_manifest.csv`.

## Validate that the corpus actually exercises the audio path

```sql
-- 1. Every audio-only call has a file; no stray files.
SELECT COUNT_IF(f.relative_path IS NULL)  AS calls_missing_file,
       COUNT_IF(d.call_id IS NULL)        AS files_without_call
FROM (SELECT call_id, recording_path FROM {{SCHEMA}}.SYNTH_CALL_DETAIL_RECORDS WHERE audio_only) d
FULL OUTER JOIN (SELECT relative_path FROM DIRECTORY(@{{SCHEMA}}.SYNTH_CALL_AUDIO)
                 WHERE relative_path ILIKE '%.wav') f
  ON f.relative_path = d.recording_path;
-- Expect 0 and 0.
```

```sql
-- 2. Variant mix.
SELECT variant, status, COUNT(*), ROUND(AVG(rendered_seconds), 1) AS avg_s
FROM {{EVAL_SCHEMA}}.SYNTH_AUDIO_RENDER_RESULTS GROUP BY 1, 2 ORDER BY 1;
```

```sql
-- 3. Smoke test: one file per variant, with error details, speaker timestamps.
--    Read the result for (a) a non-null value, (b) more than one speaker label,
--    (c) whether a spoken card number came back as words or digits.
WITH pick AS (
    SELECT variant, MIN(recording_path) AS recording_path
    FROM {{EVAL_SCHEMA}}.SYNTH_AUDIO_RENDER_RESULTS
    WHERE status = 'ok' GROUP BY 1
)
SELECT variant,
       r:error::STRING                                                AS error,
       TRY_PARSE_JSON(TO_VARCHAR(r:value)):audio_duration::FLOAT       AS audio_seconds,
       ARRAY_SIZE(TRY_PARSE_JSON(TO_VARCHAR(r:value)):segments)        AS segments,
       (SELECT COUNT(DISTINCT s.value:speaker_label)
        FROM LATERAL FLATTEN(input => TRY_PARSE_JSON(TO_VARCHAR(r:value)):segments) s) AS speakers
FROM (
    SELECT variant,
           AI_TRANSCRIBE(TO_FILE('@{{SCHEMA}}.SYNTH_CALL_AUDIO', recording_path),
                         {'timestamp_granularity': 'speaker'}, TRUE) AS r
    FROM pick
);
```

Show the result. If `lead_silence` returns empty or wrong-language text, that is a real finding to carry
into preflight for the customer's recordings.

## Cost before rendering everything

Rendering is local and free; transcription is not. Estimate from the render results before Phase 2:

```sql
SELECT SUM(GREATEST(rendered_seconds, 10)) * 50 AS est_transcribe_tokens,
       COUNT(*)                                 AS files
FROM {{EVAL_SCHEMA}}.SYNTH_AUDIO_RENDER_RESULTS WHERE status = 'ok';
```

50 tokens per second of audio, 10-second minimum per file, from the AI_TRANSCRIBE documentation. Report
tokens.

## Using customer recordings instead of, or alongside, TTS

The strongest audio test set is 20 to 50 of the customer's **own** recordings, chosen to span their
queues, with consent for this use, plus a human-checked transcript for each. Only the customer can provide
that. If they do:

- keep the files on a customer-controlled stage in their account; never copy them out;
- record the human transcript as ground truth in the eval schema;
- report transcription and role metrics separately for TTS and real audio.

Public speech corpora are a poor fit: most are read speech or meetings rather than two-party service
calls, carry no contact-reason or QA labels, and have licensing terms that must be checked before use.
Recommend against them unless the customer has a specific reason.

## What this does not fix

TTS cannot reproduce accents, crosstalk, emotional speech, or a customer reading a card number fast with
corrections. Treat accuracy here as a lower bound on what can go wrong in plumbing, not an estimate of
real-world transcription quality.

Set `phases.corpus: done` and record the stage and both tables in `created_objects`.
