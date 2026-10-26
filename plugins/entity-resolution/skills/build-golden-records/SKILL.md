---
name: build-golden-records
description: "Phase 5 of the entity-resolution build. Collects accepted match edges from rules, scores and model decisions (dropping model matches whose swapped-order probe disagreed), clusters records by connected components with iterative label propagation in a task-safe scripting block, holds clusters that exceed a size cap, contain cannot-link conflicts (multiple tax ids, GTINs or sizes) or fall below a cohesion floor, identifies the weakest edge as the cut candidate, assigns golden ids that stay stable across runs by member overlap with a persistent registry, writes a complete crosswalk including singletons, applies deterministic per-attribute survivorship with recorded provenance and deciding rule, computes weakest-link cluster confidence, and records non-identity relationships (parent/subsidiary, sibling location, product variant) between golden records. No AI calls. Use when building golden records, survivorship rules, MDM crosswalks, account hierarchies, or diagnosing over-merged clusters."
parent_skill: entity-resolution
---

# Build golden records

Pairwise decisions become entities here. Two things make this phase dangerous: transitivity (a chain
of individually reasonable edges can join records that should never be together) and downstream
consumption (once a system keys on golden ids, a bad merge or an unstable id is expensive to unwind).
Every guard below exists for one of those two reasons.

`sql/01_cluster_and_survive.sql` is the template; `sql/02_verify_golden.sql` is the gate.

## Gate: what this phase creates

| Object | Type | Notes |
|---|---|---|
| `ER_ACCEPTED_EDGES` | table, accumulates | One row per accepted pair, with source and confidence |
| `ER_CC_LABELS` | table, rebuilt each run | Work table for connected components |
| `ER_CLUSTERS` | table, accumulates | Size, cannot-link counts, cohesion, weakest edge, status, hold reasons |
| `ER_GOLDEN_ID_REGISTRY` | table, persistent | Every golden id ever minted |
| `ER_GOLDEN_ID_ASSIGNMENT` | table, rebuilt each run | Cluster to golden id for this run |
| `ER_CROSSWALK` | table, accumulates | Every source record to its golden id; review columns defaulted |
| `ER_SURVIVORSHIP_RULES` | table | Rule order per attribute, editable |
| `ER_GOLDEN_RECORDS` | table, accumulates | Survived attributes, provenance, confidence, status |
| `ER_ENTITY_RELATIONSHIPS` | table, accumulates | Non-identity links between golden records |

No AI cost.

## Step 1 — accepted edges

Three sources: `AUTO_MATCH` pairs from scoring (`RULE` or `SCORE`), and `MODEL_MATCH` decisions from
adjudication. A model match whose swapped-order probe produced a different outcome is excluded — an
answer that changes with presentation order is not a merge decision. Steward decisions, when a review
workflow exists, enter as `STEWARD` and override any automatic decision for the same pair, including
removing an edge.

Edge confidence is `1.0` for rules, the composite score for score matches, and the model's
self-reported confidence for model matches. These are on different scales and mean different things,
which is why cluster confidence below is reported with its weakest edge's source.

## Step 2 — connected components

Iterative minimum-label propagation in an `EXECUTE IMMEDIATE` block: each record starts labeled with
its own uid, each pass assigns the minimum label among itself and its neighbours, and the loop ends
when no label changes (capped at 100 passes, logged to `ER_PIPELINE_QUALITY_LOG`). It uses regular
tables, not `TEMPORARY`, so the same block runs unchanged as a task body (rule 38).

The number of passes is roughly the longest chain in the graph. Real duplicate clusters in master data
are small and converge in a handful of passes; dozens of passes is itself a signal of chaining.

Why not a recursive CTE: recursive CTEs over an undirected graph revisit nodes along every path, and the
row explosion on a large component is severe before the recursion limit is reached. Label propagation
does bounded work per pass.

## Step 3 — guards (rule 24)

Every cluster is checked; any failure sets `cluster_status = 'HELD'` with `hold_reasons`:

| Guard | Check | Why |
|---|---|---|
| `SIZE_CAP` | `cluster_size > thresholds.max_cluster_size` | Large clusters are almost always chaining or a placeholder key |
| `CANNOT_LINK_TAX_ID` | more than one distinct valid tax id among members (parties) | Two payees in one record |
| `CANNOT_LINK_GTIN`, `CANNOT_LINK_SIZE` | more than one GTIN or rounded size (products) | Variants merged into one item |
| `LOW_COHESION` | minimum composite over all scored pairs inside the cluster below `thresholds.min_cluster_cohesion` | Members were joined through intermediaries and do not resemble each other directly |

The cannot-link check reads member **attributes**, not only scored pairs, because two records with
different tax ids may never have been a candidate pair and still end up in one cluster through a chain.

For every cluster the weakest accepted edge is recorded as `weakest_edge_pair` — the edge to cut first.
The verification query shows held clusters with that edge, its source, and for model edges the reasons.

What happens to held clusters is the user's decision, made at the gate:

- **Steward review** (default): published with `cluster_status = 'HELD'`, crosswalk rows marked, golden
  record present but flagged; downstream consumers filter to `PUBLISHABLE`.
- **Cut and recluster**: remove the weakest edge (or all `SCORE` and `MODEL` edges in held clusters,
  keeping only `RULE` edges), and re-run steps 2 and 3. Record which edges were cut.
- **Raise the cap**: only with a specific reason, for example a vendor legitimately set up once per
  plant across many plants. Record the reason in `er-project.yml`.

## Step 4 — stable golden ids (rule 26)

A cluster inherits the prior run's golden id with which it shares the most member records; each prior
id is claimed by at most one new cluster (the one with the largest overlap), so when a cluster splits,
the larger part keeps the id and the rest mint new ones. New ids are minted as
`G-<type initial>-<hash>` and recorded in `ER_GOLDEN_ID_REGISTRY`.

`{{PRIOR_RUN_ID}}` is the last **published** run — not the last experiment. Calibration experiments on
the sandbox should not each become the baseline for id inheritance. Record the published run id in
`er-project.yml` when the user promotes a run.

The verification reports inherited versus minted counts and how many prior ids were not carried
forward. A large swing between two runs on the same data means the matching changed materially —
expected after recalibration, alarming otherwise.

## Step 5 — crosswalk (rule 27)

Every in-scope record appears exactly once per run, singletons included, with its golden id,
membership confidence (strongest accepted edge to another member; `1.0` for singletons), cluster size,
cluster status, id lineage, and `review_status` defaulted to `UNREVIEWED` so a steward workflow can be
layered on without a migration.

The crosswalk is the deliverable most downstream work keys on: vendor consolidation, duplicate-payment
review, the single customer view, product catalog cleanup.

## Step 6 — survivorship (rule 25)

Deterministic SQL only. For each golden record and attribute, candidate values come only from member
records; the winner is chosen by the attribute's rule order in `ER_SURVIVORSHIP_RULES`:

| Rule | Prefers |
|---|---|
| `MOST_TRUSTED_SOURCE` | lowest `trust_rank` from the source configuration |
| `MOST_RECENT` | latest `updated_at` |
| `MOST_COMPLETE` | longest value |
| `MOST_FREQUENT_NON_NULL` | value held by the most members |

Each rule is a numeric sort key, so one window function serves every attribute. Ties fall through to
the next rule, and finally to `record_uid` for determinism. `attribute_provenance` records, per
attribute, the winning `record_uid`, its source system, the **deciding rule** (the first rule on which
the winner strictly beat the runner-up, or `UNANIMOUS` / `ONLY_VALUE`), and how many distinct values
competed.

Agree the defaults with the user — they are business choices:

- **Display name**: most trusted source first, because the system of record for legal names (usually AP
  or billing) should win over a CRM free-text field.
- **Address and phone**: most recent first, because these change and stale values cause failed
  deliveries and wrong contacts.
- **Tax id, GTIN, MPN, city, country**: most frequent first — the consensus value, with the trusted
  source breaking ties.

Never ask a model to compose or "clean up" golden values. A golden value must exist in a member
record; that is what makes it auditable.

## Step 7 — relationships, not merges (rule 23)

Adjudicated pairs with relationship `PARENT_SUBSIDIARY`, `SIBLING_LOCATION` or `PRODUCT_VARIANT` are
written to `ER_ENTITY_RELATIONSHIPS` between the two golden ids. This is how the single customer view
rolls up an account hierarchy for cross-sell without merging separate legal entities, and how a product
family is linked without merging SKUs.

These links come only from pairs that reached the model. Relationships among pairs that were
auto-rejected are not discovered here; if hierarchy matters for the use case, say so, and consider a
separate pass over high-similarity cannot-link pairs.

## Cluster confidence

`cluster_confidence` is the minimum membership confidence in the cluster — weakest link — because a
chain is only as reliable as its weakest edge. It mixes scales (rule, score, model confidence), so
present it with the weakest edge's source, and validate it in `evaluate-match-accuracy`: the harness
reports cluster precision by confidence band, which is the only evidence that a given value means
anything.

## Gate verification

`sql/02_verify_golden.sql`:

1. convergence — passes and whether it converged
2. crosswalk completeness — in-scope equals crosswalk records, zero duplicates
3. cluster size distribution
4. held clusters by reason
5. the five largest clusters per type **with member names, cities and tax ids** — read them
6. weakest edge in each held cluster, with source and reasons
7. edge counts by source
8. golden id lineage and prior ids not carried
9. survivorship provenance validity — zero attributes citing a non-member
10. deciding-rule distribution per attribute
11. duplicate-reduction headline per entity type
12. relationship counts

Write `phases.golden: done` and the created objects.
