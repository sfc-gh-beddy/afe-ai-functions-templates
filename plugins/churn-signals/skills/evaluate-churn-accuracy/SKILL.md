---
name: evaluate-churn-accuracy
description: "Measure whether the churn-signals pipeline is right and what it costs. Reason classification: per-reason precision, recall and F1 plus micro and macro averages against the labeled answer key, joined from ground truth so dropped and failed interactions count as misses; binary risk detection by case type, the false-flag rate on planted distractors, per-channel recall, reason confusion pairs, intent versus case type, evidence grounding rate, and parse/failure accounting. Churn model: AUC computed in SQL from the registered model's own TEST scores and compared with the training script, bootstrap intervals, PR-AUC, decile lift and cumulative capture, calibration (predicted versus observed per decile), text uplift over a usage-only baseline, capture by latent cohort (vocal versus silent churners), and the leaky-versus-honest contrast. Cost: credits per 1K interactions from CORTEX_AI_FUNCTIONS_USAGE_HISTORY by query tag, plus show_details tokens. Sets risk-band thresholds from the lift table. Includes a protocol for labeling a real-data sample. Phase 7 of the churn-signals build; never skipped. Triggers: churn model AUC, lift, reason precision recall, is the model leaking, evaluate churn, cost per 1K."
parent_skill: churn-signals
---

# Evaluate accuracy and cost

A churn pipeline nobody has measured produces a save list of unknown value -- and CSMs who are given a
noisy list once stop reading it. This phase answers five questions with numbers:

1. Are the extracted reasons right? (precision / recall per reason)
2. Does it raise false alarms on things that only look risky? (distractor false-flag rate)
3. Does the model rank churners above renewers, beyond what usage already does? (AUC, lift, uplift)
4. Can the probabilities be summed as ARR? (calibration)
5. What did it cost per 1K interactions?

If the user wants to stop before this phase, say plainly what they will not know.

## The distinction that matters most

Three different numbers get called "accuracy" in this play, and they are not interchangeable:

| Number | Measures | Comes from |
|---|---|---|
| Reason P/R/F1 | whether a single interaction's reasons are right | answer key (sandbox) or a labeled real sample |
| Model AUC / lift | whether accounts are ranked correctly by churn risk | renewal outcomes on the TEST split |
| `p_churn` on a row | how likely one account is to churn | the model |

A high reason F1 with a weak model means the text is read correctly but carries little predictive
signal on this population. A strong model with mediocre reason F1 means the evidence shown to CSMs is
less trustworthy than the ranking. Report both, separately.

## Run it

Substitute and run `sql/01_evaluate.sql`. It reads `{{EVAL_SCHEMA}}` -- the only phase allowed to.

### 1. Silent loss first

The coverage query: `missing_from_output`, `classify_failed`, `evidence_failed`, `ungrounded_quotes`,
`grounding_rate`. If the first three are not near zero, every metric below is measured on a subset --
say so before presenting them, and fix them first (DIAGNOSING #3, #6).

### 2. Reason classification

Per-reason table, then micro and macro. Present per-reason with support; a reason with ten
interactions has an F1 that moves a lot on two errors.

How to read micro versus macro: micro is dominated by the common reasons (price/value and product gap
are weighted double in the sandbox). Macro weights every reason equally and exposes rare ones --
champion loss, business change. A large micro-macro gap means the rare reasons need better label
descriptions or examples.

Then the case-type table. The shape that indicates a working classifier:

| case_type | flag_rate should be |
|---|---|
| `SIGNAL` | high -- this is recall on pre-cutoff evidence |
| `POST_OUTCOME` | very high -- explicit statements of leaving |
| `NOISE` | low |
| `DISTRACTOR` | low -- **the precision number CSMs feel** |

Report the distractor flag rate by distractor template where it is high (join the answer key's
`interaction_id` back to `SYN_INTERACTIONS.subject` to see which pattern leaks); each pattern has a
targeted fix in best-practices 19.

Per-channel recall and false-flag rate, the reason-confusion pairs, and intent versus case type
(POST_OUTCOME should be `high` intent) complete the reason picture.

### 3. The model

**AUC from SQL, not from the script.** `_EVAL_SCORES` uses `CHURN_SCORES` for TEST rows -- what the
registered model returned through `MODEL()!PREDICT_PROBA`. The SQL AUC must match the script's
`combined` AUC to rounding. A mismatch means the deployed artifact or its feature mapping differs from
what was evaluated (DIAGNOSING #7). Do not present either number until they agree.

**Intervals.** Quote the script's bootstrap CI95 with every AUC. With few TEST churners the interval is
wide; do not compare two models whose intervals overlap as if one were better.

**Uplift.** From `MODEL_EXPERIMENTS`: `combined` versus `usage_only`, same experiment. This is the
play's central claim; present it with both intervals.

**Lift and capture.** The decile table: churn rate per decile over the base rate, and cumulative share
of churners captured. "The top 20% of scored accounts contained X% of churners" is the sentence a CS
leader can plan staffing around -- with X from this table.

**Calibration.** `mean_predicted` versus `observed_rate` per decile. If they diverge materially
(expect it: `scale_pos_weight` inflates probabilities), say that `arr_at_risk_expected` must not be
summed as a forecast. Present ARR in HIGH/WATCH bands instead, or calibrate the model and re-evaluate.

**Cohort capture (sandbox).** Top-20% capture by latent cohort. Expected: strong on `VOCAL`, weak on
`SILENT` (no text; only usage can find them), and `SAVED` accounts scored high -- which is correct
behaviour, since they were genuinely at risk. This is the honest picture of what text does and does
not do.

**Leaky contrast (sandbox).** If `--leaky-demo` ran, put `LEAKY_DEMO` next to `combined`. State which
of the three planted leaks drove it (on the sandbox `crm_status_churned` alone separates the labels by construction).

### 4. Cost

Credits by function and model from `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY`,
filtered by the `QUERY_TAG` the extraction set (`churn-signals:<run_id>:%`) and the run start time,
divided by staged interactions to give **credits per 1K interactions**. The view lags; if it is empty,
say so and re-run later rather than substituting an estimate. Add the `show_details` token totals for
the evidence stage, and compare with the gate's `AI_COUNT_TOKENS` estimate -- report how far the
estimate was below actual.

Report credits and tokens only. The value readout converts to currency only with a customer-supplied
credit price.

## Set the risk bands

From the TEST decile table, choose `thresholds.high_risk` and `thresholds.watch` with the owner, based
on CSM capacity rather than a round number:

- How many accounts per quarter can the CS team run a full save play on? That count, as a share of open
  renewals, picks the HIGH cutoff (the `min_score` of the corresponding decile from the script's lift
  table).
- WATCH is the next band the team can touch lightly (an automated check-in, a CSM review).

Write the thresholds to `churn-project.yml`, re-band `AT_RISK_ACCOUNTS` for the current
`score_run_id`, and **freeze them** for subsequent runs (best-practices 10).

## What to present at the gate

In this order:

1. Silent-loss counts (and that they are near zero, or what was done).
2. Reason micro and macro P/R/F1; the per-reason table; distractor false-flag rate.
3. Model: usage-only AUC, combined AUC, uplift -- each with its interval; SQL AUC matches script.
4. Decile lift and capture; calibration verdict.
5. Sandbox: cohort capture and the leaky contrast.
6. Credits per 1K interactions, and the estimate-versus-actual gap.

Then `phases.eval: done`. Only now offer to resume the incremental task.

## Labeling real data

On real data there is no answer key. Before quoting reason precision to a customer:

1. Draw a stratified sample of 200-400 interactions from the extraction run: flagged and unflagged,
   across channels, and oversampling the rare predicted reasons.
2. Have two people from the customer's CS team label each with the agreed taxonomy, **without seeing
   the model's labels**. Measure their agreement (share of exact-set matches). Human agreement is the
   ceiling; a model "below target" may be at the humans' level.
3. Load the labels into a quarantined table shaped like `SYN_INTERACTION_LABELS`
   (`interaction_id`, `true_reasons`, `case_type` = `SIGNAL` or `NOISE`) and run the reason section
   of `01_evaluate.sql` against it.
4. Because the sample is stratified, report per-reason precision directly but reweight recall to the
   population, or report recall only for the stratum and say so.

The model metrics need no extra labeling: renewal outcomes are the labels.

## Interpreting the numbers honestly

- Sandbox reason accuracy is an upper bound: templates are clean and single-topic.
- Sandbox AUC shows the pipeline can use planted signal; it says nothing about how much signal a
  customer's text holds. Never present sandbox AUC as an expected result on customer data.
- A small or null text uplift on real data is a legitimate finding. The reason analytics and the
  evidence on each at-risk row may still justify the build; say which.
- Do not quote external benchmarks for churn-model AUC or save rates as if they applied here.

## Rerunning after a change

New `experiment_id` and `run_id` (extraction change) or `model.version` (training change). The raw
tables, `CHURN_SCORES` and `MODEL_EXPERIMENTS` accumulate, so a before/after comparison is one query.
Compare on the same sample and the same TEST split; a change evaluated on different rows is not a
comparison.
