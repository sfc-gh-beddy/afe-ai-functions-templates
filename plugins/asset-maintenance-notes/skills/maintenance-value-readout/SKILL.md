---
name: maintenance-value-readout
description: "Phase 8 of the asset-maintenance-notes build. Applies the shared value model to measured pipeline outputs and customer-supplied inputs only: OpEx from avoidable repeat truck rolls (repeat visits x planner-reviewed avoidable share x truck roll cost) and from unplanned downtime converted to planned work (events x measured actionable event recall x intervention success x net hours x cost per hour), CapEx from condition-based replacement deferral on non-mandated assets (cash deferred and the time value of deferral at the customer's cost of capital), with disjoint event sets so nothing is counted twice, low / expected / high ranges, Snowflake consumption from measured tokens and credits converted only at the customer's own credit price, and 2-week POC success criteria. Never invents unit economics or benchmarks. Use for business case, value readout, ROI, how much capex can we defer, truck roll savings, POC criteria."
parent_skill: asset-maintenance-notes
---

# Value readout

The readout converts measured outputs into the customer's money using the customer's numbers.
It is built on `shared/references/value-model.md` (repo root) and `shared/references/poc-template.md`.

Hard rules, from the shared model and this play's best practices:

- **Customer-supplied numbers only.** Every monetary input comes from the customer and is recorded
  in `value_inputs` with `source_notes` (who supplied it, when). Absent input means that lever is
  shown as a formula with blanks, not filled with a plausible figure.
- **No benchmarks.** Do not quote industry figures for truck roll cost, downtime cost, repeat-visit
  rates or deferral rates, even if asked. Offer to compute them from the customer's own data where
  that is possible (repeat-visit rate and unplanned event counts are measurable here).
- **Measured rates come from Phase 6, with their sample sizes.** If evaluation ran only on the
  sandbox, every rate is labeled "sandbox, upper bound" and the readout recommends the production
  labeling protocol before any figure is used for a decision.
- **Each event is valued once** (best-practices rule 37).
- **Safety-mandated replacements are excluded** from the CapEx lever (best-practices rule 36).
- **Snowflake cost in tokens and credits as measured.** Converted to currency only with the
  customer's own contracted credit price, supplied by them.

## Inputs

### From the pipeline (measured)

| Quantity | Source |
|---|---|
| repeat visits per year | `MAINT_REPEAT_VISITS`, trailing 12 months, window stated |
| unplanned failure events per year | `MAINT_FAILURE_LABELS` (customer downtime log), trailing 12 months |
| actionable event recall, alert precision, lead-time percentiles, test events | Phase 6, accepted `experiment_id` and `model_variant` |
| failure-signal precision/recall | Phase 6 `OBS_EXACT` |
| assets in the replacement plan with no observed degradation and below alert threshold | query below |
| tokens per 1,000 records; credits for the evaluation run | Phase 6 cost section and usage view |
| CMMS failure-code baseline (share `OTHER` / default) | preflight section 9 |

### From the customer (ask; never default)

| Key in `value_inputs` | Question to ask |
|---|---|
| `truck_roll_cost` | fully loaded cost of one corrective visit (crew time, travel, vehicle) |
| `avoidable_repeat_share` (low / expected / high) | of a reviewed sample of repeat pairs, what share would a correct first fix have prevented? (from the planner review in Phase 4) |
| `repeat_prevention_rate` (low / expected / high) | of avoidable repeats, what share do they expect to prevent once recurring issues are visible? |
| `downtime_cost_per_hour` | by asset class or criticality if it differs |
| `avg_unplanned_downtime_hours`, `avg_planned_repair_hours` | per event; net hours saved is the difference |
| `intervention_success_rate` (low / expected / high) | when warned in time, how often can they intervene before failure? |
| `planned_age_based_replacements_per_year`, `replacement_unit_capex` | by class |
| `deferral_years` (low / expected / high) | how long a condition-evidenced replacement is typically pushed |
| `deferral_acceptance_rate` | share of evidence-supported deferrals their engineers would accept |
| `cost_of_capital_pct` | for the time value of deferral |
| `mandated_classes_or_work_types` | replacements that may never be deferred |
| `credit_price` | their contracted price per credit, if they want currency |
| `monthly_new_records` | notes + inspections per month, for run-rate cost |

## Lever formulas

All three are computed per asset class where inputs differ, then summed, each as low / expected /
high using the customer's ranges and the confidence bounds of measured rates.

### OpEx 1 -- avoidable repeat truck rolls

```
repeat_visits_per_year (measured, excluding repeats linked to a failure event)
  x avoidable_repeat_share       (customer, from planner review)
  x repeat_prevention_rate       (customer)
  x truck_roll_cost              (customer)
```

### OpEx 2 -- unplanned downtime converted to planned work

```
unplanned_events_per_year        (measured from the customer's downtime log)
  x actionable_event_recall      (measured, Phase 6; with its event count)
  x intervention_success_rate    (customer)
  x (avg_unplanned_downtime_hours - avg_planned_repair_hours)   (customer)
  x downtime_cost_per_hour       (customer)
```

Alert precision does not enter the value; it enters the **cost** of acting: false alerts consume
planner and crew time. State it as alerts per month and the share that were followed by a failure,
and let the customer judge whether that workload is acceptable within their alert budget.

### CapEx -- condition-based replacement deferral

```
candidate_deferrals = planned age-based replacements (customer plan)
                      on non-mandated classes
                      with no OBSERVED degradation finding in the lookback
                      and current risk below the alert threshold         (measured, query below)

capex_deferred_in_year   = candidate_deferrals x deferral_acceptance_rate x replacement_unit_capex
deferral_economic_value  = capex_deferred_in_year x (1 - (1 + cost_of_capital_pct) ^ (-deferral_years))
```

Present both lines and say what each means. `capex_deferred_in_year` is budget relief in the year --
the cash is still spent later. `deferral_economic_value` is the time value of spending it later, and
is the number that belongs in an ROI. The shared value model's "deferred replacements x unit capex"
is the first line; do not present it as savings.

Deferral evidence must be per asset and auditable: the absence of observed degradation means nothing
if the asset was not inspected. Require at least one inspection or condition reading in the lookback
for an asset to count as a candidate, and show the inspection coverage.

## Measured quantities -- queries

```sql
-- Repeat visits per year, excluding repeats that are part of a failure event (counted in OpEx 2).
SELECT COUNT(*) AS repeat_visits_12m, MAX(window_days) AS window_days
FROM MAINT_REPEAT_VISITS r
LEFT JOIN MAINT_LABEL_WORK_ORDERS lw ON lw.wo_id = r.repeat_wo_id
WHERE lw.wo_id IS NULL
  AND r.repeat_created_at >= DATEADD(month, -12, CURRENT_DATE());

-- Unplanned events per year, by class.
SELECT a.<class_col> AS asset_class, COUNT(*) AS unplanned_events_12m
FROM MAINT_FAILURE_LABELS l
JOIN <asset_registry> a ON a.asset_id = l.asset_id
WHERE l.failure_ts >= DATEADD(month, -12, CURRENT_DATE())
GROUP BY 1;

-- CapEx candidates: planned replacements (customer table) with condition evidence.
WITH plan AS (
    SELECT p.asset_id, p.planned_replacement_date
    FROM <replacement_plan> p
    JOIN <asset_registry> a ON a.asset_id = p.asset_id
    WHERE p.planned_replacement_date BETWEEN CURRENT_DATE() AND DATEADD(month, 12, CURRENT_DATE())
      AND a.<class_col> NOT IN (<mandated classes>)
      AND NOT COALESCE(p.is_mandated, FALSE)
), evidence AS (
    SELECT pl.asset_id,
           COUNT(DISTINCT IFF(s.source_type IN ('INSPECTION', 'INSPECTION_FILE'), s.source_id, NULL)) AS inspections_180d,
           COUNT_IF(s.polarity = 'OBSERVED'
                    AND s.failure_mode_code IN ('EXTERNAL_LEAK','HIGH_VIBRATION','OVERHEATING',
                                                'ABNORMAL_NOISE','CONTAMINATION','WEAR','BREAKDOWN')) AS degradation_findings_180d
    FROM plan pl
    LEFT JOIN MAINT_DT_SIGNALS s
      ON s.asset_id = pl.asset_id AND s.source_ts >= DATEADD(day, -180, CURRENT_DATE())
    GROUP BY 1
)
SELECT COUNT(*)                                                            AS planned_replacements_12m,
       COUNT_IF(e.inspections_180d > 0)                                    AS with_recent_inspection,
       COUNT_IF(e.inspections_180d > 0 AND e.degradation_findings_180d = 0
                AND COALESCE(r.is_alert, FALSE) = FALSE)                   AS candidate_deferrals
FROM plan p
JOIN evidence e ON e.asset_id = p.asset_id
LEFT JOIN MAINT_ASSET_RISK_CURRENT r ON r.asset_id = p.asset_id;
```

On the sandbox there is no replacement plan; the CapEx lever is shown as a formula only.

## Snowflake consumption

```
monthly_input_tokens  ~ monthly_new_records x (1 - triage_exit_share) x (1 - dedup_share)
                        x avg_prompt_tokens_per_call      (all measured)
monthly_output_tokens ~ same call count x avg_completion_tokens_per_call
```

Plus triage, embedding and `AI_AGG` usage from the usage view, and warehouse credits for the
dynamic-table and task refreshes (from `WAREHOUSE_METERING_HISTORY` for the pipeline warehouse during
the evaluation run). Report tokens and credits per month. If the customer supplied `credit_price`,
also show credits x their price; otherwise stop at credits.

ROI = (sum of lever values, expected case) / (annualized Snowflake cost at the customer's price).
If any lever input is missing, show ROI for the levers that are complete and name what is missing.

## Readout document structure

1. **The decision this changes** -- named by the customer (for example: which bad actors get a
   root-cause review this quarter; which age-based replacements are challenged).
2. **What the data showed** -- CMMS failure-code baseline versus what the notes contain; top
   recurring issues; repeat-visit count with window; precursor results with event counts.
3. **How accurate it is** -- Phase 6 headline numbers, with sample sizes, and whether they are
   sandbox or production-labeled.
4. **Value** -- each lever: formula, inputs with their source, low / expected / high. Missing inputs
   shown as blanks.
5. **Cost** -- tokens and credits per 1,000 records and per month; currency only at their price.
6. **What it does not do** -- no CMMS write-back; no automatic schedule changes; no deferral of
   mandated work; sandbox accuracy is an upper bound.
7. **POC success criteria** (below).

Write it in the session or to a governed location the user chooses. Never include note text or
evidence spans from production data in a document that leaves the account; use counts and synthetic
examples.

## POC success criteria (2 weeks, per the shared template)

Agree each target with the customer; do not propose a target number on their behalf.

| Criterion | Measured by | Target |
|---|---|---|
| Failure-signal extraction accuracy | `OBS_EXACT` precision and recall on a hand-labeled sample of 300-500 production sources | set with customer |
| Polarity correctness | `RULED_OUT -> OBSERVED` false-failure rate on inspections | set with customer |
| Cost | extraction tokens per 1,000 records; credits per month at their volume | set with customer |
| Recurring issues | planner agreement on a reviewed sample of repeat pairs | set with customer |
| Precursors (if in scope) | actionable event recall and alert precision on a time-split test, at their alert budget, leakage canary passed | set with customer |
| Decision | one named decision the business takes differently because of the output | named by the business owner |

Week 1: discovery, preflight, sandbox build and evaluation, production sample extraction and
labeling. Week 2: production evaluation, operationalize (dynamic tables, semantic view, agent),
readout.

Record `phases.readout: done` once the customer has reviewed the readout.
