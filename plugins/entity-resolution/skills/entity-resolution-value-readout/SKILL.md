---
name: entity-resolution-value-readout
description: "Final phase of the entity-resolution build. Applies the shared value model (shared/references/value-model.md) to entity resolution using customer-supplied inputs only: duplicate vendor spend and consolidation, duplicate payment exposure, steward and data-ops labor for manual deduplication, and cross-sell from a single customer view and account hierarchies. Pulls the data-derived counts (duplicate records collapsed, multi-record vendor clusters, spend through duplicate vendor clusters, customers present in multiple systems, related-account links) from the published views, applies measured precision to discount them, reports low / expected / high ranges with every assumption marked, reports Snowflake cost as measured tokens and credits per 1,000 records and per month without converting to currency, and drafts two-week POC success criteria from shared/references/poc-template.md. Use for ROI, business case, value readout, or POC criteria for entity resolution, MDM matching, vendor dedup or single customer view."
parent_skill: entity-resolution
---

# Value readout

Turn the measured output of this build into a business case the customer can defend. The rules come
from `shared/references/value-model.md` and are not negotiable:

- **Customer-supplied numbers only.** Spend, rates, costs, conversion and deal size come from the
  customer, named and dated. Never fill a gap with an industry figure, a figure from another engagement,
  or a plausible guess. A missing input means that line is not computed, and the readout says so.
- **Mark every assumption** — who supplied it, and whether it is a measured figure or an estimate.
- **Ranges, not points**: low / expected / high, driven by the customer's own range on each input and
  by the measured precision range from evaluation.
- **Cost in tokens and credits as measured.** Report billed tokens and `CREDITS` from account
  usage; the customer applies their own credit price. Do not convert to currency.

## Step 1 — data-derived counts from the published run

These come from the pipeline, not the customer. Run against the current views:

```sql
-- Duplicate records collapsed, per entity type.
SELECT entity_type,
       SUM(source_records)                               AS source_records,
       COUNT(*)                                          AS golden_records,
       SUM(duplicates_collapsed)                         AS duplicate_records,
       COUNT_IF(source_records > 1)                      AS multi_record_entities,
       COUNT_IF(source_systems > 1)                      AS multi_system_entities
FROM ER_DUPLICATE_SUMMARY_CURRENT
WHERE cluster_status = 'PUBLISHABLE'
GROUP BY 1;

-- Related but distinct entities (account hierarchy, product families).
SELECT entity_type, relationship, COUNT(*) AS links
FROM ER_RELATIONSHIPS_CURRENT
GROUP BY 1, 2;
```

For vendor spend, join the customer's AP or spend table on the source vendor key. This is the only
place spend data enters the build, and it stays in SQL:

```sql
-- Spend through vendors that resolve to a multi-record golden vendor.
-- <SPEND_TABLE>, <VENDOR_KEY>, <SYSTEM_EXPR>, <AMOUNT>, <DATE> come from the customer;
-- the window must match the period the customer's other inputs refer to.
WITH spend AS (
    SELECT <SYSTEM_EXPR> || ':' || TRIM(<VENDOR_KEY>::VARCHAR) AS record_uid,
           SUM(<AMOUNT>) AS spend
    FROM <SPEND_TABLE>
    WHERE <DATE> >= DATEADD('month', -12, CURRENT_DATE())
    GROUP BY 1
)
SELECT COUNT(DISTINCT x.golden_id)            AS duplicate_vendor_clusters_with_spend,
       SUM(s.spend)                           AS spend_through_duplicate_clusters,
       COUNT(DISTINCT x.record_uid)           AS vendor_records_with_spend
FROM ER_CROSSWALK_CURRENT x
JOIN ER_DUPLICATE_SUMMARY_CURRENT d ON d.golden_id = x.golden_id AND d.source_records > 1
JOIN spend s ON s.record_uid = x.record_uid
WHERE x.entity_type = 'VENDOR';
```

### Discount by measured precision

Every count above includes some false merges. Multiply duplicate counts by the measured pairwise
precision for that entity type (from `ER_EVAL_SUMMARY` on the sandbox holdout, or from the
steward-labeled sample on real data), and carry its uncertainty into the range: use the lower bound of
a binomial confidence interval (from the true-positive and predicted pair counts in `ER_EVAL_PAIRWISE`,
or from the labeled sample) for **low**, and the point estimate for **expected**. Say which precision figure was
used and where it came from. On real data with no labeled sample yet, state that the counts are
**unvalidated** and present them without a value figure until a sample exists.

## Step 2 — inputs to ask for

Ask only for the levers the customer wants to quantify. Record each answer with its source in the
readout.

| Lever | Inputs from the customer | Formula (value-model row) |
|---|---|---|
| OpEx: duplicate spend / consolidation | annual spend through duplicate vendor clusters (from the SQL above, or their figure); expected consolidation saving as a percentage, from their procurement team | spend through duplicate clusters x precision x consolidation saving % (`OpEx: duplicate spend`) |
| OpEx: duplicate payment exposure | historical duplicate-payment rate or recovered amount on duplicate vendors; share of that preventable by a single vendor record | spend through duplicate clusters x precision x their duplicate-payment rate x preventable share |
| OpEx: data-ops and steward labor | minutes per manual duplicate investigation today; loaded cost per hour; duplicates created per month (or this backlog once) | duplicate records x precision x minutes per record / 60 x cost per hour (`OpEx: manual processing`) |
| OpEx: review-band labor | minutes per steward review of a proposed pair; cost per hour | steward-review pairs per month x minutes / 60 x cost per hour — a **cost**, subtracted |
| Revenue: cross-sell from single customer view | number of multi-system customers or hierarchy links the account team considers addressable; qualification rate; their historical cross-sell conversion; average deal size | addressable entities x qualification rate x conversion x deal size (`Revenue: growth`) |

Notes on each:

- **Consolidation saving** is a procurement judgment (renegotiated pricing, removed duplicate fees). It
  is the customer's number or it is not in the readout.
- **Duplicate payments**: present as exposure reduced, not as recovered cash, unless the customer has
  a recovery process and a recovery rate.
- **Labor**: count only work that actually goes away. If stewards still review the review band, that
  time is a cost of the new process, shown in the same table.
- **Cross-sell**: a multi-system customer is an opportunity to be qualified, not revenue. The
  qualification rate is what turns a count into a pipeline estimate; it must come from the account team.
  Relationship links (parent/subsidiary) feed account planning; count them separately from merges.

## Step 3 — Snowflake cost

From `evaluate-match-accuracy` section 9: tokens per 1,000 source records, by phase, function and
model, and `CREDITS` from `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` for the measured runs. Project
steady state from **change volume**, not total volume, because embeddings and model calls are
incremental (publish skill): ask the customer for new and changed master records per month per entity
type, and multiply by the measured per-record figures for embedding, and by the measured
review-band-per-changed-record rate for adjudication. Add warehouse credits for the scheduled runs
from `WAREHOUSE_METERING_HISTORY` if the customer wants a full picture.

Present: initial backlog run (measured), monthly steady state (projected, assumption: change volume),
both in tokens and credits. ROI is the customer's value range divided by the credits at their price.

## Step 4 — the readout document

Structure:

1. **Decision this changes** — named by the business owner at discovery (for example "vendor master
   cleanup and consolidated renegotiation", "account plans built on one customer record").
2. **What was found** — counts per entity type, with the precision used and its source.
3. **Accuracy** — blocking pair completeness, pairwise and B-cubed precision and recall, hard-negative
   over-merge rate, model failure count, position-bias flip rate. Sandbox figures are labeled as
   sandbox; they demonstrate the pipeline, not this customer's data.
4. **Value** — one table per lever: inputs (with source), formula, low / expected / high.
5. **Cost** — tokens and credits, backlog and monthly.
6. **Assumptions and gaps** — every input not supplied, every count not yet validated on real data.
7. **POC criteria** — below.

Do not include customer names in any file outside the account, and do not include record contents —
counts and synthetic examples only.

## Step 5 — POC success criteria

From `shared/references/poc-template.md` (two weeks: discovery and a sample in week 1; incremental
pipeline, semantic view and agent, readout in week 2). Draft criteria for the customer to set targets
on — propose the metric, let them set the number:

- **Accuracy on a labeled sample**: pairwise precision of auto-merged pairs at or above
  `<customer target>`; B-cubed F1 at or above `<target>` (or pairwise recall where full cluster truth is
  unavailable); zero merges across different valid tax ids.
- **Blocking recall**: pair completeness on known duplicates (previously merged records, or a steward
  set) at or above `<target>`.
- **Cost control**: share of candidate pairs sent to the model at or below `<target>`; tokens per 1,000
  records reported for embed and adjudicate.
- **Operational**: crosswalk covers 100 percent of in-scope records; golden ids stable across two
  consecutive runs on unchanged data (zero minted, zero split).
- **Decision**: one named business decision the owner commits to make from the output (a vendor
  consolidation list reviewed by procurement; an account list reviewed by sales).

Write `phases.readout: done`.
