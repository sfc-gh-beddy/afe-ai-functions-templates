---
name: intake-value-readout
description: "Final phase of the document-intake build: turn measured pipeline results into a defensible value narrative and POC success criteria, using shared/references/value-model.md with customer-supplied inputs only. Quantifies the OpEx lever (manual keying and review labor avoided, net of exception review and STP audit labor) and working-capital levers (early-payment discount capture, late-fee avoidance, cycle time from receipt to decision, duplicate-payment prevention) as low / expected / high ranges driven by measured STP and false-STP intervals, against measured credits per 1K pages times the customer's own credit price. Refuses to invent unit economics or benchmarks, marks every assumption, and writes the readout plus a two-week POC plan with measurable criteria. Use for business case, ROI, value readout, POC criteria, or 'what is this worth'."
parent_skill: document-intake
---

# Value readout and POC criteria

The readout converts four measured numbers — STP rate, false-STP rate, exception mix, and credits per
1K pages — into money, using the customer's own unit economics. Nothing in this file supplies a unit
cost, a minutes-per-document figure, a discount rate, or an industry benchmark. If an input is missing,
the corresponding line is omitted and listed as "needs input", never filled.

Read `shared/references/value-model.md` (the repo-level model) and `shared/references/poc-template.md`
before starting. This skill specializes them for document intake.

## Inputs

### Measured by the pipeline (from Phase 5 and production monitoring)

| Input | Source | Notes |
|---|---|---|
| `stp_rate` with 95% interval | `evaluate-intake-accuracy` headline table | **from the keyed real sample** if one exists; sandbox values are labelled "wiring test, not a forecast" |
| `false_stp_rate` with interval | same | the risk side; drives the audit-labor line |
| exception mix by `primary_reason` | `EXCEPTIONS_QUEUE` | determines review effort per exception |
| fields failing per exception | `EXCEPTIONS_QUEUE.reason_count` | a reviewer fixing two fields is faster than keying eleven |
| `credits_per_1k_pages` | Phase 5 cost query | AI function credits only; warehouse separate |
| `pages_per_document` | preflight sample of the customer's stage | not the rendered corpus's |
| decision latency | `DOCUMENT_DECISION.decided_at - DOC_CLASSIFICATION.received_at` | minutes or hours, versus the customer's current days |
| duplicate and bank-change flag rates | `INTAKE_DAILY_HEALTH` | counts only; their value needs customer history |

### Supplied by the customer — every one with a named source and date

Record each under `value_inputs` in `intake-project.yml` as `{value, source, as_of}`. Ask in one
structured form (`ask_user_question`), and accept "unknown" as an answer.

| Input | Ask for | Used in |
|---|---|---|
| `docs_per_month` | documents received per month, per in-scope type | every line |
| `minutes_per_doc_manual` | median handling time today per document (keying, checking, matching) | OpEx |
| `minutes_per_exception` | expected time to resolve one queued exception with fields pre-filled | OpEx |
| `minutes_per_audit` | time to verify one sampled auto-approved document | OpEx (cost) |
| `audit_sample_per_month` | how many approved documents they will audit | OpEx (cost) |
| `loaded_cost_per_hour` | fully loaded hourly cost of the people doing this work | OpEx |
| `invoices_with_discount_terms_pct` | share of invoices offering early-pay discount | working capital |
| `avg_invoice_amount` | average invoice value, in one currency | working capital |
| `avg_discount_pct` | average discount offered (for example 2 in "2/10 NET 30") | working capital |
| `discount_capture_rate_now` | share of available discounts captured today | working capital |
| `discount_capture_rate_target` | share they believe they could capture if invoices were approved within the window | working capital |
| `late_payments_per_month`, `avg_late_fee` | late-payment events and their average fee | working capital |
| `share_attributable_to_intake_delay` | share of late payments caused by slow intake rather than cash or approval policy | working capital |
| `duplicate_payments_per_year`, `avg_duplicate_amount`, `duplicate_recovery_rate` | historical duplicate payments, and the share recovered after the fact | risk |
| `current_cycle_days` | median days from receipt to approval today | narrative |
| `credit_price` | their contracted price per credit | Snowflake cost |
| `incumbent_cost_per_month` | current OCR/IDP software or BPO cost, if any | optional offset |

**Never** substitute a number from another engagement, a published survey, a vendor benchmark, or
"typical" AP metrics — even if the user asks for a placeholder. Offer instead to show the formula with
the input blank, or to run the readout with the user's own estimate explicitly labelled as their
estimate.

## The formulas

All monthly. `D` = `docs_per_month`. Ranges use the measured interval endpoints for STP (`stp_low`,
`stp`, `stp_high`) — the uncertainty in the value comes from the measurement, not from adjectives.

### OpEx — manual processing labor

```
hours_today       = D * minutes_per_doc_manual / 60
hours_with_intake = D * (1 - stp)  * minutes_per_exception / 60      -- exceptions still need a person
                  + audit_sample_per_month * minutes_per_audit / 60   -- verifying straight-through work
hours_saved       = hours_today - hours_with_intake
opex_value        = hours_saved * loaded_cost_per_hour
```

Compute at `stp_low`, `stp`, `stp_high` for the low / expected / high range. Rejected documents are
excluded from `D` if the customer's current process also discards them without handling; ask.

Two honesty notes for the narrative:

- `minutes_per_exception` must be the customer's estimate **for a pre-filled exception** (one or two
  failing fields shown with the document), not the full manual time. If they cannot estimate it, use
  `minutes_per_doc_manual` for exceptions — conservative — and say so.
- Hours saved is capacity, not necessarily headcount. Let the customer say whether it becomes reduced
  overtime, absorbed growth, reduced BPO spend, or reassignment. Do not write "FTE reduction" unless they
  do.

### Working capital — early-payment discount capture

Only if the customer offers the inputs. Discounts are lost mostly because invoices are not approved
inside the window; the pipeline shortens time-to-decision for straight-through invoices to minutes.

```
discountable_amount   = D_invoices * invoices_with_discount_terms_pct * avg_invoice_amount
discount_value        = discountable_amount * avg_discount_pct
                        * (discount_capture_rate_target - discount_capture_rate_now)
```

The capture-rate uplift is the customer's judgment, and STP bounds it: an invoice that goes to
exceptions may still miss the window. Show the line with the customer's target, and a second line
capping the uplift at `stp` (only straight-through invoices are assumed to make the window) — use the
lower of the two as "expected".

### Working capital — late-payment fees avoided

```
late_fee_value = late_payments_per_month * avg_late_fee * share_attributable_to_intake_delay
```

`share_attributable_to_intake_delay` is a customer input. Late payments also come from cash management
and approval-chain delays this pipeline does not touch. If they cannot attribute, show the line as
"not quantified" rather than assuming all late fees are intake-driven.

### Risk — duplicate payments prevented

```
duplicate_value_per_month = duplicate_payments_per_year / 12 * avg_duplicate_amount
                            * (1 - duplicate_recovery_rate)
```

This is the unrecovered amount the duplicate rule would have stopped. Measured flag counts from
production validate the order of magnitude; they do not replace the customer's history. Payment
redirection (bank-change) fraud is **not** quantified — losses are rare, large, and the customer's own
history is the only legitimate basis. Present it as a control, with the count of flags raised.

### Snowflake cost

```
pages_per_month     = D * pages_per_document
credits_per_month   = pages_per_month / 1000 * credits_per_1k_pages        -- AI function credits
                    + warehouse credits per month (measured separately, if all-in is requested)
snowflake_cost      = credits_per_month * credit_price                     -- customer's price only
```

If `credit_price` is not provided, present cost in credits and value in currency, side by side, and do
not compute ROI. Never look up a list price.

### Summary

```
net_value_month = opex_value + discount_value + late_fee_value + duplicate_value_per_month
                  - snowflake_cost - (optional) added review tooling cost
                  + (optional) incumbent_cost_per_month avoided
roi_multiple    = (net_value_month + snowflake_cost) / snowflake_cost
```

Present low / expected / high for every line that has a range, and list every line omitted for missing
input.

## Write the readout

Use `ask_user_question` to confirm the audience (finance, AP leadership, claims operations) — it
changes the emphasis, not the numbers. Produce a one-page narrative in this order:

1. **What we measured.** Documents, pages, types; STP and false-STP with intervals; which ground truth
   (keyed real sample, or sandbox only — and if sandbox only, say in the first sentence that the money
   is indicative until the keyed sample is done).
2. **What it is worth.** The table of lines, low / expected / high, with each input's source.
3. **What it costs.** Credits per 1K pages measured, credits per month at their volume, cost at their
   price if given.
4. **What it protects.** Bank-change and duplicate controls, with counts flagged; what would have
   happened without them is the customer's call to state.
5. **What changes for the team.** Exceptions queue with pre-filled fields and reasons; time from receipt
   to decision; audit sampling as the new control.
6. **What we do not know yet.** Real-document accuracy if not yet keyed; handwriting; new vendor
   templates; volume seasonality.

Every number carries its source in a footnote-style tag: `[measured: eval exp_003]`,
`[customer: AP manager, 2026-10-20]`, `[assumption: conservative, exceptions at full manual time]`.

Write the readout to a file only if the user asks, and include no document content or extracted values
in it — aggregates only.

## POC success criteria

Specialize `shared/references/poc-template.md`. Agree these **with the customer before the POC
starts**, and record them in `intake-project.yml`:

| Criterion | Measured by | Threshold |
|---|---|---|
| Posting-field accuracy (normalized) on a keyed sample of N real documents per type | `evaluate-intake-accuracy` field table | customer-set |
| False-STP rate at the chosen thresholds, with 95% interval upper bound | headline table + Wilson interval | customer-set (the go-live gate) |
| STP rate at those thresholds | headline table | customer-set |
| Zero missed exceptions on the control cases (bank change, duplicate, coverage) | hard-case scorecard, plus customer-supplied known-bad documents if they have them | zero, not negotiable |
| Credits per 1K pages on the customer's documents | Phase 5 cost query | reported, compared with the value per 1K documents |
| Decision latency from receipt | `DOCUMENT_DECISION` timestamps | customer-set |
| One business decision that changes | narrative | named by the business owner (for example: "stop keying invoices from the portal channel") |

Plan:

- **Week 1:** preflight; sandbox and rendered corpus wired end to end; customer keys the real sample in
  parallel (this is the critical path — start it on day one); classify and extract a 500–1,000 document
  slice of their stage; review exceptions with an AP or claims owner.
- **Week 2:** evaluation on the keyed sample; threshold choice by the owner; incremental pipeline and
  semantic view; agent demo in CoWork; this readout.

If the keyed sample is not available by mid-week 2, the readout says so and presents sandbox numbers
as wiring evidence only. Do not let a sandbox STP rate stand in for a production forecast in any slide.

Set `phases.readout: done`.
