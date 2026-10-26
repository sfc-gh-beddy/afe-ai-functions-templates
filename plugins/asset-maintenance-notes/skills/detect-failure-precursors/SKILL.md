---
name: detect-failure-precursors
description: "Phase 5 of the asset-maintenance-notes build. Builds per-asset failure-precursor signals that are leak-free by construction: labels from unplanned downtime (or emergency work orders), a weekly point-in-time cutoff grid, text features from OBSERVED and UNCLEAR signals filtered by note timestamp, maintenance-history and repeat-visit features, sensor drift features with NULLs kept and rolling point-in-time baselines, a max_source_ts leakage assertion, a time-based train/test split with a lookback-plus-horizon gap, failure work orders excluded by id, and three SNOWFLAKE.ML.CLASSIFICATION variants (combined, sensor-only, text-only) so the value added by maintenance text is measured. Produces MAINT_ASSET_RISK. Use for failure precursors, early warning, predictive maintenance from notes, asset risk scoring, condition-based replacement evidence."
parent_skill: asset-maintenance-notes
---

# Detect failure precursors

The question this phase answers: **before an unplanned failure, did the notes, inspections, sensors
and maintenance history contain enough signal, early enough, to act?** And the companion question
that makes the answer trustworthy: **could the pipeline have known it at the time?**

Precursor models in maintenance are unusually easy to leak, because the records describing a failure
are written in the same system, often on the same work orders, and frequently after the fact. A
leaked model reports long, confident lead times in evaluation and nothing in production.

`sql/30_precursor_features.sql` is the plain-SQL implementation.

## Prerequisites and settled inputs

Before building features, these must be in `maintenance-project.yml` -- ask for the customer-owned
ones, never default them:

| Key | Owner | Meaning |
|---|---|---|
| `precursor.horizon_days` | customer | how far ahead a warning should look (e.g. the parts lead time plus planning cycle) |
| `precursor.min_lead_days` | customer | below this, an alert cannot change the outcome (no crew, no part) |
| `precursor.alert_budget_per_month` | customer | how many alerts planners can act on per month |
| `precursor.cutoff_policy` | preflight | `note_ts` or `wo_last_modified` (preflight section 5) |
| `precursor.label_source` | preflight | `downtime` preferred; `emergency_wo` fallback |
| `precursor.split.train_end`, `test_start` | this phase | with gap >= lookback + horizon |

Also required: `phases.extract: done`; `phases.recurring: done` if repeat-visit features are used
(skip those features otherwise).

## The leakage model, stated once

Every feature row is `(asset_id, cutoff_ts)`. A record may contribute only if **its own timestamp is
strictly before `cutoff_ts`**. The leaks this phase defends against, and where:

| Leak | Defense | Where |
|---|---|---|
| As-found and hindsight notes appended to older WOs | filter on note `source_ts`, never on WO `created_at` | text features |
| WO long text edited after the event | `cutoff_policy: wo_last_modified` excludes WOs modified at or after cutoff | text features (alternative policy) |
| The failure's own WO raised just before the downtime log start | `MAINT_LABEL_WORK_ORDERS`: emergency/CM WOs within `grace_hours` before failure, excluded by id | all WO-derived features |
| Label-derived features | no "days since last emergency WO" when emergency WOs are the label; history counts exclude label WOs | history features |
| Random split | time split with a gap of at least lookback + horizon | grid `split` column |
| Fitted things seeing the future | sensor baselines are rolling windows ending before the recent window; clusters fitted on train only (Phase 4) | sensor features, cluster ids |
| Asset identity as a feature | `asset_id` and timestamps excluded from training views | training views |
| Model's own random holdout | `SNOWFLAKE.ML.CLASSIFICATION` built-in evaluation metrics are not reported; Phase 6 evaluates on `TEST` | Phase 6 |
| Cutoffs during the outage | cutoffs inside `[failure, failure_end + recovery_days)` excluded | grid |

And one assertion that catches anything missed: `max_source_ts < cutoff_ts` for every row. The
script runs it; dbt mode makes it a build-failing test.

## Steps

### 1. Labels

Unplanned downtime events become `MAINT_FAILURE_LABELS`. Planned downtime is excluded. Show counts
per asset class; fewer than a few dozen events per class means results for that class are anecdotal,
and the readout must say so.

If `label_source: emergency_wo`, labels come from emergency work orders. State the consequence: the
label is timestamped when the WO was raised, which can be hours or days after the actual failure,
which **inflates** apparent lead time. Prefer an operations log, SCADA trip record, or outage table if
one exists.

### 2. Cutoff grid and split

Weekly cutoffs per asset. A cutoff is labeled positive when a failure starts in
`(cutoff, cutoff + horizon]`. Cutoffs whose label window runs past the end of history are dropped
(the label is not observable yet). Split:

- `TRAIN`: cutoff and its whole horizon before `train_end`;
- `TEST`: cutoff on or after `test_start`;
- `GAP`: everything between -- not used for training or testing.

Run the gap guard first; it must return `gap_ok = TRUE`. For the sandbox at default parameters, a
`train_end` around the middle of the history leaves planted events on both sides; check
`02_verify_seed.sql` check 12 for the event spread and pick dates accordingly.

Where the asset count allows, prefer `time_and_asset`: additionally hold out a set of assets entirely
from training. It tests whether the model generalizes to equipment it has never seen, which is the
production situation for new installs.

### 3. Features

| Family | Features | Notes |
|---|---|---|
| Text (signals) | observed counts 30/60d, unclear count, medium/high severity count, distinct components, degradation-mode count, days since last observed | from `MAINT_SIGNALS` filtered to valid rows; `UNCLEAR` is its own feature (hedged early mentions), never counted as observed |
| Maintenance history | corrective and PM WO counts 180d, days since PM | label WOs excluded |
| Repeat visits | repeat visits 180d | point in time on `repeat_created_at` |
| Sensors | 7-day average, rolling baseline (window ending 60 days before cutoff), delta, 21-day slope, 14-day coverage | NULLs kept; coverage tells the model when absence of drift means "no data" |
| Asset | class, age at cutoff | age is point in time from install date; use move history if equipment changes position |

Keep NULLs where the absence is meaningful (`days_since_last_observed` NULL = nothing observed in the
window). The classification function accepts NULL feature values; do not impute zeros, which would
claim "observed today".

### 4. Leakage assertion and base rate

```sql
SELECT asset_id, cutoff_ts, max_source_ts
FROM MAINT_PRECURSOR_FEATURES
WHERE max_source_ts >= cutoff_ts;           -- must return zero rows
```

Then the base rate per split. Report it next to every precision figure from here on; it is the
precision a coin weighted to the base rate would achieve.

### 5. Train three variants

`SNOWFLAKE.ML.CLASSIFICATION` on views that exclude identifiers and timestamps:

| Model | Features | Why |
|---|---|---|
| `COMBINED` | text + history + sensors + asset | the candidate |
| `SENSOR` | sensors + asset | the baseline most customers already have or can buy |
| `TEXT` | text + history + asset | what the notes alone carry -- the core claim of this play |

The ablation is the point. "Maintenance text improves precursor precision at a fixed alert budget
over sensors alone" is a claim the readout can only make if `COMBINED` beats `SENSOR` on `TEST`. For
the many fleets with no condition monitoring, `TEXT` is the whole model, and its numbers alone go in
the readout.

The model's own `SHOW_EVALUATION_METRICS` uses a holdout drawn from the training rows -- which are
weekly snapshots of the same assets, so neighbouring weeks of the same asset land on both sides.
Those metrics are optimistic and are not reported. `SHOW_FEATURE_IMPORTANCE` is useful and is shown.

```sql
CALL MAINT_PRECURSOR_MODEL_COMBINED!SHOW_FEATURE_IMPORTANCE();
```

If importance is dominated by one feature that looks like the label in disguise (for example a
history feature that jumps right before failures), audit that feature's inputs against
`MAINT_LABEL_WORK_ORDERS` before doing anything else.

### 6. Score

`PREDICT` over `TRAIN` and `TEST` cutoffs into `MAINT_ASSET_RISK`, one row per model variant. Inspect
the `prediction` object once and confirm the probability key for the positive class before trusting
`risk_score`; with a BOOLEAN target the key is expected to be the class label as text, but verify on
this account rather than assuming. Thresholding and alerting happen in Phase 6, against the alert
budget, not here.

## Rules-only baseline (when there are too few events to train)

With very few failures per class, a trained model overfits. Use a transparent score instead and
evaluate it identically in Phase 6:

```sql
SELECT asset_id, cutoff_ts, split,
       2.0 * observed_30d + 1.0 * (observed_60d - observed_30d) + 0.5 * unclear_60d
     + 1.5 * observed_med_high_60d + 1.0 * repeat_visits_180d
     + IFF(vib_delta > 0, vib_delta, 0) + IFF(temp_delta > 0, temp_delta / 5, 0) AS rule_score
FROM MAINT_PRECURSOR_FEATURES;
```

The weights are a starting point to be reviewed with a reliability engineer, not a calibrated model;
say so. The value is that every alert can be explained in one sentence.

## Gate verification

- gap guard returns `TRUE`;
- leakage assertion returns zero rows;
- base rate and distinct events per split (both splits must contain events);
- feature importance for `COMBINED`;
- three sample `prediction` objects with the confirmed probability path.

On the sandbox, also run the canary check from `evaluate-maintenance-accuracy` (harness-side): no
`ANSWER_KEY_LEAKAGE_CANARY` record may fall inside any feature window for its event.

Record models and tables in `created_objects`, and set `phases.precursor: done`.

## Explaining an alert

When an asset is flagged, the planner needs the evidence, not the score. For any `(asset_id,
cutoff_ts)`:

```sql
SELECT s.source_ts, s.source_type, s.component_code, s.failure_mode_code, s.polarity, s.severity,
       s.evidence_span
FROM MAINT_SIGNALS s
WHERE s.asset_id = :asset_id
  AND s.run_id = $run_id
  AND s.polarity IN ('OBSERVED', 'UNCLEAR')
  AND s.source_ts <  :cutoff_ts
  AND s.source_ts >= TIMESTAMPADD(day, -$lookback_days, :cutoff_ts)
ORDER BY s.source_ts;
```

The agent in Phase 7 uses the same query pattern, so the explanation it gives is the same evidence
the features were built from.
