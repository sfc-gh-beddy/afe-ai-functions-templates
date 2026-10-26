# Call Center Intelligence

A guided build that turns contact-center calls already in Snowflake — audio recordings, vendor transcripts, or
both — into contact reasons, agent QA scores, escalation and repeat-contact drivers, and save/upsell signals, with
measured accuracy and a value readout. Everything runs inside the account.

## The problem

Contact centers record nearly every call and listen to almost none of them.

- **QA covers a sliver.** Analysts score a small manual sample, so coaching is driven by whichever calls happened
  to be picked.
- **Contact reasons are guesses.** The agent picks a disposition code at the end of the call, often a generic one,
  so the reasons that drive volume, repeats and escalations are anecdote.
- **Repeat contacts and escalations have no "why".** The CDR says a customer called back; it does not say what the
  first call failed to do.
- **Revenue walks out on recorded lines.** Customers state an intent to cancel and are never offered a save;
  customers describe a need a product would meet and nobody offers it.

The signal for all of this is in recordings the organization already stores.

**Levers:** OpEx (handle time on avoidable and repeat contacts, QA labor, self-service deflection) and revenue
(saves, upsell).

## What this plugin builds

```
Call audio (stage) and/or vendor transcripts (table) + call detail records
  -> scope              exclude abandons and unreachable files; count every exclusion
  -> AI_TRANSCRIBE      audio only; speaker timestamps where the 60-minute limit allows; errors counted
  -> normalize          one segment grain across audio, vendor segments and full-text blobs
  -> AI_REDACT          on by default, before any other model sees text; chunked; no raw fallback
  -> speaker roles      SPEAKER_nn -> AGENT / CUSTOMER / IVR, resolved and measured
  -> contact reasons    AI_CLASSIFY on the customer's opening, versioned taxonomy, catch-all gate
  -> outcomes           repeats from metadata, escalation sources kept separate, resolution via AI_EXTRACT
  -> sentiment          AI_SENTIMENT on opening and closing slices, aspect-level
  -> agent QA           rubric as data, AI_COMPLETE with a JSON schema, cited evidence, N/A not zero
  -> save / upsell      screened with AI_FILTER, extracted with AI_EXTRACT, offer separate from outcome
  -> CALL_FACTS         one row per call, no transcript text
  -> rollups, AI_AGG / AI_SUMMARIZE_AGG driver narratives, semantic view, Cortex Agent for CoWork
  -> evaluation and value readout
```

## Decisions already made for this play

- **Corpus supports audio and text.** `calls.input_mode` is `audio`, `transcript` or `mixed`; every downstream phase
  reads one normalized, redacted segment table.
- **QA uses a generic rubric the customer can override.** The rubric is a versioned table; a customer form becomes a
  new rubric version, never an in-place edit.
- **AI_REDACT runs by default before any other AI function**, with an explicit opt-out recorded in project state
  (who, when, why). Redaction is measured against planted PII, not assumed.

## What it does not build

- **Ingestion** from the telephony or CCaaS platform. Recordings and transcripts are assumed landed.
- **A coaching or QA workflow application**, or write-back to WFM, CRM or the QA tool.
- **Decisions about agents.** Scores are coaching signal with measured agreement against human reviewers.

## Getting started

Ask in plain language:

- "why are customers calling us — we have the recordings in Snowflake"
- "set up automated QA on our call transcripts"
- "find calls where customers wanted to cancel and nobody tried to save them"
- "what is driving repeat calls in billing"

The build runs in gated phases. Each says what it will create and what it will cost in tokens, waits for
confirmation, runs, and shows a verification query. State lives in `callcenter-project.yml`.

**Start in the sandbox.** Phase 1 generates synthetic calls with a labeled answer key — contact reason, repeat,
escalation source, cancel intent, save offer and outcome, upsell, per-criterion QA scores, true speaker roles, and
planted PII in digit and spoken-word form. Accuracy and redaction leak rate are measurable on day one, before anyone
grants access to real recordings.

**If the corpus includes audio**, also run `build-call-test-corpus`, which renders the sandbox's audio-only calls to
WAV with distinct voices and graded conditions (telephony, noise, leading silence, stereo channel split) so the
transcription and diarization path is tested rather than simulated.

## Skills

| Skill | Role |
|---|---|
| `call-center-intelligence` | Entry point. Intent detection, phase gating, redaction posture, state contract, dbt mapping, diagnosis. |
| `call-center-system-of-record` | Preflight: function access, region and cross-region for AI_TRANSCRIBE, models, call inventory and metadata mapping, duration profile, channel layout, vendor-redaction evidence, PII/PCI posture. |
| `call-center-best-practices` | Correctness rules. Always loaded. |
| `seed-call-center-sandbox` | Synthetic calls, transcripts and CDRs with distractors, repeats, planted PII and a quarantined answer key. |
| `build-call-test-corpus` | Renders sandbox calls to audio on a stage under graded conditions. Needed for audio or mixed input. |
| `transcribe-and-redact-calls` | AI_TRANSCRIBE, normalization, AI_REDACT, speaker-role resolution. |
| `classify-contact-reasons` | Taxonomy, AI_CLASSIFY reasons, repeats, escalation sources, resolution, sentiment. |
| `score-agent-qa` | Rubric-as-data QA scoring with cited evidence and customer override. |
| `extract-save-upsell-signals` | Cancel intent, save offers and outcomes, buying signals, upsell, competitor mentions. |
| `evaluate-call-intelligence-accuracy` | Redaction leak rate, role accuracy, CER, reason F1, QA agreement, signal precision/recall, silent loss, tokens per 1K calls. |
| `operationalize-call-insights` | Stream and task graph, CALL_FACTS, dynamic-table rollups, driver narratives, semantic view, Cortex Agent. |
| `call-center-value-readout` | Value model with customer-supplied inputs only, measured cost, POC criteria. |

## Requirements

- A role with `SNOWFLAKE.CORTEX_USER` (preflight verifies each function and reports the exact missing grant).
- For audio: an account in a region where AI_TRANSCRIBE is available, or cross-region inference enabled by the
  account administrator as a deliberate data-residency decision. Preflight checks both.
- A warehouse, and a database and schema the role can create objects in.
- For the audio test corpus: `ffmpeg` and a local TTS engine (`say` on macOS or `espeak-ng`).

## A note on PII, PCI, and people

Every AI function call runs inside Snowflake. Redaction removes PII from transcripts and from everything derived from
them; it does not touch audio, so preflight reports who can read the recording stage. Spoken card numbers are a known
weak spot for text redaction and are measured, not assumed. Agent QA scores are HR-sensitive: they carry rubric
version and measured agreement, roll up only above a minimum call count, and are governed by the customer's QA
process rather than by this pipeline.
