---
name: score-agent-qa
description: "Phase 4 of the call-center-intelligence build. Scores agent behavior on every role-eligible call against a versioned QA rubric stored as data: a generic default rubric (greeting, verification, discovery, accuracy, resolution, empathy, retention and sales, compliance, closing) that the customer can override with their own form as a new rubric version. Uses AI_COMPLETE with a response_format JSON schema so each criterion returns applicability, a 1-5 score, cited segment numbers and a quoted redacted excerpt; enforces non-empty, resolvable evidence in SQL; treats not-applicable as excluded rather than zero; computes weighted call scores over applicable criteria only; hashes the assembled prompt; logs parse failures; and flags non-discriminating criteria. Use for: agent QA, automated QA, QA scorecard, call scoring, coaching, quality assurance, our QA form, rubric override."
parent_skill: call-center-intelligence
---

# Agent QA scoring

Decided for this play: QA uses a **generic rubric the customer can override**. The rubric is data
(`QA_RUBRIC`), versioned, and every score row records the rubric version and prompt hash that produced it.

Automated QA has people consequences. These scores are coaching signal with a **measured** agreement rate
against human reviewers, produced in Phase 6. Say this every time scores are presented, and do not put scores
in front of supervisors (Phase 7) until Phase 6 has run (best-practices Q5).

Reads `CALL_SEGMENTS_REDACTED`, `CALL_ELIGIBILITY`, `CALLS_IN_SCOPE`, and `CALL_REASONS` (for context).
Writes `QA_RUBRIC`, `QA_RAW`, `QA_CRITERION_SCORES`, `QA_CALL_SCORES`, `PIPELINE_QUALITY_LOG`.

---

## Step 1 — The rubric

```sql
CREATE TABLE IF NOT EXISTS QA_RUBRIC (
    rubric_version VARCHAR,
    criterion_id   VARCHAR,     -- letters, digits, underscore; used as an enum in the schema
    name           VARCHAR,
    description    VARCHAR,     -- what a 5 looks like and what a 1 looks like
    applies_when   VARCHAR,     -- plain-language applicability rule, given to the model
    weight         FLOAT,
    scale_max      INT,
    sort_order     INT,
    active         BOOLEAN
);

INSERT INTO QA_RUBRIC
SELECT 'rub_v1', column1, column2, column3, column4, column5, 5, column6, TRUE FROM VALUES
 ('GREETING',        'Greeting',
  '5: greets, identifies self and company, invites the customer to explain. 1: no greeting or a curt word.',
  'Always applies when an agent answers the call.', 1.0, 1),
 ('VERIFICATION',    'Identity verification',
  '5: verifies identity with an appropriate method before discussing or changing the account, asks only for what is needed. 1: no verification before account details, or asks for excessive sensitive data.',
  'Applies when the agent accesses or changes a customer account. Not applicable to wrong numbers or general questions with no account access.', 1.0, 2),
 ('DISCOVERY',       'Discovery',
  '5: asks questions that establish the real cause and need before acting. 1: acts without understanding the issue or ignores what the customer said.',
  'Always applies when the customer raises an issue.', 1.5, 3),
 ('ACCURACY',        'Accuracy of information',
  '5: information and policy given are correct and complete for this situation. 1: incorrect, misleading, or contradicts what the call itself shows.',
  'Applies when the agent states facts, prices, timelines, or policies.', 1.5, 4),
 ('RESOLUTION',      'Resolution',
  '5: resolves the issue on the call or sets a specific, owned next step. 1: leaves the customer with no resolution or deflects without a path.',
  'Always applies when the customer raises an issue.', 2.0, 5),
 ('EMPATHY',         'Empathy and tone',
  '5: acknowledges frustration, stays courteous and patient, adapts tone. 1: dismissive, rude, or argumentative.',
  'Always applies.', 1.5, 6),
 ('RETENTION_SALES', 'Retention and sales handling',
  '5: on cancel intent, explores the reason and makes a relevant save offer; on a stated need, offers a fitting product without pressure. 1: processes a cancellation with no attempt, or ignores a clear buying signal.',
  'Applies only when the customer states an intent to cancel or downgrade, or expresses a need a product or plan could meet. Not applicable otherwise.', 1.5, 7),
 ('COMPLIANCE',      'Required disclosures and data handling',
  '5: states required terms when taking payment or changing a plan, and does not repeat full card or ID numbers aloud. 1: omits required terms or reads back full card or ID numbers.',
  'Applies when payment is taken, a plan or price changes, or a cancellation is processed.', 1.5, 8),
 ('CLOSING',         'Closing',
  '5: confirms the outcome, asks if anything else is needed, closes courteously. 1: ends abruptly.',
  'Always applies when the call reaches a natural end.', 0.5, 9);
```

Criterion ids match the sandbox answer key (`SYNTH_ANSWER_KEY_QA`). The weights are illustrative defaults,
not a recommendation; confirm with the customer's QA lead.

### Customer override

When the customer supplies their own QA form (`qa.rubric_source: customer`):

1. Insert it under a new `rubric_version` (for example `rub_cust_v1`); never edit `rub_v1` in place.
2. One row per criterion. Write each `description` as "what a top score looks like, what a bottom score looks
   like", and write an explicit `applies_when`. Forms that say only "Empathy: 1-5" produce undiscriminating
   scores.
3. Binary items on the customer's form (yes/no compliance checks) become criteria with `scale_max = 1` and a
   description that says 1 = done, 0 = not done. The schema's score description says the range; SQL clamps.
4. If the customer has historical human QA scores on this form, record `qa.human_qa_table` — Phase 6 calibrates
   against it.
5. Bump `qa.rubric_version` and `experiment.prompt_version` in the state file.
6. If the sandbox is still used for evaluation, either keep scoring `rub_v1` on the sandbox in parallel or
   accept that sandbox QA agreement cannot be measured for criteria with no sandbox label.

Keep the criterion count reasonable (roughly 5 to 15). Each criterion adds output tokens on every call.

## Step 2 — Assemble the input

Only role-eligible calls are scored; the rest are counted (best-practices A5, T1).

```sql
CREATE OR REPLACE TABLE QA_INPUT AS
WITH segs AS (
    SELECT s.call_id, s.seq, s.speaker_role, s.text_redacted,
           COUNT(*) OVER (PARTITION BY s.call_id) AS n
    FROM CALL_SEGMENTS_REDACTED s
    JOIN CALL_ELIGIBILITY e ON e.call_id = s.call_id AND e.role_eligible
)
SELECT call_id,
       LISTAGG('[' || seq || '] ' || speaker_role || ': ' || text_redacted, '\n')
         WITHIN GROUP (ORDER BY seq)                         AS convo,
       ARRAY_AGG(seq) WITHIN GROUP (ORDER BY seq)             AS valid_seqs,
       MAX(n)                                                 AS segments,
       FALSE                                                  AS windowed
FROM segs
GROUP BY call_id;
```

Long calls: if `AI_COUNT_TOKENS('ai_complete', :qa_judge_model, convo)` exceeds the budget you set for the judge
(start at roughly 12,000 tokens), rebuild that call's input from the first 15 segments, the last 15 segments,
and any segment flagged in `CALL_OUTCOMES` or containing a save/upsell cue, with a `[... n segments omitted ...]`
marker, and set `windowed = TRUE` (best-practices Q7). Report windowed calls separately.

## Step 3 — Build the prompt from the rubric, and hash it

```sql
CREATE OR REPLACE TABLE QA_PROMPTS AS
WITH rubric_text AS (
    SELECT LISTAGG('- ' || criterion_id || ' (' || name || '): ' || description
                   || ' Applies when: ' || applies_when, '\n')
             WITHIN GROUP (ORDER BY sort_order) AS txt,
           ARRAY_AGG(criterion_id) WITHIN GROUP (ORDER BY sort_order) AS ids
    FROM QA_RUBRIC WHERE rubric_version = :rubric_version AND active
)
SELECT q.call_id, q.valid_seqs, q.windowed, r.ids AS criterion_ids,
       'You are a contact center quality analyst scoring one agent on one customer service call.\n'
    || 'The transcript is redacted: bracketed tokens such as [NAME], [PHONE_NUMBER], [PAYMENT_CARD_DATA] replace '
    || 'personal data. Treat a placeholder as the value having been said; do not penalize the agent because a '
    || 'value is not visible.\n'
    || 'Each line starts with a segment number in square brackets and the speaker role. Score only the AGENT. '
    || 'Use CUSTOMER turns as context.\n\n'
    || 'Rubric (score 1 to 5 unless stated otherwise):\n' || r.txt || '\n\n'
    || 'For every criterion in the rubric return one result. If the criterion does not apply to this call under '
    || 'its "Applies when" rule, set applicable to false and score to 0. If it applies, cite the segment numbers '
    || 'that justify the score and quote a short excerpt from those segments exactly as written. Cite only segment '
    || 'numbers that appear in the transcript. Respond in JSON.\n\n'
    || 'Transcript:\n' || q.convo                                     AS prompt,
       SHA2('You are a contact center quality analyst' || r.txt)      AS rubric_prompt_hash
FROM QA_INPUT q CROSS JOIN rubric_text r;
```

`prompt_hash` on the output is `SHA2(prompt)` of this exact text; `rubric_prompt_hash` is the per-version hash of
the instructions and rubric without the call, which is what makes two runs comparable (best-practices O6).

## Step 4 — Score

Gate: estimate tokens on a sample with `AI_COUNT_TOKENS('ai_complete', :qa_judge_model, prompt)`, say that
billed input will be materially higher than the estimate because `response_format` on Claude models adds
request content not counted by the estimate (documented), and that output tokens bill on top. Offer a 100-call
sample first.

```sql
CREATE TABLE IF NOT EXISTS QA_RAW (
    call_id VARCHAR, resp VARIANT, prompt_hash VARCHAR, rubric_prompt_hash VARCHAR,
    rubric_version VARCHAR, model VARCHAR, windowed BOOLEAN,
    run_id VARCHAR, experiment_id VARCHAR, prompt_version VARCHAR, scored_at TIMESTAMP_LTZ
);

INSERT INTO QA_RAW
SELECT p.call_id,
       AI_COMPLETE(
         model => :qa_judge_model,
         prompt => p.prompt,
         model_parameters => {'temperature': 0, 'max_tokens': 3000},
         response_format => {
           'type': 'json',
           'schema': {
             'type': 'object',
             'properties': {
               'criteria': {
                 'type': 'array',
                 'items': {
                   'type': 'object',
                   'properties': {
                     'criterion_id': {'type': 'string', 'description': 'One of the criterion ids in the rubric'},
                     'applicable':   {'type': 'boolean'},
                     'score':        {'type': 'number', 'description': 'Integer from 1 to the criterion maximum when applicable, 0 when not applicable'},
                     'evidence_seq': {'type': 'array', 'items': {'type': 'integer'},
                                      'description': 'Segment numbers from the transcript that justify the score'},
                     'evidence':     {'type': 'string', 'description': 'Short exact quote from the cited segments'},
                     'rationale':    {'type': 'string'}
                   },
                   'required': ['criterion_id', 'applicable', 'score', 'evidence_seq', 'evidence']
                 }
               },
               'coaching_note': {'type': 'string', 'description': 'One or two sentences of specific, actionable coaching for the agent'}
             },
             'required': ['criteria', 'coaching_note']
           }
         },
         show_details => TRUE
       )                                     AS resp,
       SHA2(p.prompt), p.rubric_prompt_hash, :rubric_version, :qa_judge_model, p.windowed,
       :run_id, :experiment_id, :prompt_version, CURRENT_TIMESTAMP()
FROM QA_PROMPTS p
WHERE NOT EXISTS (SELECT 1 FROM QA_RAW x
                  WHERE x.call_id = p.call_id AND x.run_id = :run_id
                    AND x.resp:structured_output[0]:raw_message IS NOT NULL);
```

`criterion_id` could be declared with an `enum` built from the rubric to constrain it further; that requires
generating the schema text per rubric version. It is optional: SQL below rejects unknown ids either way.

If a single model error is aborting the statement, wrap the call so one bad row does not cost the batch
(`TRY_COMPLETE` semantics; see best-practices O8), then count the failures.

## Step 5 — Validate, then land the scores

```sql
CREATE OR REPLACE TABLE QA_CRITERION_SCORES AS
WITH parsed AS (
    SELECT r.call_id, r.run_id, r.experiment_id, r.rubric_version, r.prompt_hash, r.rubric_prompt_hash,
           r.model, r.windowed, c.value AS cv
    FROM QA_RAW r,
         LATERAL FLATTEN(input => r.resp:structured_output[0]:raw_message:criteria) c
),
checked AS (
    SELECT p.*,
           qr.criterion_id IS NOT NULL                                     AS known_criterion,
           p.cv:applicable::BOOLEAN                                        AS applicable,
           LEAST(GREATEST(ROUND(p.cv:score::FLOAT), 1), qr.scale_max)      AS score_clamped,
           p.cv:evidence_seq                                               AS evidence_seq,
           p.cv:evidence::STRING                                           AS evidence,
           p.cv:rationale::STRING                                          AS rationale,
           qr.weight, qr.scale_max,
           (SELECT COUNT(*) FROM LATERAL FLATTEN(input => p.cv:evidence_seq) e
            WHERE NOT ARRAY_CONTAINS(e.value::INT::VARIANT, qi.valid_seqs))  AS bad_citations
    FROM parsed p
    LEFT JOIN QA_RUBRIC qr ON qr.rubric_version = p.rubric_version
                          AND qr.criterion_id = p.cv:criterion_id::STRING
    JOIN QA_INPUT qi ON qi.call_id = p.call_id
)
SELECT call_id, cv:criterion_id::STRING AS criterion_id, applicable,
       IFF(applicable, score_clamped, NULL)                          AS score,
       scale_max, weight, evidence_seq, evidence, rationale,
       CASE WHEN NOT known_criterion                                   THEN 'UNKNOWN_CRITERION'
            WHEN applicable AND COALESCE(ARRAY_SIZE(evidence_seq), 0) = 0 THEN 'NO_EVIDENCE'
            WHEN applicable AND bad_citations > 0                     THEN 'BAD_CITATION'
            ELSE 'OK' END                                            AS validation_status,
       rubric_version, prompt_hash, rubric_prompt_hash, model, windowed, run_id, experiment_id
FROM checked;
```

If your account rejects the correlated `FLATTEN` count, compute `bad_citations` in a separate CTE that
flattens `evidence_seq` and left-joins the valid segments.

Rules applied here, all from best-practices:

- Not applicable is `NULL` score, excluded from the denominator (Q1). The model's `score` is ignored when
  `applicable` is false.
- A score without evidence, or citing a segment that does not exist, is `validation_status <> 'OK'` and excluded
  from call scores (Q2). It goes to the quality log, not to `/dev/null`.
- Unknown criterion ids (a model inventing a criterion) are rejected.
- A criterion missing from a response is a coverage gap: counted below.

Call-level score, applicable and valid criteria only:

```sql
CREATE OR REPLACE TABLE QA_CALL_SCORES AS
SELECT call_id, run_id, experiment_id, rubric_version,
       COUNT_IF(applicable AND validation_status = 'OK')                    AS criteria_scored,
       COUNT_IF(NOT applicable)                                              AS criteria_na,
       COUNT_IF(validation_status <> 'OK')                                   AS criteria_rejected,
       ROUND(100 * SUM(IFF(applicable AND validation_status = 'OK', weight * score / scale_max, 0))
             / NULLIF(SUM(IFF(applicable AND validation_status = 'OK', weight, 0)), 0), 1) AS qa_score_pct,
       ANY_VALUE(windowed)                                                   AS windowed
FROM QA_CRITERION_SCORES
GROUP BY 1, 2, 3, 4;
```

`qa_score_pct` is a weighted percentage of the maximum over applicable criteria. Never average it across rubric
versions.

Parse failures and coverage:

```sql
INSERT INTO PIPELINE_QUALITY_LOG (run_id, stage, total_calls, unparseable_calls, detail, logged_at)
SELECT :run_id, 'qa',
       COUNT(*),
       COUNT_IF(resp:structured_output[0]:raw_message IS NULL),
       OBJECT_CONSTRUCT(
         'missing_criteria', (SELECT COUNT(*) FROM (
              SELECT r.call_id, qr.criterion_id
              FROM QA_RAW r JOIN QA_RUBRIC qr ON qr.rubric_version = r.rubric_version AND qr.active
              WHERE r.run_id = :run_id
              EXCEPT
              SELECT call_id, criterion_id FROM QA_CRITERION_SCORES WHERE run_id = :run_id)),
         'rejected_rows', (SELECT COUNT(*) FROM QA_CRITERION_SCORES
                           WHERE run_id = :run_id AND validation_status <> 'OK')),
       CURRENT_TIMESTAMP()
FROM QA_RAW WHERE run_id = :run_id;
```

Create `PIPELINE_QUALITY_LOG (run_id VARCHAR, stage VARCHAR, total_calls INT, unparseable_calls INT,
detail VARIANT, logged_at TIMESTAMP_LTZ)` once; every phase writes to it.

## Verification at the gate

```sql
-- Coverage: eligible vs scored.
SELECT (SELECT COUNT(*) FROM CALL_ELIGIBILITY WHERE role_eligible)              AS role_eligible_calls,
       (SELECT COUNT(*) FROM CALL_ELIGIBILITY WHERE NOT role_eligible)          AS not_eligible_calls,
       (SELECT COUNT(*) FROM QA_CALL_SCORES WHERE run_id = :run_id)             AS scored_calls,
       (SELECT COUNT(*) FROM QA_CALL_SCORES WHERE run_id = :run_id AND criteria_scored = 0) AS scored_nothing;

-- Per-criterion distribution: a criterion with ~zero stddev is not discriminating (Q6).
SELECT criterion_id,
       COUNT_IF(applicable)                         AS applicable_calls,
       ROUND(100.0 * COUNT_IF(NOT applicable) / COUNT(*), 1) AS pct_na,
       ROUND(AVG(score), 2)                         AS avg_score,
       ROUND(STDDEV(score), 2)                      AS sd_score,
       COUNT_IF(validation_status <> 'OK')          AS rejected
FROM QA_CRITERION_SCORES WHERE run_id = :run_id
GROUP BY 1 ORDER BY 1;

-- Evidence guarantee: must be zero rows.
SELECT COUNT(*) AS scored_without_evidence
FROM QA_CRITERION_SCORES
WHERE run_id = :run_id AND applicable AND validation_status = 'OK'
  AND COALESCE(ARRAY_SIZE(evidence_seq), 0) = 0;

-- Spot check, redacted text only, only if the user asks to see examples.
SELECT call_id, criterion_id, score, evidence
FROM QA_CRITERION_SCORES WHERE run_id = :run_id AND applicable
ORDER BY RANDOM() LIMIT 5;
```

Also check the evidence quotes are actual substrings of the cited segments on a sample. A quote that does not
appear in the transcript means the model paraphrased or invented; tighten the instruction or switch models.

```sql
SELECT COUNT(*) AS checked,
       COUNT_IF(NOT CONTAINS(LOWER(seg_text), LOWER(LEFT(q.evidence, 40)))) AS quote_not_found
FROM (
    SELECT q.call_id, q.evidence, q.evidence_seq,
           (SELECT LISTAGG(s.text_redacted, ' ') FROM CALL_SEGMENTS_REDACTED s
            WHERE s.call_id = q.call_id AND ARRAY_CONTAINS(s.seq::VARIANT, q.evidence_seq)) AS seg_text
    FROM QA_CRITERION_SCORES q
    WHERE q.run_id = :run_id AND q.applicable AND q.validation_status = 'OK'
    LIMIT 500
) q;
```

## What this phase does not do

It does not decide anything about an agent. It produces scores, evidence and a coaching note per call. Agent
rollups (by week, by team, by criterion) are built in Phase 7 with minimum-call thresholds so one bad call does
not define a person, and they carry the Phase 6 agreement rate alongside.

Then `phases.qa: done` and record objects.
