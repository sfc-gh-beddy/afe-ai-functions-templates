---
name: churn-value-readout
description: "Turn churn-signals results into a revenue-retention value range and POC success criteria, using shared/references/value-model.md with customer-supplied inputs only. Computes retained ARR as at-risk ARR reached times incremental save rate, using the measured capture of churners in the actionable bands and the customer's own historical save rate, with low/expected/high ranges, plus the measured Snowflake cost (credits per 1K interactions, converted only with the customer's credit price) and ROI. Includes reason-driven value (churned ARR by text-derived reason versus the CRM picklist), what the numbers do not show, and a one-page narrative. Phase 8 of the churn-signals build. Triggers: churn business case, value of churn signals, retention ROI, POC criteria churn, readout."
parent_skill: churn-signals
---

# Value readout -- revenue retention

Read `shared/references/value-model.md` first. Its rule governs this skill: **customer-supplied
numbers only, every assumption marked, no invented unit economics.** This skill applies the
`Revenue: retention` row -- at-risk ARR x expected save rate -- and makes each term measurable.

## Inputs -- and where each one comes from

| Input | Source | If the customer cannot supply it |
|---|---|---|
| Annual ARR up for renewal | customer finance / CRM | required; stop |
| Historical gross churn rate (ARR) | customer, or measured from `SYN_RENEWAL_OUTCOMES`-equivalent history | use the measured rate from their renewal table and say so |
| Share of churned ARR the actionable bands capture | **measured** in Phase 7: cumulative capture at the HIGH (and WATCH) cutoff on TEST | not optional -- this is what the build measures |
| Save rate when a CSM intervenes in time | customer: historical outcomes of save plays | ask for a range; if none exists, present the formula with save rate as an open variable, never a guessed value |
| Share of those saves that would have been missed without the list | customer judgment; the CS leader's estimate of how many at-risk accounts surface today | ask; default to presenting the range 0-100% explicitly rather than assuming |
| CS capacity per quarter | customer | bounds the HIGH band (Phase 7 threshold) |
| Credit price | customer contract | present cost in credits only |

Write each supplied value into `churn-project.yml` under a `value_inputs:` key with who supplied it
and the date. Mark every assumption `assumed: true`.

## The formula

```
churned_arr_expected    = arr_up_for_renewal * gross_churn_rate
arr_reached             = churned_arr_expected * capture_at_actionable_bands      # measured
arr_saved               = arr_reached * save_rate                                  # customer
incremental_arr_saved   = arr_saved * share_not_already_caught                     # customer
annual_snowflake_cost   = (interactions_per_year / 1000) * credits_per_1k * credit_price
                          + scoring and training compute (credits, measured)
roi                     = incremental_arr_saved / annual_snowflake_cost
```

Build low / expected / high by varying only the customer-supplied terms across the range they gave,
and the measured capture across its bootstrap interval if available (the TEST capture at a band is a
proportion of a small number of churners -- show it with its count, for example "14 of 21").

Two rules that keep the number defensible:

- **Use capture, not probability-weighted ARR.** `SUM(arr_at_risk_expected)` is a forecast only if the
  model is calibrated (Phase 7). Capture at a band is an observed rate on held-out renewals.
- **Use the sandbox for mechanics only.** Never put a sandbox capture rate into a customer's value
  range. Until the model is trained and evaluated on their renewal history, the capture term is
  unknown, and the readout says "to be measured in the POC".

## Reason-driven value

The second, often larger, conversation is not the save list but the **reasons**:

```sql
SELECT * FROM CHURNED_ARR_BY_REASON;
```

ARR is attributed once per account (best-practices 26). Put it next to the CRM picklist comparison from
`score-at-risk-accounts` Step 4: "N% of churned ARR was coded 'Other' in CRM; the text attributes it to
..." This informs product and pricing decisions whose value the customer, not this plugin, can size.
Present it as evidence, not as a dollar figure.

## What the numbers do not show -- say this in the readout

- **Silent churners.** Churn with no text signal is reachable only through usage; text uplift is
  measured on accounts that wrote something.
- **Save rate is the customer's.** The build measures who to call and why; whether the call saves the
  account depends on the play, the offer and the people.
- **Correlation, not causation.** A reason associated with churn is a reason customers cite, not proof
  that fixing it retains them.
- **Data coverage.** The account join rate and the share of accounts with text in the lookback window,
  both from preflight and features, bound what the model can see.

## POC success criteria

Extend `shared/references/poc-template.md` with play-specific, measurable criteria. Set targets **with
the customer**; leave them blank rather than proposing numbers.

| Criterion | Measured by | Target |
|---|---|---|
| Reason precision and recall per reason on a labeled sample of their interactions | `evaluate-churn-accuracy`, "Labeling real data" | set with customer |
| False-flag rate on routine and look-alike interactions | same sample, unflagged-stratum review | set with customer |
| Evidence grounding rate | quality log | set with customer |
| Leakage audit clean | `02_leakage_audit.sql` all zero | must pass; not negotiable |
| AUC and top-band capture on held-out renewals, combined versus usage-only | Phase 7, with intervals | set with customer |
| Credits per 1K interactions | `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` by query tag | set with customer |
| One decision changed | the CS leader names an account action or a product/pricing discussion driven by the output | qualitative, named |

Two-week shape, following the shared template:

- **Week 1:** preflight, taxonomy workshop with the CS owner, extraction on a 1-5K sample of real
  interactions, labeled-sample review of reasons and false flags.
- **Week 2:** features and leakage audit on their renewal history, model with usage-only comparison,
  scoring of the next quarter's renewals, semantic view and agent, readout with the value range above.

## The one-page narrative

Structure, filled only with measured or customer-supplied numbers:

1. **The problem in their words** -- churned ARR last year, the picklist "Other" share.
2. **What their customers said** -- top reasons by churned ARR, two or three cited quotes (redacted if
   required).
3. **Who is at risk now** -- HIGH/WATCH counts and ARR for next quarter's renewals, with `USAGE_ONLY`
   rows called out.
4. **How good the ranking is** -- capture at the HIGH band on held-out renewals, usage-only versus
   combined, with counts.
5. **Value range** -- low / expected / high from the formula, every input labeled with its source.
6. **Cost** -- credits per 1K interactions and annual credits; currency only with their price.
7. **POC criteria** -- the table above with their targets.

Record `phases.readout: done`. Do not write the narrative or any customer numbers to a local file
unless the user asks for a file; if they do, it is a customer document and stays in their workspace.
