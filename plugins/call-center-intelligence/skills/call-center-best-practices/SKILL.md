---
name: call-center-best-practices
description: "Correctness rules every call-center-intelligence pipeline must follow. Always loaded by the call-center-intelligence router. Catches silent failure modes in call analytics: AI_TRANSCRIBE returning NULL on error and its string-JSON return type, the 60-minute limit with speaker timestamps, the 10-second minimum bill, language detection failing on IVR silence, SPEAKER_00 not meaning agent, stereo channel loss, AI_REDACT failing the whole query by default and its 4,096/1,024 token limits, spoken card numbers, redaction erasing agent attribution, AI_SENTIMENT 2,048-token window and 'unknown' versus neutral, AI_CLASSIFY case sensitivity and catch-all labels, contact reason taken from the opening not the whole call, repeat contact as a metadata fact, escalation source separation, QA N/A versus zero, evidence-cited rubric scoring, AI_EXTRACT string-only schema, offer versus acceptance, AHT from the system of record, AI_SUMMARIZE_AGG narratives that are not counts, measurement traps, experiment tracking, and dbt and task traps."
parent_skill: call-center-intelligence
---

# Call center intelligence — correctness rules

Every rule here has a failure mode in which the SQL succeeds, the row counts look plausible, and the
result is wrong. Apply them to every artifact this plugin generates. Rules are grouped: **A** audio and
transcription, **R** redaction, **T** transcript structure, **S** sentiment, **C** contact reasons,
**Q** agent QA, **X** extraction, **G** aggregation, **M** measurement, **O** operations.

Function behavior below was checked against the Snowflake documentation for AI_TRANSCRIBE, AI_REDACT,
AI_SENTIMENT, AI_CLASSIFY, AI_EXTRACT, AI_SUMMARIZE_AGG, AI_AGG and AI_COUNT_TOKENS. Where a behavior is
an inference rather than documented, it says so; verify it on the sandbox before relying on it.

---

## A. Audio and transcription

### A1. AI_TRANSCRIBE returns NULL on failure by default — count it

**The failure:** a batch transcription over a stage completes successfully, a share of rows are `NULL`,
and those calls vanish from every downstream join. A `NULL` transcript reads exactly like "this call had
nothing in it". Contact-reason distributions and QA coverage are then computed over survivors only.

**The rule:** always pass `return_error_details => TRUE` (third positional argument) and persist the
error. The function then returns an OBJECT with `value` and `error`, one of which is `NULL`.

```sql
SELECT call_id,
       AI_TRANSCRIBE(TO_FILE('@' || :stage, recording_path),
                     {'timestamp_granularity': 'speaker'},
                     TRUE) AS tx
FROM calls_to_transcribe;

-- then
SELECT COUNT(*)                          AS files,
       COUNT_IF(tx:error IS NOT NULL)    AS failed,
       COUNT_IF(tx:value IS NULL AND tx:error IS NULL) AS null_without_error
FROM transcribe_raw;
```

Failed rows go to a quality log with the error text. They are never filtered out with
`WHERE tx IS NOT NULL` upstream of the count.

### A2. The return value is a JSON string — parse it defensively

Documented as "a string containing a JSON representation". With `return_error_details => TRUE`, the
`value` field is a VARCHAR. Parse with `TRY_PARSE_JSON(TO_VARCHAR(...))` so the expression works whether
the value arrives as a string or (as AI_PARSE_DOCUMENT has been observed to do on some accounts) an
OBJECT. A plain `PARSE_JSON` on an OBJECT is a compile error; a plain `:segments` path on a string
returns `NULL` silently.

```sql
TRY_PARSE_JSON(TO_VARCHAR(tx:value)) AS tx_json
```

### A3. Know the hard limits before batching

From the documentation, verified:

| Limit | Value | Consequence if ignored |
|---|---|---|
| Max file size | 700 MB | error row |
| Max duration with `timestamp_granularity` = `word` or `speaker` | 60 minutes | error row on long escalated calls, exactly the calls you most want |
| Max duration without timestamps | 120 minutes | — |
| Minimum billed duration | 10 seconds | a corpus of short abandons bills 10 s each |
| Language detection | speech must begin in the first 5 seconds | IVR silence, hold music or a beep at the start can defeat detection |
| Billing | 50 tokens per second of audio | predictable from duration; AI_COUNT_TOKENS does not accept audio |

Rules that follow:

- Pre-filter by duration from metadata. Calls over 60 minutes either run without speaker timestamps
  (and get speaker roles from the text-only path in T2) or are split upstream. Record which.
- Exclude calls shorter than `definitions.min_call_seconds` before transcription, and count them.
  They are mostly abandons and cost a 10-second minimum each.
- If recordings begin with an IVR prompt or silence, say so at preflight. The documentation recommends
  trimming excess leading silence. Test on the sandbox corpus (it renders files with a leading silence
  variant) before assuming detection works.

### A4. Stereo channel separation is not preserved

Documented: AI_TRANSCRIBE internally converts to **monophonic** 16 kHz audio. Many contact-center
platforms record agent and customer on separate stereo channels, which is the most reliable speaker
attribution signal available. That signal does not survive the call.

If `calls.audio_channel_layout` is `stereo_split`, the strongest option is to split channels upstream
into two mono files per call and transcribe each, so role comes from the channel rather than from a
diarization label. Whether this is worth the doubled token cost is the customer's call; record the
decision. If splitting is not possible, use the T2 role-resolution path.

### A5. SPEAKER_00 is not the agent

Documented: speaker labels are assigned **in the order speakers are detected**. On an inbound call the
first voice is often an IVR prompt, sometimes the customer, sometimes the agent. Mapping
`SPEAKER_00 = agent` produces a QA score of the customer's behavior and a sentiment curve of the agent.

Roles are resolved per call in Phase 2 from content (greeting script, verification questions, "thank
you for calling") and validated against the sandbox answer key. Every segment carries
`speaker_role` in (`AGENT`, `CUSTOMER`, `IVR`, `UNKNOWN`) and a `role_confidence`. `UNKNOWN` segments are
counted at the gate.

### A6. More than two speakers is normal

Transfers, supervisors, interpreters and three-way calls produce `SPEAKER_02` and beyond. The role
resolver must allow multiple `AGENT` speakers per call and record which agent leg a segment belongs to
when `calls.leg_col` exists. Do not force a two-speaker assumption.

### A7. Do not derive handle time from audio duration

`audio_duration` includes IVR, queue messages and hold, and excludes after-call work. AHT for the value
model comes from `calls.handle_seconds_col` in the system of record, never from the transcript. Audio
duration is used only for transcription cost.

---

## R. Redaction

### R1. AI_REDACT fails the entire query by default — set the session parameter

This is the opposite of AI_TRANSCRIBE, AI_SENTIMENT and AI_CLASSIFY, which return `NULL` per row.
Documented: AI_REDACT raises an error if it cannot process an input and, in a multi-row query, **the whole
query fails**. One oversized chunk aborts a batch of thousands.

```sql
ALTER SESSION SET AI_SQL_ERROR_HANDLING_USE_FAIL_ON_ERROR = FALSE;
```

With that set, failing rows return `NULL` (or an OBJECT with `value`/`error` when
`return_error_details` is `TRUE`, which also requires this parameter to be `FALSE`). Then count them,
because a `NULL` redaction is now a silent hole — see R3. In a scheduled task, set the parameter inside
the task's own statements; a session parameter set interactively does not carry into a task session.

### R2. Respect the token limits by chunking — and the output limit binds first

Documented: input plus output together up to 4,096 tokens; **output limited to 1,024 tokens**. In redact
mode, output is roughly the same length as input, so the 1,024 output limit is the binding constraint,
not the 4,096 total. A 2,000-token transcript fits the total limit and still cannot be returned whole.

The rule: redact per segment or per small group of consecutive segments, targeting
`redaction.chunk_target_tokens` (default 700) of input measured with
`AI_COUNT_TOKENS('ai_redact', <text>)`. Split any single segment over the target with
`SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER`. Never redact a whole call in one call.

Whether over-length output is truncated or errored is **not stated precisely in the documentation**.
Guard for both: compare redacted length to input length per chunk and flag any chunk whose redacted text
is materially shorter than the input minus the placeholders it introduced.

### R3. A NULL redaction must not fall back to raw text

The tempting line is `COALESCE(redacted_text, raw_text)`. It turns every redaction failure into a PII
leak, silently. A failed chunk is written as `NULL` with `redaction_status = 'FAILED'` and is excluded
from every downstream AI function until retried. Count failed chunks at the gate.

### R4. Spoken numbers are a known weak spot — test, do not assume

AI_REDACT categories include `PAYMENT_CARD_DATA`, `PHONE_NUMBER`, `NATIONAL_ID` and others, and it works
best on well-formed English text. A transcript renders a card number as "four one one one, one one one
one..." or with transcription errors mid-digit. Whether those spoken forms are detected is **not
documented**. The sandbox plants spoken-form card numbers, phone numbers and SSNs for exactly this
reason, and Phase 6 reports leak rate per category and per form (digits vs words). Do not tell a
customer PCI is handled until that number is measured on their own transcript style.

Defense in depth worth recommending: most contact centers already pause recording during payment
capture. Ask at preflight; it changes how much PCI exposure there is to measure.

### R5. Redaction erases agent and customer names — keep identity in metadata

`NAME` redaction removes the agent's name from "Hi, this is Dana" as well as the customer's. That is
correct for privacy and breaks any logic that tries to find the agent from the text. Agent and customer
identity always come from `agent_id_col` and `customer_id_col` on the metadata table, joined by
`call_id`, never from transcript content. QA criteria such as "agent introduced themselves by name" must
be scored as "agent introduced themselves" with the `[NAME]` placeholder counting as present.

### R6. Placeholders are signal for downstream functions

Prompts for QA and extraction state that bracketed tokens like `[NAME]`, `[PHONE_NUMBER]`,
`[PAYMENT_CARD_DATA]` are redaction placeholders. Without that instruction a model may score "agent
failed to confirm the customer's phone number" because it sees no number.

### R7. Redaction does not cover audio, derived text, or the raw table

- Audio on the stage stays fully sensitive. Report stage grants at preflight.
- Model-written fields (summaries, evidence quotes, reasoning) are derived from redacted text, so they
  should contain placeholders, not PII. Phase 6 runs the planted-PII leak check against **derived
  columns too**, not only the redacted transcript, because a model can reconstruct a value from context.
- If `redaction.keep_raw_segments` is true, the raw segment table needs a deliberate grant decision at
  preflight; it is never readable by the pipeline role used by downstream phases or by the agent.

### R8. An opt-out is a recorded decision

If `redaction.enabled` is `false`, every report produced by this plugin states it in its header. The
pipeline does not "partially" redact (for example, redacting only for the agent) without a recorded
decision; partial redaction is reported as `redaction.categories` with the explicit list.

---

## T. Transcript structure

### T1. Normalize to one segment grain

Audio (AI_TRANSCRIBE speaker segments), vendor segment tables, and vendor full-text blobs all land in
one table: `call_id, leg, seq, start_s, end_s, speaker_label, speaker_role, role_confidence,
text_raw (optional), text_redacted, source`. Full-text blobs are split into turns on speaker markers
when present; when absent, the whole blob is one `UNKNOWN` segment and that call is flagged ineligible
for role-dependent outputs (QA, per-party sentiment) rather than scored on a guess.

### T2. Resolve speaker roles with a documented, measured method

For audio without channel separation, resolve roles per call with one structured `AI_COMPLETE` call
over the first several turns (labels plus redacted text), returning a mapping
`{speaker_label: role, confidence}`. Use a JSON schema with `required` fields (see Q3). Validate on the
sandbox, where roles are known. Report role accuracy in Phase 6. Do not use a keyword heuristic alone;
greeting scripts vary by line of business.

### T3. Deduplicate transfer legs and re-recordings

Transfers can produce one recording per leg, or one recording of the whole call plus legs. Without
`calls.leg_col`, the same conversation can be transcribed and scored twice. Detect duplicates on
`(call_id, MD5 of the first N redacted characters)` scoped to the call, never across calls, since scripted
greetings make different calls look identical at the start.

### T4. Unbounded VARCHAR for anything a model writes

Declare model-generated columns (`text_redacted`, summaries, evidence, reasoning) as `VARCHAR` with no
length. A length limit buys nothing in Snowflake and guarantees an eventual "String is too long" abort.

---

## S. Sentiment

### S1. AI_SENTIMENT has a 2,048-token window — never pass a whole call

Documented: optimized for 2,048 tokens; inputs that exceed the window **return an error**, which by
default becomes `NULL` per row. Whole-call sentiment on long calls therefore silently disappears for
exactly the long, difficult calls. Score sentiment on bounded slices:

- `opening_customer`: customer turns in the first ~2 minutes
- `closing_customer`: customer turns in the last ~2 minutes
- per-segment customer sentiment for the trajectory, aggregated in SQL

The **change** from opening to closing is the useful operational signal ("the agent recovered the call"),
and it is computable only if both ends are scored separately.

### S2. 'unknown' is not 'neutral'

With categories, each returns `positive`, `negative`, `neutral`, `mixed`, or `unknown`, where
`unknown` means the category was **not mentioned**. Averaging `unknown` as zero alongside `neutral`
drags every aspect toward neutral and destroys the signal. Exclude `unknown` from aspect averages and
report mention rate separately.

### S3. Aspect names: at most 10, at most 30 characters

Exceeding either is an error. Keep aspect names short and stable (`agent`, `wait time`, `price`,
`product`, `resolution`, `policy`), and version them with the taxonomy.

### S4. Language support is narrower than transcription

AI_SENTIMENT supports English, French, German, Hindi, Italian, Spanish and Portuguese. AI_TRANSCRIBE
detects many more languages. Calls in an unsupported language get `sentiment_status = 'UNSUPPORTED_LANGUAGE'`
rather than a misleading score. Record language per call when the metadata or transcription offers it.

---

## C. Contact reasons, repeats, escalations

### C1. Contact reason comes from the customer's opening, not the whole call

A billing call where the agent later pitches an upgrade is a billing call. Classifying the whole
transcript lets agent talk dominate. Classify on the customer's turns in the opening window, plus the
agent's restatement of the issue if present. Keep `secondary_reasons` (multi-label) for genuine
multi-issue calls.

### C2. AI_CLASSIFY categories are case-sensitive and should be described

Documented: categories are case-sensitive, accept optional `description` (at most 25 words), a
`task_description` of at most 50 words, and `output_mode: 'multi'` for multi-label. Accuracy degrades past
roughly twenty categories. Rules:

- Store the taxonomy as a table with `label`, `description`, `parent_label`, `taxonomy_version`. Build
  the category array from it in SQL so the classifier input and the reporting labels can never drift.
- Two-level taxonomies (for example 8 parents, each with a few children) classify parent first, then
  child within the parent, rather than one flat list of 40.
- Every taxonomy includes an explicit catch-all (`Other`) with a description. Without it, the model
  forces unclassifiable calls into the nearest real label and inflates it.
- Descriptions, task description and examples are billed as input tokens on **every** call; keep them
  tight.

### C3. Gate on the catch-all share

A taxonomy that sends 40 percent of calls to `Other` is not working, and the distribution of the other 60
percent is biased. Gate on `taxonomy.max_other_share`, then use `AI_AGG` over a sample of `Other` calls to
propose new labels for a human to approve. Never auto-add labels.

### C4. The agent's disposition code is a comparison, not ground truth

Report agreement between model reason and disposition code. Disagreement is an insight (disposition
codes are frequently wrong or defaulted), not an error. Never train or tune the taxonomy toward matching
dispositions.

### C5. Repeat contact is a metadata fact

Whether the customer called again within `definitions.repeat_window_days` is a join on `customer_id_col`
and `start_col`, not a model judgment. The model contributes **why**: whether the later call references
the earlier issue ("I called last week about...") and whether the earlier call ended unresolved. Keep
`is_repeat_metadata` and `references_prior_contact` as separate columns. The repeat window is stated in
every report.

### C6. Escalation sources stay separate

`transfer_flag_col` (a system fact), "customer asked for a supervisor" (a model-detected request), and
"call was transferred to a retention queue" (a routing fact, often good) are different things. Store each
in its own column; never collapse them into one `escalated` boolean that mixes a successful save transfer
with a complaint.

---

## Q. Agent QA

### Q1. N/A is not zero

A criterion that does not apply (no upsell opportunity on an outage call, no verification needed on a
general inquiry) is `NOT_APPLICABLE`, excluded from the denominator. Scoring it as zero punishes agents
for calls they could not have done better on, and scoring it as full marks inflates the average. The schema
carries `applicable` as a required boolean per criterion.

### Q2. Every score cites evidence from the transcript

Each criterion result carries `evidence_seq` (segment numbers supplied in the prompt) and a short quoted
`evidence` string from the redacted text. A score with no evidence is unauditable and will not survive the
first agent who disputes it. Enforce in SQL, because a JSON schema cannot require a non-empty array:

```sql
WHERE c.value:applicable::BOOLEAN
  AND (ARRAY_SIZE(c.value:evidence_seq) = 0
       OR EXISTS (SELECT 1 FROM LATERAL FLATTEN(input => c.value:evidence_seq) e
                  WHERE e.value::INT NOT IN (SELECT seq FROM call_segments s WHERE s.call_id = q.call_id)))
-- rows matching this go to the quality log, not to the score table
```

### Q3. Use AI_COMPLETE with a response_format schema for rubric scoring

AI_EXTRACT's JSON-schema form supports only string scalars, arrays and tables, which cannot express a
per-criterion object with a boolean, a number and an evidence array. Rubric scoring therefore uses
`AI_COMPLETE` with `response_format` and `required` on every field the pipeline depends on, `temperature: 0`,
and `show_details => TRUE` for token accounting. Schema constraints: property names letters, digits,
hyphen, underscore only, max 64 characters; `minItems`, `maxItems`, `minimum`, `maximum`, `minLength`,
`maxLength`, `format` are not supported. Say the score range in the field `description` and clamp in SQL.

### Q4. The rubric is data, versioned and hashed

The rubric lives in a table (`criterion_id`, `name`, `description`, `scale_max`, `weight`,
`applies_when`, `rubric_version`). The prompt is assembled from it; the assembled prompt is hashed; the hash
and version are written on every score row. A customer override is a new `rubric_version`, never an edit
in place. Trend charts filter to one rubric version or show the break.

### Q5. Calibrate against human QA before anyone uses the scores

Automated QA scores used for agent performance management have people consequences. Before Phase 7 puts
scores in front of supervisors, Phase 6 measures agreement against human-scored calls (sandbox labels, and
`qa.human_qa_table` if the customer has one): exact agreement, within-one agreement, and mean absolute
error per criterion. Present scores as coaching signal with measured agreement, not as a replacement for
the QA analyst's judgment, and say so in the readout.

### Q6. A criterion with no variance is not measuring anything

If a criterion returns the same score for nearly every call, either the description is too vague or the
transcripts do not carry the evidence (for example, a hold-time criterion on transcripts with hold removed).
Report per-criterion standard deviation at the gate; flag any near zero.

### Q7. Score the agent's turns in context, not in isolation

Pass the whole redacted conversation with roles and segment numbers, not agent turns alone; empathy and
accuracy are judged against what the customer said. For calls over the model's comfortable context,
pass the opening, the resolution window and any segment the reason classifier flagged, and record that
the call was windowed.

---

## X. Extraction of save and upsell signals

### X1. AI_EXTRACT JSON schema: strings and arrays only

Documented: the top level is an object; sub-objects may be a string, an array of strings, or a table;
string is the only scalar. Booleans are therefore asked as constrained strings ("Answer yes or no") and
normalized in SQL with an explicit mapping. Anything not `yes`/`no` after `LOWER(TRIM())` is
`UNPARSED`, counted, not coerced to `no`.

Also documented: at most 100 entity questions per call, 512 output tokens per question, and the `text`
and `file` arguments cannot be combined.

### X2. Offer is not acceptance

Separate columns for `cancel_intent_stated`, `save_offer_made`, `save_offer_type`,
`save_outcome` (`ACCEPTED`, `DECLINED`, `UNDECIDED`, `NOT_OFFERED`), and likewise for upsell
(`buying_signal`, `upsell_offered`, `upsell_outcome`). Revenue in the value model attaches only to the
**gap** (intent stated, no offer made) and to measured acceptance rates, never to "upsell mentioned".

### X3. Restrict signal extraction to eligible calls

Run save extraction on calls whose reason is cancellation, downgrade, or a complaint with stated intent to
leave, plus a cheap `AI_FILTER` or classification pass for cancellation intent on other calls (customers
mention leaving on billing calls). Running it on every call costs tokens and produces false offers on
calls where "cancel" meant "cancel my appointment".

### X4. "Offered" requires the agent to have said it

The extraction prompt names the agent role explicitly: an offer counts only if an `AGENT` turn made it.
The customer saying "I was told I could get a discount" is not an offer on this call.

---

## G. Aggregation

### G1. AI_SUMMARIZE_AGG and AI_AGG produce narrative, not numbers

They summarize a column larger than the context window, which is what makes "what are customers
complaining about in Billing this week" possible. Their output is not deterministic and not countable.
All counts, rates and rankings come from the classified tables in SQL; the aggregate functions describe
**why** within a group whose size SQL already computed. The Cortex Agent is instructed never to quote a
number that appears only inside a summary.

### G2. Prefer AI_AGG with an instruction for driver analysis

`AI_SUMMARIZE_AGG` is general-purpose. For "the top drivers of repeat contacts in this group, with how they
differ from first contacts", `AI_AGG(expr, instruction)` with a declarative instruction describing the
data and the use case is more targeted. Feed it compact per-call summaries or extracted fields, not full
transcripts, to control tokens.

### G3. Aggregate over redacted, derived text only

Driver summaries are built from redacted segments or model-written per-call summaries, never from raw
segments, because a summary of PII is still PII.

---

## M. Measurement

### M1. Join from ground truth outward

Every accuracy table is built from the answer key with a `FULL OUTER JOIN` to predictions. A call that
failed transcription or redaction must appear as a miss, not disappear. An upstream
`WHERE transcript IS NOT NULL` turns total failure into perfect accuracy on survivors.

### M2. Normalize labels with one shared expression on both sides

`UPPER(TRIM(label))` on both sides, applied after splitting multi-label strings, never on the whole
delimited string. Taxonomy labels are case-sensitive in AI_CLASSIFY; the comparison should not be.

### M3. Macro and micro together, plus per-label

Contact-reason distributions are long-tailed. Micro accuracy is dominated by the top two reasons; macro-F1
shows whether small reasons are recognized at all. Report both, and per-label precision and recall.

### M4. QA agreement is not accuracy

Report exact agreement, within-one agreement and MAE per criterion against labels, plus applicability
agreement (did the model and the label agree the criterion applied). A model that marks everything N/A
has perfect score agreement on the few it scores.

### M5. Redaction is measured as leak rate on planted PII

Leak rate = planted PII values found verbatim (or as the digit sequence, for numbers) in any redacted or
derived column / planted PII values. Normalize digits by stripping non-digits before matching, and match
the spoken-word form separately. Report by category and by form.

### M6. Tokens, not dollars; reconcile against account usage

Per-call tokens come from `show_details` on AI_COMPLETE, from duration for AI_TRANSCRIBE, and from
`SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` as the system of record for billed totals. That view
has `QUERY_ID`, `FUNCTION_NAME`, `MODEL_NAME`, `METRICS` (token counts), `CREDITS` and `WAREHOUSE_ID`, and its `START_TIME` is an hourly aggregation window, so a time filter cannot isolate one run. Record `LAST_QUERY_ID()` into a
`RUN_QUERY_LOG` table after every model-calling statement and join on `query_id`. Account usage has latency; a
missing row means "not yet", not zero.
`AI_COUNT_TOKENS` estimates input only; for AI_REDACT the billed total also includes the generated text, and
for AI_COMPLETE with `response_format` on Claude models the billed input is materially higher than the
estimate. Say so whenever an estimate is shown. Never look up prices or convert to currency.

---

## O. Operations

### O1. Every model-calling layer is materialized, never a view

A view over AI_TRANSCRIBE, AI_REDACT or AI_CLASSIFY re-invokes and re-bills on every select. Staging is
a view; every layer that calls a model is a table, incremental model, or dynamic table.

### O2. Incremental by call, idempotent by run

Process new calls only (stream on the metadata table, or `call_start_ts` watermark). Key outputs on
`(call_id, leg, run_id)` with merge so a task retry does not re-transcribe and double-bill. Audio
transcription especially must never re-run on a call already transcribed unless explicitly requested.

### O3. Dynamic tables and AI functions

Dynamic tables are a good fit for the SQL rollups downstream of the model layers. For layers that call
AI functions, prefer a stream plus task with an explicit `MERGE`, so re-processing is controlled and
visible. If a dynamic table is used over an AI function, it must refresh incrementally; a full refresh
re-bills the entire history. Load the `dynamic-tables` skill and check the refresh mode before committing.

### O4. No TEMPORARY tables between tasks

Each task runs in its own session; a temp table from a parent is invisible to a child.

### O5. Session parameters do not follow you into tasks

`AI_SQL_ERROR_HANDLING_USE_FAIL_ON_ERROR = FALSE` (R1) must be set as a session parameter on the task
definition (`CREATE TASK` accepts session parameters) or inside the procedure body; an interactive
`ALTER SESSION` does not apply to scheduled runs. Test that it is in effect with one deliberately oversized chunk
before trusting the schedule.

### O6. Hash the prompt that ran

Persist `prompt_hash = SHA2(assembled_prompt)` and bind that same assembled text into the call. When
`prompt_version` matches and `prompt_hash` differs, trust the hash.

### O7. Experiment tracking needs incremental materialization

If scoring and evaluation layers are `table` materializations, each run replaces the last and every
comparison returns one experiment. Use incremental with `run_id` in the unique key.

### O8. dbt traps

- dbt concatenates `+schema` onto the target schema; override `generate_schema_name`.
- Never `authenticator: externalbrowser` in a profile used by dbt on Snowflake.
- Use `TRY_COMPLETE`-style or `return_error_details` forms in any model that calls a model over a table,
  so one bad row does not fail the model.
- Never commit a real `profiles.yml`; never default the run role to `ACCOUNTADMIN`.

### O9. Cross-region and regional availability

AI_TRANSCRIBE is documented as available in a short list of regions (at time of writing, AWS US West 2,
AWS US East 1, AWS EU Central 1, Azure East US 2). Outside those, it requires
`CORTEX_ENABLED_CROSS_REGION`. Preflight checks both, and states plainly that enabling cross-region
inference means audio and text are processed in another region — a data-residency decision for the
customer, not a setting to flip silently.
