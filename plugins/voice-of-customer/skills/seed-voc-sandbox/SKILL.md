---
name: seed-voc-sandbox
description: "Generate a synthetic voice-of-customer corpus with a labeled answer key so a topic classification, aspect-sentiment, emerging-theme and summarization pipeline can be built, demonstrated and accuracy-tested before touching real customer feedback. Creates products, regions, reviews, survey open-ends and social posts composed from labeled single-topic fragments (so thousands of rows carry exact topic and aspect-sentiment labels), hand-authored hard cases (sarcasm, negation, comparatives, mixed aspects, off-topic, spam, non-English, over-window length, syndicated duplicates, template collisions, SKU-from-text, return intent), two planted emerging themes outside taxonomy v1 with known onset week, SKU and region, and synthetic weekly returns and contacts. Labels are quarantined in a separate schema. Phase 1 of the voice-of-customer build."
parent_skill: voice-of-customer
---

# Seed the sandbox

Generate a synthetic feedback corpus with **ground truth**. This is what lets the accuracy harness
report topic and aspect-sentiment precision and recall on day one, and lets the build be demonstrated
before anyone approves access to real customer text.

## Why not just point at real feedback

You can; this phase is skippable. Be honest about what is given up. Real feedback has no labels, so
precision and recall are unmeasurable until someone labels a sample. Emerging-theme detection is
worse: without a planted theme with a known onset, there is no way to say whether the detector would
have fired, or how late. A detector that "found nothing" on real data might be correct or might be
blind, and nothing distinguishes the two.

## How the corpus is built

The generator is designed so labels are **exact at scale** without hand-labeling thousands of rows.

1. **Labeled fragments.** About forty single-sentence fragments, each about exactly one taxonomy node
   with one aspect and one polarity ("Delivery took almost three weeks with no explanation" is
   Shipping and Delivery > Delivery Speed, negative). Some fragments only fit one product line (fit
   and sizing fragments only appear on apparel).
2. **Composition.** Each background item concatenates one to three fragments eligible for its
   product line. Its labels are the union of its fragments' labels; two fragments on the same aspect
   with opposite polarity produce `mixed`, which is exactly what `AI_SENTIMENT` should return.
3. **A materialized plan.** The random draws are written once to `SYNTH_FEEDBACK_PLAN` before the text
   is composed. If the plan were a view or CTE, `RANDOM()` would re-roll on each reference and the
   composed text would stop matching its labels. Verification check 2 catches that.
4. **Channel styling.** Social posts get a handle and a hashtag; about 40 percent of social items
   have no SKU so linking is exercised. Star ratings and NPS are derived from polarity so they look
   plausible, but they are never used as truth.
5. **Hard cases.** Thirty-odd hand-authored items, each targeting a specific failure, with explicit
   labels in `SYNTH_HARD_LABELS` and `SYNTH_HARD_ROW_LABELS`.
6. **Emerging themes.** Two themes with known onset, both outside taxonomy v1 at L2.
7. **Weekly outcomes.** Synthetic units sold, returned and support contacts per SKU, region and week,
   with returns on the hinge SKU rising after onset, so the theme-to-outcome join has something to
   show. These are illustrations, never inputs to a value readout.

## The hard cases and what each one catches

| Case role | Example | Catches |
|---|---|---|
| `SARCASM` | "Love waiting three weeks for a package..." | literal-positive misread |
| `NEGATION` | "Not bad at all for the price" | negation flipping polarity |
| `COMPARATIVE` | "The Classic sounded far better than this Fold version" | sentiment attached to the wrong product |
| `MIXED_ASPECTS` | great fit, slow delivery | item-level sentiment smeared across topics (rule 11) |
| `MIXED_WITHIN_ASPECT` | powerful, but the lid cracked | `mixed` mapped to neutral (rule 10) |
| `OFF_TOPIC`, `PRESALES_QUESTION` | store hours; compatibility question | missing relevance gate (rule 16) |
| `SPAM` | identical promo text from three handles | spam classified into a topic |
| `NON_ENGLISH*` | Spanish; French with no reported language; German reported as English | trusting reported language (rule 14) |
| `OVER_WINDOW` | long survey answer above 2,048 tokens | silent NULL or truncation in `AI_SENTIMENT` (rules 8, 9) |
| `SYNDICATED_*` | same author and text on three retailer sites | double counting (rule 15) |
| `TEMPLATE_COLLISION` | "Great product, fast shipping." from three customers | text-only dedup deleting real customers |
| `RATING_TEXT_MISMATCH` | five stars, product disconnects constantly | stars used as truth (rule 12) |
| `SKU_FROM_TEXT` | social post naming the product | SKU linking, and fabricated SKUs (rule 18) |
| `ASPECT_AMBIGUITY` | "Cheap, and it feels cheap." | price versus quality aspect confusion |
| `RECOVERY` | product failed, support fixed it fast | overall positive while product aspect negative |
| `RETURN_INTENT*` | "Sending these back"; "thinking about returning it" | return-intent flag recall |
| `NEUTRAL` | "It is a kettle. It boils water." | forced polarity |
| `EMERGING_PRECURSOR` | one hinge complaint in week 2 in another region | detector firing on a single mention |
| `SHOUTING` | all caps checkout complaint | casing and punctuation robustness |

## Planted emerging themes

| Theme | Where | Onset | Taxonomy v1 truth | Taxonomy v2 truth |
|---|---|---|---|---|
| `HINGE`: folding hinge cracking or snapping | `SYN-SKU-HP-200`, `SYN-EU`, all channels | week 6 of 16, accelerating | Product Quality > Durability | Product Quality > Hinge Breakage |
| `SUBSCRIPTION`: backlash at a new recurring fee | social only, all regions, several SKUs | week 10 of 16, accelerating | Price and Value > Too Expensive | Price and Value > Subscription Fees |

Both are deliberately invisible as **new nodes** under v1: they land inside a broad existing L2. That
is the realistic case. A detector that only watches existing topic series sees Durability rise
slightly across the whole SKU portfolio; one that also clusters novel text sees a tight, growing
cluster about hinges on one SKU in one region. This is how the plugin tests drift handling: run on
v1, detect, propose, adopt v2, re-run, and compare.

## Configure before generating

Write these into `voc-project.yml` under `target` and the seed parameters:

| Parameter | Default | Notes |
|---|---|---|
| Background rows | 3,000 | Enough per-class support for stable metrics; small enough to classify cheaply |
| End date | a fixed literal | Not `CURRENT_DATE`, so re-seeding produces the same calendar and runs stay comparable |
| Pipeline schema | `SANDBOX` | Feedback, products, regions, weekly outcomes |
| Eval schema | `VOC_EVAL` | Fragments, plan, every label table. Quarantined |

The taxonomy must be loaded (Phase 2) before verification check 6, which confirms the planted themes
are outside v1. Generating the corpus first is fine; run check 6 after Phase 2.

## Estimate before generating

The seed itself makes no AI calls except verification check 8 (`AI_COUNT_TOKENS`, a single row).
Before Phase 4, estimate classification on the seeded corpus:

```sql
SELECT COUNT(*) AS items,
       SUM(AI_COUNT_TOKENS('ai_sentiment', feedback_text)) AS sentiment_input_tokens
FROM <SCHEMA>.SYNTH_FEEDBACK;
```

## What gets created

| Object | Schema | Purpose |
|---|---|---|
| `SYNTH_PRODUCTS` | pipeline | nine SKUs across three product lines |
| `SYNTH_REGIONS` | pipeline | five regions |
| `SYNTH_FEEDBACK` | pipeline | reviews, surveys, social posts |
| `SYNTH_SKU_WEEKLY` | pipeline | synthetic units sold, returned, contacts |
| `SYNTH_FRAGMENTS` | eval | labeled fragments |
| `SYNTH_FEEDBACK_PLAN` | eval | materialized draw plan |
| `SYNTH_HARD_LABELS`, `SYNTH_HARD_ROW_LABELS` | eval | hard-case labels |
| `SYNTH_LABEL_TOPICS` | eval | topic truth per taxonomy version |
| `SYNTH_LABEL_ASPECTS` | eval | aspect-sentiment truth |
| `SYNTH_LABEL_ROWS` | eval | row truth: relevance, canonical id, SKU, language, return intent, overall |
| `SYNTH_LABEL_EMERGING` | eval | emerging-theme truth |

`sql/01_seed_sandbox.sql` is the template. Read it, substitute the placeholders (`{{DB}}`,
`{{SCHEMA}}`, `{{EVAL_SCHEMA}}`, `{{BACKGROUND_ROWS}}`, `{{END_DATE}}`), confirm at the gate, and run
it. Do not run it unmodified.

## The answer key is quarantined

The fragments and the plan carry labels, so they live with the answer key in the eval schema, not
next to the feedback. Rules:

- No pipeline query reads the eval schema. Only `evaluate-voc-accuracy` does.
- Grant the pipeline role no privileges on the eval schema if the build uses separate roles.
- Never put label text, fragment text, or labeled examples into a prompt, a few-shot example, a
  taxonomy description, or an embedding reference set.

A pipeline that has seen its own answer key reports meaningless accuracy, and the leak is easy to
introduce: a `SELECT *` across a database is enough.

## Verification before declaring the phase done

Run `sql/02_verify_seed.sql` (same placeholders as `01`, plus `{{TAXONOMY_SCHEMA}}` for check 6) and show every result. The nine checks:

1. Every feedback row has row labels and every labeled feedback row has topic labels.
2. Composed text contains every one of its fragments (catches a plan/text divergence).
3. Label support per L1 and L2 (a node with very few rows produces a meaningless metric).
4. Aspect truth includes `mixed`, so the within-aspect conflict case is tested.
5. Planted themes are zero before onset and rising after.
6. Planted themes are not v1 L2 nodes (run after Phase 2).
7. Every trap is present, and the duplicate patterns are distinguishable.
8. The over-window case really exceeds 2,048 sentiment tokens.
9. No label-bearing table sits in the pipeline schema.

Then write `phases.seed: done` and record created objects.

## Keep it synthetic, and obviously so

- Every identifier carries a `SYN-` prefix; handles are `syn_user_` plus digits.
- Product and brand names are fabricated and generic.
- No real addresses, emails, order numbers or names. The redaction step is tested on real data at
  POC time; do not plant realistic personal data in the sandbox to test it, because the sandbox gets
  screenshotted.
- Do not model the corpus on a specific company's catalogue or taxonomy.

## Teardown

Drop the sandbox once real data is wired in, or it will eventually be queried by accident alongside
real feedback. Drop the eval schema last; evaluation history references it.
