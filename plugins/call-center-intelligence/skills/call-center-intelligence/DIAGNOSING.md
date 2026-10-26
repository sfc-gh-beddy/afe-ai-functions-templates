# Diagnosing a call pipeline that is not producing what you expect

Work these in order. The first four look identical from a dashboard: fewer calls than expected, or numbers that
seem too clean.

## 1. Calls are missing — where did they drop out?

**Symptom:** reason counts sum to fewer calls than the CDR shows; QA covers a small share.

Walk the funnel from scope to facts:

```sql
SELECT 'in metadata window' AS step, COUNT(*) FROM <metadata_table> WHERE <start_col> >= :window_start
UNION ALL SELECT 'in scope (not excluded)', COUNT(*) FROM CALLS_IN_SCOPE WHERE source_route NOT LIKE 'EXCLUDED%'
UNION ALL SELECT 'excluded: too short', COUNT(*) FROM CALLS_IN_SCOPE WHERE source_route = 'EXCLUDED_TOO_SHORT'
UNION ALL SELECT 'excluded: no source', COUNT(*) FROM CALLS_IN_SCOPE WHERE source_route = 'EXCLUDED_NO_SOURCE'
UNION ALL SELECT 'audio transcribed ok', COUNT(*) FROM TRANSCRIBE_RAW WHERE error IS NULL
UNION ALL SELECT 'audio errored', COUNT(*) FROM TRANSCRIBE_RAW WHERE error IS NOT NULL
UNION ALL SELECT 'text eligible', COUNT_IF(text_eligible) FROM CALL_ELIGIBILITY
UNION ALL SELECT 'role eligible', COUNT_IF(role_eligible) FROM CALL_ELIGIBILITY
UNION ALL SELECT 'with reason', COUNT(DISTINCT call_id) FROM CALL_REASONS WHERE run_id = :run_id AND primary_reason IS NOT NULL
UNION ALL SELECT 'with QA score', COUNT(*) FROM QA_CALL_SCORES WHERE run_id = :run_id AND criteria_scored > 0;
```

The step with the big drop is the problem. Common causes:

- **`EXCLUDED_NO_SOURCE` is large:** `recording_path` does not resolve, or the metadata-to-transcript join key
  differs in type or format (`CALL-123` vs `123`).
- **Audio errors:** see section 2.
- **Text eligible far below in scope:** redaction failures (section 3).
- **Role eligible far below text eligible:** role resolution (section 4).

## 2. AI_TRANSCRIBE errors or empty transcripts

```sql
SELECT error, COUNT(*) FROM TRANSCRIBE_RAW WHERE error IS NOT NULL GROUP BY 1 ORDER BY 2 DESC LIMIT 10;

SELECT COUNT(*) AS near_empty
FROM TRANSCRIBE_RAW
WHERE error IS NULL
  AND COALESCE(ARRAY_SIZE(tx_value:segments), 0) = 0
  AND COALESCE(LENGTH(tx_value:text::STRING), 0) < 20;
```

| Pattern | Likely cause | Fix |
|---|---|---|
| every row errors | wrong stage reference or path double-prefixed in `TO_FILE` | test `TO_FILE('@stage', path)` on one row |
| errors on long calls only | over 60 minutes with speaker timestamps | route over-60-minute calls without timestamps (best-practices A3) |
| errors on large files | over 700 MB | downsample or split upstream |
| near-empty, no error | leading silence or IVR music beyond five seconds; unsupported language | trim leading silence upstream; check language mix |
| all `NULL`, no error column | `return_error_details` not passed | add it; re-run only failed rows |
| `tx_value` null, error null | parsed a non-string with `PARSE_JSON` | use `TRY_PARSE_JSON(TO_VARCHAR(...))` (best-practices A2) |
| region error | AI_TRANSCRIBE not available in region and cross-region disabled | preflight section 2; customer decision |

## 3. Redaction failures, or PII still visible

**Whole statement errored:** `AI_SQL_ERROR_HANDLING_USE_FAIL_ON_ERROR` is still `TRUE` in the session that ran it.
In a task, it must be set on the task or inside the procedure body (best-practices R1, O5).

```sql
SHOW PARAMETERS LIKE 'AI_SQL_ERROR_HANDLING_USE_FAIL_ON_ERROR' IN SESSION;
```

**Many `FAILED` segments:**

```sql
SELECT LEFT(redaction_error, 120) AS err, COUNT(*), ROUND(AVG(input_chars)) AS avg_chars
FROM REDACT_RESULTS WHERE redaction_error IS NOT NULL GROUP BY 1 ORDER BY 2 DESC;
```

Errors concentrated on long inputs mean chunks are too large for the 1,024-token output limit. Lower
`redaction.chunk_target_tokens` and re-chunk.

**PII visible after redaction:** run the Phase 6 leak check. Then:

- spoken numbers ("four one one one ...") not caught: not documented as supported; report as a finding. Options:
  recording pause during payment (upstream), or a deterministic pre-pass that converts spoken digit runs to digits
  before AI_REDACT, measured on the sandbox before adoption;
- a value split across a chunk boundary: chunk on sentence separators, re-measure;
- leak in a derived column but not in segments: a model reconstructed it; tighten the prompt and re-measure.

**Someone used `COALESCE(redacted, raw)`:** search the pipeline SQL for it. It converts every failure into a leak
(best-practices R3).

## 4. Roles are wrong — QA scores look like they are scoring the customer

**Symptom:** low empathy scores on calls where the customer was rude; agent sentiment looks like customer sentiment.

```sql
SELECT role_source, speaker_role, COUNT(*), ROUND(AVG(role_confidence), 2)
FROM CALL_SEGMENTS_REDACTED GROUP BY 1, 2 ORDER BY 1, 2;

-- Calls where more than one label maps to CUSTOMER and none to AGENT, or vice versa.
SELECT call_id
FROM CALL_SEGMENTS_REDACTED
GROUP BY call_id
HAVING COUNT_IF(speaker_role = 'AGENT') = 0 OR COUNT_IF(speaker_role = 'CUSTOMER') = 0;
```

Causes:

- `SPEAKER_00` hard-coded as agent somewhere (best-practices A5). Search for it.
- IVR prompt detected as a speaker and labeled AGENT. The role prompt must list IVR as an option.
- Stereo recordings downmixed to mono lost the channel signal (A4). On the sandbox, compare `stereo_split` against
  `clean` in Phase 6.
- Full-text vendor blobs without markers: these should be `UNKNOWN` and role-ineligible, not guessed.

## 5. Everything is `Other`, or one reason dominates

```sql
SELECT primary_reason, COUNT(*), ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM CALL_REASONS WHERE run_id = :run_id GROUP BY 1 ORDER BY 2 DESC;
```

- **High `Other`:** the opening window is too short (customers explain after verification), or the taxonomy is
  missing a real reason. Mine `Other` with AI_AGG (classify Step 4) and widen the window; measure on the sandbox.
- **One label dominates:** a description that is too broad ("General inquiry" swallowing everything). Tighten it; check
  the confusion matrix in Phase 6.
- **Labels in output that are not in the taxonomy:** impossible with AI_CLASSIFY's fixed categories unless the
  category array was hand-typed and drifted from the table. Build it from `CONTACT_TAXONOMY` (best-practices C2).
- **Case mismatch:** AI_CLASSIFY categories are case-sensitive; the reporting join should not be.

## 6. QA scores are all the same, or all N/A

```sql
SELECT criterion_id, ROUND(AVG(score), 2) avg, ROUND(STDDEV(score), 2) sd,
       ROUND(100.0 * COUNT_IF(NOT applicable) / COUNT(*), 1) pct_na,
       COUNT_IF(validation_status <> 'OK') rejected
FROM QA_CRITERION_SCORES WHERE run_id = :run_id GROUP BY 1 ORDER BY 1;
```

- **SD near zero:** vague criterion description, or the transcript does not carry the evidence (best-practices Q6).
  Rewrite the 5-and-1 anchors in `QA_RUBRIC` under a new rubric version.
- **N/A near 100 percent on a criterion that should apply:** the `applies_when` rule is too narrow or ambiguous.
- **Many `NO_EVIDENCE` / `BAD_CITATION`:** the prompt does not show segment numbers, or long calls were windowed
  without keeping numbering. Check `QA_INPUT`.
- **Compliance always failing on payment calls:** expected on the sandbox `PAYMENT_BY_PHONE` scenario. On real calls,
  check whether the judge treats `[PAYMENT_CARD_DATA]` as "agent read the number back" when the agent only confirmed
  the last four (best-practices R6).
- **Raw responses null:** parse failures. `SELECT COUNT_IF(resp:structured_output[0]:raw_message IS NULL) FROM QA_RAW`.
  Check the response path on one row; check `max_tokens` is not truncating a long criteria array.

## 7. Sentiment is null for long calls

The 2,048-token AI_SENTIMENT window (best-practices S1). Confirm the pipeline scores bounded slices, not whole calls:

```sql
SELECT COUNT_IF(sentiment_error IS NOT NULL) AS errors,
       ANY_VALUE(sentiment_error) AS example
FROM CALL_SENTIMENT WHERE run_id = :run_id;
```

Also check for `unknown` being averaged as neutral in any aspect rollup (S2).

## 8. Save gaps look implausibly high, or offers appear on calls with no agent offer

```sql
SELECT r.scenario_hint, COUNT(*) FROM (
  SELECT s.call_id,
         IFF(LOWER(TRIM(raw.r:response:save_offer::STRING)) = 'yes' AND NOT s.save_offer_made,
             'model_yes_but_no_agent_segment', 'consistent') AS scenario_hint
  FROM CALL_SIGNALS s JOIN CALL_SIGNALS_RAW raw ON raw.call_id = s.call_id AND raw.run_id = s.run_id
  WHERE s.run_id = :run_id) r
GROUP BY 1;
```

- High save gaps on non-cancel reasons: the AI_FILTER screen is too loose ("cancel my appointment"). Tighten the
  predicate wording; measure on `DISTRACTOR_CANCEL_APPOINTMENT`.
- Offers credited to the customer's words: the agent-segment check (best-practices X4) is not applied, or
  `offer_segments` came back as prose instead of numbers.
- Gaps on offer-ineligible cancel reasons: exclude them with the customer's list before valuing (value readout).

## 9. Repeat rate looks wrong

Repeats are a metadata join; the model is not involved.

```sql
SELECT COUNT(*) AS calls, COUNT(customer_id) AS with_customer_id,
       COUNT(DISTINCT customer_id) AS customers
FROM CALLS_IN_SCOPE WHERE source_route NOT LIKE 'EXCLUDED%';
```

- Repeat rate near zero: `customer_id` mostly null (unidentified callers), or mapped to a per-call identifier.
- Repeat rate implausibly high: `customer_id` mapped to something shared (account with many users, a queue id), or
  transfer legs counted as separate calls (set `calls.leg_col`, best-practices T3).
- The window is not what the customer means: check `definitions.repeat_window_days`.

## 10. Cost is higher than expected

```sql
SELECT l.stage, u.function_name, u.model_name, SUM(u.tokens) AS tokens
FROM RUN_QUERY_LOG l
JOIN SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY u ON u.query_id = l.query_id
WHERE l.run_id = :run_id
GROUP BY 1, 2, 3 ORDER BY tokens DESC;
```

- **Transcription repeated:** the incremental guard is missing, so calls are re-transcribed each run. Count calls in
  `TRANSCRIBE_RAW` with more than one successful row.
- **Short calls transcribed:** 10-second minimum bill per file (best-practices A3); check the exclusion threshold.
- **A view over an AI function:** something downstream selects from a view that calls a model (O1).
- **Whole calls sent to classification or sentiment:** the slicing rules (C1, S1) are not applied; compare average
  input tokens to average full-call tokens.
- **QA billed far above estimate:** expected with `response_format` on Claude models (documented) — reconcile, and if
  it matters, reduce criteria count or window long calls.
- **Usage rows missing:** account usage has latency; re-check later before concluding anything.
