---
name: evaluate-maintenance-accuracy
description: "Phase 6 of the asset-maintenance-notes build, never skipped. Measures the pipeline against ground truth: failure-signal precision, recall and F1 at exact, component and assembly level (hierarchical scoring), per asset class and text kind, micro and macro with spread, polarity confusion matrix, triage and parse-failure losses counted as misses, CMMS failure-code agreement as a separate comparison; recurring-issue recovery and spurious repeats; precursor evaluation on a time-split test set with a leakage canary, threshold calibrated on training data at the customer's alert budget, alert precision against base rate, actionable event recall, lead-time distribution, late alerts, false alarms on controls, and the sensor-only versus text-only versus combined ablation; tokens per 1,000 records from measured usage. Includes production hand-labeling protocol. Use for how accurate is it, precision and recall, lead time, is it leaking, compare experiments, cost per thousand work orders."
parent_skill: asset-maintenance-notes
---

# Evaluate accuracy, lead time and cost

This is the phase that decides whether anything downstream is worth building. It answers four
questions, each with numbers from this corpus:

1. **Extraction:** how often is an extracted failure signal right, and how many real ones are
   missed?
2. **Recurring issues:** are real repeat problems grouped as one issue, and are non-repeats left
   alone?
3. **Precursors:** at the number of alerts planners can act on, how many failures are flagged early
   enough to act, how early, and how many alerts are wasted -- measured without leakage?
4. **Cost:** tokens per 1,000 source records, measured, not estimated.

`sql/40_evaluate.sql` implements it. It is the only code that reads the eval schema. Results are
written to `EVAL_*` tables keyed by `run_id` and `experiment_id`, so experiments accumulate.

## Rules the harness follows

From best-practices rule 39, restated because each one, broken, produces a confidently wrong number:

- **Ground truth outward.** Every truth tuple is scored, including those whose source was triaged
  out, errored, failed to parse, or never reached extraction. Section 0 of the script reports how
  many labeled sources were lost at each stage; each one is a miss, not an absence.
- **The empty answer is an answer.** Boilerplate, admin and no-fault-found sources have zero truth
  signals. Any predicted signal on them is a false positive. `ANSWER_KEY_SOURCES` exists so those
  sources are in the denominator.
- **Hierarchical scoring.** Exact (component and mode), component-only (right item, wrong mode),
  assembly-only (right subunit, wrong item), miss. A component-level error is a different problem
  from a missed finding: it usually points at the taxonomy (synonyms, boundaries) rather than the
  prompt.
- **One taxonomy version and one prompt hash per evaluation.** The script checks and the result
  must be `1, 1`. Never pool.
- **Micro and macro.** Micro pools tuples; a few multi-finding notes dominate it. Macro averages per
  source, with stddev and minimum. A macro F1 whose stddev approaches its mean describes a pipeline
  that works on some note styles and not others -- the per-kind breakdown says which.
- **Precursor metrics on `TEST` only,** with the threshold set on `TRAIN`.

## 1. Extraction

### Headline

Report, per run, from `EVAL_EXTRACTION_SUMMARY`:

| Level | Meaning | Use |
|---|---|---|
| `OBS_EXACT` | observed failure: right component **and** failure mode | the number for the readout |
| `OBS_COMPONENT` | right component, any mode | "what broke" accuracy |
| `OBS_ASSEMBLY` | right subunit | coarse reporting and clustering accuracy |

Each with precision, recall, F1, truth and prediction counts, overall and per asset class. The
`min_acceptable_failure_mode_f1` threshold in `maintenance-project.yml` starts at 0.0; after the
first accepted run, raise it to just under the achieved `OBS_EXACT` F1 so a regression fails the
gate.

### Where the errors are

- **Outcome distributions** (truth side: exact / component-only / assembly-only / miss; prediction
  side: exact / wrong mode / wrong component / polarity error / spurious).
- **Polarity confusion matrix** on (source, component). The cells that matter most:
  - `RULED_OUT -> OBSERVED`: negated findings counted as failures; the main precision killer;
  - `ACTION_ONLY -> OBSERVED`: replacements counted as failures;
  - `UNCLEAR -> OBSERVED`: hedges treated as confirmation;
  - `OBSERVED -> (none)`: missed findings, often a second finding in a multi-finding note.
- **Per text kind** (sandbox `kind`): exact, missed and false failures for `NEGATIVE`, `ACTION`,
  `PRECURSOR`, `NFF`, `BOILERPLATE`, `ADMIN`, `FAILURE`. This tells the user which rule in the prompt
  to work on.

### CMMS code agreement (comparison, not accuracy)

The script tabulates the CMMS `failure_code` against whether the work order truly contains an
observed failure. On the sandbox, `OTHER` dominates by construction. On production data, this table
is the "before" picture for the readout: what the structured field says versus what the notes say.

## 2. Recurring issues

- planted groups recovered as exactly one cluster;
- fragmented (more than one cluster) and not extracted (zero clusters);
- groups with exactly the expected two repeats;
- repeats on assets with no planted group (spurious repeats).

Fragmentation points at the similarity threshold; not-extracted points at Phase 3; spurious repeats
point at the window or at clusters that are too broad.

## 3. Precursors

### 3a. Leakage canary -- run first

For each planted event's last pre-failure cutoff:

- `leaked_under_note_ts` -- canary records (as-found notes, hindsight notes, the failure WO note)
  visible under the pipeline's rule. **Must be 0.** If not, stop: every precursor number is invalid.
- `trap_live_under_wo_created` -- canary records that **would** be visible if features filtered on
  WO creation date. Expect greater than 0. This proves the trap exists and the pipeline avoided it,
  rather than the test being vacuous.

Then the structural assertion from Phase 5 (`max_source_ts < cutoff_ts`, zero rows) is re-run here
so the evaluation record contains it.

### 3b. Threshold at the alert budget

The threshold is the training-period score at which alerts per month equal
`precursor.alert_budget_per_month`. It is then applied unchanged to `TEST`. Report test alerts per
month next to the budget: if test volume is far above budget, score distributions shifted between
periods (drift), which is itself a finding.

Never pick the threshold on `TEST`, and never report precision at a threshold that fires on a large
share of the fleet.

### 3c. Report

| Metric | Definition |
|---|---|
| alert precision | share of test alerts followed by an unplanned failure within the horizon |
| test base rate | share of test cutoffs that are positive -- report beside precision, always |
| actionable event recall | test failures with a first alert at least `min_lead_days` before |
| late catches | test failures alerted, but with lead below `min_lead_days` |
| lead time p25 / median / p75 | days from first alert in the horizon to failure; a distribution, never a mean |
| control false alarms (sandbox) | false-alarm control assets alerted within 30 days of their benign anomaly |

Run for each `model_variant` (`COMBINED`, `SENSOR`, `TEXT`, and the rules baseline if used) and
present side by side. The comparison sentence the readout may use is exactly what these numbers
support, for example "at N alerts per month, adding notes to sensors raised actionable event recall
from A to B at similar precision" -- with the event counts, because with a few dozen test events a
difference of one or two events is noise.

### 3d. Small-sample honesty

State the number of test events with every precursor figure. With fewer than roughly 30 test events
in a class, report counts ("caught 7 of 11, median lead 19 days") rather than rates, and do not
compare classes.

## 4. Cost

From `MAINT_SIGNAL_RAW` usage on the run:

- source records, distinct texts (after dedup), extraction calls;
- prompt and completion tokens; average prompt tokens per call (the schema overhead);
- **extraction tokens per 1,000 source records** -- the number for the POC criteria.

Triage (`AI_CLASSIFY`), embeddings and `AI_AGG` do not return usage inline. Take them from
`SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` for the run window once the view has
caught up (it lags), and add them to the per-1K figure in the readout:

```sql
-- Attribute by query tag. The extraction script
-- sets QUERY_TAG to the run_id, which makes the run's queries selectable exactly.
SELECT u.function_name, u.model_name, SUM(u.tokens) AS tokens, SUM(u.token_credits) AS credits
FROM (
    -- CORTEX_AI_FUNCTIONS_USAGE_HISTORY: one row per query, function, model and hourly window;
    -- tokens live in the METRICS array, credits in CREDITS.
    SELECT h.query_id, h.query_tag, h.function_name, h.model_name,
           ANY_VALUE(h.credits) AS token_credits,
           SUM(IFF(m.value:key:unit::STRING = 'tokens', m.value:value::NUMBER, 0)) AS tokens
    FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY h,
         LATERAL FLATTEN(input => h.metrics, outer => TRUE) m
    GROUP BY h.query_id, h.query_tag, h.start_time, h.function_name, h.model_name
) u
WHERE u.query_tag = :run_id
GROUP BY 1, 2 ORDER BY 3 DESC;
```

Report tokens and credits as recorded. Do not convert to currency.

## 5. Comparing experiments

```sql
SELECT experiment_id, prompt_hash, taxonomy_version, level, slice,
       ROUND(precision_, 3) AS p, ROUND(recall_, 3) AS r, ROUND(f1, 3) AS f1, truth_n
FROM <EVAL_SCHEMA>.EVAL_EXTRACTION_SUMMARY
WHERE level = 'OBS_EXACT' AND slice = 'ALL'
ORDER BY evaluated_at;
```

Only compare rows with the same `taxonomy_version`. When two runs share `prompt_version` but differ
in `prompt_hash`, say the prompt changed. A change "helped" when the outcome distribution moved in
the intended cell (for example `RULED_OUT -> OBSERVED` dropped) without a new error appearing
elsewhere -- show both confusion matrices.

## 6. Production labeling protocol

On production data there is no answer key. Before any accuracy figure on customer data:

1. **Sample, stratified.** 300-500 sources: by source type, WO type, asset class, and note length
   bucket; oversample corrective and emergency WOs, which carry most failures. Include a slice of
   triage exits so triage false negatives are measured.
2. **Label in a table, in the account.** Create a labeling table in a governed schema (same
   column shape as `ANSWER_KEY_SIGNALS`, plus `labeler_role` and `labeled_at`). A maintenance lead or
   reliability engineer labels component, failure mode and polarity per finding, plus "no findings".
   Never export notes to a spreadsheet outside the account to label them.
3. **Double-label a subset** (50-100 sources) with a second person; report agreement on polarity
   and component. Where humans disagree, the model cannot be held to a higher standard -- record the
   human agreement level next to model accuracy.
4. **Point the harness at the labeled table** as the answer key (same column names), with
   `ANSWER_KEY_SOURCES` built from the sampled sources.
5. **Precursors on production:** labels are the downtime log; the canary is replaced by a manual
   audit of the ten highest-scoring true positives -- read the evidence each alert was built from and
   confirm every record pre-dates the cutoff and none describes the failure itself.

## Gate output

A compact report: coverage losses; `OBS_EXACT` / `OBS_COMPONENT` / `OBS_ASSEMBLY` P/R/F1 overall and
per class; macro F1 with stddev; the polarity confusion cells listed above; per-kind table; recurring
recovery; canary result; per-variant precursor table with base rate, events and lead-time
percentiles; tokens per 1K records. Write `phases.eval: done` and the new
`min_acceptable_*` thresholds once the user accepts the run.
