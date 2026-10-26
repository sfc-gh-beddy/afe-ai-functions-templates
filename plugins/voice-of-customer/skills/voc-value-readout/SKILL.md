---
name: voc-value-readout
description: "Turn the measured voice-of-customer pipeline into a value readout and POC success criteria, applying shared/references/value-model.md with customer-supplied inputs only. Maps taxonomy levers to formulas for OpEx returns (avoidable returns from addressable product, sizing and information themes, and earlier detection of emerging defects), OpEx support (contacts avoidable from tracking, information and process themes), OpEx analyst time (manual coding of verbatims replaced), revenue retention (customers expressing churn language on pricing or service themes, times customer save rate and value), and revenue product and pricing hypotheses. Every input carries its source; nothing comes from benchmarks or the sandbox. Volumes are adjusted by measured precision, ranges are low, expected and high, Snowflake cost comes from measured credits per 1K items times the customer's volume, and POC criteria follow shared/references/poc-template.md. Phase 9 of the voice-of-customer build."
parent_skill: voice-of-customer
---

# Value readout

This phase converts what the pipeline measured into a business case the customer can defend to
their own finance team. Its single most important rule: **every unit-economics number comes from the
customer**, with a named source, or the line is left as a question. The repository value model says
it directly: use customer-supplied numbers only, mark every assumption, never invent unit economics.

**Prerequisite:** `phases.eval: done`. A readout built on unmeasured theme counts multiplies an
unknown error rate by a business number and presents the product as fact. If evaluation ran only on
the sandbox, say so on the first line of the readout: sandbox accuracy is an upper bound, and the
volumes below must be re-derived from the customer's own labeled sample before the case is final.

Read `shared/references/value-model.md` and `shared/references/poc-template.md` from the repository
root before starting; this skill applies them to this play rather than restating them.

## 1. Agree the decision first

Ask the business owner one question before any arithmetic: *what decision would you make differently
if you had this output every week?* Examples: pull a SKU for a hinge redesign two months earlier;
reverse a subscription change; rewrite a size chart; staff support for a known issue. A readout that
cannot name a decision is a reporting project, and should be presented as one.

Record the answer as the readout's headline and in `value_inputs.decision`.

## 2. Map taxonomy levers to formulas

Each taxonomy node carries a `lever`. Group the measured themes by lever and apply the matching
formula. All inputs in angle brackets come from the customer.

### OpEx: returns avoided by fixing addressable causes

Themes with `lever = OPEX_RETURNS` (defective on arrival, sizing, damaged in transit, product
information accuracy, and emerging defects such as the hinge).

```
avoidable_returns_per_month
  = <returns per month on the affected SKUs>
  x <share of those returns caused by the theme>
  x <expected reduction in those returns after the fix>

value_per_month = avoidable_returns_per_month x <fully loaded cost per return>
```

- **Share caused by the theme** is the weakest input. Prefer the customer's return reason codes joined
  to SKU and period; otherwise use the share of return-intent feedback on that SKU that carries the
  theme, from this pipeline, **adjusted by measured precision** (section 3) and labeled as derived.
- **Fully loaded cost per return**: reverse logistics, inspection, refurbishment or write-off, refund
  processing, and any customer service contact. The customer's finance or operations team owns this.
- **Expected reduction** is the product team's estimate for the specific fix. Give a range.

### OpEx: earlier detection of an emerging defect

The emerging-theme detector is valuable because it is early. Quantify the earliness, not the defect.

```
value_per_incident
  = <weeks earlier than the current detection method>
  x <excess returns per week during a comparable past incident>
  x <fully loaded cost per return>

annual_value = value_per_incident x <comparable incidents per year>
```

- **Weeks earlier** compares the measured detection lag (Phase 8) against how the customer detects
  such issues today (returns reports, warranty claims, escalations). The customer states their current
  lag; never assume it.
- Use one real past incident the customer can describe. If none, leave the line as a question.
- Sandbox lag is evidence the mechanism works, not this customer's lag.

### OpEx: support contacts avoided

Themes with `lever = OPEX_SUPPORT` (tracking, refund delay, response time, confusing policies).

```
avoidable_contacts_per_month
  = <support contacts per month on the theme's reason codes>
  x <expected deflection rate after the fix or content change>

value_per_month = avoidable_contacts_per_month x <average handle time in hours> x <loaded cost per hour>
```

If the customer cannot map support reason codes to themes, use the theme's feedback volume only as a
directional indicator, clearly labeled, and do not convert it to contacts.

### OpEx: manual verbatim coding replaced

Many VoC teams hand-code survey open-ends or review samples today.

```
value_per_month
  = <verbatims coded manually per month>
  x <minutes per verbatim>
  / 60
  x <loaded cost per analyst hour>
  x <share of that work the pipeline replaces>
```

The share replaced is not 100 percent: a human still reviews low-agreement items and owns the
taxonomy. Use the Phase 8 per-label precision to decide which labels can go unreviewed, and let the
customer set the share.

### Revenue: retention

Themes with `lever = REVENUE_RETENTION` or with churn language (the subscription backlash, repeated
delivery failures).

```
value_per_month
  = <customers expressing the theme per month, identifiable to an account>
  x <expected save rate when contacted or when the cause is fixed>
  x <monthly revenue per customer, or margin if the customer prefers>
```

- Only feedback that can be tied to an identifiable customer counts. Anonymous social posts count as
  signal for a pricing decision, not as savable revenue.
- The save rate comes from the customer's own retention history. Without one, present the line as a
  sensitivity table, not a number.
- Avoid double counting with the `churn-signals` play if it is also deployed.

### Revenue: product and pricing decisions

Themes with `lever = REVENUE_PRODUCT` or `REVENUE_PRICING` usually support a decision rather than a
formula: reverse a fee, change a price point, prioritise a feature. Present them as **hypotheses with
the evidence** (measured volume, net sentiment trend, summaries, example ids) and the experiment the
customer would run to size them. Do not attach a revenue figure unless the customer supplies the
model (for example, conversion and traffic for a product-page fix, with their own uplift estimate).

## 3. Adjust for measured accuracy

Theme volumes from the pipeline are estimates. Adjust before multiplying:

```
adjusted_theme_volume = pipeline_theme_volume x precision_for_that_label
```

using the per-label precision from the customer's labeled sample (Phase 8, `EVAL_TOPIC_PER_LABEL`).
Recall below 1 means the true volume is likely higher; do not scale up for it, and say the figure is
conservative for that reason. If only sandbox accuracy exists, apply no adjustment and mark the
volume "unadjusted, accuracy not yet measured on this customer's data".

## 4. Snowflake cost

Use the **measured** cost from Phase 8, section 10, not an estimate:

```
monthly_credits = credits_per_1k_source_items / 1000 x <feedback items per month>
```

Add the one-time cost of the initial backfill (same rate times the historical volume classified).
The customer converts credits to currency at their contracted rate; if they share the rate, it is a
customer input like any other and is labeled as such. Never look up or assume a credit price.

Then: `ROI = annual value / annual Snowflake cost`, computed only from the figures above.

## 5. Ranges, not points

For every line, take low, expected and high values of each customer input (ask for all three, or ask
for a range and use its ends and midpoint). Compute the line at all three. Present the total as a
range. Do not multiply all highs together and call it expected.

## 6. Record inputs

Every input goes into `value_inputs` in `voc-project.yml` with its source:

```yaml
value_inputs:
  decision: "Detect product defects on new SKUs before they show in the monthly returns report"
  returns_per_month_affected_skus: {low: null, expected: null, high: null, source: "ops returns dashboard, owner: <name>", as_of: null}
  cost_per_return: {low: null, expected: null, high: null, source: null, as_of: null}
  current_detection_lag_weeks: {low: null, expected: null, high: null, source: null, as_of: null}
  feedback_items_per_month: {value: null, source: "preflight row counts"}
```

A `null` stays `null` and the readout shows the line as an open question. Never fill one from the
sandbox's `SYNTH_SKU_WEEKLY`, from another deployment, or from an industry figure.

## 7. The readout

One page, in this order:

1. **Decision** this enables, in the business owner's words.
2. **What was measured**: corpus, period, channels; topic and aspect accuracy with the sample it was
   measured on; emerging-theme lag; NULL and error counts.
3. **What it found**: top rising themes with counts, net sentiment trend, one summary each, and the
   owning team.
4. **Value by lever**: a table of lines, each with formula, inputs and their sources, and the
   low/expected/high result. Open questions shown as such.
5. **Cost**: measured credits per 1K items, monthly credits at the customer's volume, backfill.
6. **ROI range**, from the lines above only.
7. **Assumptions and limits**: every input that is an estimate, the accuracy caveat, what the pipeline
   does not do (no ingestion, no automatic replies).
8. **POC criteria** (below).

If the readout is written to a file, load the `html-authoring` skill for HTML. Keep it free of
customer names, verbatims and author identifiers unless the user explicitly asks and the posture from
preflight allows it; examples in a readout use feedback ids and redacted text.

## 8. POC success criteria

Follow `shared/references/poc-template.md`: two weeks, a business owner, measured accuracy, cost per
1K records, and one decision changed. For this play, make each criterion specific and measurable:

| Criterion | Measure | Target |
|---|---|---|
| Topic accuracy on the customer's labeled sample | L1 micro and macro F1, worst-label F1 | set with the customer |
| Aspect sentiment accuracy | aspect claim F1, polarity accuracy, `mixed` recall | set with the customer |
| Drift handling | one governed taxonomy change adopted, with v1/v2 comparison and roll-up agreement | completed |
| Emerging-theme detection | lag on one past incident replayed from history, in weeks, versus current method | set with the customer |
| Failure accounting | error and NULL rate per stage | at or below `thresholds.max_null_rate` |
| Cost | credits per 1K items, measured | reported; customer judges against budget |
| Decision | one named decision the owner would make differently, with the evidence | owner sign-off |

Replaying a real past incident is the strongest emerging-theme test available on customer data: load
the feedback from before and during a known issue, run the detector as if week by week, and report
when it would have fired. It is worth more than any sandbox figure.

Targets come from the customer. Do not propose numeric targets from other deployments.

Then `phases.readout: done`.
