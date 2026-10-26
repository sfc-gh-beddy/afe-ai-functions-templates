-- =====================================================================
-- Verification for the call-center-intelligence sandbox. Read-only.
-- Substitute {{DB}}, {{SCHEMA}}, {{EVAL_SCHEMA}}, {{REPEAT_WINDOW_DAYS}}.
-- Every query states its expected result. Run all of them and show the
-- results at the Phase 1 gate.
-- =====================================================================
USE DATABASE {{DB}};
USE SCHEMA {{DB}}.{{SCHEMA}};

-- V1. Population shape. Expect a long tail of reasons, repeats > 0,
--     audio_only roughly AUDIO_SHARE of calls, some out-of-scope calls.
SELECT ak.contact_reason,
       COUNT(*)                         AS calls,
       COUNT_IF(ak.is_repeat)           AS repeats,
       COUNT_IF(ak.audio_only)          AS audio_only,
       COUNT_IF(NOT ak.in_scope)        AS out_of_scope,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
GROUP BY 1 ORDER BY calls DESC;

-- V2. Every follow-up is a repeat by the metadata definition. Expect 0 rows.
SELECT ak.call_id
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
JOIN SYNTH_CALL_DETAIL_RECORDS cur ON cur.call_id = ak.call_id
JOIN SYNTH_CALL_DETAIL_RECORDS pri ON pri.call_id = ak.prior_call_id
WHERE ak.is_repeat
  AND (cur.customer_id <> pri.customer_id
       OR DATEDIFF(hour, pri.call_start_ts, cur.call_start_ts) > 24 * {{REPEAT_WINDOW_DAYS}});

-- V3. No unintended repeats. Base calls are assigned customers by a
--     bijective step (7919 mod 900 is coprime with 900), so with
--     CALL_COUNT <= 900 no two base calls share a customer and only
--     constructed follow-ups are repeats. Expect 0. If CALL_COUNT > 900,
--     this will be non-zero and is_repeat labels undercount metadata repeats:
--     either raise the customer count in 01_seed_sandbox.sql or treat the
--     metadata definition as truth for is_repeat in evaluation.
SELECT COUNT(*) AS incidental_repeats
FROM (
  SELECT call_id, customer_id, call_start_ts,
         LAG(call_start_ts) OVER (PARTITION BY customer_id ORDER BY call_start_ts) AS prev_ts
  FROM SYNTH_CALL_DETAIL_RECORDS) x
JOIN {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak ON ak.call_id = x.call_id
WHERE NOT ak.is_repeat
  AND x.prev_ts IS NOT NULL
  AND DATEDIFF(hour, x.prev_ts, x.call_start_ts) <= 24 * {{REPEAT_WINDOW_DAYS}};

-- V4. Audio-only calls have no vendor transcript, and vice versa. Expect 0 and 0.
SELECT COUNT_IF(d.audio_only AND t.call_id IS NOT NULL)     AS audio_with_transcript,
       COUNT_IF(NOT d.audio_only AND t.call_id IS NULL)     AS transcript_missing
FROM SYNTH_CALL_DETAIL_RECORDS d
LEFT JOIN (SELECT DISTINCT call_id FROM SYNTH_CALL_TRANSCRIPTS) t ON t.call_id = d.call_id;

-- V5. Planted PII present in vendor text, by category and form.
--     Expect present_in_vendor_text = planted for transcript calls.
SELECT pk.category, pk.form,
       COUNT(*) AS planted,
       COUNT_IF(d.audio_only) AS planted_in_audio_only_calls,
       COUNT_IF(NOT d.audio_only AND EXISTS (
           SELECT 1 FROM SYNTH_CALL_TRANSCRIPTS t
           WHERE t.call_id = pk.call_id AND (t.seq = pk.seq OR t.seq = 0)
             AND CONTAINS(t.utterance_text, pk.planted_value))) AS present_in_vendor_text
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_PII pk
JOIN SYNTH_CALL_DETAIL_RECORDS d ON d.call_id = pk.call_id
GROUP BY 1, 2 ORDER BY 1, 2;

-- V6. No unsubstituted placeholders. Expect 0.
SELECT COUNT(*) AS leftover_placeholders
FROM SYNTH_CALL_TRANSCRIPTS
WHERE CONTAINS(utterance_text, '{{');

-- V7. Case roles present. Expect STANDARD, DISTRACTOR, BORDERLINE, EXCLUDE all > 0.
SELECT case_role, COUNT(*) FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS GROUP BY 1;

-- V8. Full-text blobs exist and carry inline role markers. Expect > 0 rows, all with markers.
SELECT COUNT(*) AS blobs,
       COUNT_IF(REGEXP_LIKE(utterance_text, '^(Agent|Customer|Ivr): .*', 's')) AS with_markers
FROM SYNTH_CALL_TRANSCRIPTS WHERE seq = 0;

-- V9. Disposition noise. Expect agreement well below 100 percent (about 60 by construction).
SELECT ROUND(100.0 * COUNT_IF(UPPER(REPLACE(ak.contact_reason, ' ', '_')) = d.disposition_code) / COUNT(*), 1)
         AS pct_disposition_correct
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
JOIN SYNTH_CALL_DETAIL_RECORDS d ON d.call_id = ak.call_id;

-- V10. QA labels: every in-scope call has all nine criteria, and N/A is used. Expect 9 and some NA.
SELECT MIN(n) AS min_criteria_per_call, MAX(n) AS max_criteria_per_call, SUM(na) AS na_labels
FROM (SELECT call_id, COUNT(*) AS n, COUNT_IF(NOT applicable) AS na
      FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_QA GROUP BY 1);

-- V11. Quarantine: the sandbox schema holds no label-bearing tables. Expect 0 rows.
SELECT table_name FROM information_schema.tables
WHERE table_schema = UPPER('{{SCHEMA}}')
  AND (table_name ILIKE '%ANSWER%' OR table_name ILIKE '%SCENARIO%' OR table_name ILIKE '%TRUE_SEG%'
       OR table_name ILIKE '%PII_VALUES%');
