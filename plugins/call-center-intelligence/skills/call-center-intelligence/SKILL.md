---
name: call-center-intelligence
description: "**[REQUIRED]** Use for ALL requests about turning contact-center calls, call recordings, or call transcripts in Snowflake into business signal. Triggers: call center intelligence, contact center analytics, speech analytics, conversation intelligence, call recordings, call transcripts, transcribe calls, AI_TRANSCRIBE on calls, contact reasons, call drivers, why are customers calling, top call reasons, agent QA, quality assurance scoring, automated QA, QA scorecard, call scoring, coaching insights, escalation drivers, supervisor requests, repeat contacts, repeat calls, first contact resolution, FCR, callbacks, handle time, AHT reduction, deflection, self-service opportunity, IVR containment, save desk, retention calls, cancellation calls, churn on calls, upsell signals, cross-sell on calls, redact call transcripts, PII in transcripts, PCI in recordings, voice of the customer from calls, call center cost reduction, hidden revenue in call recordings. This is the REQUIRED entry point for this work even if the request seems simple. DO NOT hand-write the transcription, redaction, classification or QA SQL; always invoke this skill first."
---

# Call Center Intelligence — Router

## What this builds and why

Contact centers record and often transcribe every call, then read almost none of them. A QA team
typically samples a small slice of calls by hand, contact reasons come from an agent-selected
disposition code that is frequently wrong or "Other", and the reasons customers call back, escalate,
or cancel are anecdotes rather than numbers. That leaves money on two sides of the P&L:

- **OpEx.** Handle time spent on avoidable and repeat contacts, manual QA labor that covers a fraction
  of calls, and contacts that self-service could have deflected if anyone knew which reasons drive
  volume.
- **Revenue.** Customers who stated an intent to cancel and were never offered a save, and buying
  signals that were voiced and never followed up.

This plugin builds a pipeline over calls **already in Snowflake** (audio files on a stage, transcript
text in a table, or both) that emits, per call: redacted transcript, contact reason(s), repeat-contact
and escalation flags with drivers, a rubric-based QA score with cited evidence, sentiment trajectory,
and save/upsell signals. It then rolls those up into a semantic view and a Cortex Agent, and produces a
value readout.

**Scope boundary.** Ingestion from the telephony or CCaaS platform is out of scope; recordings and
transcripts are assumed landed. The pipeline ends at scored tables, a semantic view, and an agent.
There is no coaching application and no write-back to the workforce-management or CRM system.

## Setup — do these before anything else

1. **Read** `PROJECT_STATE.md` (this directory). It defines `callcenter-project.yml`, the single state
   file every phase reads and writes.
2. **Load** `call-center-system-of-record/SKILL.md`. Required first step in every session.
3. **Load** `call-center-best-practices/SKILL.md`. Required. These rules prevent silent failure modes
   specific to audio, redaction and call scoring.
4. **Settle the redaction posture** and record it in `redaction`. The default, already decided for this
   play, is that **AI_REDACT runs before any other AI function sees transcript text**. A customer may
   opt out (for example, because their CCaaS vendor already redacts upstream). An opt-out is recorded
   explicitly with who decided, when, and why; it is never inferred from silence. See the redaction
   section below.
5. **Settle how the pipeline is built** — dbt or plain SQL — and record `materialization.mode`. Read
   `DBT_MATERIALIZATION.md` and delegate dbt deploy and execute mechanics to the
   **`dbt-projects-on-snowflake`** skill. Recommend dbt when the build will outlive the first demo,
   because dbt tests become build-failing gates on redaction leakage, QA coverage and parse failures.
   Recommend plain SQL for a time-boxed proof of value.

> **PII and PCI caution.** Recordings and transcripts contain names, phone numbers, addresses and
> sometimes spoken card numbers. Never write transcript text, audio, or extracted signals to a local
> file, a log, an issue tracker, or anywhere outside the account. Show samples in the session only when
> the user asks, show **redacted** text when you do, and prefer synthetic sandbox calls for any demo.

## Intent detection

| Intent | Trigger phrases | Route |
|---|---|---|
| **BUILD** | "set up call analytics", "build speech analytics on our recordings", "start from scratch", "why are people calling us" | Run the phased build below |
| **RESUME** | "continue", "pick up where we left off", "what's left" | Read `phases`, report status, continue at first phase not `done` |
| **SINGLE_PHASE** | names one phase: "just transcribe", "re-run QA scoring", "rebuild the taxonomy", "regenerate the sandbox", "render audio" | Load that phase's skill after confirming prerequisites are `done` |
| **EVALUATE** | "how accurate is it", "does the QA score match our reviewers", "is redaction catching card numbers", "what does this cost per call" | `evaluate-call-intelligence-accuracy/SKILL.md` |
| **VALUE** | "what is this worth", "build the business case", "ROI", "POC success criteria" | `call-center-value-readout/SKILL.md` |
| **DEBUG** | "transcripts are empty", "everything is Other", "QA scores are all the same", "sentiment is null", "PII is leaking" | `DIAGNOSING.md` (this directory) |
| **COMPARE** | "did the new rubric help", "compare the two runs", "A/B the taxonomy" | `evaluate-call-intelligence-accuracy/SKILL.md`, across `experiment_id` |
| **CUSTOMIZE** | "use our QA form", "our reason codes", "change the rubric" | `score-agent-qa` (rubric) or `classify-contact-reasons` (taxonomy); bump `prompt_version` |
| **EXPLAIN** | "how does this work", "walk me through the architecture" | Answer from this file. Create nothing. |

If intent is unclear, ask. Do not default to BUILD, because BUILD creates objects and spends tokens.

## The phased build

Each phase is a gate. The gate protocol is not optional:

1. State what the phase will create — object names and types.
2. State what it will cost when it makes AI calls over a table: audio in **tokens from duration**
   (AI_TRANSCRIBE bills 50 tokens per second of audio, minimum 10 seconds per file), text via
   `AI_COUNT_TOKENS` on a sample. Report tokens. Say output tokens bill on top for text functions. Never
   convert to dollars.
3. Get confirmation with `ask_user_question`.
4. Run it.
5. Show a verification query and its actual result.
6. Update `phases` and `created_objects` in `callcenter-project.yml`.

Never chain two gates without stopping. A user who wanted contact reasons on a sample should not
discover that a year of audio has been transcribed.

| # | Phase | Skill | Creates | Skippable |
|---|---|---|---|---|
| 0 | Preflight | `call-center-system-of-record` | nothing | no |
| 1 | Sandbox | `seed-call-center-sandbox` | synthetic calls, transcripts, metadata, answer key | yes, if real data has a labeled sample |
| 1b | Test corpus | `build-call-test-corpus` | synthetic audio files on a stage + manifest | yes, if the customer has transcripts only |
| 2 | Transcribe and redact | `transcribe-and-redact-calls` | normalized, speaker-attributed, redacted segment table | no |
| 3 | Contact reasons | `classify-contact-reasons` | taxonomy table, per-call reasons, repeat and escalation flags | no |
| 4 | Agent QA | `score-agent-qa` | rubric table, per-call per-criterion scores with evidence | yes, if the customer only wants drivers |
| 5 | Save and upsell | `extract-save-upsell-signals` | per-call retention and sales signal table | yes, if no retention or sales motion on calls |
| 6 | Evaluation | `evaluate-call-intelligence-accuracy` | accuracy, redaction-leak, cost, and parse-failure reports | no |
| 7 | Operationalize | `operationalize-call-insights` | incremental pipeline, driver rollups, semantic view, Cortex Agent | yes, for a pure assessment |
| 8 | Value readout | `call-center-value-readout` | value model and POC criteria (document, not objects) | no |

### Phase order is a real dependency chain

- **Redaction before every other AI function.** Contact reason, QA, sentiment and extraction all read
  the redacted segment table, never the raw one. A classification run over raw text has already sent
  PII through a model and written derived text that may echo it.
- **Speaker attribution before QA and sentiment.** QA scores the agent's behavior and sentiment is
  meaningful per party. If the pipeline cannot tell agent turns from customer turns, both are noise.
- **Contact reasons before save/upsell.** Save signals are only meaningful on calls whose reason is a
  cancellation or downgrade intent, and upsell is scored differently on a complaint call than on a
  sales call.
- **Evaluation before operationalize.** Scheduling a pipeline whose redaction recall and reason
  accuracy nobody measured puts unmeasured QA scores in front of supervisors every morning.
- **Value readout last**, because its inputs include measured accuracy and measured tokens per call.

### Strongly recommend the sandbox first

Push back once if the user wants to skip Phase 1:

> The sandbox ships calls with known answers: the contact reason, whether it is a repeat, whether the
> agent made a save offer, the expected QA score per criterion, and every piece of PII planted in it.
> That makes accuracy and redaction-leak rate measurable immediately. On real calls there is no ground
> truth until QA analysts label a sample, and the redaction leak rate in particular cannot be measured
> at all without planted PII.

If they still want real data, mark `seed: skipped` and recommend a labeled sample of real calls from
their QA team before evaluation.

## Inputs this play supports — audio, text, or both

Decided for this play: the corpus may be audio files, transcript text, or a mix. Preflight records
which in `calls.input_mode` (`audio`, `transcript`, `mixed`). Every downstream phase reads one
normalized table — `CALL_SEGMENTS_REDACTED` — so the rest of the pipeline is indifferent to where text
came from. Two things differ by mode and must be reported:

- **Cost.** Audio transcription is the largest single token line in an audio build and scales with
  minutes, not with text length.
- **Speaker attribution.** Vendor transcripts usually carry an agent/customer channel. AI_TRANSCRIBE
  returns `SPEAKER_00`, `SPEAKER_01` in order of first detection, which is not a role. Phase 2 resolves
  roles; in mixed mode, report attribution confidence separately for each source.

## Redaction is on by default, and an opt-out is explicit

The order is fixed: transcribe (if audio) -> redact -> everything else. `transcribe-and-redact-calls`
owns the mechanics. Router-level rules:

- `redaction.enabled: true` unless the user explicitly opts out. If they do, record
  `redaction.enabled: false`, `redaction.opt_out_by`, `redaction.opt_out_date`, and
  `redaction.opt_out_reason` in the state file, and repeat the opt-out in the Phase 6 report and the
  value readout so nobody downstream assumes redaction happened.
- Redaction does not touch audio. The audio on the stage remains fully sensitive; preflight reports
  who can read the stage.
- Redaction is measured, not assumed: the sandbox plants PII and Phase 6 reports the leak rate per
  category. A non-zero leak rate on `PAYMENT_CARD_DATA` is reported as a finding, not a footnote.

## QA uses a generic rubric the customer can override

Decided for this play: `score-agent-qa` ships a generic rubric (greeting and verification,
discovery, accuracy of information, resolution, empathy and tone, compliance statements, closing). The
customer may replace it with their own form. The rubric is data, stored in a table with a version and a
hash, and every score row records which rubric version produced it. Never silently mix scores from two
rubric versions in one trend line.

## Every run is a labelled experiment

Before Phase 3, set `experiment.run_id`, `experiment_id`, `experiment_name`, and `prompt_version`.
These are selected into every output row, together with `taxonomy_version`, `rubric_version`, and a
`prompt_hash` computed from the assembled prompt that actually ran. Output layers accumulate rather than
replace, so experiments can be compared side by side.

## Verification queries to run at each gate

| Phase | Verification |
|---|---|
| Transcribe and redact | files in scope vs transcripts produced vs transcription errors (counted, not dropped); segments with unresolved speaker role; chunks whose redaction returned NULL (must be zero or explained); sandbox planted-PII leak count |
| Contact reasons | reason distribution with percent; share in `Other` (investigate above the threshold set at the gate); calls with no reason (must be zero); repeat and escalation rates against metadata |
| Agent QA | calls scored vs eligible; per-criterion score distribution (a criterion with one value across all calls is not discriminating); rows with a score but no evidence (must be zero); N/A rate per criterion |
| Save and upsell | cancellation-intent calls vs save-offer rate vs accepted; upsell mentions vs offers vs accepts |
| Evaluation | reason macro-F1, QA agreement with labels, save/upsell precision and recall, redaction leak rate by category, parse failures, tokens per 1K calls |
| Operationalize | stream has data or not; last task run status; semantic view answers two reference questions with numbers that match the base tables |

## When the user asks what this costs

Stay in tokens. For audio builds, transcription dominates and is fully predictable from duration:
`total_audio_seconds x 50` plus `10 s x 50` for every file shorter than 10 seconds. Redaction is the
second line, because it processes the whole transcript in chunks and its billed tokens include the
regenerated text. Classification, sentiment and extraction run on targeted slices of the transcript
rather than whole calls, which is a deliberate lever. Phase 6 reports measured tokens per 1K calls on
this corpus. Do not quote figures from elsewhere as this account's numbers.

## Teardown

Read `created_objects` from `callcenter-project.yml` and drop exactly what is listed. Confirm first and
name each object. Warn if QA score tables have rows that supervisors may already have used, and never
drop the customer's source recording stage — it is not in `created_objects` because this plugin did not
create it.
