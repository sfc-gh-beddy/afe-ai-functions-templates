---
name: evaluate-leakage-accuracy
description: "Phase 5 of the spend-and-contract-leakage build. Measures the pipeline against ground truth before anyone sees a dollar figure: document classification, family and duplicate accuracy; header-term extraction accuracy per term with failure modes (wrong value, missed, invented, failed, unverified); effective-rate accuracy (price, window, unit, currency, missing, spurious); leakage-finding precision, recall and F1 overall and per finding type, with type confusions and distractor hits reported separately; dollar-impact reconciliation per impact kind and currency against literal expected totals; parse and extraction failure accounting; and measured cost per 1K documents from CORTEX_AI_FUNCTIONS_USAGE_HISTORY by query tag. Also covers labeling a reviewed sample on customer data and comparing experiments. Triggers: how accurate is it, precision and recall, does the dollar figure tie, term extraction accuracy, what does this cost per contract, compare runs, did the prompt change help, evaluation."
parent_skill: spend-and-contract-leakage
---

# Evaluate accuracy, dollars and cost

A leakage total is a claim that a supplier owes money or that a renewal is at risk. This phase decides
whether that claim is safe to make, by measuring three things separately because they fail
separately:

1. **Did it read the contracts correctly?** Document, term and rate accuracy.
2. **Did it find the right leakage?** Finding precision and recall per type.
3. **Does the money tie?** Dollar reconciliation per impact kind and currency.

Then what it cost, measured rather than estimated.

Prerequisites: `phases.reconcile: done` for the `run_id` being evaluated. On the sandbox,
`phases.seed: done` and `eval.key_schema` set. On customer data, see "Without an answer key" below.

## What gets created

All in `{{EVAL_SCHEMA}}`, accumulated by `run_id`: `EVAL_DOC_RESULTS`, `EVAL_TERM_RESULTS`,
`EVAL_RATE_RESULTS`, `EVAL_FINDING_MATCHES`, `EVAL_DOLLAR_RECONCILIATION`, `EVAL_COST`,
`EVAL_SUMMARY`.

SQL: `sql/01_evaluate.sql`. It is the only file in the plugin that reads the answer keys
(rule 21). No AI functions run; cost is zero inference.

## How matching works

| Level | Key | Match on | Outcomes |
|---|---|---|---|
| Document | `SYNTH_DOCUMENT_KEY` (10) | `document_id` | class, family, duplicate each correct or not |
| Term | `SYNTH_TERM_KEY` (77) | family, term name | `CORRECT`, `WRONG_VALUE`, `MISSED`, `INVENTED`, `FAILED`, `UNVERIFIED`, `ABSENT` |
| Rate | `SYNTH_RATE_KEY` (14) | family, SKU, tier minimum, effective from | `CORRECT`, `WRONG_PRICE`, `WRONG_WINDOW`, `WRONG_UNIT_OR_CCY`, `MISSING`, `SPURIOUS` |
| Finding | `SYNTH_LEAKAGE_KEY` (47 planted, 23 distractors) | type plus invoice line, or type plus family for renewals | `TP`, `FP`, `FN`, `TYPE_CONFUSION_FP` / `_FN`, `DISTRACTOR_HIT` |

Two choices in the matching are deliberate:

- **Type confusion counts twice.** Tailspin's expired spend reported as `RATE_VARIANCE` is one false
  positive and one false negative. It is also reported on its own, because the fix (coverage before
  price, rule 8) differs from the fix for a missed finding.
- **`MISSED` and `INVENTED` are separate from `WRONG_VALUE`.** `INVENTED` — a value for a term the
  contract does not state — is the dangerous one: an invented renewal cap creates findings, an invented
  auto-renewal creates renewal alerts. `MISSED` loses findings. They are tuned in opposite directions.

## The dollar reconciliation

`EVAL_DOLLAR_RECONCILIATION` has one row per impact kind and currency. `pipeline_total` is what a
reader would see — every finding the pipeline emitted, false positives included — against
`expected_total` from `SYNTH_EXPECTED_TOTALS`. Alongside it: `tp_total`, `fp_total`, `fn_total` and
`tp_abs_error`, the per-finding error on true positives. A pipeline can have a perfect finding count
and a wrong total (retroactive tiers: right lines, wrong amounts), or a correct total from offsetting
errors; these columns separate the two.

Sandbox expectations:

| Impact kind | Currency | Expected |
|---|---|---|
| `RECOVERABLE_OVERCHARGE` | USD | 40,900.00 |
| `RECOVERABLE_OVERCHARGE` | EUR | 1,500.00 |
| `SPEND_UNDER_MANAGEMENT` | USD | 133,400.00 |
| `COMMITMENT_EXPOSURE` | USD | 403,950.00 |

Never present the sum of these rows. It is wrong by construction (rule 13).

## Reading the results

Run R1 to R8 and show them. Lead with R1 (finding precision and recall) and R4 (dollars), then R2
and R3 (extraction), R6 (failures), R7 (cost).

### Mapping errors to rules

Every non-`TP` row in R5 should be traced to a best-practices rule before anything is changed.

| Symptom in R5 | Likely cause | Rule |
|---|---|---|
| Northwind lines doubled, USD overcharge +16,800 | duplicate governed | 3 |
| `DISTRACTOR_HIT` on Northwind 2026-01..03 | amendment not linked or not dated | 4 |
| `DISTRACTOR_HIT` on Northwind 2025-06 | no tolerance | 18 |
| `DISTRACTOR_HIT` on Wide World 2026 | escalator not applied | 15 |
| Contoso March amount 3,600 instead of 600 | retroactive tiering | 7 |
| `DISTRACTOR_HIT` on Contoso Jan-Feb | tier applied from first unit | 7 |
| Tailspin `TYPE_CONFUSION` | price checked before coverage | 8 |
| Proseware lines as `OFF_CONTRACT` FPs and the EUR finding FN | vendor link failed | 10 |
| Proseware EUR finding FN alone | SKU-less match failed or ambiguous | 11 |
| EUR total missing, USD total high by 1,500 | currencies mixed | 12 |
| Fabrikam `AUTO_RENEWAL_NOTICE_MISSED` FN | term rolling missing | 14 |
| Fabrikam `UPLIFT_OVER_CAP` FN | renewal cap not extracted or not applied | 15 |
| Renewal FP on Contoso, Proseware or NDA | "expires" read as "renews", or NDA not excluded | 16, 17 |

### Term accuracy

R3 shows accuracy per term with the failing families. Term errors propagate silently: a notice period
of 30 instead of 90 days moves a deadline by two months and nothing downstream notices. Treat every
`INVENTED` term as a blocker for the findings that use that term.

### Failure accounting

R6 must be zero on the text sandbox apart from `pages_low_text` on rendered signature pages. Any
`FAILED` or `UNVERIFIED` count on customer data is recall the pipeline lost without saying so;
report it as such, not as a clean result.

### Cost

R7 reads `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` filtered by the query tag every
phase sets (`<prefix>:<phase>:<run_id>`), and reports credits, pages and tokens per phase and
function, normalized per 1,000 documents. Notes:

- The view can lag by up to 24 hours. If R7 is empty right after a run, say so and rerun section 6
  later; do not substitute an estimate presented as a measurement.
- Do not use `CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY`. It has no timestamp column and is no longer
  updated.
- Credits are what the account was billed in AI credits; do not convert to currency in the session.
  The readout applies the customer's own credit price if they supply it.
- The sandbox is ten short documents. Its cost per 1K documents is a floor, not a forecast: real MSAs
  are longer, and the corpus experiment (rendered PDFs) adds per-page parse cost. Extrapolate only
  from a measured sample of the customer's own contracts.

## Comparing experiments

R8 lists the latest summary per experiment. When comparing:

- Change one thing per experiment (a question's wording, the clause window regex, the tolerance, the
  model) and bump `prompt_version`, so a difference is attributable.
- Report the change in precision, recall and dollar error together. A change that lifts recall by
  catching more borderline variances often costs precision on distractors.
- The text-native and rendered-file experiments share a key. The difference between them is the cost
  of parsing on this corpus, and is the most useful number to take to a customer whose contracts are
  scans.

## Gates for later runs

After the first sandbox run, write the achieved figures, slightly lowered, into
`eval.min_finding_precision`, `eval.min_finding_recall` and `eval.max_dollar_abs_error_pct`. In dbt
mode these become failing tests on `EVAL_SUMMARY` and `EVAL_DOLLAR_RECONCILIATION` (see
`DBT_MATERIALIZATION.md`), so a prompt change that regresses accuracy fails the build. On customer
data without a key these gates must be disabled, not left to pass vacuously.

## Without an answer key: labeling a reviewed sample

On customer data nobody knows the true leakage until a recovery audit is done. Do not report
precision or recall from the sandbox as if it applied to the customer's corpus. Instead:

1. **Term accuracy.** Ask procurement or legal to abstract 20 to 30 contracts by hand into a table
   with the same shape as `SYNTH_TERM_KEY_WIDE`, chosen to cover the major suppliers by spend and at
   least one amendment, one SOW and one scan. Store it in the eval schema. Section 2 then runs
   unchanged.
2. **Finding precision.** Draw a stratified sample of findings — every finding type, weighted toward
   the largest amounts — and have an analyst mark each `CONFIRMED`, `REJECTED` (with reason) or
   `NEEDS_LEGAL`. Precision is confirmed over reviewed, per type. Use `review_status` on
   `LEAKAGE_FINDINGS` to hold the decisions so they survive reruns.
3. **Recall.** Only estimable against a completed recovery audit or a fully reviewed supplier.
   Choose two or three suppliers, have every invoice line reviewed against the contract, and compare.
   Say plainly that recall outside those suppliers is unmeasured.
4. **Dollars.** For confirmed findings, the analyst's own computation of the overcharge is the
   reference; report the absolute and percentage difference per kind and currency.

Record the sample design, size and reviewer in the readout. A precision figure without its sample is
not a figure.

## Output of this phase

R1 to R8 shown to the user; the summary written to `EVAL_SUMMARY`; `phases.eval: done`. If any dollar
reconciliation row is off on the sandbox, or any term is `INVENTED`, say so first and do not proceed
to the readout until it is explained.
