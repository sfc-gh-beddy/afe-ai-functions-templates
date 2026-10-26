---
name: build-voc-taxonomy
description: "Build, govern and version the voice-of-customer topic taxonomy that classification, aspect sentiment, trends and summaries all depend on. Two-level taxonomy (L1 topics, L2 subtopics) with label descriptions within AI_CLASSIFY limits, AI_SENTIMENT aspect names within 10 aspects and 30 characters, business owner and P&L lever per node, few-shot examples kept out of the evaluation set, and a version map (SAME, RENAME, SPLIT, MERGE, RETIRE) so results from different taxonomy versions stay comparable. Covers reusing an existing customer taxonomy or vendor tags, bootstrapping a taxonomy from a sample with AI_AGG, and the drift workflow: Other Feedback rate monitoring, out-of-taxonomy proposals, governed adoption of a new version, and re-baselining trends. Phase 2 of the voice-of-customer build."
parent_skill: voice-of-customer
---

# Build and govern the taxonomy

The taxonomy is the contract between the pipeline and the business. Every count, trend, summary and
value figure is expressed in its labels, so the labels must be owned, versioned and stable. A
pipeline that lets the model invent topics per call produces output that cannot be aggregated,
trended, or acted on.

## Three ways to get a taxonomy, in order of preference

### 1. Reuse the customer's existing taxonomy

Preflight section 8 looks for one: a VoC program taxonomy, survey coding frame, support reason codes,
or vendor tagging scheme. Reuse it when it exists. The business already reports on it, and a new
taxonomy forces every stakeholder to re-learn their dashboards.

Adapt it to the function limits rather than the other way round:

- More than about twenty L1 nodes: group into L1 parents and push the originals down to L2.
- L2 lists over twenty under one parent: split the parent.
- Labels that are codes or abbreviations: rewrite as plain English; keep the code as a column.
- No descriptions: write them, at most 25 words each, saying what distinguishes the node from its
  siblings. Have the node's business owner approve them.

Vendor tags on existing feedback are useful as a bootstrap and as a comparison. They are not ground
truth.

### 2. Bootstrap from a sample of the customer's own feedback

When there is no taxonomy, propose one from data and curate it with the business. Never ship a
generated taxonomy without curation.

```sql
-- Propose candidate themes from a stratified sample. AI_AGG handles inputs
-- larger than a model context window. Stratify by channel so social does
-- not dominate a review-heavy corpus or the reverse.
WITH sample AS (
    SELECT text_for_ai, source_channel
    FROM <VOC_FEEDBACK_STG>
    WHERE is_included
    QUALIFY ROW_NUMBER() OVER (PARTITION BY source_channel ORDER BY RANDOM()) <= 400
)
SELECT source_channel,
       AI_AGG(text_for_ai,
              'You are reading customer feedback about a company''s products and service. '
           || 'List the 10 to 15 distinct topics customers raise, as short plain-English topic names, '
           || 'each with a one-sentence description and an estimate of how common it is '
           || '(very common, common, occasional). Group related subtopics under a parent topic. '
           || 'Do not include customer names or quotes.') AS proposed_topics
FROM sample
GROUP BY source_channel;
```

Reconcile the per-channel proposals into one draft, then hold a review with the business owners:
merge synonyms, drop topics nobody would act on, assign an owner and a lever to each node. Record
`taxonomy.source: bootstrapped`.

### 3. Use the sandbox taxonomy

For the sandbox, `sql/01_taxonomy.sql` loads v1 and v2 matched to the synthetic corpus. Do not carry
the sandbox taxonomy into a customer build: it was designed to make the sandbox's planted themes
testable, not to describe anyone's products.

## Structure

`VOC_TAXONOMY` holds one row per L2 node per version:

| Column | Purpose |
|---|---|
| `taxonomy_version` | `v1`, `v2`... Every result row carries the version it was produced under |
| `topic_l1`, `topic_l1_desc` | parent label and description (at most 25 words) |
| `topic_l2`, `topic_l2_desc` | child label and description (at most 25 words) |
| `aspect_name` | the `AI_SENTIMENT` aspect this node's sentiment is read from; at most 30 characters |
| `business_owner` | who acts on this node; the readout routes findings by it |
| `lever` | `REVENUE_PRODUCT`, `REVENUE_PRICING`, `REVENUE_RETENTION`, `OPEX_RETURNS`, `OPEX_SUPPORT` |
| `is_active`, `valid_from`, `valid_to` | lifecycle |

### Aspects are a separate, smaller list

`AI_SENTIMENT` takes at most 10 aspects per call. The usual design is one aspect per L1, named for
the L1, so a taxonomy with eight L1 topics produces eight aspects and fits in one call. If the
taxonomy has more than ten L1 topics, group several L1s onto one aspect rather than batching calls
(batching doubles the sentiment cost). Aspect names are what the model sees, with no description, so
they must be self-explanatory: "Shipping and Delivery", not "Logistics".

**Keep aspect names stable across taxonomy versions.** A taxonomy change usually happens at L2; the
aspect series should continue unbroken across it. Renaming an aspect breaks every aspect trend line.

### Other Feedback

Include one L1 for genuine feedback the taxonomy does not cover, described explicitly as the last
resort. It is the drift signal. It is distinct from "not feedback", which the relevance gate removes
before classification.

### Examples

`VOC_TAXONOMY_EXAMPLES` holds a few examples per level per version, used as `AI_CLASSIFY` few-shot
`examples` (each with `input`, `labels`, and `explanation`, as the reference requires). Rules:

- Two to five per level is usually enough. Each one bills on every call.
- Target the confusions you actually see in evaluation (sibling L2 nodes, price versus quality), not
  easy cases.
- Never copy a labeled evaluation item, a sandbox fragment, or a hard case into an example. The
  harness checks.

## Running the template

Read `sql/01_taxonomy.sql`, substitute `{{DB}}` and `{{TAXONOMY_SCHEMA}}`, and for a customer build
replace the `INSERT` values with the curated taxonomy, keeping the structure, the views, and the
contract checks. At the gate, show the L1 list with descriptions, the L2 count per L1, and the aspect
list.

The script ends with contract checks. Every row must be zero:

| Check | Why |
|---|---|
| `description_over_25_words` | AI_CLASSIFY description limit |
| `aspect_name_over_30_chars` | AI_SENTIMENT aspect limit |
| `more_than_10_aspects_in_version` | AI_SENTIMENT aspect limit |
| `l1_list_over_20`, `l2_list_over_20` | accuracy degrades past about twenty categories |
| `l2_list_under_2` | AI_CLASSIFY needs at least two categories |
| `duplicate_l2_label_across_l1` | an L2 label under two parents cannot be rolled up unambiguously |
| `v1_node_without_v2_mapping` | every old node must map, or trends break at the version boundary |

The classifier-ready views (`VOC_TAXONOMY_L1_CATEGORIES`, `VOC_TAXONOMY_L2_CATEGORIES`,
`VOC_TAXONOMY_ASPECTS`, `VOC_TAXONOMY_EXAMPLES_CFG`) are what Phases 4 and 5 bind. They are views over
plain tables with no AI calls, so a view is the right materialization here.

## Estimate the per-call overhead of the taxonomy

Descriptions and examples are billed on every row. Measure what the taxonomy adds before Phase 4:

```sql
-- Overhead of the bound L1 call on a short fixed input. Multiply the
-- difference by the item count for the per-run cost of the taxonomy itself.
SELECT
    AI_COUNT_TOKENS('ai_classify', 'Delivery was late.',
                    TRANSFORM(c.categories, x VARIANT -> OBJECT_CONSTRUCT('label', x:label))) AS labels_only,
    AI_COUNT_TOKENS('ai_classify', 'Delivery was late.', c.categories)        AS with_descriptions,
    AI_COUNT_TOKENS('ai_classify', 'Delivery was late.', c.categories,
                    {'task_description': :task_description,
                     'output_mode': 'multi',
                     'examples': e.examples})                                 AS with_task_and_examples
FROM VOC_TAXONOMY_L1_CATEGORIES c
LEFT JOIN VOC_TAXONOMY_EXAMPLES_CFG e
  ON e.taxonomy_version = c.taxonomy_version AND e.level = 'L1'
WHERE c.taxonomy_version = :taxonomy_version;
```

If descriptions and examples dominate the per-row token count, shorten them before running on the
full corpus, then confirm in evaluation that accuracy did not drop.

## Drift: how the taxonomy changes without breaking history

Taxonomies drift because products, prices and policies change. The failure is not that drift
happens; it is that a label quietly changes meaning and the trend line lies. The workflow:

### 1. Detect

Two signals, both produced by `detect-emerging-themes`:

- **Other Feedback rate** above `taxonomy.other_rate_threshold`, or rising week on week.
- **Out-of-taxonomy clusters**: tight groups of feedback whose embeddings are far from every taxonomy
  node, with names proposed by `AI_COMPLETE`.

A third, softer signal: one L2 node growing much faster than its siblings may be absorbing a new
subject (the sandbox hinge theme does exactly this inside Durability).

### 2. Propose

For each candidate, produce a change record for the owner: proposed label and description, parent,
relation to existing nodes (new node, split of an existing node, merge), cluster size and growth,
and five example item ids. Never auto-adopt.

### 3. Adopt as a new version

Adoption is a new `taxonomy_version`, never an in-place edit:

1. Insert the new version's rows (copy the previous version, then apply the changes).
2. When splitting a node, **narrow the parent's description** so the model can tell siblings apart;
   otherwise the old node keeps absorbing the new subject.
3. Write `VOC_TAXONOMY_MAP` rows for every old node, with the relation.
4. Add examples for the new node and its nearest sibling.
5. Re-run the contract checks.
6. Update `taxonomy.active_version` and `taxonomy.versions` in `voc-project.yml`, and bump
   `experiment.experiment_id` and `prompt_version`.

### 4. Re-baseline

After adoption, items from the adoption date forward are classified under the new version. History
stays under the old version unless the user chooses to re-classify it (a new experiment with its own
cost estimate). For continuous trend lines across the boundary, roll up through the map:

```sql
-- Express v2 results in v1 terms for a continuous series. SPLIT children
-- roll up to their v1 parent; RENAME maps back 1:1; SAME is identity.
CREATE OR REPLACE VIEW VOC_TOPICS_IN_V1_TERMS AS
SELECT t.feedback_id, t.run_id, t.week_start, t.sku, t.region_code,
       COALESCE(m.from_l1, t.topic_l1) AS topic_l1,
       COALESCE(m.from_l2, t.topic_l2) AS topic_l2,
       'v1'                            AS expressed_in_version,
       t.taxonomy_version              AS produced_under_version
FROM <voc_topics_flat> t
LEFT JOIN VOC_TAXONOMY_MAP m
  ON m.to_version = t.taxonomy_version
 AND m.to_l1 = t.topic_l1
 AND m.to_l2 = t.topic_l2
 AND m.from_version = 'v1'
WHERE t.taxonomy_version IN ('v1', 'v2')
-- One item can carry two v2 children of the same v1 parent; collapse them
-- so the rolled-up count does not double.
QUALIFY ROW_NUMBER() OVER (PARTITION BY t.feedback_id, t.run_id,
                                        COALESCE(m.from_l1, t.topic_l1),
                                        COALESCE(m.from_l2, t.topic_l2)
                           ORDER BY t.topic_l2) = 1;
```

The reverse direction (v1 history expressed in v2 terms) is not possible for split nodes without
re-classification. Say so plainly when asked for it.

### 5. Measure the change

Run `evaluate-voc-accuracy` on both versions against the answer key keyed by version. The question
the business cares about: did the new node raise recall on the new subject without lowering precision
on its siblings? In the sandbox, adopting v2 should move the planted hinge items from Durability to
Hinge Breakage and leave Durability's precision intact.

Record `taxonomy.last_drift_review` with the date, whatever the outcome.

## Verification before declaring the phase done

1. All contract checks zero.
2. The L1 list, L2 counts, and aspect list shown to the user and confirmed.
3. A dry classification of five hand-picked items (not from any labeled set) with the bound
   categories, showing labels, to confirm the call shape works on this account.
4. The taxonomy overhead estimate.

Then `phases.taxonomy: done`, `taxonomy.active_version` set, and objects recorded.
