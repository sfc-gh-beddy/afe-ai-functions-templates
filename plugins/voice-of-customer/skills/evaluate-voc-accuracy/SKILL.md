---
name: evaluate-voc-accuracy
description: "Measure whether the voice-of-customer pipeline is right and what it costs. Topic precision, recall and F1 at L1 and L2 (multi-label set scoring, micro and macro, per label, per slice including translated items and hard cases), aspect-sentiment detection versus polarity with a five-way confusion matrix that keeps unknown, mixed and missing distinct, end-to-end topic-sentiment accuracy, return-intent precision and recall, normalization accuracy (relevance gate, dedup, language, SKU linking), emerging-theme detection lag and false-alarm rate, taxonomy drift handling across versions, test-retest stability, few-shot leakage, NULL and error accounting, and billed tokens and credits per 1K items attributed by query tag. All metrics join from ground truth outward. Includes how to label a real customer sample. Phase 8 of the voice-of-customer build."
parent_skill: voice-of-customer
---

# Evaluate accuracy and cost

A theme dashboard nobody has measured is a set of confident numbers of unknown quality. This phase
answers five questions with numbers: are the topics right, is the sentiment right, did it catch what
was emerging and how late, what did it silently lose, and what did it cost per thousand items.

Do not skip this. If the user wants to stop before it, say plainly what they will not know.

## Inputs

- Pipeline tables from Phases 3 to 7 for one `experiment_id` and `taxonomy_version`.
- An answer key in the quarantined schema: the sandbox `SYNTH_LABEL_*` tables, or a labeled sample of
  the customer's feedback in the same shapes (see "Labeling real data").
- The run's query tag. Before running any phase, the session set
  `ALTER SESSION SET QUERY_TAG = 'voc:<run_id>'`. Without it, usage cannot be attributed to the run.

`sql/01_eval_metrics.sql` implements everything below. Substitute the placeholders and run it
section by section, showing each result.

## Measurement rules that matter more than any metric

These are the ways a harness reports a confident wrong number. `voc-best-practices` section H has the
full statements.

1. **Join from ground truth outward**, with a `FULL OUTER JOIN` on `(item, label)`. Excluded, errored
   and empty items count as false negatives for every label they carry.
2. **A missing aspect prediction is `MISSING`, not `unknown`.** Otherwise an `AI_SENTIMENT` error
   scores as a correct "not mentioned" on every aspect the item does not discuss, and errors raise
   accuracy.
3. **Score L2 only where L2 is labeled**, and only under the right parent.
4. **Score against the truth for the taxonomy version the run used.** The key is keyed by version.
5. **Duplicates scored once.** The scoring universe is canonical items; dedup is measured on its own.
6. **Fail on few-shot leakage.** Section 0 of the SQL must return zero before any topic metric is
   read.
7. **Synthetic accuracy is an upper bound.** Say so every time a sandbox number is shown.

## 1. Topics

Sections 2 and 3 of the SQL build one row per `(item, label)` with `in_truth` and `in_pred`, then
`EVAL_TOPIC_METRICS` reports micro and macro precision, recall and F1, and the worst label's F1.

How to read it:

- **Micro** answers "of all topic assignments, how many were right". Frequent topics dominate it.
- **Macro** answers "how good is it on a typical topic". Rare topics count equally. A large micro to
  macro gap means one or two rare topics are poor, and rare topics (Packaging, Refund Delay) are
  often the expensive ones.
- **`labels_predicted_never_true`**: labels the pipeline assigns that never occur in truth. Usually a
  description that attracts unrelated text.
- **Per-label table** (`EVAL_TOPIC_PER_LABEL`), sorted worst first: the actionable output. Low
  precision on a label means its description is too broad or a sibling's is too narrow; low recall
  means the description does not cover how customers actually phrase it, which is what few-shot
  examples are for.
- **Recall by slice**: case role, channel, translated. Any slice well below the aggregate is a blind
  spot. Translated items and social posts are the usual ones.

Multi-label scoring is per label decision, so an item with three true topics where two were found
contributes two true positives and one false negative, not one failure.

## 2. Aspect sentiment

Section 4 builds the grid of every scored item by every bound aspect, so "not mentioned" is truth
too. Report four things, because they fail for different reasons:

| Metric | Question | Usual fix when low |
|---|---|---|
| detection precision | when it says an aspect was mentioned, was it? | aspect names too generic |
| detection recall | when an aspect was mentioned, did it notice? | aspect name does not read as the concept; translated text |
| polarity accuracy when detected | given both say mentioned, is the polarity right? | sarcasm, negation, `mixed` handling |
| aspect claim F1 | end to end, mentioned and correct | both of the above |

Then the per-polarity table (watch `mixed` and `neutral` recall: they are the weakest classes for
most sentiment systems), the full confusion matrix, and the hard-case table, which is the one to read
with the customer: each row is a named failure mode with a pass or fail.

The overall-sentiment table by case role and the star-rating crosstab go together: the crosstab shows
how often stars disagree with what the customer wrote, which is why stars are never a label.

## 3. Topic-level sentiment

Section 5 scores the number a dashboard actually shows: right topic and right sentiment for that
topic, joined through the taxonomy's aspect. It is lower than either component alone. Present it as
the headline accuracy for any "sentiment by topic" chart.

## 4. Return intent

Section 6. The support is small in the sandbox (the hard cases only); treat the figure as a smoke
test, and require it to be measured on a labeled real sample before it feeds a returns figure in the
value readout.

## 5. Normalization

Section 7:

- **Gate**: precision and recall of the not-feedback exclusion, and `genuine_feedback_lost`, which
  must be near zero. Losing real complaints to an aggressive gate is worse than letting a little spam
  through, because the loss is invisible.
- **Dedup**: syndicated copies collapse to the expected canonical id; template collisions all survive.
- **Language**: expected versus resolved language for every non-English item, including the
  misreported and unreported ones.
- **SKU linking**: accuracy, wrong links and unresolved counts. A wrong link is worse than unresolved.

## 6. Emerging themes

Section 8:

- **Detection lag** per planted theme at the planted grain, in weeks from onset to the first
  persistent candidate. With the default persistence rule the earliest possible lag is one week. A
  `NULL` means not detected at that grain; check coarser grains and the sub-theme discovery output
  before calling it missed.
- **False alarms** with the number of series tested, so the rate is interpretable.
- **Precursor**: the single early hinge mention in another region must not fire.
- **Discovery naming**: the closest proposals per planted theme, for a human to judge. The similarity
  score from `AI_SIMILARITY` is a sorting aid, not a pass mark.

Re-run with `emerging.min_weekly_mentions`, `z_threshold` and `baseline_weeks` varied and show the
lag versus false-alarm tradeoff, so the customer chooses the operating point knowingly.

## 7. Taxonomy drift handling

The sandbox is built to test the full drift loop. Run it as two experiments:

1. `exp_v1`: classify on v1. Expect hinge and subscription items labeled Durability and Too
   Expensive, correctly under v1 truth; expect detection to surface them as split candidates.
2. Adopt v2 through `build-voc-taxonomy` (new version, narrowed parent descriptions, map rows).
3. `exp_v2`: classify on v2, score against v2 truth.

Then compare:

```sql
SELECT experiment_id, taxonomy_version, l1_micro_f1, l1_macro_f1, l2_micro_f1, l2_macro_f1,
       aspect_micro_f1
FROM <EVAL>.EVAL_EXPERIMENT_SUMMARY
ORDER BY evaluated_at;
```

And the three drift-specific checks:

```sql
-- a. New nodes found their items: recall on the split children under v2.
SELECT label, tp, fn, recall, precision
FROM <EVAL>.EVAL_TOPIC_PER_LABEL      -- evaluated for exp_v2
WHERE label IN ('Product Quality > Hinge Breakage', 'Price and Value > Subscription Fees',
                'Product Quality > Durability', 'Price and Value > Too Expensive');

-- b. Parents did not keep absorbing the new subject: precision on the
--    narrowed parents should hold or rise between v1 and v2.

-- c. Roll-up consistency: v2 results rolled up to v1 terms should agree
--    with the v1 run on the same items.
SELECT COUNT(*) AS items_compared,
       COUNT_IF(v1.topic_l2 = up.topic_l2) / NULLIF(COUNT(*), 0) AS rollup_agreement
FROM <PIPE>.VOC_TOPICS v1
JOIN <TAX>.VOC_TOPICS_IN_V1_TERMS up
  ON up.feedback_id = v1.feedback_id AND up.topic_l1 = v1.topic_l1
WHERE v1.experiment_id = 'exp_v1' AND up.produced_under_version = 'v2';
```

Low roll-up agreement means the two versions disagree beyond the intended split, usually because the
v2 descriptions changed more than the change record says. Report all three; this is the accuracy
statement for "taxonomy drift handling".

## 8. Stability

Re-run Phases 4 and 5 on a fixed sample of a few hundred items under a new `experiment_id` with no
other change, and report the agreement:

```sql
SELECT COUNT_IF(a.topics = b.topics) / COUNT(*) AS topic_set_agreement
FROM (SELECT feedback_id, ARRAY_SORT(ARRAY_AGG(DISTINCT topic_l1)) AS topics
      FROM <PIPE>.VOC_TOPICS WHERE experiment_id = 'exp_retest_a' GROUP BY 1) a
JOIN (SELECT feedback_id, ARRAY_SORT(ARRAY_AGG(DISTINCT topic_l1)) AS topics
      FROM <PIPE>.VOC_TOPICS WHERE experiment_id = 'exp_retest_b' GROUP BY 1) b
  USING (feedback_id);
```

Accuracy differences between experiments smaller than the test-retest disagreement are noise. Say so
before declaring that a description change helped.

## 9. Failure accounting

Section 9: errors by stage with a sample message, and the reconciliation of included items against
items with topics, items with an empty L1, items with sentiment, and segmented items. Every metric
above is reported **with** these numbers beside it. A recall figure without the error count is not a
recall figure.

## 10. Cost per 1K items

Section 10 attributes billed tokens and credits to the run through `QUERY_HISTORY` on the query tag,
because `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` is bucketed by hour, so filter on the run's `QUERY_TAG`. Usage can take a
few hours to appear; if the totals look low right after a run, wait and re-run before reporting.

Report per function and per model:

- tokens and credits per 1K **source** items (what the customer's volume will cost), and
- the share removed before any AI call by dedup and the near-empty rule (the cheapest lever).

Compare against the Phase 4 and 5 estimates. `AI_CLASSIFY` and `AI_SENTIMENT` estimates should be
close; summaries and `AI_COMPLETE` calls are where the estimate and the bill diverge. Report tokens
and credits only. Do not convert to currency, even when asked; point the user to their contract
rate.

## Labeling real data

Before any figure from this phase is used in a business case, label a sample of the customer's own
feedback:

1. **Stratify** by channel, product line, region and month, and oversample the non-English share and
   any topic expected to be rare. 300 to 500 items is a workable first set.
2. **Label with the taxonomy version in use**, at L1 and L2, plus aspect sentiment for each topic,
   plus `is_feedback`, return intent and expected SKU where relevant. Use the same table shapes as the
   sandbox key.
3. **Double-label a subset** (at least 100 items) by two people and measure their agreement per label.
   Human agreement is the ceiling; a pipeline cannot be expected to exceed it, and a label where humans
   disagree often needs a better description, not a better model.
4. **Adjudicate** disagreements and record the decision.
5. **Quarantine** the labeled sample in the eval schema. Never use labeled items as few-shot examples.
6. **Freeze** the sample. Re-label only for a new taxonomy version, as a new keyed version.

## Accuracy targets

Do not invent targets or quote figures from other deployments. Set them with the customer, per use:
a trend dashboard tolerates lower per-item precision than a workflow that routes individual items to
a team. Record the agreed targets in `thresholds` and in the POC criteria.

## Gate output

A short report: topic micro and macro F1 at L1 and L2 with the worst labels; aspect detection,
polarity and claim F1 with the confusion matrix; topic-sentiment accuracy; return-intent precision and
recall with support; gate, dedup, language and linking results; emerging-theme lag and false alarms;
the v1 to v2 drift comparison; test-retest agreement; error counts; tokens and credits per 1K items;
and the statement that sandbox figures are an upper bound. Then set `thresholds.min_topic_f1_l1` and
`min_aspect_f1` to just under the achieved values if the user wants regression gates, and
`phases.eval: done`.
