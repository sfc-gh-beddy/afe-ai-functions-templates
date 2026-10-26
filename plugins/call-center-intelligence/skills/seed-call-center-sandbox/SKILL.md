---
name: seed-call-center-sandbox
description: "Generate a synthetic contact-center corpus with a labeled answer key so a call-center-intelligence pipeline can be built, demonstrated, and accuracy-tested before touching real recordings or customer PII. Creates agents, customers, call detail records with noisy dispositions, vendor-style transcripts (segment grain and full-text blobs), an audio-only subset for the transcription path, repeat contacts generated from unresolved calls, and planted PII in digit and spoken-word forms. The answer key records contact reason, repeat, escalation source, cancel intent, save offer and outcome, buying signal, upsell outcome, per-criterion QA scores with applicability, true speaker roles, and every planted PII value. Includes distractor and borderline calls. Phase 1 of the call-center-intelligence build."
parent_skill: call-center-intelligence
---

# Seed the sandbox

Generate a synthetic call corpus with **ground truth**. This makes contact-reason accuracy, QA agreement,
save/upsell precision and — most importantly — **redaction leak rate** measurable on day one, and lets
the build be demonstrated before anyone grants access to real recordings.

## Why not just point at real calls

Phase 1 is skippable, but be clear about what is given up:

- **Redaction leak rate is unmeasurable on real data** without someone manually finding every piece of PII
  in a sample. The sandbox plants it, so leakage is a number, including for spoken card numbers.
- **QA agreement needs labeled calls.** A customer's QA team may have scores, but rarely with
  applicability per criterion; the sandbox has both.
- **Repeat contacts and save gaps are constructed**, so their recall is known.

Recommend the sandbox first, then a labeled sample of 100 to 300 real calls scored by the customer's QA
analysts before any score is shown to a supervisor.

## Configure before generating

Ask, default sensibly, write into `callcenter-project.yml` under a `sandbox:` key.

| Parameter | Default | Notes |
|---|---|---|
| `CALL_COUNT` | 600 | base calls; follow-ups are added on top. Keep at or below 900 (the customer count) so the only repeats are constructed ones |
| `REPEAT_SHARE` | 0.6 | share of calls on unresolved scenarios that generate a follow-up within 1–5 days |
| `AUDIO_SHARE` | 0.25 | share of calls with no vendor transcript; these exercise AI_TRANSCRIBE once `build-call-test-corpus` renders them |
| `FULLTEXT_SHARE` | 0.10 | share of transcript calls delivered as one blob with inline `Agent:` / `Customer:` markers |
| `START_DATE` | three weeks before today | calls spread over 21 days so a 7-day repeat window has room |
| `MIN_CALL_SECONDS` | `definitions.min_call_seconds` | must match, or the scope comparison in Phase 6 is off |

Cost note: generation runs no AI functions. It is pure SQL and costs warehouse time only.

## What gets created

Sandbox schema (`{{SCHEMA}}`) — what the pipeline maps, as it would map a customer's tables:

| Object | Plays the role of |
|---|---|
| `SYNTH_AGENTS` | agent roster |
| `SYNTH_CUSTOMERS` | customer master (fabricated) |
| `SYNTH_CALL_DETAIL_RECORDS` | CDR / interaction metadata: ids, queue, start, recording and handle seconds, hold, transfer flag, noisy disposition, `audio_only`, `recording_path` |
| `SYNTH_CALL_TRANSCRIPTS` | vendor transcript export, segment grain with `AGENT` / `CUSTOMER` / `SYSTEM`, plus full-text blobs with `seq = 0` and `NULL` role |

Eval schema (`{{EVAL_SCHEMA}}`) — quarantined, read only by `evaluate-call-intelligence-accuracy`:

| Object | Purpose |
|---|---|
| `SYNTH_SCENARIOS` | the hand-authored conversation templates and their labels |
| `SYNTH_CALL_SCENARIO` | which scenario each call was generated from, and the prior call for repeats |
| `SYNTH_CALL_PII_VALUES` | the fabricated values substituted into each call |
| `SYNTH_TRUE_SEGMENTS` | every segment with its **true** role and raw text — source for audio rendering and role accuracy |
| `SYNTH_ANSWER_KEY_CALLS` | per-call labels |
| `SYNTH_ANSWER_KEY_QA` | per-call, per-criterion applicability and expected score (1–5) |
| `SYNTH_ANSWER_KEY_PII` | every planted PII occurrence with category, form (`text`, `digits`, `words`) and segment |
| `SYNTH_AUDIO_RENDER_MANIFEST` | view used by the audio rendering script |

`sql/01_seed_sandbox.sql` is the template. Read it, substitute every `{{...}}` placeholder, and run it.
Do not run it unmodified.

## The answer key is quarantined

- It lives in a separate schema. The pipeline role should not have `USAGE` on it; if the same role is used
  for both in a demo, say so and show that no pipeline query references the schema.
- `SYNTH_SCENARIOS` is in the eval schema too: its rows are the labels.
- Nothing from the eval schema appears in a prompt, a few-shot example, a taxonomy description, or a
  rubric. Few-shot examples for AI_CLASSIFY, if used, are written fresh, not copied from scenarios.

A pipeline that has seen its own answer key produces meaningless numbers. `SELECT *` over the wrong schema
is enough to leak it.

## How the scenarios are constructed

Twenty scenarios, each a complete conversation. Labels are deliberate:

| Scenario | Tests |
|---|---|
| `BILL_DOUBLE_CHARGE` | clean, resolved billing call; high QA on every applicable criterion |
| `BILL_LATE_FEE_POOR` -> `BILL_LATE_FEE_FOLLOWUP` | poor QA, unresolved, generates a repeat that **references the prior contact** |
| `CANCEL_SAVED` | cancel intent, offer made, accepted, includes an IVR turn and a transfer |
| `CANCEL_NO_OFFER` | cancel intent with **no save offer** — the revenue gap the readout values |
| `CANCEL_DECLINED` | offer made and declined; must not count as a miss by the agent |
| `TECH_OUTAGE_ESCALATED` -> `TECH_OUTAGE_FOLLOWUP` | supervisor request **and** transfer; phone number read out in words |
| `TECH_SLOW_UPSELL` | technical reason with a secondary upgrade; buying signal, offer, acceptance |
| `ACCOUNT_LOCKED` | heavy PII: name, DOB, full national ID volunteered, email; self-service candidate |
| `PAYMENT_BY_PHONE` | card number in **words** and read back in **digits**; compliance criterion scores low because the agent repeated the full number |
| `ORDER_STATUS` | simple, deflectable reason |
| `PLAN_UPGRADE_INBOUND` | customer-initiated upgrade; upsell to a higher tier accepted |
| `DISTRACTOR_CANCEL_APPOINTMENT` | "cancel" that is not cancel intent — catches naive save extraction |
| `DISTRACTOR_DISCOUNT_HEARSAY` | customer mentions a discount they heard about; **no offer was made on this call** |
| `COMPLAINT_SUPERVISOR_UNAVAILABLE` | supervisor requested, **no transfer** — catches collapsed escalation flags |
| `MULTI_BILLING_AND_ORDER` | genuine two-reason call; tests multi-label secondary reasons |
| `MISROUTED_OTHER` | belongs in `Other`; verification criterion is N/A |
| `SHORT_ABANDON` | below the minimum length; must be excluded and counted, not scored |

Disposition codes are correct roughly 60 percent of the time and otherwise `GENERAL`, `OTHER` or
`RESOLVED`, so the "model reason vs disposition" comparison has something real to find.

## Planted PII

Every placeholder substituted into a call is recorded in `SYNTH_ANSWER_KEY_PII`:

| Category | Forms planted |
|---|---|
| `NAME` | customer full name, agent first name |
| `PHONE_NUMBER` | digits (`206-555-01xx`) and spoken words |
| `EMAIL` | `@example.com` addresses |
| `ADDRESS` | fabricated street, fabricated town |
| `DATE_OF_BIRTH` | long-form date |
| `PAYMENT_CARD_DATA` | published test card numbers, as digits and as spoken words |
| `NATIONAL_ID` | 9xx-area numbers, a range never issued as a US SSN |

Agent names are planted on purpose: redaction should remove them (best-practices R5), and the pipeline
must still attribute the call to the agent through `agent_id`.

Whether AI_REDACT detects the spoken-word forms is not documented. That is exactly what the sandbox is
for; report it from Phase 6 rather than asserting it.

## Verification before declaring the phase done

`sql/02_verify_sandbox.sql` holds the full read-only verification set (eleven checks, each with its expected
result). Run all of it and show the results. The most important ones are reproduced here.

```sql
-- 1. Population shape: long-tailed reasons, follow-ups present, audio-only share as configured.
SELECT ak.contact_reason,
       COUNT(*)                         AS calls,
       COUNT_IF(ak.is_repeat)           AS repeats,
       COUNT_IF(ak.audio_only)          AS audio_only,
       COUNT_IF(NOT ak.in_scope)        AS out_of_scope,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
GROUP BY 1 ORDER BY calls DESC;
```

```sql
-- 2. Every follow-up is really a repeat by the metadata definition:
--    same customer, prior call within the configured window. If not, the
--    harness will report repeat-detection misses that are seed bugs.
SELECT ak.call_id
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS ak
JOIN SYNTH_CALL_DETAIL_RECORDS cur ON cur.call_id = ak.call_id
JOIN SYNTH_CALL_DETAIL_RECORDS pri ON pri.call_id = ak.prior_call_id
WHERE ak.is_repeat
  AND (cur.customer_id <> pri.customer_id
       OR DATEDIFF(day, pri.call_start_ts, cur.call_start_ts) > :repeat_window_days);
-- Expect zero rows.
```

```sql
-- 3. Audio-only calls have NO vendor transcript (otherwise mixed mode
--    double-processes them), and transcript calls do have one.
SELECT COUNT_IF(d.audio_only AND t.call_id IS NOT NULL)     AS audio_with_transcript,
       COUNT_IF(NOT d.audio_only AND t.call_id IS NULL)     AS transcript_missing
FROM SYNTH_CALL_DETAIL_RECORDS d
LEFT JOIN (SELECT DISTINCT call_id FROM SYNTH_CALL_TRANSCRIPTS) t ON t.call_id = d.call_id;
-- Expect 0 and 0.
```

```sql
-- 4. Planted PII exists in every category and form, and actually appears
--    in the vendor transcripts (proves substitution worked).
SELECT pk.category, pk.form, COUNT(*) AS planted,
       COUNT_IF(CONTAINS(t.utterance_text, pk.planted_value)) AS present_in_vendor_text
FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_PII pk
LEFT JOIN SYNTH_CALL_TRANSCRIPTS t
  ON t.call_id = pk.call_id AND (t.seq = pk.seq OR t.seq = 0)
GROUP BY 1, 2 ORDER BY 1, 2;
-- present_in_vendor_text should equal planted minus audio-only calls.
```

```sql
-- 5. No unsubstituted placeholders anywhere.
SELECT COUNT(*) AS leftover_placeholders
FROM SYNTH_CALL_TRANSCRIPTS
WHERE CONTAINS(utterance_text, '{{');
-- Expect 0.
```

```sql
-- 6. Distractors and borderline cases are present in volume.
SELECT case_role, COUNT(*) FROM {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS GROUP BY 1;
```

Then set `phases.seed: done` and record every created object, in both schemas, in `created_objects`.

## Keep it synthetic, and obviously synthetic

- Every identifier is prefixed `SYN-`. Names are transparently fabricated (`Synthia Testerson`).
- Card numbers are published test numbers; phones are in the fictional 555-01xx range; national IDs use
  the 9xx area. Never replace them with realistic real-world values.
- Conversations are coherent. Nonsense dialogue makes every classifier look good.
- The scenario taxonomy is generic (subscription services). Do not model it on a specific real
  organization's queues; the customer's taxonomy arrives through `classify-contact-reasons`.

## Teardown

Drop the sandbox once real data is wired in, so synthetic calls do not end up in a supervisor's
dashboard. Use `created_objects`; drop both schemas' objects and the rendered audio stage if Phase 1b ran.
