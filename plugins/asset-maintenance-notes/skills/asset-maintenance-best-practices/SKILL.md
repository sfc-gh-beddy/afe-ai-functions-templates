---
name: asset-maintenance-best-practices
description: "Correctness rules every asset maintenance notes pipeline must follow. Always loaded by the asset-maintenance-notes router. Catches silent failure modes in work order, technician note and inspection text: negated and ruled-out findings counted as failures, PM replacements counted as failures, component versus failure mode versus cause versus action confusion, unconstrained component vocabularies, taxonomy version drift, asset attribution from text tags instead of the record, equipment versus functional location history, AI_COMPLETE structured-output contracts and parse-failure accounting, AI_CLASSIFY category limits and case sensitivity, AI_EXTRACT response wrapping, evidence-span provenance, deduplication of copy-forward notes, shorthand and abbreviation glossaries, embedding raw text versus normalized signals, single embedding model, guessed similarity thresholds, repeat-visit window definition, precursor leakage (failure WO text, post-hoc edits, random splits, clusters fitted on test data, label-derived features), lead-time measurement, alert-budget precision, sensor NULL handling and time alignment, dynamic table refresh mode with AI functions, token instrumentation, unbounded VARCHAR, safety-mandated work, and value double counting."
parent_skill: asset-maintenance-notes
---

# Asset maintenance notes -- correctness rules

Every rule here has a failure mode where the SQL succeeds, the row counts look reasonable, and the
answer is wrong. Apply them to every artifact this plugin generates. They are grouped by stage.

---

## A. What a "failure" is

### 1. Polarity is a required field, and only `OBSERVED` counts

**The failure:** an extractor asked "what component failed and how" answers for every component it
sees mentioned. Inspection checklists are mostly negatives -- "no leaks observed at mech seal",
"DE brg temp normal", "coupling guard secure: Y". Counting those makes the best-maintained assets
look like the worst, because they are inspected most.

**The rule:** every signal carries `polarity` with exactly these values, schema-enforced:

| Polarity | Meaning | Example |
|---|---|---|
| `OBSERVED` | a fault, degradation or abnormal condition was seen or measured | "weeping at seal faces", "vib 7.1 mm/s DE horizontal" |
| `RULED_OUT` | the component was checked and found normal, or a fault was explicitly negated | "no leak", "checked brg - OK", "nil abnormal noise" |
| `ACTION_ONLY` | work was done with no stated fault | "replaced filter per PM", "greased brgs", "re-torqued flange" |
| `UNCLEAR` | hedged or reported second hand without confirmation | "operator thinks it may be noisy", "possible weep?" |

Every failure-mode statistic, cluster, repeat-visit count and precursor feature filters
`polarity = 'OBSERVED'`. `UNCLEAR` is kept as its own precursor feature (hedged early mentions are
often the earliest signal) but never counted as a failure. Put this filter in a single view
(`MAINT_SIGNALS_OBSERVED`) and have every consumer read the view, so it cannot be forgotten in one
query.

### 2. A replacement is not a failure

"Replaced DE bearing" on a PM work order is an interval action. On a corrective work order it is a
repair whose cause may or may not be stated. The extractor must not infer a failure mode from an
action alone: no stated fault means `ACTION_ONLY`, and `failure_mode_code = 'NONE'`.

Use the work-order type as **context in the prompt** (it changes how a technician writes), but never
as a rule that overrides the text: a PM visit that finds a cracked coupling is an `OBSERVED` failure.

### 3. Keep component, failure mode, cause and action separate

Technician text mixes four things that reliability engineering keeps apart:

| Field | Question | Example |
|---|---|---|
| `component_code` | what item | mechanical seal, DE bearing |
| `failure_mode_code` | how the failure manifested (the observed effect) | external leak, high vibration, overheating, fail to start |
| `cause_text` | why, if stated | misalignment, dry running, contamination |
| `action_text` | what was done | replaced seal, realigned coupling |

Collapsing them ("bearing failure due to misalignment, replaced") into one label loses the thing
clustering needs (mode) and the thing root-cause analysis needs (cause). Cause is free text, not a
closed list, unless the customer already owns a cause taxonomy -- inventing one adds a second,
unvalidated vocabulary.

### 4. One note, many signals

A single note routinely contains several findings ("seal weeping, brg temp up 10C, coupling OK").
The schema returns an **array** of signals, each with its own component, mode, polarity and evidence
span. A schema with one `component` field forces the model to pick one, and the others are lost
silently. The harness then reports low recall with no hint why.

---

## B. Vocabulary and taxonomy

### 5. Constrain components and failure modes to a pinned taxonomy

**The failure:** free-text component names. "DE brg", "drive end bearing", "brg #1", "motor bearing
(pump side)" become four components, and no cluster, rate or Pareto chart is meaningful.

**The rule:** pass the class-appropriate component and failure-mode codes as `enum` values in the
`response_format` schema, plus an explicit `OTHER` for each. Do not rely on the prompt alone to
restrict the vocabulary.

- Build the enum **per asset class**: a pump has no gearbox; offering every code to every asset
  invites wrong-class answers. Group sources by class and run one prompt variant per class.
- `OTHER` must exist, and its share is a reported metric. A high `OTHER` share is a taxonomy gap,
  not a model failure; route it to `build-failure-taxonomy` with examples.
- Keep a separate free-text `component_mention` with the exact words used, so taxonomy gaps can be
  reviewed without re-reading notes.

### 6. Pin and carry the taxonomy version

Every signal row carries `taxonomy_version`. A taxonomy edit bumps `taxonomy.version`. The harness
refuses to pool signals across versions, and clusters are rebuilt per version. Two runs that look
comparable because the prompt hash matches can still differ because a code was split in two.

### 7. Expand shorthand with a customer glossary, in the prompt

Maintenance text is dense with abbreviations that differ by site and trade: `brg`, `vib`, `o/h`
(overhaul **or** overhead), `DE`/`NDE`, `mech seal`, `VFD`, `PRV`, `LOTO`, `nil`, `u/s`
(unserviceable). Ambiguous ones are dangerous: `o/h` misread flips a component.

Pass the customer's glossary (from `TAX_GLOSSARY`) in the prompt, scoped to the asset class. Build
it from the corpus (`build-failure-taxonomy` mines high-frequency tokens) and have a maintenance
lead confirm it. Never ship a generic glossary as if it were the customer's.

### 8. Do not use the CMMS failure code as ground truth

It is picked at close-out, frequently defaulted, and is the field this play exists to improve.
Compare against it and report agreement, but never train, tune or evaluate against it as truth.
High agreement with a bad label is not accuracy.

---

## C. Extraction contracts

### 9. Structured output with a schema, `required` everywhere it matters

Never ask for JSON in prose. Use `response_format` with a JSON schema; `required` on `signals` and,
inside each signal, on `component_code`, `failure_mode_code`, `polarity` and `evidence_span`.

```sql
AI_COMPLETE(
    model            => :extract_model,
    prompt           => :assembled_prompt,
    model_parameters => {'temperature': 0, 'max_tokens': 2048},
    response_format  => {
      'type': 'json',
      'schema': {
        'type': 'object',
        'properties': {
          'signals': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'component_code':    {'type': 'string', 'enum': [/* class codes + 'OTHER' */]},
                'component_mention': {'type': 'string'},
                'failure_mode_code': {'type': 'string', 'enum': [/* mode codes + 'OTHER', 'NONE' */]},
                'polarity':          {'type': 'string', 'enum': ['OBSERVED','RULED_OUT','ACTION_ONLY','UNCLEAR']},
                'severity':          {'type': 'string', 'enum': ['LOW','MEDIUM','HIGH','UNKNOWN']},
                'measured_value':    {'type': 'string'},
                'cause_text':        {'type': 'string'},
                'action_text':       {'type': 'string'},
                'evidence_span':     {'type': 'string',
                                      'description': 'Exact words copied from the note. Do not paraphrase.'}
              },
              'required': ['component_code','failure_mode_code','polarity','evidence_span']
            }
          },
          'has_maintenance_finding': {'type': 'boolean'}
        },
        'required': ['signals','has_maintenance_finding']
      }
    },
    show_details         => TRUE,
    return_error_details => TRUE
)
```

Notes:

- `temperature: 0` on every extraction call. A note scored twice must give one answer.
- Say "Respond in JSON" in the prompt text as well; it is free redundancy on complex prompts.
- Unsupported schema keywords are errors, not warnings: do not use `minItems`, `maxItems`,
  `minimum`, `maximum`, `minLength`, `maxLength`, or `format`. Property names: letters, digits,
  hyphen, underscore, no spaces, at most 64 characters.
- An empty `signals` array is a legitimate answer ("job complete, no findings"). It must be
  distinguishable from a failed call -- which is why `has_maintenance_finding` is required.

### 10. Count parse failures and errors on every run

`AI_COMPLETE` returns `NULL` for a row it cannot process and the statement still completes. With
`return_error_details => TRUE` the return is an object with `value` and `error`; persist both.

```sql
INSERT INTO PIPELINE_QUALITY_LOG (run_id, stage, total_calls, error_calls, unparseable_calls, empty_signal_calls, logged_at)
SELECT :run_id, 'extract',
       COUNT(*),
       COUNT_IF(r:error::STRING IS NOT NULL),
       COUNT_IF(r:error::STRING IS NULL AND r:value:structured_output[0]:raw_message:signals IS NULL),
       COUNT_IF(ARRAY_SIZE(r:value:structured_output[0]:raw_message:signals) = 0),
       CURRENT_TIMESTAMP()
FROM MAINT_SIGNAL_RAW
WHERE run_id = :run_id;
```

A pipeline that cannot say how many calls failed cannot make a recall claim.

**JSON null is not SQL NULL.** A successful call returns `"error": null`, and `r:error IS NULL` is
**FALSE** for it (verified: a VARIANT JSON null fails `IS NULL`). Test `r:error::STRING IS NOT NULL`
or `IS_NULL_VALUE(r:error)`. Getting this wrong reports every call as errored -- or, written the
other way round, reports none. The same applies to any optional field in a structured response
(`measured_value`, `cause_text`): cast before testing for null. The harness counts a
failed call on a labeled note as missed signals, never as "no finding".

### 11. Evidence spans must be found in the source

Every signal carries `evidence_span`, copied verbatim. Verify in SQL, after normalizing whitespace
and case on **both** sides with one expression:

```sql
CONTAINS(LOWER(REGEXP_REPLACE(src.text, '\\s+', ' ')),
         LOWER(REGEXP_REPLACE(sig.evidence_span, '\\s+', ' ')))  AS evidence_found_in_source
```

Signals with `evidence_found_in_source = FALSE` go to the quality log, not the signal table. A
paraphrased span is a soft failure (the model described rather than quoted); a span from a
different note is a hard one. Both are counted.

### 12. `AI_CLASSIFY` for triage: few categories, descriptions, case matters

Triage asks "does this note contain a maintenance finding at all", before the expensive call.

```sql
AI_CLASSIFY(
    text,
    [
      {'label': 'MAINTENANCE_FINDING', 'description': 'Describes a condition, measurement, defect, or repair of equipment'},
      {'label': 'ADMIN_ONLY',          'description': 'Scheduling, access, permits, parts ordering, travel, with no equipment condition'},
      {'label': 'CLOSEOUT_BOILERPLATE','description': 'Standard completion text such as job complete, area clean, LOTO removed'}
    ],
    {'task_description': 'Triage maintenance work order notes before detailed extraction'}
):labels[0]::STRING
```

- Returns an object whose `labels` field is an array; single-label mode has exactly one element.
- Categories and input are **case sensitive**. Compare labels exactly as defined.
- Keep it to a handful of categories; documentation notes accuracy may degrade past roughly twenty.
- Descriptions count as input tokens on every row; keep them short.
- Triage errs toward `MAINTENANCE_FINDING`. Measure the triage false-negative rate on the sandbox
  (findings exited before extraction) and report it -- it caps recall for the whole pipeline.

### 13. `AI_EXTRACT` returns a wrapper; read `:response`

`AI_EXTRACT` returns `{"error": ..., "response": {...}}`. Reading `AI_EXTRACT(...):part_number`
returns `NULL` on every row. Read `:response:part_number`, and count rows where `:error` is not
null. Use `AI_EXTRACT` for verbatim fields (part numbers, nameplate readings, measured values on
inspection forms), and `AI_COMPLETE` with a schema for anything that must be constrained to the
taxonomy -- `AI_EXTRACT` has no enum constraint.

### 14. Window by tokens, segment instead of truncating

Long notes (multi-day outage logs, overhaul reports) exceed a sensible per-call budget.
`LEFT(text, N)` drops the end of the log, which is where the as-found condition and the root cause
are written. Measure with `AI_COUNT_TOKENS('ai_complete', <model>, text)`; above
`extraction.max_input_tokens`, split on paragraph or entry boundaries into segments that carry the
same `source_id` and a `segment_no`, extract each, and union the signals.

### 15. Assemble the prompt once; hash what ran

Build the prompt (instructions + class taxonomy + glossary + note) in one CTE column, bind that
column into `AI_COMPLETE`, and persist `SHA2(prompt, 256)` as `prompt_hash` from the same column.
Rebuilding the `CONCAT` in two places guarantees a hash of a prompt that did not run. When
`prompt_version` matches but `prompt_hash` differs, trust the hash.

---

## D. Attribution and deduplication

### 16. Asset comes from the record, never from text

Signals inherit `asset_id` from the work order or inspection row. Tags in free text ("P-101A",
"the A pump", "pump 101 A") are recorded as `asset_mention` for review only. Resolving them with a
model invents attributions that look authoritative.

### 17. Equipment versus functional location

If the CMMS has both, decide per analysis which history is followed:

- failure-mode statistics and component life follow the **equipment** (serial number), because a
  refurbished pump installed elsewhere carries its history;
- downtime and service impact follow the **functional location**.

Resolve point in time with the move history (`sources.asset_moves`) using the note timestamp. A
join to the current registry row attributes every historical WO to the equipment's position today.

### 18. Deduplicate before extraction, scoped to the asset

Copy-forward notes, templated close-out text and notes duplicated onto parent and child work orders
are common. Deduplicate on `MD5(asset_id || '::' || normalized_text)` before extraction -- billing
once per distinct text per asset -- and keep a mapping table back to every original `source_id`
so counts per work order remain correct. A dedup key without `asset_id` collapses identical
"replaced filter per PM" notes across the whole fleet into one asset.

---

## E. Recurring issues

### 19. Embed the normalized signal, not the raw note

Raw notes are dominated by template and boilerplate; embedding them clusters by author and template.
Embed a constructed string per `OBSERVED` signal:

```sql
asset_class || ' | ' || component_code || ' | ' || failure_mode_code || ' | ' || evidence_span
```

This clusters by what was wrong, while the evidence span keeps distinctions the taxonomy does not
encode (a seal leak at the flush port versus at the gland).

### 20. One embedding model per comparison, carried as a column

Vectors from different models are not comparable even when the dimensions match and
`VECTOR_COSINE_SIMILARITY` compiles. Store `embed_model` on every row and assert a single value.

### 21. The similarity threshold is measured, not guessed

A cosine threshold copied from a blog post is a guess. Sweep thresholds on the sandbox (which carries
`ANSWER_KEY_RECURRING`), pick the one that best recovers known issue groups, record it in
`recurring.similarity_threshold`, and re-check on a customer-reviewed sample. Report cluster purity
and fragmentation, not just a count of clusters.

### 22. A repeat visit has a definition, and the customer owns it

A repeat visit is: same asset (or functional location, per rule 17), same issue cluster, a second
non-PM work order **created** within `repeat_window_days` of the first one being **closed**. The
window is the customer's first-time-fix definition -- ask; do not default it. Exclude PM types.
Measuring from creation instead of closure makes a long-open WO look like its own repeat.

### 23. Use `AI_AGG` to describe a cluster, not to form one

Cluster membership is decided by vectors and a threshold, which are reproducible. `AI_AGG` /
`AI_SUMMARIZE_AGG` then write a label or narrative over a formed cluster's evidence spans. Asking a
model to "group these notes into recurring issues" is not reproducible and cannot be evaluated.

---

## F. Precursors and leakage

### 24. Every feature has a cutoff, and nothing at or after it is visible

A precursor feature row is `(asset_id, cutoff_ts)`. Every input -- note, inspection, sensor
reading, prior WO -- must have its own timestamp strictly before `cutoff_ts`. Carry `max_source_ts`
on the feature row and assert `max_source_ts < cutoff_ts` with a build-failing test.

### 25. Use the note timestamp, not the work order's

Notes are appended to long-running WOs, including "as found" notes written after the failure that
mention earlier symptoms ("weep reported last month"). Filtering by WO `created_at` lets those in.
Filter by note timestamp. If only a single long-text field exists, exclude any WO whose
`last_modified_at >= cutoff_ts` (`cutoff_policy: wo_last_modified`).

### 26. Exclude the failure work order itself

The corrective or emergency WO raised for the labeled failure is the label's own description.
Exclude it explicitly by id, and exclude any WO created within a short grace window before the
recorded failure start (the operator often raises the WO before the downtime log records the event).

### 27. Split by time, never randomly

Train on events before `split.train_end`, test on events after `split.test_start`, with a gap at
least as long as the feature lookback so no test-period note sits in a training window. A random row
split puts next week's notes for the same asset in training. Where asset count allows, also hold out
assets (`time_and_asset`).

### 28. Anything fitted is fitted on training data only

Cluster centroids, IDF weights, thresholds, sensor baselines (per-asset mean and stddev) and
glossary expansions mined from the corpus are fitted on the training period only. A baseline
computed over all history includes the post-failure readings and makes the pre-failure drift look
larger than it was.

### 29. No feature may be derived from the label

"Days since last emergency WO" leaks when the emergency WO is the label source. "Open corrective WO
count" leaks if the failure WO is open at the cutoff. Audit every feature against
`precursor.label_source`.

### 30. Measure lead time as a distribution, at a fixed alert budget

- Lead time = failure start minus the **first** alert for that asset within `horizon_days` before
  it. Report the distribution (median and percentiles), not the mean; a few very early alerts
  inflate it.
- An alert with lead time below `min_lead_days` cannot change a decision (no time to plan a crew or
  order a part). Report it separately as "late".
- Report precision at the customer's `alert_budget_per_month` -- the number of alerts planners can
  act on -- not at an arbitrary score threshold. Precision at a threshold that fires on half the
  fleet is meaningless operationally.
- Report the base rate alongside precision. Precision of 0.2 is strong when the monthly failure
  base rate is 1 percent and useless when it is 25 percent.

### 31. Sensor data: keep NULLs, align time, check units

- Never `COALESCE(reading, 0)`. A sensor outage is not a healthy reading. Carry a coverage feature
  (share of expected readings present in the window).
- Convert timestamps to one zone once, at staging; record the source zone.
- Join notes to sensors by window (`reading_date BETWEEN cutoff - lookback AND cutoff - 1`), or with
  `ASOF JOIN` for point lookups -- never by equality on a date that may be local on one side and UTC
  on the other.
- Check units by month before trusting a trend.

---

## G. Operations, cost and value

### 32. Dynamic tables that call models must be `REFRESH_MODE = INCREMENTAL`

Cortex AI functions are supported in the `SELECT` of dynamic tables in incremental refresh mode. Set
`REFRESH_MODE = INCREMENTAL` explicitly. `AUTO` can choose full refresh, and a full refresh re-sends
the entire note history through the model on every refresh. After creation, confirm with
`SHOW DYNAMIC TABLES` that the refresh mode is `INCREMENTAL`; if the definition is not
incrementalizable, the build should fail rather than fall back.

### 33. Tokens, never currency

Use `show_details => TRUE` for per-call usage and
`SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY` for billed totals. Report tokens and
credits as recorded; do not look up prices or convert to currency.

- That view carries `query_id`, `function_name`, `model_name`, `tokens`, `token_credits` -- and **no
  timestamp**. A filter on `start_time` against it does not compile. Join to
  `ACCOUNT_USAGE.QUERY_HISTORY` on `query_id`. Tag every AI step with the run id so a run's spend is selectable exactly,
  and expect the view to lag by hours. `ALTER SESSION SET QUERY_TAG = $run_id` fails (verified:
  `ALTER SESSION` does not resolve session variables); set it from a scripting block that builds the
  statement, as `extract-failure-signals/sql/10_triage_and_extract.sql` does.

- `AI_COUNT_TOKENS` signature: `('ai_complete', '<model>', <text>)` -- function name first,
  lowercase. A wrong function name returns `NULL`, which looks like an empty estimate. Use
  `return_error_details => TRUE` while developing.
- `AI_COUNT_TOKENS('ai_classify', <text>, <categories>)` for triage estimates.
- It estimates **input only**; output bills on top. The taxonomy enum and glossary are sent on every
  extraction call -- include that overhead.
- **Structured output adds billed input that `AI_COUNT_TOKENS` does not see, and on short notes it
  dominates.** Measured while building this plugin: a one-line note (`Seal - no leaks. DE brg running
  warm 78C...`) estimated at **36** input tokens by `AI_COUNT_TOKENS('ai_complete',
  'claude-haiku-4-5', ...)`; the same call with a small enum schema attached reported
  **750** `prompt_tokens` in `show_details` usage. Maintenance notes are short, so per-call schema
  overhead -- not note length -- is the main input cost. Consequences:
  - estimate from a **measured** per-call overhead (run five sandbox calls with the real schema and
    read `usage.prompt_tokens`), not from `AI_COUNT_TOKENS` on the note text;
  - batch several short notes for the same asset class into one call when the schema allows an
    array keyed by `source_id`, and re-measure;
  - triage exits are worth more than their note length suggests, because each avoided call avoids
    the whole overhead.
  The overhead varies by model family and schema size; measure on the pinned model.

### 34. Never length-constrain a column that holds model output

`VARCHAR` with no length for evidence spans, mentions, causes, actions, cluster narratives.
Constrained columns fail on the first verbose response. Give code columns headroom (`VARCHAR` too)
so a contract violation lands as inspectable data, not an aborted insert.

### 35. Keep extracted arrays as `VARIANT` / `ARRAY`

`...:signals::VARCHAR` produces a string that looks like JSON; every `FLATTEN` downstream then
returns nothing. Store raw responses as `VARIANT`, flatten into typed columns once.

### 36. Safety-mandated and regulatory work is never "deferred" by this pipeline

Replacement intervals required by regulation, insurance, or a safety case are out of scope for
deferral, whatever the condition evidence says. The readout excludes them from the CapEx lever, and
the agent instructions say so. Ask the customer which asset classes or work types are mandated.

### 37. Do not double count value

A failure avoided removes a repeat truck roll **or** contributes to deferred replacement **or**
avoids downtime hours -- one event can touch several levers, but each dollar of value is claimed
once. The readout builds each lever from disjoint event sets and states the assumption.

### 38. Orchestration

- No `TEMPORARY` tables shared between tasks; each task has its own session.
- Idempotent on `run_id`: task retries re-invoke the step, and a non-idempotent extraction step
  double-bills and double-inserts.
- Fully qualify object names in every task body.

### 39. Accuracy harness traps (detail in `evaluate-maintenance-accuracy`)

- Build from ground truth outward (`FULL OUTER JOIN`), so a source the pipeline dropped counts as
  missed, not absent.
- Normalize codes on both sides with one expression (`UPPER(TRIM(x))` per element, after splitting).
- Score components hierarchically: exact component, same assembly, miss.
- Report micro and macro, per class, with polarity confusion.
- Never pool across `taxonomy_version`.
