---
name: evaluate-call-intelligence-accuracy
description: "Phase 6 of the call-center-intelligence build. Measures whether the pipeline is right and what it costs, against the sandbox answer key and any customer-labeled sample, always joining from ground truth so failed transcriptions and redactions count as misses. Reports redaction leak rate on planted PII by category and by form (digits versus spoken words) across the redacted transcript and every model-written column; speaker-role accuracy; transcription character error rate by audio condition; contact-reason accuracy, macro and micro F1, per-label precision and recall and a confusion matrix; repeat, escalation-source and resolution accuracy; sentiment agreement; QA agreement per criterion (exact, within-one, MAE, applicability agreement) and calibration against human QA scores; save and upsell precision and recall including distractors; parse-failure and rejection accounting; and tokens per 1,000 calls from recorded query ids joined to CORTEX_AI_FUNCTIONS_USAGE_HISTORY. Compares experiments and sets regression thresholds."
parent_skill: call-center-intelligence
---

# Evaluate accuracy, leakage and cost

A call analytics pipeline nobody measured generates dashboards of unknown truth, and an automated QA score
nobody calibrated generates disputes. This phase answers, with numbers: is PII leaking, are roles right, are the
reasons right, do QA scores agree with people, are save and upsell signals real, how much was silently lost, and
what did it cost per thousand calls.

Do not skip this. If the user wants to stop before it, list exactly what they will not know.

All metrics are computed per `run_id` and stored, so experiments compare. Evaluation tables are incremental
(`best-practices O7`).

## Ground rules (best-practices M1–M6)

- **Join from ground truth outward.** Every metric starts from the answer key with a `LEFT JOIN` (or
  `FULL OUTER JOIN` where false positives matter) to predictions. A call the pipeline lost is a miss.
- **Normalize both sides with one expression.** `UPPER(TRIM(x))`, applied per element after splitting.
- **Scope matches the pipeline's scope.** Out-of-scope calls (`in_scope = FALSE`: too short, `EXCLUDE` role)
  are reported separately — the expected behavior for them is exclusion, and "was it excluded" is itself a
  check.
- **Tokens, not currency.**

```sql
CREATE OR REPLACE VIEW EVAL_SCOPE AS
SELECT ak.*,
       c.source_route,
       e.text_eligible, e.role_eligible
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
LEFT JOIN CALLS_IN_SCOPE c   ON c.call_id = ak.call_id
LEFT JOIN CALL_ELIGIBILITY e ON e.call_id = ak.call_id;

-- Exclusion check: out-of-scope calls must be excluded; in-scope calls must not be.
SELECT in_scope,
       COUNT(*) AS calls,
       COUNT_IF(source_route LIKE 'EXCLUDED%') AS excluded,
       COUNT_IF(text_eligible)                 AS text_eligible,
       COUNT_IF(role_eligible)                 AS role_eligible
FROM EVAL_SCOPE GROUP BY 1;
```

Lost in-scope calls (not text-eligible) are listed with their reason (transcription error, redaction failure,
no segments). That count is reported at the top of the evaluation, before any accuracy number.

---

## 1. Redaction leak rate — first, always

The one metric with a hard gate (`thresholds.max_redaction_leak_rate`). Measured on **every** text column the
pipeline produces, because a model can echo or reconstruct a value (best-practices R7).

```sql
CREATE OR REPLACE TABLE EVAL_PII_LEAKS AS
WITH derived AS (
    SELECT call_id, 'segments' AS col, text_redacted AS txt FROM CALL_SEGMENTS_REDACTED
    UNION ALL SELECT call_id, 'qa_evidence',  evidence  FROM QA_CRITERION_SCORES WHERE run_id = :run_id
    UNION ALL SELECT call_id, 'qa_rationale', rationale FROM QA_CRITERION_SCORES WHERE run_id = :run_id
    UNION ALL SELECT call_id, 'qa_coaching',  resp:structured_output[0]:raw_message:coaching_note::STRING
              FROM QA_RAW WHERE run_id = :run_id
    UNION ALL SELECT call_id, 'cancel_reason', cancel_reason FROM CALL_SIGNALS WHERE run_id = :run_id
    UNION ALL SELECT call_id, 'competitor',    competitor    FROM CALL_SIGNALS WHERE run_id = :run_id
),
per_call AS (
    SELECT call_id, col, LISTAGG(txt, ' ') AS txt FROM derived WHERE txt IS NOT NULL GROUP BY 1, 2
)
SELECT pk.call_id, pk.category, pk.form, pk.planted_value, d.col,
       CONTAINS(LOWER(d.txt), LOWER(pk.planted_value))
         OR (pk.planted_digits IS NOT NULL AND LENGTH(pk.planted_digits) >= 7
             AND CONTAINS(REGEXP_REPLACE(d.txt, '[^0-9]', ''), pk.planted_digits)) AS leaked,
       :run_id AS run_id
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_PII pk
JOIN per_call d ON d.call_id = pk.call_id;
```

Matching is per call, not per segment, because AI_TRANSCRIBE segment numbers do not align with the source
script. Digit matching strips non-digits on the redacted side so `4111-1111...` and `4111 1111...` both count.
The `LENGTH >= 7` guard avoids false leaks from short coincidental digit runs.

For **audio** calls, transcription may render a spoken card number as digits or as words regardless of how it
was planted. Check both: for audio calls, also match the digit form of `words` plants and the word form of
`digits` plants.

```sql
SELECT category, form, col,
       COUNT(*)                     AS planted_checks,
       COUNT_IF(leaked)             AS leaks,
       ROUND(COUNT_IF(leaked) / NULLIF(COUNT(*), 0), 4) AS leak_rate
FROM EVAL_PII_LEAKS WHERE run_id = :run_id
GROUP BY 1, 2, 3
ORDER BY leaks DESC, category;
```

Present this table first, by category and form. Rules for the narrative:

- Any leak on `PAYMENT_CARD_DATA` or `NATIONAL_ID` is a finding stated in the first line of the readout.
- A leak in a derived column with no leak in the segments means a model reconstructed or echoed data; tighten
  the prompt ("never repeat numbers") and re-measure.
- `NAME` leaks of the **agent** first name are expected to be low-risk relative to customer data, but report them
  separately rather than folding them in.
- If `redaction.enabled` is false, this section reports the planted-PII exposure that remains, labeled
  "redaction opted out by <opt_out_by> on <opt_out_date>".

## 2. Speaker roles

```sql
SELECT s.source,
       COUNT(*)                                             AS segments,
       COUNT_IF(s.speaker_role = ts.true_role)              AS correct,
       ROUND(COUNT_IF(s.speaker_role = ts.true_role) / COUNT(*), 3) AS role_accuracy,
       COUNT_IF(s.speaker_role = 'UNKNOWN')                 AS unknown
FROM {{EVAL_SCHEMA}}.SYNTH_TRUE_SEGMENTS ts
JOIN CALL_SEGMENTS_REDACTED s ON s.call_id = ts.call_id AND s.seq = ts.seq AND s.source LIKE 'VENDOR%'
GROUP BY 1;
```

For AI_TRANSCRIBE calls, segment numbers differ, so measure at the call level: did the speaker label mapped to
`AGENT` produce text that best matches the true agent turns? A practical check:

```sql
WITH agent_text AS (
    SELECT call_id, LISTAGG(text_redacted, ' ') WITHIN GROUP (ORDER BY seq) AS pred_agent
    FROM CALL_SEGMENTS_REDACTED WHERE source = 'AI_TRANSCRIBE' AND speaker_role = 'AGENT' GROUP BY 1
),
true_agent AS (
    SELECT call_id, LISTAGG(text, ' ') WITHIN GROUP (ORDER BY seq) AS true_agent
    FROM {{EVAL_SCHEMA}}.SYNTH_TRUE_SEGMENTS WHERE true_role = 'AGENT' GROUP BY 1
)
SELECT rr.variant,
       COUNT(*) AS calls,
       ROUND(AVG(JAROWINKLER_SIMILARITY(LEFT(a.pred_agent, 2000), LEFT(t.true_agent, 2000))), 1) AS agent_text_similarity
FROM true_agent t
JOIN {{EVAL_SCHEMA}}.SYNTH_AUDIO_RENDER_RESULTS rr ON rr.call_id = t.call_id
LEFT JOIN agent_text a ON a.call_id = t.call_id
GROUP BY 1 ORDER BY 1;
```

This is a coarse proxy (redaction placeholders and transcription differences lower it), useful **comparatively**
across variants and experiments rather than as an absolute. A collapse on `stereo_split` or `lead_silence` is the
finding to carry into the customer conversation.

## 3. Transcription quality (audio only)

Snowflake has no built-in word error rate. Report **character error rate** on normalized text, computed with
`EDITDISTANCE`, and say that it is CER, not WER:

```sql
WITH pred AS (
    SELECT call_id, REGEXP_REPLACE(LOWER(tx_value:text::STRING), '[^a-z0-9 ]', '') AS t
    FROM TRANSCRIBE_RAW WHERE error IS NULL AND timestamp_granularity = 'none'
    UNION ALL
    SELECT r.call_id,
           REGEXP_REPLACE(LOWER(LISTAGG(s.value:text::STRING, ' ') WITHIN GROUP (ORDER BY s.index)), '[^a-z0-9 ]', '')
    FROM TRANSCRIBE_RAW r, LATERAL FLATTEN(input => r.tx_value:segments) s
    WHERE r.error IS NULL AND r.timestamp_granularity = 'speaker'
    GROUP BY r.call_id
),
truth AS (
    SELECT call_id, REGEXP_REPLACE(LOWER(LISTAGG(text, ' ') WITHIN GROUP (ORDER BY seq)), '[^a-z0-9 ]', '') AS t
    FROM {{EVAL_SCHEMA}}.SYNTH_TRUE_SEGMENTS GROUP BY 1
)
SELECT rr.variant, COUNT(*) AS calls,
       COUNT_IF(p.call_id IS NULL) AS no_transcript,
       ROUND(AVG(EDITDISTANCE(LEFT(p.t, 5000), LEFT(tr.t, 5000)) / NULLIF(LENGTH(LEFT(tr.t, 5000)), 0)), 3) AS cer
FROM {{EVAL_SCHEMA}}.SYNTH_AUDIO_RENDER_RESULTS rr
JOIN truth tr ON tr.call_id = rr.call_id
LEFT JOIN pred p ON p.call_id = rr.call_id
GROUP BY 1 ORDER BY 1;
```

This reads `TRANSCRIBE_RAW` (unredacted) because the comparison must be against the raw source script; it is the
only evaluation query that does, it runs under the pipeline role, and its output is a number, not text. TTS audio
is cleaner than real speech; state that CER here is a plumbing check, not a forecast for the customer's calls.

## 4. Contact reasons

```sql
CREATE OR REPLACE TABLE EVAL_REASONS AS
SELECT ak.call_id, UPPER(TRIM(ak.contact_reason)) AS truth,
       UPPER(TRIM(COALESCE(r.primary_reason, '__MISSING__'))) AS pred,
       ak.case_role, :run_id AS run_id
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
LEFT JOIN CALL_REASONS r ON r.call_id = ak.call_id AND r.run_id = :run_id
WHERE ak.in_scope;

-- Overall accuracy, and lost calls counted as wrong.
SELECT COUNT(*) AS calls,
       COUNT_IF(pred = '__MISSING__') AS missing,
       ROUND(COUNT_IF(truth = pred) / COUNT(*), 3) AS accuracy
FROM EVAL_REASONS WHERE run_id = :run_id;

-- Per-label precision / recall / F1, then macro and micro.
WITH labels AS (SELECT DISTINCT truth AS label FROM EVAL_REASONS WHERE run_id = :run_id),
pl AS (
    SELECT l.label,
           COUNT_IF(e.truth = l.label AND e.pred = l.label) AS tp,
           COUNT_IF(e.truth <> l.label AND e.pred = l.label) AS fp,
           COUNT_IF(e.truth = l.label AND e.pred <> l.label) AS fn
    FROM labels l CROSS JOIN EVAL_REASONS e
    WHERE e.run_id = :run_id
    GROUP BY 1
)
SELECT label, tp, fp, fn,
       ROUND(tp / NULLIF(tp + fp, 0), 3) AS precision,
       ROUND(tp / NULLIF(tp + fn, 0), 3) AS recall,
       ROUND(2 * tp / NULLIF(2 * tp + fp + fn, 0), 3) AS f1
FROM pl ORDER BY tp + fn DESC;
-- macro_f1 = AVG(f1) over labels; micro_f1 = 2*SUM(tp) / (2*SUM(tp)+SUM(fp)+SUM(fn)). Report both.

-- Confusion matrix (top cells).
SELECT truth, pred, COUNT(*) FROM EVAL_REASONS WHERE run_id = :run_id AND truth <> pred
GROUP BY 1, 2 ORDER BY 3 DESC LIMIT 15;
```

Secondary reasons (multi-label): recall of `secondary_reasons` on `MULTI_BILLING_AND_ORDER` and similar scenarios
is the relevant number; compute per call as set overlap after flattening both arrays with the same normalization.

Also report agreement between model reason and disposition **and** between disposition and truth. On the sandbox
the disposition is about 60 percent right by construction; on real data, this comparison is how the readout shows
that disposition codes undercount specific reasons.

## 5. Repeats, escalations, resolution

```sql
SELECT 'is_repeat' AS metric,
       COUNT_IF(ak.is_repeat AND rp.is_repeat)         AS tp,
       COUNT_IF(NOT ak.is_repeat AND rp.is_repeat)     AS fp,
       COUNT_IF(ak.is_repeat AND NOT COALESCE(rp.is_repeat, FALSE)) AS fn
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak LEFT JOIN CALL_REPEATS rp ON rp.call_id = ak.call_id
WHERE ak.in_scope
UNION ALL
SELECT 'references_prior',
       COUNT_IF(ak.references_prior AND o.references_prior_contact = 'YES'),
       COUNT_IF(NOT ak.references_prior AND o.references_prior_contact = 'YES'),
       COUNT_IF(ak.references_prior AND COALESCE(o.references_prior_contact, 'MISSING') <> 'YES')
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak LEFT JOIN CALL_OUTCOMES o ON o.call_id = ak.call_id AND o.run_id = :run_id
WHERE ak.in_scope
UNION ALL
SELECT 'supervisor_request',
       COUNT_IF(ak.supervisor_request AND o.supervisor_requested = 'YES'),
       COUNT_IF(NOT ak.supervisor_request AND o.supervisor_requested = 'YES'),
       COUNT_IF(ak.supervisor_request AND COALESCE(o.supervisor_requested, 'MISSING') <> 'YES')
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak LEFT JOIN CALL_OUTCOMES o ON o.call_id = ak.call_id AND o.run_id = :run_id
WHERE ak.in_scope
UNION ALL
SELECT 'unresolved',
       COUNT_IF(NOT ak.resolved AND o.resolution_status IN ('UNRESOLVED','PARTIAL')),
       COUNT_IF(ak.resolved AND o.resolution_status IN ('UNRESOLVED','PARTIAL')),
       COUNT_IF(NOT ak.resolved AND COALESCE(o.resolution_status, 'MISSING') NOT IN ('UNRESOLVED','PARTIAL'))
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak LEFT JOIN CALL_OUTCOMES o ON o.call_id = ak.call_id AND o.run_id = :run_id
WHERE ak.in_scope;
```

Wrap with precision and recall per metric. `is_repeat` should be near perfect because it is a metadata join; if
it is not, the customer-id mapping or the window is wrong, which is a preflight bug, not a model bug.

The `COMPLAINT_SUPERVISOR_UNAVAILABLE` scenario has a supervisor request and no transfer: check that it scores
`supervisor_requested = YES` with `was_transferred = FALSE`. If the pipeline only has a transfer flag, it misses
this case entirely, which is the point of best-practices C6.

## 6. Sentiment

```sql
SELECT ak.opening_sentiment AS truth_open, s.opening_overall AS pred_open, COUNT(*)
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
LEFT JOIN CALL_SENTIMENT s ON s.call_id = ak.call_id AND s.run_id = :run_id
WHERE ak.in_scope GROUP BY 1, 2 ORDER BY 3 DESC;
-- same for closing, and agreement on RECOVERED vs DETERIORATED shift.
```

Sentiment labels on the sandbox are authored per scenario and are coarse. Treat agreement as directional; the
important checks are that errors (`sentiment_error`) are near zero and that shift detection separates recovered
from deteriorated calls.

## 7. Agent QA agreement

```sql
CREATE OR REPLACE TABLE EVAL_QA AS
SELECT k.call_id, k.criterion_id,
       k.applicable AS truth_applicable, k.expected_score,
       q.applicable AS pred_applicable, q.score AS pred_score,
       q.validation_status, :run_id AS run_id
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_QA k
LEFT JOIN QA_CRITERION_SCORES q
  ON q.call_id = k.call_id AND q.criterion_id = k.criterion_id AND q.run_id = :run_id;

SELECT criterion_id,
       COUNT(*)                                                         AS pairs,
       COUNT_IF(pred_applicable IS NULL)                                AS missing,
       ROUND(COUNT_IF(truth_applicable = pred_applicable) / COUNT(*), 3) AS applicability_agreement,
       COUNT_IF(truth_applicable AND pred_applicable AND validation_status = 'OK') AS both_scored,
       ROUND(COUNT_IF(truth_applicable AND pred_applicable AND pred_score = expected_score)
             / NULLIF(COUNT_IF(truth_applicable AND pred_applicable AND validation_status = 'OK'), 0), 3) AS exact_agreement,
       ROUND(COUNT_IF(truth_applicable AND pred_applicable AND ABS(pred_score - expected_score) <= 1)
             / NULLIF(COUNT_IF(truth_applicable AND pred_applicable AND validation_status = 'OK'), 0), 3) AS within_one,
       ROUND(AVG(IFF(truth_applicable AND pred_applicable, ABS(pred_score - expected_score), NULL)), 2) AS mae
FROM EVAL_QA WHERE run_id = :run_id
GROUP BY 1 ORDER BY 1;
```

Read it in this order (best-practices M4):

1. `missing` — calls or criteria the pipeline never scored. Lost coverage is not agreement.
2. `applicability_agreement` — a model that marks everything N/A has perfect score agreement on nothing.
3. `within_one` — the primary number to present; human QA analysts rarely agree exactly with each other either.
4. `mae` and `exact_agreement`.

Report per criterion; a single averaged agreement hides that, for example, empathy agrees and compliance does not.

The `PAYMENT_BY_PHONE` scenario expects a low `COMPLIANCE` score because the agent reads back the full card
number. With redaction on, the read-back appears as `[PAYMENT_CARD_DATA]`. Whether the judge still recognizes the
read-back from the placeholder is a real test of rule R6; report it.

### Calibration against human QA (real data)

If `qa.human_qa_table` exists, repeat the agreement computation against it, mapped by call id and criterion, on the
calls both scored. If the customer's form differs from the rubric used, calibrate only criteria that map one to one,
and say which. Report the human-vs-model agreement next to any human-vs-human agreement the customer has (many QA
teams run calibration sessions); a model that agrees with analysts about as often as analysts agree with each other
is a defensible place to be. Do not supply an industry benchmark figure for human agreement.

## 8. Save and upsell signals

```sql
SELECT 'cancel_intent' AS signal,
       COUNT_IF(ak.cancel_intent AND s.cancel_intent)                  AS tp,
       COUNT_IF(NOT ak.cancel_intent AND s.cancel_intent)              AS fp,
       COUNT_IF(ak.cancel_intent AND NOT COALESCE(s.cancel_intent, FALSE)) AS fn
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
LEFT JOIN CALL_SIGNALS s ON s.call_id = ak.call_id AND s.run_id = :run_id
WHERE ak.in_scope
UNION ALL
SELECT 'save_offer_made',
       COUNT_IF(ak.save_offer_made AND s.save_offer_made),
       COUNT_IF(NOT ak.save_offer_made AND s.save_offer_made),
       COUNT_IF(ak.save_offer_made AND NOT COALESCE(s.save_offer_made, FALSE))
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
LEFT JOIN CALL_SIGNALS s ON s.call_id = ak.call_id AND s.run_id = :run_id
WHERE ak.in_scope
UNION ALL
SELECT 'save_gap',
       COUNT_IF(ak.cancel_intent AND NOT ak.save_offer_made AND s.save_gap),
       COUNT_IF(NOT (ak.cancel_intent AND NOT ak.save_offer_made) AND s.save_gap),
       COUNT_IF(ak.cancel_intent AND NOT ak.save_offer_made AND NOT COALESCE(s.save_gap, FALSE))
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
LEFT JOIN CALL_SIGNALS s ON s.call_id = ak.call_id AND s.run_id = :run_id
WHERE ak.in_scope
UNION ALL
SELECT 'upsell_offered',
       COUNT_IF(ak.upsell_offered AND s.upsell_offered),
       COUNT_IF(NOT ak.upsell_offered AND s.upsell_offered),
       COUNT_IF(ak.upsell_offered AND NOT COALESCE(s.upsell_offered, FALSE))
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
LEFT JOIN CALL_SIGNALS s ON s.call_id = ak.call_id AND s.run_id = :run_id
WHERE ak.in_scope;
```

Note `LEFT JOIN` from the key: calls screened out in Step 1 of the signals phase have no row in `CALL_SIGNALS` and
correctly count as `fn` when the truth is positive. That makes screening recall visible.

Distractors, explicitly:

```sql
SELECT ak.scenario_id, COUNT(*) AS calls,
       COUNT_IF(s.cancel_intent)    AS flagged_cancel_intent,
       COUNT_IF(s.save_offer_made)  AS flagged_offer
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
LEFT JOIN CALL_SIGNALS s ON s.call_id = ak.call_id AND s.run_id = :run_id
WHERE ak.case_role = 'DISTRACTOR'
GROUP BY 1;
-- Expect zeros. Non-zero on DISTRACTOR_CANCEL_APPOINTMENT means the screen or the question wording is too loose;
-- non-zero offers on DISTRACTOR_DISCOUNT_HEARSAY means the agent-segment check is not working.
```

Outcome accuracy (`save_outcome`, `upsell_outcome`) on offered calls: exact match after normalization.

## 9. Silent loss — what nothing else surfaces

```sql
SELECT stage, SUM(total_calls) AS calls, SUM(unparseable_calls) AS unparseable, ANY_VALUE(detail) AS detail
FROM PIPELINE_QUALITY_LOG WHERE run_id = :run_id GROUP BY 1;

SELECT
  (SELECT COUNT_IF(error IS NOT NULL) FROM TRANSCRIBE_RAW)                              AS transcribe_errors,
  (SELECT COUNT_IF(redaction_status IN ('FAILED','MISSING')) FROM CALL_SEGMENTS_REDACTED) AS redaction_failed_segments,
  (SELECT COUNT_IF(classify_error IS NOT NULL) FROM CALL_REASONS WHERE run_id = :run_id) AS classify_errors,
  (SELECT COUNT_IF(resolution_status = 'UNPARSED') FROM CALL_OUTCOMES WHERE run_id = :run_id) AS outcome_unparsed,
  (SELECT COUNT_IF(sentiment_error IS NOT NULL) FROM CALL_SENTIMENT WHERE run_id = :run_id) AS sentiment_errors,
  (SELECT COUNT_IF(validation_status <> 'OK') FROM QA_CRITERION_SCORES WHERE run_id = :run_id) AS qa_rejected,
  (SELECT COUNT_IF(has_unparsed OR extract_failed) FROM CALL_SIGNALS WHERE run_id = :run_id) AS signal_unparsed;
```

Present this as one table. Every non-zero number is a share of calls whose outputs are missing or degraded.

## 10. Cost — tokens per 1,000 calls

`SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` carries `QUERY_ID`, `FUNCTION_NAME`, `MODEL_NAME`,
`METRICS` (token counts), `CREDITS` and `QUERY_TAG` and `WAREHOUSE_ID`; its `START_TIME` is an hourly window, so attribute cost through query ids.
Every phase should record the query id of each batch statement right after it runs:

```sql
CREATE TABLE IF NOT EXISTS RUN_QUERY_LOG (run_id VARCHAR, stage VARCHAR, query_id VARCHAR, logged_at TIMESTAMP_LTZ);
-- immediately after each model-calling INSERT:
INSERT INTO RUN_QUERY_LOG SELECT :run_id, 'redact', LAST_QUERY_ID(), CURRENT_TIMESTAMP();
```

Then, once account usage has caught up (it has latency; if rows are missing, say so and re-check later rather than
reporting zero):

```sql
SELECT l.stage, u.function_name, u.model_name,
       SUM(u.tokens)        AS tokens,
       SUM(u.token_credits) AS token_credits
FROM RUN_QUERY_LOG l
JOIN (
    -- CORTEX_AI_FUNCTIONS_USAGE_HISTORY: one row per query, function, model and hourly window;
    -- tokens live in the METRICS array, credits in CREDITS.
    SELECT h.query_id, h.query_tag, h.function_name, h.model_name,
           ANY_VALUE(h.credits) AS token_credits,
           SUM(IFF(m.value:key:unit::STRING = 'tokens', m.value:value::NUMBER, 0)) AS tokens
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h,
         LATERAL FLATTEN(input => h.metrics, outer => TRUE) m
    GROUP BY h.query_id, h.query_tag, h.start_time, h.function_name, h.model_name
) u ON u.query_id = l.query_id
WHERE l.run_id = :run_id
GROUP BY 1, 2, 3 ORDER BY tokens DESC;
```

Per 1,000 calls: divide each stage's tokens by the number of calls that stage processed, times 1,000. Present tokens
(and credits only if the user asks; never currency). Expected shape: transcription dominates audio builds and is
`50 x audio seconds` by definition; redaction is next because it touches all text and its billed tokens include the
regenerated text; QA is the largest text-model line. Compare measured against the gate estimates and explain gaps —
on Claude models with `response_format`, measured QA input will exceed the `AI_COUNT_TOKENS` estimate.

Also report what the slicing levers did: average tokens sent to classification (opening only) and sentiment (two
slices) versus the average full-call token count. That is the real, measured effect of rules C1 and S1 on this
corpus.

## 11. Compare experiments

```sql
CREATE TABLE IF NOT EXISTS EVAL_SUMMARY (
    run_id VARCHAR, experiment_id VARCHAR, experiment_name VARCHAR, prompt_version VARCHAR,
    taxonomy_version VARCHAR, rubric_version VARCHAR,
    reason_accuracy FLOAT, reason_macro_f1 FLOAT, reason_micro_f1 FLOAT,
    qa_within_one FLOAT, qa_applicability_agreement FLOAT,
    save_gap_precision FLOAT, save_gap_recall FLOAT,
    max_leak_rate FLOAT, card_leaks INT,
    lost_calls INT, tokens_per_1k_calls FLOAT,
    evaluated_at TIMESTAMP_LTZ
);
```

Insert one row per run. When the user asks whether a change helped, compare rows on these metrics, list what
changed (`prompt_hash`, `taxonomy_version`, `rubric_version`, model), and do not judge from a handful of examples.
If two runs share `prompt_version` but differ in prompt hash, trust the hash.

## 12. Thresholds

After the first evaluation, set in `callcenter-project.yml`:

- `thresholds.min_reason_macro_f1` just under the achieved macro F1;
- `thresholds.min_qa_within_one_agreement` just under achieved within-one;
- `thresholds.max_redaction_leak_rate` stays at the level the customer's privacy owner accepts — this is their
  decision, not a tuned value.

In dbt mode these become build-failing tests (`DBT_MATERIALIZATION.md`).

## What to present at the gate

1. Scope and lost calls.
2. Redaction leak table (with opt-out banner if applicable).
3. Role accuracy and, for audio, CER and role proxy by condition.
4. Contact reasons: accuracy, macro and micro F1, worst three labels, top confusions.
5. Repeats, escalation sources, resolution.
6. QA agreement per criterion, and human calibration if available.
7. Save and upsell precision/recall, distractor results.
8. Silent-loss table.
9. Tokens per 1,000 calls by stage, measured vs estimated.

## When the pipeline disagrees with the answer key, check the key

Synthetic labels are authored by a person. If the judge consistently scores a criterion one point away from a label
and its cited evidence is persuasive, read the scenario: the label may be wrong. Fix the scenario (new seed run),
not the metric, and record the change. Never tune the rubric or prompt to match a label you believe is wrong.

## Interpreting honestly

- Sandbox metrics measure the pipeline on clean, coherent synthetic calls. Real calls are messier. Present sandbox
  numbers as an upper bound on accuracy and a lower bound on failure modes.
- A labeled sample of real calls from the customer's QA team is the POC success criterion that matters; the sandbox
  makes the pipeline trustworthy enough to get there.

Then `phases.eval: done`.
