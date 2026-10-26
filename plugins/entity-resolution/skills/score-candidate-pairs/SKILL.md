---
name: score-candidate-pairs
description: "Phase 3 of the entity-resolution build. Embeds each canonical record once with AI_EMBED into a stored VECTOR column keyed by model, template version and text hash (re-embedding only changed records), adds a SEMANTIC_KNN blocking pass from stored vectors, verifies stored-vector cosine against AI_SIMILARITY on a small sample, computes deterministic pair features (scaled Jaro-Winkler on names and addresses, postal, city, phone, domain, tax id, GTIN, MPN and size relations, token substitution), applies cannot-link and positive rules before any threshold, and bands every pair into AUTO_MATCH, REVIEW or AUTO_REJECT with an explicit band source. Use when computing embeddings or similarity for matching, choosing between AI_SIMILARITY and VECTOR_COSINE_SIMILARITY, designing match scores, or deciding which pairs go to the model."
parent_skill: entity-resolution
---

# Score candidate pairs

This phase turns candidate pairs into three bands. Only the middle band costs model calls in Phase 4,
so the quality of this phase is simultaneously an accuracy lever and the main cost lever of the play.

`sql/01_embed_and_score.sql` is the template. Sections are run in order, with the gate after
section 1 (estimate) and again after section 5 (scoring).

## Gate: what this phase creates

| Object | Type | AI cost |
|---|---|---|
| `ER_RECORD_EMBEDDINGS` | table, persistent across runs | `AI_EMBED` once per new or changed record |
| `ER_KNN_PAIRS` | table | none (vector function) |
| `ER_CANDIDATE_PAIRS` | updated with `SEMANTIC_KNN` pairs | none |
| `ER_SCORED_PAIRS` | table, accumulates by `run_id` | none |
| parity sample | query only | `AI_SIMILARITY` on 20 pairs, billed under `AI_EMBED` |

Before section 2, run section 1 and report: records to embed, estimated input tokens, and the largest
single-record token count. Embedding has no output tokens, so this estimate is close to the bill. On a
re-run after a template change, every record is re-embedded — say so before confirming.

## Why stored vectors, not `AI_SIMILARITY`, over pairs

`AI_SIMILARITY(text_a, text_b)` returns the cosine similarity of the two inputs' embeddings, billed as
`AI_EMBED`. Over a pair table, each call embeds both texts, so a record appearing in many pairs is
embedded many times — and the same work is repeated on every run. Embedding each record once into
`ER_RECORD_EMBEDDINGS` and comparing with `VECTOR_COSINE_SIMILARITY` makes the embedding cost
proportional to records, not pairs, and makes re-scoring with new thresholds free.

`AI_SIMILARITY` still has two jobs here:

- **Parity check (section 4).** On 20 pairs, compare the stored-vector cosine with `AI_SIMILARITY`
  using the same model. They should agree within floating-point tolerance (the vector function is
  documented with a margin of error up to `1e-4`). A material difference means the stored vectors are
  stale or were built from different text — find out why before scoring.
- **Ad hoc probes.** "How similar are these two names under this model" questions during calibration,
  where a handful of calls is cheaper than wiring up stored vectors.

### Model and dimension

Default `snowflake-arctic-embed-l-v2.0`, which the vector-embeddings reference lists as 1024
dimensions and a 512-token input; the `-m` variants are 768 dimensions. `embed.dimensions` must match
the model or the `VECTOR(FLOAT, n)` cast fails. For multilingual master data (names in several scripts
or languages), evaluate `voyage-multilingual-2` or `multilingual-e5-large` — and treat a model change
as a new experiment, since every vector must be rebuilt (rule 12).

Preflight confirms the chosen model is available in the region or via cross-region inference. Do not
assume.

## Semantic KNN blocking

Section 3 adds the top `blocking.semantic_knn_k` cosine neighbours per record within entity type and
country as candidate pairs tagged `SEMANTIC_KNN`. This catches variation the lexical keys miss — word
order, synonyms, reformatting that changes the first token. It is a vector computation, not an AI
call, but it is quadratic within each partition. At sandbox scale it is trivial; for partitions in the
hundreds of thousands, partition further (first core-token letter, region) and tell the user the
partitioning is a recall tradeoff.

After this pass, re-run the pair-completeness query from `evaluate-match-accuracy`. The difference from
the Phase 2 figure is what semantic blocking bought.

## Features

| Feature | Definition | Notes |
|---|---|---|
| `cos_sim` | stored-vector cosine | from the configured model and template only |
| `name_jw`, `core_jw` | `JAROWINKLER_SIMILARITY / 100` on `name_norm`, `name_core` | 0-100 scaled to 0-1 (rule 17) |
| `addr_jw` | Jaro-Winkler on `address_key` | NULL when either side is missing |
| `city_eq`, `postal_eq`, `phone_eq` | exact equality | NULL when either side is missing |
| `domain_eq` | any overlap of email and website domains | free-mail already removed in Phase 2 |
| `tax_rel`, `gtin_rel`, `mpn_rel`, `size_rel` | `SAME` / `DIFFERENT` / `MISSING` | size equal within 0.6 oz |
| `brand_eq` | exact brand equality | products |
| `token_substitution` | each side has a core token the other lacks | sibling-risk signal (rule 15) |

**Missing is not different.** Every feature is NULL (or `MISSING`) when either side lacks the
attribute, and the composite is a weighted mean over the features that are present. A record with no
phone is not penalized for not matching a phone.

## Rules before thresholds

In order:

1. **Cannot-link** (rule 16): different valid tax ids (parties); different GTIN, size, or MPN
   (products). Band `AUTO_REJECT`, source `CANNOT_LINK`. If the user prefers to see these, change the
   band to `REVIEW` — but never to `AUTO_MATCH`. Cannot-link flags are carried into clustering.
2. **Positive rules**: same tax id (parties); same GTIN without a size conflict (products). Band
   `AUTO_MATCH`, source `RULE`.

   Confirm the tax-id rule with the user. In most vendor masters, one tax id is one legal payee and the
   rule is correct. In some, a parent's tax id is entered on subsidiary vendor records, or a tax id is
   reused across divisions of one legal entity that are still managed as separate vendors. If that is
   the case here, demote the rule to a strong feature and let the score decide.
3. **Score bands** on `composite_score`: `>= auto_match` is `AUTO_MATCH` **only if** there is no token
   substitution (or core names are near-identical); `< auto_reject` is `AUTO_REJECT`; everything else
   is `REVIEW`.

The substitution guard is what stops `Harlow Ridge Logistics` and `Harlow Ridge Holdings` — same city,
same domain, high cosine, no tax ids on the customer side — from auto-merging on score. They go to the
model, which is shown that the distinguishing word differs and is asked for the relationship.

## Weights and thresholds are starting points

The weights in the template and the default thresholds (`auto_match: 0.92`, `auto_reject: 0.55`) are
placeholders that make the first run produce a sensible band distribution. They are not calibrated
values. `evaluate-match-accuracy` sweeps both thresholds on a calibration split of the labeled data
and reports the precision of the `AUTO_MATCH` band, the recall lost in the `AUTO_REJECT` band, and the
review-band size at each setting. Write the chosen values back with a new `experiment_id` and re-run
section 5 only — it is free, because no AI call depends on the thresholds.

Do not import thresholds from other engagements or documentation (rule 14).

## Gate verification

From section 6 of the template:

- records without a current embedding — must be zero
- band distribution by entity type and band source
- contract checks — NULL bands, NULL scores, `AUTO_MATCH` with cannot-link, pairs missing cosine — all
  zero
- excluded-field labels in `embed_text` — must be zero (rule 36)
- score histogram per entity type — look for separation, and say plainly if there is none
- review-band size per entity type — this is the Phase 4 call count

If the review band is a large share of candidate pairs, the score is not separating well. Look at
calibration first, then at which features are mostly NULL in this data, before accepting a large
adjudication bill.

Write `phases.score: done` and the created objects.

## Incremental behaviour

On later runs only new or changed records are embedded (the `MERGE` source is restricted to rows whose
`(record_uid, model, template, text hash)` has no current vector). Pairs are rescored in full, because
a changed record changes every pair it is in, and rescoring is a vector and string computation with no
AI cost. `publish-entity-resolution` covers scheduling.
