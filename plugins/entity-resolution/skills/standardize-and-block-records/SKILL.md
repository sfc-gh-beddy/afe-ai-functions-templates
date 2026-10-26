---
name: standardize-and-block-records
description: "Phase 2 of the entity-resolution build. Maps every in-scope source table into one canonical record shape with a fixed record_uid, normalizes names at the token level through an inspectable token map (legal suffixes, abbreviations, stopwords), normalizes addresses, postal codes, phones, email and web domains, tax ids, MPNs, GTINs and product sizes (including metric to ounce), excludes placeholder values and free-mail domains, builds NULL-safe embedding text, then generates candidate pairs from several independent blocking passes with block-size caps, canonical pair ordering, per-rule contribution, and reduction-ratio reporting. No AI calls. Use when standardizing master data, building blocking keys, generating candidate pairs, or diagnosing missed duplicates caused by blocking."
parent_skill: entity-resolution
---

# Standardize and block

Two jobs, both without AI: turn heterogeneous source rows into one canonical record per source row,
and decide which pairs of records are worth comparing at all. Everything downstream — embeddings,
scores, model decisions, clusters — can only work on the pairs this phase emits. A duplicate pair that
is not generated here is lost for good, silently.

`sql/01_standardize_and_block.sql` is the template, written against the sandbox tables.
`sql/02_verify_blocking.sql` is the gate verification.

## Gate: what this phase creates

| Object | Type | Notes |
|---|---|---|
| `ER_TOKEN_MAP` | table | Token normalization rules, editable |
| `ER_FREE_EMAIL_DOMAINS` | table | Domains that are never evidence |
| `ER_SOURCE_STAGING` | table | Mapped union of all in-scope sources |
| `ER_RECORDS` | table | Canonical, normalized records with `embed_text` and `embed_text_hash` |
| `ER_BLOCK_KEYS` | table | One row per record per blocking rule that produced a key |
| `ER_BLOCK_STATS` | table | Block sizes, potential pairs, capped flag |
| `ER_CANDIDATE_PAIRS` | table | Canonical-order pairs with the rules that produced them |
| `ER_PIPELINE_QUALITY_LOG` | table | Created if absent; shared by all phases |

No AI cost. Warehouse cost is dominated by the pair self-join, which is bounded by the block cap.

## Step 1 — source staging from configuration

On the sandbox, section 1 of the template is ready to run. On real data, generate `ER_SOURCE_STAGING`
from `sources` in `er-project.yml`: one `SELECT` per source, every canonical column present (NULL when
unmapped), the source's `filter` applied, `trust_rank` from configuration. Rules while doing so:

- **`record_uid` construction is fixed.** `source_system || ':' || TRIM(source_record_id::VARCHAR)`.
  Do not pad, re-case or re-format the key — the crosswalk must point back to the exact source row.
- **Columns in `excluded_from_ai` are never selected.** They are not needed by any phase. The sandbox
  ERP table's `bank_account_last4` is deliberately left out of the staging select.
- **Split-field overflow.** ERP name fields are often fixed-width with an overflow column; concatenate
  before normalizing, as the sandbox does with `vendor_name || name_2`.
- **Single-line addresses.** When a source stores the whole address in one string, parse what can be
  parsed reliably (street, locality, country) and leave the rest NULL. A wrong city is worse than a
  missing one, because a wrong city builds a wrong block key.
- **Multi-entity sources.** Some systems hold customers and vendors in one partner table with a role
  flag. Map the flag to `entity_type`; a partner flagged as both produces two staged rows only when
  `scope.cross_type_party` is false and both roles are in scope.

Show the user the per-source staged count and the count removed by each `filter` at the gate.

## Step 2 — canonical records

`ER_RECORDS` is the single source of normalized truth (rule 2). The template implements:

| Attribute | Normalization |
|---|---|
| `name_norm` | upper-case, `&` to `AND`, dotted `L.L.C.` to `LLC`, punctuation to space, tokenized, each token mapped through `ER_TOKEN_MAP` (`MFG` to `MANUFACTURING`, `INCORPORATED` to `INC`), re-joined in order |
| `name_core` | `name_norm` with `LEGAL_SUFFIX` and `STOPWORD` tokens removed — the comparison form |
| `address_norm` / `address_key` | token-mapped through the `ADDRESS` domain; `address_key` additionally drops suite and unit designators |
| `postal_norm` | US: first five digits. Elsewhere: upper-case alphanumerics |
| `phone_norm` | digits only, last ten; NULL if shorter or a single repeated digit |
| `email_domain` | lower-case domain; NULL when in `ER_FREE_EMAIL_DOMAINS` |
| `website_domain` | protocol, `www.` and path stripped |
| `tax_id_norm` | upper-case alphanumerics; NULL for short values, all-zero values, and `NA` / `NONE` / `UNKNOWN` / `TBD` / `PENDING` |
| `mpn_norm`, `gtin_norm` | alphanumerics; GTIN left-padded to 14 digits |
| `size_oz` | parsed from text: `12 oz`, `12OZ`, `12-Ounce`, and `355 ml` converted to ounces |
| `embed_text` | labeled, NULL-safe `ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(...))` of identity attributes only |

### Extend the token map from the customer's own data

The shipped token map is a starting point. Before committing it on real data, find the most frequent
name tokens and review them with the user:

```sql
SELECT f.value::STRING AS token, COUNT(*) AS records
FROM ER_RECORDS, LATERAL FLATTEN(input => SPLIT(name_norm, ' ')) f
GROUP BY 1
ORDER BY 2 DESC
LIMIT 60;
```

High-frequency tokens that carry no identity (`GROUP`, `HOLDINGS`, `SERVICES`, regional words, the
customer's own industry vocabulary) are candidates for `STOPWORD` — but only for `name_core` and
blocking. Be careful: `HOLDINGS` versus `LOGISTICS` is exactly what distinguishes two sibling companies,
so a token that is noise for blocking can still be signal for scoring. The scorer reads `name_norm`,
which keeps every token; only blocking keys use `name_core`.

### Embedding text: what goes in, what stays out

Identity-bearing, human-readable attributes only, front-loaded: name, address key, city, region,
country for parties; product name, brand, size for products. Identifiers (tax id, phone, GTIN, MPN)
stay out — they are compared exactly in SQL, which is more reliable than letting an embedding treat
`SYN1000123` and `SYN1000124` as near-identical strings. Notes and long free text stay out of party
records entirely.

Every element is labeled (`'city: ' || city_norm`), so a NULL attribute drops out of the text together
with its label rather than leaving a dangling `city:`.

## Step 3 — blocking passes

Each pass emits a key only when its inputs are present. Defaults:

| Rule | Key | Catches | Misses |
|---|---|---|---|
| `NAME_PREFIX_POSTAL` | first 4 chars of first core token + first 3 of postal | typical duplicates | typo in first 4 chars, missing postal |
| `NAME_SOUNDEX_CITY` | Soundex of first core token + city | typos, spelling variants | missing city, rebrands |
| `NAME_CORE_2TOK_COUNTRY` | first two core tokens + country | missing postal and city | first-token typos |
| `TAX_ID` | exact normalized tax id | relocations, rebrands, acronyms | records without a tax id |
| `PHONE` | exact ten digits | acronyms, abbreviations | reformatted beyond digits, moved |
| `EMAIL_DOMAIN` | exact non-free domain | acronyms, abbreviations | free-mail contacts |
| `WEBSITE_DOMAIN` | exact domain | as above | |
| `PRODUCT_BRAND_TYPE` | brand (or first token) + product noun | description rewrites | missing brand and noun |
| `PRODUCT_MPN` | exact normalized MPN | abbreviated descriptions | missing MPN |
| `PRODUCT_GTIN` | exact GTIN | everything with a GTIN | missing GTIN |
| `SEMANTIC_KNN` | added in Phase 3 — top-K cosine neighbours within type and country | word-order and synonym variation | — |

Note that tax id, phone and domain blocks deliberately **include** siblings sharing a corporate domain
or switchboard — that is correct. Blocking is for recall; telling siblings apart is scoring's and
adjudication's job.

**The `PRODUCT_BRAND_TYPE` noun list in the template is sandbox vocabulary.** On real data replace it
with a category column, or with nouns taken from the customer's own top product tokens.

### The block cap

Blocks larger than `blocking.max_block_size` are marked `is_capped` and excluded from pair generation,
and every capped block is listed at the gate. Large blocks are almost always a placeholder or a
too-common token; the fix is to add the value to the placeholder exclusions or the token to the
stopword list, then regenerate — not to raise the cap until the pair count explodes.

## Step 4 — candidate pairs

Self-join of block keys within uncapped blocks, `record_uid_a < record_uid_b`, same `entity_type`,
deduplicated across rules with `block_rules` as an array. `pair_id` is a hash of the ordered uid pair,
stable across runs, so scores and decisions from different experiments join on it.

## Gate verification

Run `sql/02_verify_blocking.sql` and show:

1. staged versus canonical counts per source, zero duplicate uids
2. normalization failures — empty `name_norm`, `name_core`, `embed_text` (investigate any)
3. attribute fill rates per source — tells you which rules can contribute
4. top values of every exact-match key — placeholders show up here
5. capped blocks — what was not compared
6. self-pairs, non-canonical order, duplicate pairs — all zero
7. cross-type pairs — zero unless cross-type linking was requested
8. reduction ratio and candidates per record per entity type
9. per-rule contribution, including pairs produced only by that rule
10. records with no candidate pair, and records with no block key at all

**On the sandbox, also run the blocking-recall query from `evaluate-match-accuracy` now** (pair
completeness against the answer key, broken down by case role). It costs nothing and it is the moment
to fix blocking — before embeddings and model calls are spent on a pair set that is missing duplicates.
Expect the MOVED and ACRONYM hard positives to be found only by `TAX_ID`, `PHONE` or domain rules; if
they are missing, check those rules' fill rates first.

Write `phases.standardize_block: done` and the created objects to `er-project.yml`.

## dbt mode

`ER_TOKEN_MAP` and `ER_FREE_EMAIL_DOMAINS` become seeds; `ER_SOURCE_STAGING` and `ER_RECORDS` are
`table` models (cheap to rebuild, no AI); block keys, stats and candidate pairs are `table` models.
See `DBT_MATERIALIZATION.md` for tests that make self-pairs, duplicate uids and empty `embed_text`
build-failing.
