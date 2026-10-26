---
name: leakage-value-readout
description: "Phase 7 of the spend-and-contract-leakage build. Turns evaluated findings into a value readout and POC criteria using shared/references/value-model.md and customer-supplied inputs only: recoverable overcharge within the audit window times the customer's recovery rate (OpEx), spend under management times the customer's savings rate (OpEx), renewal exposure times the customer's renegotiation assumption (OpEx), CapEx equipment variance (CapEx), contract abstraction labor avoided (OpEx manual processing), and the measured AI Functions credit cost, giving low / expected / high ranges and ROI per lever without ever summing impact kinds or currencies. Produces the readout document and two-week POC success criteria. Triggers: what is this worth, business case, ROI, value readout, procurement savings, CFO summary, POC criteria, success criteria."
parent_skill: spend-and-contract-leakage
---

# Value readout

The readout converts findings into a business case. It is where the play is most often discredited,
so its rules are strict:

- **Customer inputs only.** Every rate, price, hour and percentage in a formula comes from the
  customer and is labeled with who supplied it. Nothing from this plugin, its sandbox, or general
  industry figures is used as a customer number. If an input is missing, the lever is shown as
  "not valued — needs <input>", never filled with a plausible default.
- **Measured accuracy travels with the value.** Every lever states the precision measured in Phase 5
  for the finding types it rests on, and on what sample.
- **Impact kinds and currencies are never added** (rules 12, 13). The readout has one line per lever
  per currency. If the customer wants a single figure, it is a sum of *valued levers* in one currency
  at customer-supplied conversion rates, with each component shown.
- **Sandbox results are not a business case.** A readout on sandbox data demonstrates the method and
  the accuracy harness; its dollar figures are synthetic and must be labeled so on every page.

Prerequisites: `phases.eval: done`. For a customer readout, findings must come from customer data
with a reviewed sample (see "Without an answer key" in `evaluate-leakage-accuracy`).

Read `shared/references/value-model.md` and `shared/references/poc-template.md` from the repository
root before writing.

## Inputs to ask for

Ask once with `ask_user_question`, record answers in `value` in the project file with the source
("CFO office", "procurement lead", "AP manager"), and leave anything not given absent.

| Input | Used by | Notes |
|---|---|---|
| `recovery_rate_pct` (low / expected / high) | recoverable overcharge | share of confirmed overcharge the customer expects suppliers to credit; their past recovery experience is the right source |
| `audit_window_months` per supplier, if not in the contract | recoverable overcharge | the contract term wins where extracted |
| `savings_rate_on_managed_spend_pct` (low / expected / high) | spend under management | what bringing spend under a negotiated contract typically saves *this* customer |
| `renegotiation_savings_pct` and `share_of_renewals_acted_on_pct` | commitment exposure | both required; exposure is not savings until someone negotiates |
| `capex_spend_in_scope` | CapEx | annual equipment spend under contracts like those checked |
| `analyst_hours_per_contract_abstraction`, `loaded_cost_per_hour`, `contracts_per_year` | manual processing | only if the customer abstracts contracts by hand today |
| `credit_price` | Snowflake cost | the customer's contracted price per AI credit; otherwise report credits only |
| `fx_rates` and rate date | single-currency view | only if they ask for one |

## Levers and formulas

All figures per currency. Let `P(type)` be the measured precision for a finding type from Phase 5 (or
the reviewed sample), and `C` the share of spend price-checked from reconcile V1.

### 1. Recoverable overcharge — OpEx (procurement savings)

```
identified_recoverable  = SUM(impact_amount) WHERE impact_kind = 'RECOVERABLE_OVERCHARGE'
                                             AND lever = 'OPEX'
                                             AND within_audit_window IS NOT FALSE
expected_confirmed      = identified_recoverable x P(type), per finding type
one_time_recovery       = expected_confirmed x recovery_rate_pct          (low / expected / high)
```

Report outside-window overcharge separately as negotiating evidence, not recovery. Report whether
credit memos were netted.

**Run-rate.** If the same overcharge recurs monthly (a rate never corrected), the forward value of
correcting it is the latest month's confirmed overcharge times the remaining months of the term —
from the term period, not assumed to be twelve. Show it as a separate line; it is avoidance, not
recovery.

### 2. Spend under management — OpEx

```
unmanaged_spend   = SUM(impact_amount) WHERE impact_kind = 'SPEND_UNDER_MANAGEMENT'
annualized        = unmanaged_spend x 12 / months_of_spend_analyzed    (state the months)
value             = annualized x savings_rate_on_managed_spend_pct     (low / expected / high)
```

Split off-contract from expired-contract spend: expired spend usually has a supplier willing to
re-paper quickly; off-contract spend may need sourcing. State both.

### 3. Commitment exposure — OpEx

```
exposure          = SUM(impact_amount) WHERE impact_kind = 'COMMITMENT_EXPOSURE'
value             = exposure x share_of_renewals_acted_on_pct x renegotiation_savings_pct
```

List each renewal with its deadline. `AUTO_RENEWAL_NOTICE_MISSED` items have the least leverage and
the most urgency; say so rather than valuing them the same as upcoming ones. Without both customer
inputs this lever is reported as exposure only, unvalued.

### 4. CapEx — equipment bought above the negotiated price

```
capex_recoverable = SUM(impact_amount) WHERE impact_kind = 'RECOVERABLE_OVERCHARGE' AND lever = 'CAPEX'
observed_rate     = capex_recoverable / price-checked CapEx spend      (from this corpus; state n)
forward_value     = capex_spend_in_scope x observed_rate x P(RATE_VARIANCE)
```

`observed_rate` is measured on the customer's own data and must carry its sample size; with a handful
of CapEx lines it is an illustration, not an estimate, and the readout says so. Where the PO already
carried the wrong price (as in the sandbox Litware case), name the control gap: the fix is checking
the PO against the contract before approval, which has value beyond recovery.

### 5. Contract abstraction labor — OpEx (manual processing)

Only if the customer abstracts contracts by hand today.

```
automated_share   = governing documents with all scored terms EXTRACTED and verified / governing documents
value             = contracts_per_year x automated_share x analyst_hours_per_contract_abstraction x loaded_cost_per_hour
```

`automated_share` comes from this run's term statuses, not from the sandbox. Terms still need review
on a sample; say what review effort the customer should keep.

### 6. Snowflake cost and ROI

From `EVAL_COST` and `PIPELINE_RUNS`:

```
annual_credits    = (credits per 1K contracts x contracts parsed per year / 1000)
                  + (reconcile credits per run x runs per year)
annual_cost       = annual_credits x credit_price                       (only if supplied)
ROI per lever     = lever value / annual_cost                            (same currency only)
```

Credits per 1K contracts must come from a measured run on the customer's contracts, not the
sandbox (ten short synthetic documents understate pages per contract). Warehouse credits for the
reconcile SQL are separate from AI credits; include them from `WAREHOUSE_METERING_HISTORY` for the
pipeline warehouse if the customer wants full cost.

## The readout document

Produce it as Markdown in the session (or an HTML report if asked; load `html-authoring` for that).
Do not write findings, prices or contract quotes to a file outside the account; if the user wants a
shareable artifact, put aggregate figures only in it and keep finding-level detail in the agent.

Structure:

1. **What was analyzed.** Contracts by class and parse source; spend in scope by currency and months;
   price-checked share `C`; as-of date; experiment and prompt version.
2. **How accurate it is.** Phase 5 precision and recall per finding type, term and rate accuracy,
   dollar reconciliation — on the sandbox key, and on the customer's reviewed sample with its size.
3. **What was found.** One table per impact kind, per currency: count, amount, top suppliers. No
   grand total across kinds.
4. **What it is worth.** One row per lever per currency: low / expected / high, the formula, each
   input with its source, and the precision it rests on. Unvalued levers listed with the missing input.
5. **What it costs.** Credits measured; currency only at the customer's credit price.
6. **What would change.** The specific decisions the output supports: supplier claims to file (with
   audit-window dates), renewals to act on before their deadlines (dated), suppliers to bring under
   contract, PO controls to add for CapEx.
7. **Caveats.** Credits netted or not; service date or invoice date basis; currencies not converted;
   interpretations flagged for legal (retroactive tiers, business-day notice clauses, unpriced
   renewals).

## POC success criteria

Following `shared/references/poc-template.md`, propose criteria for the customer to set, not
targets from this plugin:

| Criterion | Measured by | Target |
|---|---|---|
| Term extraction accuracy on a reviewed sample of the customer's contracts | `EVAL_TERM_RESULTS` on the customer key | set with the customer |
| Finding precision per type on a reviewed sample of findings | analyst review in `review_status` | set with the customer |
| Dollar reconciliation of confirmed findings against analyst computation | `EVAL_DOLLAR_RECONCILIATION` analogue | set with the customer |
| Share of spend price-checked | reconcile V1 | set with the customer |
| Cost per 1K contracts and per run | `EVAL_COST`, `PIPELINE_RUNS` | report, then agree a ceiling |
| One decision changed | a supplier claim filed, a renewal acted on before its deadline, or a PO control added | named by the business owner |

Week 1: preflight, a 1-5K line and 20-50 contract sample, the reviewed term sample, first findings
reviewed with procurement. Week 2: the scheduled pipeline, semantic view and agent, and this readout.

Then write `phases.readout: done`.
