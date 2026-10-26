---
name: seed-entity-resolution-sandbox
description: "Generate synthetic customer, vendor and product master records across several fictional source systems with planted duplicates and a quarantined, labeled answer key, so an entity resolution pipeline can be built, demonstrated, calibrated and accuracy-tested before touching real PII. Plants easy, medium and hard duplicate variations (suffix spellings, abbreviations, typos, address and phone reformatting, missing fields, relocation with shared tax id, acronym names), hard negatives (same-city sibling companies sharing a corporate domain, franchise locations, product size variants with different GTINs), cross-type organizations that are both customer and vendor, free-mail contacts, blocked vendors, and a fabricated bank field to exercise the excluded-from-AI control. Deterministic and reproducible. Phase 1 of the entity-resolution build."
parent_skill: entity-resolution
---

# Seed the sandbox

Generate synthetic master data with **ground truth**: every source record is labeled with the true
entity it belongs to. That is what lets the accuracy harness report blocking recall, pairwise
precision and recall, and cluster precision and recall on day one, and what makes threshold
calibration a measurement instead of a guess.

## Why not just point at real master data

You can — Phase 1 is skippable. Be honest about what is lost: real master data has no ground truth.
Without labels the only signal is stewards rejecting proposed merges, which measures precision on what
was proposed and says nothing about duplicates that were never proposed. Blocking recall in particular
is unmeasurable, and blocking is where most duplicates are lost.

The intended path is sandbox first, then real data with a steward-labeled sample built by
`evaluate-match-accuracy` (stratified by score band, so the sample covers the boundary rather than the
easy cases).

## Configure before generating

Ask, default sensibly, and write into `er-project.yml`.

| Parameter | Default | Notes |
|---|---|---|
| `{{PARTY_ENTITIES}}` | 1500 | True organizations. Must be at least 1200 so the sibling construction (stems that repeat every 600 entities) produces siblings; at most 7200 (name pool size). Yields roughly 2.3 source records per entity. |
| `{{PRODUCT_BASES}}` | 150 | Base products; each gets 12, 16 and 32 oz variants, so 450 true products and roughly 900 source records. |
| `{{SCHEMA}}` | `target.schema` | Synthetic source tables. The pipeline reads these. |
| `{{EVAL_SCHEMA}}` | `target.eval_schema` | Ground truth. The pipeline never reads this schema. |

At the defaults the corpus is small enough that embedding every record is a modest, bounded call
count. Show the actual count with `AI_COUNT_TOKENS` at the score gate, not here — this phase makes no AI
calls.

## What gets created

| Object | Schema | Purpose |
|---|---|---|
| `SYNTH_CRM_ACCOUNTS` | pipeline | Customers. CRM layout: separate address fields, website. |
| `SYNTH_BILLING_CUSTOMERS` | pipeline | Customers. Upper-cased names, contact email, tax registration. |
| `SYNTH_ECOM_ACCOUNTS` | pipeline | Customers. Single-line address, lower-case uuid-style ids. |
| `SYNTH_ERP_VENDORS` | pipeline | Vendors for two ERP company codes, 35-character name field with overflow to `name_2`, tax number, `blocked_flag`, fabricated `bank_account_last4`. |
| `SYNTH_P2P_SUPPLIERS` | pipeline | Vendors from a procurement platform. Single-line address, email domain, tax id. |
| `SYNTH_PIM_PRODUCTS` | pipeline | Products with clean titles and GTINs. |
| `SYNTH_ERP_ITEMS` | pipeline | Products with abbreviated upper-case 40-character descriptions, MPN sometimes without dashes, no GTIN. |
| `SYNTH_SUPPLIER_CATALOG` | pipeline | Products with metric sizes on hard copies (12 oz as 355 ml), lower-case MPN, partial GTIN. |
| `SYNTH_GEO`, `SYNTH_TRUE_ENTITIES`, `SYNTH_COPIES`, `SYNTH_COPY_VALUES`, `SYNTH_TRUE_PRODUCTS`, `SYNTH_PRODUCT_COPIES` | eval | Generator internals and truth. |
| `SYNTH_ER_ANSWER_KEY` | eval | One row per source record: `record_uid`, `entity_type`, `true_entity_id`, `case_role`, `difficulty`. |
| `SYNTH_ER_ANSWER_KEY_WITHIN_TYPE` | eval | View that splits cross-type organizations into a customer entity and a vendor entity, which is what within-type resolution should produce. |

`sql/01_seed_sandbox.sql` is the template. Substitute the placeholders and run it as one script. It
uses `CREATE OR REPLACE`, so re-running regenerates an identical corpus — generation is driven by
`HASH` of stable inputs, not `RANDOM()`.

## What is planted, and what each plant tests

### Duplicate variations (positives)

| Recipe | Difficulty | Variation | Tests |
|---|---|---|---|
| 0 | EASY | verbatim, upper-cased | case normalization |
| 1 | EASY | legal suffix spelled differently (`Inc` / `Incorporated`, `LLC` / `L.L.C.`) | legal-suffix token map |
| 2 | MEDIUM | industry abbreviated (`Mfg`, `Svcs`, `Dist`, `Tech`, `Logistics & Freight`) | abbreviation map, embedding robustness |
| 3 | MEDIUM | one-character typo | phonetic and prefix blocking, Jaro-Winkler |
| 4 | EASY | suffix dropped, trailing comma, `The` prefix | stopword handling |
| 5 | MEDIUM | `St`, `Ave`, `Ste 210`, ZIP+4, reformatted phone | address and phone normalization |
| 6 | MEDIUM | phone and tax id missing, lower-case | NULL-safe serialization (rule 1), missing-evidence handling |
| 7 | HARD | typo plus abbreviation plus postal missing | multi-pass blocking (prefix plus postal alone fails) |
| 90 | HARD | **MOVED**: new city, address and phone; `Industries` becomes `Group`; same tax id | tax-id blocking and the tax-id match rule; name and address keys all fail |
| 91 | HARD | **ACRONYM**: name reduced to initials; same phone and domain | phone and domain blocking; embeddings fail |

### Hard negatives (must not merge)

- **SIBLING** — shares the first two name words, the city, and the corporate web domain with another
  true entity, with a different industry word and a different tax id. Tests rule 15 and rule 16: the
  model must see `tax_id: different` and the relationship field should say `PARENT_SUBSIDIARY` or
  `SIBLING_LOCATION`, not `SAME_ENTITY`.
- **FRANCHISE** — identical trading name to another entity, different city, phone, domain and tax id.
  Tests that name similarity alone does not merge.
- **SIZE_VARIANT** — products identical except size, with different GTIN and MPN. Tests that the
  product cannot-link rule fires and that the model is shown size explicitly.

### Cross-type and operational traps

- **BOTH_TYPES** — an organization present as a customer and as a vendor. With
  `scope.cross_type_party: false` (default) these must **not** merge across type; the within-type view
  of the answer key encodes that. With it true, `evaluate-match-accuracy` evaluates the party link
  separately.
- **Free-mail contacts** (`@freemail.example`) on about one in five records. A blocking key on email
  domain that does not exclude free-mail domains creates a giant block.
- **Blocked vendors** (`blocked_flag = 'X'`) — tests the per-source status filter.
- **`bank_account_last4`** — fabricated. Must be listed in `excluded_from_ai` at preflight and must never
  appear in `embed_text` or a prompt. The verification in `score-candidate-pairs` checks this.
- **Truncated ERP names** — the 35-character name field pushes long names into `name_2`; the column map
  must concatenate them.

## The answer key is quarantined

- It lives in `eval_schema`. No pipeline query joins it; only `evaluate-match-accuracy` reads it.
- It is never in a prompt, an embedding, or a semantic view.
- Source record ids are salted hashes, so no identifier reveals which records share an entity. Keep that
  property if you extend the generator — an id derived from the entity id lets blocking and the model
  match on the id itself, and every metric becomes meaningless.

## Verification before declaring the phase done

Run `sql/02_verify_seed.sql` and show the results. Each block names what it catches:

1. records per system and type — every system populated
2. true cluster-size distribution — clusters of size 3+ exist, so transitive clustering is tested
3. true pair count by difficulty — the recall denominator, with a non-empty HARD slice
4. entities by case role — hard negatives and hard positives exist
5. sibling collisions on name stem and city with different tax ids — the over-merge slice is real
6. leakage guard — zero source ids containing entity id fragments
7. uid round trip — every answer-key `record_uid` resolves to exactly one source row using the
   standardize phase's construction; zero orphans either way
8. free-mail share — the blocking-key hygiene trap is present
9. three distinct GTINs per base product
10. blocked vendor count — the status filter is testable

Then write `phases.seed: done` and add every created object to `created_objects`.

## Keep it synthetic, and keep it obviously synthetic

- Names are combinations of invented words; cities are invented; domains use `.example`; phones use the
  555 exchange; tax ids carry `SYN-`; GTIN-like values start `0099` and are not valid GTINs.
- Do not model the corpus on a specific customer's systems. The system names here are generic; the
  customer's real systems arrive through preflight.
- Product and industry vocabulary is generic on purpose. Do not add real brand names.

## Teardown

Drop the sandbox once real data is wired in; otherwise synthetic golden records sit alongside real ones
and eventually get queried by accident. Drop exactly what `created_objects` lists.
