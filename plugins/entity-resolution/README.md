# Entity Resolution

A guided build that matches and merges customer, vendor, and product records spread across source
systems into golden records, entirely inside Snowflake, on master data the organization already
stores.

## The problem

Every organization with more than one system of record carries the same entity many times over: a
customer in CRM, again in billing, again in the e-commerce platform; a vendor set up twice in accounts
payable because a second plant onboarded it under a slightly different name; a product listed under
three descriptions by the item master, the PIM, and a supplier catalog. Exact-key joins miss these
because the keys differ and the names drift. That costs in two directions:

- **OpEx.** Duplicate vendors fragment spend, defeat volume pricing, and open the door to duplicate
  payments. Duplicate customer and product records consume data-steward time in manual cleanup, and
  every downstream report built on them is quietly wrong.
- **Revenue.** Without a single customer view, an account that buys one product line from one
  business unit looks unrelated to the same account buying another line elsewhere. Cross-sell and
  account planning run on a fragment of the relationship.

Both close with data already in the account. Nothing needs to be acquired.

## What this plugin builds

```
Source records (CRM, ERP, AP, PIM, catalogs ...)
  -> standardize            canonical record per source row, normalized attributes, serialized text
  -> block                  multi-pass blocking keys -> candidate pairs, with measured pair completeness
  -> score                  stored AI_EMBED vectors + deterministic features -> auto-match / auto-reject / review
  -> adjudicate             AI_COMPLETE structured judgment on the review band only, with reasons
  -> cluster                connected components over accepted matches, with cannot-link and size guards
  -> survive                deterministic per-attribute survivorship with provenance and confidence
  -> golden records         golden table + source-to-golden crosswalk with stable golden ids
```

Every accepted match carries a decision source (rule, score, or model), a score, and — for
model-adjudicated pairs — structured reasons naming the attributes that drove the decision. Every
golden attribute carries the source record it came from and the survivorship rule that chose it, so a
steward can see why the golden record says what it says.

## What it does not build

- **Ingestion.** Source records are assumed landed in Snowflake.
- **Write-back to the source systems.** The pipeline ends at the golden table and crosswalk. Merging
  vendors in the ERP or retiring customer records in CRM is a business process with its own approvals;
  the crosswalk is designed to feed it, not replace it.
- **A steward application.** Review-status columns are defined and defaulted so a review workflow can
  be layered on later without a migration, but nothing here writes them.

## Getting started

Ask for it in plain language. The router picks up phrases like:

- "find duplicate vendors across our ERPs"
- "build a single customer view from CRM and billing"
- "deduplicate our product master"
- "set up entity resolution / record matching / MDM matching"

The build runs in gated phases. Each phase says what it will create, estimates AI token volume before
any AI call over a table, waits for confirmation, runs, and shows a verification query. State lives in
`er-project.yml` in the working directory, so the build can be stopped and resumed.

**Start in the sandbox.** Phase 1 generates synthetic customer, vendor and product records across
several fictional systems with planted duplicates, hard negatives (sibling companies, franchise
locations, product size variants) and a quarantined answer key. The accuracy harness then produces
real pairwise and cluster precision and recall on day one, and thresholds can be calibrated before
anyone grants access to real master data.

There is no document-rendering skill in this play: entity resolution operates on structured and
semi-structured rows, not files, so there is no OCR tier to exercise.

## Skills

| Skill | Role |
|---|---|
| `entity-resolution` | Entry point. Intent detection, phase gating, state file, dbt mapping, diagnosis. |
| `entity-resolution-system-of-record` | Preflight: function access, model and region availability, cross-region setting, source inventory, attribute fill rates, PII posture. |
| `entity-resolution-best-practices` | Correctness rules. Always loaded. |
| `seed-entity-resolution-sandbox` | Synthetic multi-system records with planted duplicates, hard negatives, and a labeled answer key. |
| `standardize-and-block-records` | Canonical records, normalization, multi-pass blocking, candidate pairs, reduction ratio. |
| `score-candidate-pairs` | Stored embeddings, deterministic features, cannot-link rules, three-way banding. |
| `adjudicate-match-pairs` | AI_COMPLETE (or snowflake-decision) on the review band, with structured reasons. |
| `build-golden-records` | Clustering, chaining guards, survivorship, golden ids, crosswalk, confidence. |
| `evaluate-match-accuracy` | Blocking recall, pairwise and cluster precision/recall, threshold calibration, cost per 1K records, parse-failure accounting. |
| `publish-entity-resolution` | Incremental pipeline, semantic view, Cortex Agent for CoWork. |
| `entity-resolution-value-readout` | Applies the shared value model to customer-supplied inputs; POC criteria. |

## Requirements

- A role with Cortex AI function access (`SNOWFLAKE.CORTEX_USER`, or `SNOWFLAKE.CORTEX_EMBED_USER`
  for embeddings only) — preflight verifies this and reports the exact missing grant.
- A warehouse, and a database and schema the role can create objects in.
- An embedding model and an adjudication model available in the account's region, or
  `CORTEX_ENABLED_CROSS_REGION` set — verified at preflight.

## A note on PII and confidential data

Customer and vendor master data carries personal and commercially sensitive information: contact
names, emails, phone numbers, bank details on vendor records. Every AI function call runs inside
Snowflake; record text does not leave the account boundary. Preflight reports existing masking and row
access policies, and the build never sends bank or payment fields to any model — they are not needed to
decide whether two records describe the same entity, and including them only widens exposure.
