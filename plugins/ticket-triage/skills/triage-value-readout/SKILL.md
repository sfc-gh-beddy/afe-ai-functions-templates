---
name: triage-value-readout
description: "Turn measured triage accuracy into an OpEx value range and POC success criteria, using only customer-supplied unit economics. Applies the shared value model to four non-overlapping levers in a fixed order: deflection (contacts avoided), dispatcher touch removed on auto-routable tickets, reassignments avoided versus the measured current-state first-touch baseline, and known-issue and duplicate handling time. Uses measured precision with Wilson intervals for the low and high bounds, keeps MTTR as an operational metric unless the customer prices delay, computes monthly credits from measured credits per 1K tickets for the customer to apply their own rate, marks every assumption, and produces a one-page readout and a 2-week POC plan. Phase 9 of the ticket-triage build. Triggers: business case, ROI, value readout, what is this worth, savings estimate, POC criteria, success criteria."
parent_skill: ticket-triage
---

# Value readout

This is the last phase and it depends on every earlier one: the readout may only use accuracy figures that
phase 7 measured and unit economics the customer supplied. Read `shared/references/value-model.md` (repo root)
and `shared/references/poc-template.md` first; this skill applies them to triage.

## Rules that are not negotiable

- **Customer inputs only.** Every unit-economics number comes from the customer and is stored in
  `value_inputs` with a `source`. No industry benchmarks, no figures from other engagements, no "typical" handle
  times. If an input is missing, the lever that needs it is reported as *not quantified* with the input that
  would quantify it.
- **Measured accuracy only.** Precision, recall and baseline figures come from `EVAL_EXPERIMENT_SUMMARY` and
  the phase 7 views for the accepted run, on a named truth table. Sandbox accuracy describes the sandbox; say
  explicitly when a figure comes from synthetic data and do not present it as a forecast for the customer's
  tickets.
- **No double counting.** A deflected ticket never reaches a dispatcher, so it cannot also save dispatch time.
  Levers are applied to a shrinking ticket population in a fixed order (below).
- **Credits, not currency, for Snowflake cost.** Report monthly credits from measured credits per 1K tickets;
  the customer applies their own contract rate. Do not look up or assume a price.
- **A range, not a point.** Low / expected / high, with the source of the spread stated.

## Step 1 — Collect inputs

Ask with `ask_user_question`, one lever at a time. Record each with its source in `triage-project.yml`.

| Input | Used by | Notes |
|---|---|---|
| Monthly ticket volume (in scope) | all levers | the population the pipeline would see; exclude channels it will not see |
| Loaded cost per agent hour | all labour levers | the customer's figure; may differ by tier — ask for tier 1 and specialist separately |
| Dispatcher / triage minutes per ticket | dispatch lever | time a person spends reading and assigning a new ticket |
| Minutes of work per reassignment | reassignment lever | handling cost of a bounce: re-reading, re-assigning, context loss |
| Hours of delay per reassignment | MTTR metric | elapsed time a bounce adds; an operational metric unless delay is priced |
| Cost per contact avoided | deflection lever | fully loaded cost of a contact that never needed an agent |
| Self-service adoption rate (range) | deflection lever | share of requesters who would use a suggested article instead of waiting; the customer's estimate or a range they choose, labelled as an assumption |
| Minutes saved per known-issue link | known-issue lever | time not spent diagnosing an already-documented issue |
| Minutes per duplicate handled independently | duplicate lever | time an agent spends on a duplicate before realising it is one |
| Auto-route precision bar | dispatch lever | the precision at which the customer would let a confidence band assign without review |
| Cost of an hour of delay by priority (optional) | MTTR in money | only if the customer prices SLA breach or downtime |

## Step 2 — Pull the measured figures

```sql
-- Accepted run summary.
SELECT *
FROM <db>.<eval_schema>.EVAL_EXPERIMENT_SUMMARY
WHERE run_id = '<accepted_run_id>';

-- Current-state baseline versus pipeline, on the same scored tickets.
SELECT * FROM <db>.<eval_schema>.EVAL_BASELINE;

-- Auto-routable share: tickets in bands whose measured queue precision clears the customer's bar.
SELECT bucket AS confidence_band, tickets, queue_precision
FROM <db>.<eval_schema>.EVAL_RELIABILITY
WHERE signal = 'band';

-- Deflection precision and candidate share.
SELECT d.*, DIV0(d.flagged, s.scored_tickets) AS candidate_share
FROM <db>.<eval_schema>.EVAL_DEFLECTION d
CROSS JOIN (SELECT scored_tickets FROM <db>.<eval_schema>.EVAL_EXPERIMENT_SUMMARY
            WHERE run_id = '<accepted_run_id>') s;

-- Link volumes as shares of scored tickets.
SELECT DIV0(COUNT_IF(known_issue_id IS NOT NULL), COUNT(*))  AS known_issue_share,
       DIV0(COUNT_IF(parent_ticket_id IS NOT NULL), COUNT(*)) AS duplicate_share
FROM <db>.<eval_schema>.EVAL_BASE;
```

### Uncertainty from the sample, not from optimism

Use a Wilson score interval on each measured proportion for the low and high bounds — it behaves sensibly at
small counts, which sandbox and holdout sets often are:

```sql
-- Wilson 95% interval for k successes out of n.
WITH x AS (SELECT :k::FLOAT AS k, :n::FLOAT AS n, 1.96::FLOAT AS z)
SELECT k / n AS point,
       (k / n + z*z / (2*n) - z * SQRT((k / n) * (1 - k / n) / n + z*z / (4*n*n))) / (1 + z*z / n) AS low,
       (k / n + z*z / (2*n) + z * SQRT((k / n) * (1 - k / n) / n + z*z / (4*n*n))) / (1 + z*z / n) AS high
FROM x;
```

Apply it to deflection precision (`k = tp`, `n = flagged`), pipeline queue accuracy (`pipeline_queue_accuracy`), the current baseline,
and the auto-routable band's precision. Combine with the low and high ends of any input the customer gave as a
range. State both sources of spread.

## Step 3 — Apply the levers in order

Let `V` be monthly in-scope volume and `C` the loaded cost per hour (use the tier the lever affects).

**1. Deflection (contacts avoided).** Applied first; deflected tickets leave the population.

```
deflected      = V x candidate_share x deflection_precision x adoption_rate
value_deflect  = deflected x cost_per_contact_avoided
remaining      = V - deflected
```

Only the *precise* share counts (false positives are not deflections; they are a requester who comes back), and
only the share requesters actually adopt. If the customer's intended use is agent assist rather than
self-service, there is no deflection value — the value moves to MTTR and handling time, and the readout says so.

**2. Dispatcher touch removed.** Only for tickets in confidence bands whose measured precision clears the
customer's auto-route bar; everything else still gets a human look.

```
auto_routed    = remaining x share_in_qualifying_bands
value_dispatch = auto_routed x dispatcher_minutes / 60 x C
```

If no band clears the bar, the value is zero and the readout says the pipeline is currently a dispatcher
assist, not a replacement — with the precision it would need.

**3. Reassignments avoided.** The improvement over the current process, from measured first-touch accuracy on
the same tickets.

```
misroutes_now   = remaining x (1 - current_first_touch_accuracy)
misroutes_ai    = remaining x (1 - pipeline_queue_accuracy)
avoided         = max(0, misroutes_now - misroutes_ai) x avg_reassignments_per_misroute
value_reassign  = avoided x minutes_per_reassignment / 60 x C
```

`avg_reassignments_per_misroute` comes from the customer's data (mean `reassignment_count` on reassigned tickets
from preflight), not from an assumption. If the pipeline is *worse* than the current process for some queue,
show that queue's negative contribution rather than flooring it silently.

**4. Known-issue and duplicate handling.**

```
value_known = remaining x known_issue_share x precision_ki x minutes_saved_per_ki / 60 x C
value_dups  = remaining x duplicate_share   x duplicate_pair_precision   x minutes_per_duplicate / 60 x C
```

Use pairwise duplicate precision as the precision term; it is the closest measured analogue of "this link was
right".

**MTTR.** Report as an operational metric: `avoided x hours_of_delay_per_reassignment` hours of ticket waiting
removed per month, and by priority where the matrix allows. Convert to money **only** if the customer supplies a
cost of delay; otherwise it stays in hours, which is often the more persuasive number for a service-desk
audience anyway.

**Snowflake consumption.**

```
monthly_credits = V / 1000 x credits_per_1k_tickets      (from EVAL_COST for the accepted run)
```

Add Cortex Search serving and refresh, which are not per-ticket: report them from the service's usage over the
evaluation period and scale by time, separately labelled. The customer applies their credit rate; ROI is
`total value / (monthly_credits x their rate + search cost)`, computed by them or with their rate.

## Step 4 — The readout

One page, in this order. Write it to the session, and to a file only if the user asks; it contains aggregates
and customer inputs, never ticket text.

1. **The decision this changes.** One sentence, agreed with the business owner — for example, "first-line
   dispatch for the top five categories moves from manual to AI-assigned with spot checks".
2. **What was measured, on what.** Truth source and size; macro-F1 per queue with the worst queue; priority
   P1/P2 recall; deflection precision; silent-loss counts; whether figures are sandbox or customer holdout.
3. **Value range.** A table: lever, formula, inputs (with source), low / expected / high, and what is not
   quantified and why.
4. **Operational metrics.** Hours of delay removed, reassignments avoided, share auto-routable, share deflectable.
5. **Consumption.** Credits per 1K tickets by stage, monthly credits, search service cost, and what the cost
   levers saved on this corpus.
6. **Risks and what would change the numbers.** Low-support queues; historical-label noise; taxonomy changes;
   deflection adoption is an assumption until measured.
7. **Next step.** The POC below, or production if the POC is done.

## Step 5 — POC success criteria

Apply `shared/references/poc-template.md`. For triage, propose — and agree targets with the customer; never set
the numbers yourself:

| Criterion | Measured by | Target |
|---|---|---|
| Routing quality | macro-F1 per queue on a customer-labelled holdout of N tickets, plus minimum recall on named critical queues | set with customer |
| Priority safety | P1/P2 recall and under-prioritization count on the holdout | set with customer |
| Deflection precision at the intended use | `EVAL_DEFLECTION` precision with Wilson interval | set with customer, by use (assist / suggest / auto) |
| Silent loss | function errors, gate nulls, uncited suggestions | zero uncited; errors below an agreed count |
| Cost | credits per 1K tickets per stage | within an agreed envelope |
| Decision changed | the business owner names one process change they would make on this output | yes / no |

A typical shape: week 1 — preflight, taxonomy with the SME, sandbox proof, holdout labelling on 1-5K real
tickets; week 2 — real-data run, evaluation on the holdout, incremental pipeline on a test feed, semantic view
and agent, readout.

Then `phases.readout: done`.
