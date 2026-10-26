---
name: call-center-value-readout
description: "Phase 8 of the call-center-intelligence build. Converts measured pipeline output into a value narrative and POC success criteria by applying the repo's shared value model (shared/references/value-model.md) with customer-supplied unit economics only. Covers OpEx levers (QA labor redirected by automated scoring, avoidable repeat-contact handle time, self-service deflection by contact reason, escalation load) and revenue levers (save-gap recovery, unworked buying signals), each as low / expected / high ranges, adjusted by measured signal precision, de-duplicated across overlapping levers, and set against measured Snowflake consumption from account usage. Never invents benchmarks, AHT, loaded cost, save rates or conversion rates. Produces a one-page readout and POC criteria from shared/references/poc-template.md. Use for: business case, ROI, value of call analytics, what is this worth, POC success criteria, readout."
parent_skill: call-center-intelligence
---

# Value readout

This phase writes a document, not database objects. It answers one question for an economic buyer: what decisions
would this signal change, and what is that worth **in their numbers**.

Read first: `shared/references/value-model.md` and `shared/references/poc-template.md` at the repo root. The value
model's rule governs everything here: **customer-supplied numbers only; mark every assumption; never invent unit
economics.** That includes industry "typical" AHT, QA cost, deflection or save rates. If the customer does not have
a number, the lever is shown as a formula with a blank, not filled with a plausible guess.

## Inputs — three kinds, labeled distinctly

| Kind | Source | Example | Label in the readout |
|---|---|---|---|
| **Measured** | this pipeline, on this corpus | calls per reason, repeat-generating calls, save gaps, signal precision, tokens per 1K calls | "measured, sandbox" or "measured, real sample (n = ...)" |
| **System of record** | customer tables found at preflight | handle seconds, monthly call volume, cancellation outcomes | "from <table>" |
| **Customer-supplied** | stated by the customer in the session | loaded cost per agent hour, QA minutes per evaluation, retained value per saved customer, assumed reducible share | "customer input, <who>, <date>" |

Record every customer-supplied input in `callcenter-project.yml` under `value_inputs`, with who supplied it and when:

```yaml
value_inputs:
  monthly_call_volume:        {value: null, source: "system of record: RAW.CALL_DETAIL_RECORDS, last full month"}
  loaded_cost_per_agent_hour: {value: null, source: "customer input", by: null, date: null}
  qa_minutes_per_evaluation:  {value: null, source: "customer input", by: null, date: null}
  manual_evaluations_per_month: {value: null, source: "customer input", by: null, date: null}
  qa_effort_redirect_share:   {low: null, expected: null, high: null, source: "customer input"}
  repeat_reducible_share:     {low: null, expected: null, high: null, source: "customer input"}
  self_service_containment:   {low: null, expected: null, high: null, source: "customer input"}
  cost_per_self_service_contact: {value: null, source: "customer input"}
  save_acceptance_rate:       {value: null, source: "measured | system of record | customer input"}
  retained_value_per_save:    {value: null, source: "customer input"}
  upsell_conversion_rate:     {value: null, source: "measured | system of record | customer input"}
  incremental_value_per_upsell: {value: null, source: "customer input"}
  credit_price:               {value: null, source: "customer input (their contract)"}
```

Ask for them with `ask_user_question`, a few at a time, starting with the levers the customer cares about. Do not
ask for all thirteen up front.

## Pull the measured volumes

From `CALL_FACTS` over a representative window (prefer the last full month of real data; on the sandbox, say the
figures are synthetic and only illustrate the arithmetic):

```sql
SELECT
  COUNT(*)                                                           AS calls,
  SUM(handle_seconds) / 3600                                         AS handle_hours,
  AVG(handle_seconds)                                                AS avg_handle_seconds,
  COUNT_IF(generated_repeat)                                         AS repeat_generating_calls,
  COUNT_IF(is_repeat)                                                AS repeat_calls,
  SUM(IFF(is_repeat, handle_seconds, 0)) / 3600                      AS repeat_handle_hours,
  COUNT_IF(self_service_fit = 'HIGH')                                AS high_fit_calls,
  SUM(IFF(self_service_fit = 'HIGH', handle_seconds, 0)) / 3600      AS high_fit_handle_hours,
  COUNT_IF(is_repeat AND self_service_fit = 'HIGH')                  AS overlap_repeat_and_high_fit,
  COUNT_IF(supervisor_requested = 'YES')                             AS supervisor_requests,
  COUNT_IF(cancel_intent)                                            AS cancel_intents,
  COUNT_IF(save_gap)                                                 AS save_gaps,
  COUNT_IF(save_offer_made)                                          AS save_offers,
  COUNT_IF(save_outcome = 'ACCEPTED')                                AS saves_accepted,
  COUNT_IF(unworked_buying_signal)                                   AS unworked_buying_signals,
  COUNT_IF(upsell_offered)                                           AS upsell_offers,
  COUNT_IF(upsell_outcome = 'ACCEPTED')                              AS upsells_accepted,
  MIN(call_date) AS window_start, MAX(call_date) AS window_end
FROM CALL_FACTS
WHERE call_date BETWEEN :window_start AND :window_end;
```

Scale to a month using the **system-of-record** monthly volume, not by extrapolating the sample's day count, and
say which calls the sample represents (queues, lines of business). If the sample excludes a queue, the readout
excludes it too.

Handle time is from `handle_seconds` (system of record), never from audio duration (best-practices A7).

## Accuracy adjustment

A volume from the pipeline is only as good as the signal's precision. Multiply each measured volume by the
**measured precision** of the signal behind it from Phase 6 (`save_gap` precision for save gaps, `cancel_intent`
precision, reason precision for the HIGH-fit labels, `references_prior` / `is_repeat` for repeats). State recall
alongside: low recall means the volume is an **undercount**, which makes the estimate conservative, and say so.

If precision was measured only on the sandbox, label the adjusted figure "sandbox precision; to be confirmed on
the POC labeled sample".

## The levers

Each is computed for low / expected / high using the customer's range for any share or rate. Formulas follow
`shared/references/value-model.md`; the call-center-specific forms are below.

### OpEx 1 — QA labor redirected

Automated scoring covers every eligible call; the value is the analyst time the customer chooses to redirect from
listening to coaching, calibration or other work. It is **not** headcount removal unless the customer says so.

```
qa_hours_redirected = manual_evaluations_per_month x qa_minutes_per_evaluation / 60 x qa_effort_redirect_share
value               = qa_hours_redirected x loaded_cost_per_agent_hour   (or QA analyst cost per hour, if supplied)
```

Also report, without a dollar figure: coverage today (`manual_evaluations_per_month / monthly_call_volume`) versus
coverage with the pipeline (role-eligible share from Phase 2), and the measured within-one agreement per criterion.
Coverage is often the larger story and needs no assumption.

### OpEx 2 — Avoidable repeat contacts

```
repeat_hours        = repeat_handle_hours_per_month x precision(is_repeat)
value               = repeat_hours x repeat_reducible_share x loaded_cost_per_agent_hour
```

`repeat_reducible_share` is the customer's estimate of how much of repeat volume fixing the top drivers would
remove. Show the top three repeat drivers by reason and by driver narrative so the customer is estimating against
something concrete. Never supply the share.

### OpEx 3 — Self-service deflection

```
deflectable_calls   = high_fit_calls_per_month x precision(reason, HIGH-fit labels)
value               = deflectable_calls x self_service_containment
                      x (avg_handle_seconds_high_fit / 3600 x loaded_cost_per_agent_hour - cost_per_self_service_contact)
```

`self_service_fit` per label must be customer-confirmed (see `classify-contact-reasons`). Do not count calls the
customer says are already offered self-service and still call; they are evidence the flow does not work, which is
a different (and useful) finding.

### De-duplicate OpEx 2 and OpEx 3

A repeat call in a HIGH-fit reason would be counted by both levers. Subtract `overlap_repeat_and_high_fit` hours
from one lever (state which) before summing. Show the overlap explicitly.

### OpEx 4 — Escalation load (optional)

Only if the customer supplies supervisor minutes per escalation:

```
value = supervisor_requests_per_month x precision(supervisor_requested) x escalation_reducible_share
        x supervisor_minutes_per_escalation / 60 x supervisor_cost_per_hour
```

### Revenue 1 — Save-gap recovery

```
recoverable_saves   = save_gaps_per_month x precision(save_gap)
                      x (1 - share of gaps in offer-ineligible cancel reasons)
value               = recoverable_saves x save_acceptance_rate x retained_value_per_save
```

- `save_acceptance_rate`: prefer the customer's historical save-desk rate; otherwise the **measured** in-call
  acceptance rate (`saves_accepted / save_offers`) with its sample size, labeled as such. In-call acceptance is not
  the same as retention a month later; if cancellation outcomes exist (signals Step 4), use the post-call outcome.
- `retained_value_per_save`: customer input (for example, monthly value times expected retained months). Never
  derived from the sandbox's placeholder values.
- Offer-ineligible reasons (moves, deaths, fraud, policy) come from the customer.

### Revenue 2 — Unworked buying signals

```
value = unworked_buying_signals_per_month x precision(buying_signal) x upsell_conversion_rate x incremental_value_per_upsell
```

Same sourcing rules for the conversion rate. This lever is typically the least certain; present it last and say so.

## Snowflake cost, measured

From Phase 6 section 10: tokens per 1,000 calls by stage, measured on this corpus, times monthly volume. Convert to
credits using `TOKEN_CREDITS` ratios observed in `CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY` for the same functions and
models. Add warehouse credits for the pipeline from `WAREHOUSE_METERING_HISTORY` over the evaluation window if the
warehouse was dedicated.

Convert credits to currency **only** with the customer's own contracted `credit_price`, and label it. Without it,
present ROI as value per 1,000 credits and let the customer apply their price. Never look up list prices.

For audio builds, note that transcription tokens are fixed by duration (50 per second); the levers to reduce cost are
scope (queues, minimum length) and not transcribing calls the vendor already transcribes.

## The readout

Write `callcenter-value-readout.md` in the working directory. It contains aggregates only: no transcript text, no
customer or agent identifiers, no per-agent scores. Structure:

1. **Header.** Corpus (sandbox or real, window, queues, call count), redaction posture (on, or opted out by whom and
   when), taxonomy and rubric versions.
2. **What we found.** Three to five findings stated as decisions: "Billing calls are 22 percent of volume and
   generate 40 percent of repeats; the top driver is ..." (with real numbers from this corpus). Include the
   disposition-vs-model comparison when it is striking.
3. **Trust.** Redaction leak rate by category, reason macro-F1, QA within-one agreement, save-gap precision and recall,
   lost-call share. One line each.
4. **Value.** A table: lever, formula, inputs with labels, low / expected / high. Then the de-duplicated total, with
   the overlap stated.
5. **Cost.** Measured tokens and credits per month; currency only with the customer's price.
6. **What is not counted.** Levers with missing inputs, shown as formulas with blanks; any queue excluded; signals
   whose precision was not measured on real data.
7. **POC success criteria** (below).

Offer to copy the file to a Snowflake Workspace for sharing.

## POC success criteria

Follow `shared/references/poc-template.md` and make each criterion measurable on the customer's data:

- **Labeled sample.** 100 to 300 real calls labeled by the customer's QA analysts for contact reason, QA criteria
  (with applicability), cancel intent and save offer. Who labels, by when.
- **Accuracy targets set with the customer**, not by this plugin: contact-reason macro-F1, QA within-one agreement per
  criterion, save-gap precision. Record the agreed targets in `thresholds`.
- **Redaction:** leak rate on a customer-reviewed sample of real transcripts at or below the level their privacy owner
  sets, including spoken card numbers if recording is not paused during payment.
- **Cost:** measured tokens and credits per 1,000 calls on their data.
- **One decision changed:** name the owner and the decision (for example, "the billing team rewrites the late-fee
  policy explanation and we measure repeat rate on billing calls for four weeks").

## Guardrails

- No benchmark, peer comparison, or "typical contact center" figure appears in the readout unless the customer
  supplied it.
- No per-agent ranking. Agent-level outputs are coaching tools governed by the customer's QA process.
- Sandbox numbers are labeled synthetic everywhere they appear, and the value table is not computed from sandbox
  volumes at all — on the sandbox, show the formulas with the customer's inputs and a placeholder volume column
  marked "to be measured on real calls".

Then `phases.readout: done`.
