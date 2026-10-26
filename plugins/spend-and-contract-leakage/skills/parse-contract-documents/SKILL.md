---
name: parse-contract-documents
description: "Phase 2 of the spend-and-contract-leakage build. Turns contracts already in Snowflake (text in a CLM export table, PDFs and scans on a stage, or both) into a page-level text table and a document registry: AI_PARSE_DOCUMENT in LAYOUT mode with page_split for files, content-hash caching so unchanged contracts are never reparsed, AI_CLASSIFY into master agreement, amendment, order form or SOW, and non-commercial, exact and near-duplicate detection (hash, then AI_SIMILARITY confirmed by agreement number), AI_EXTRACT of document identity (agreement number, parent agreement, counterparty, effective date), contract families that link amendments to the agreement they amend, and deterministic vendor linking by CLM id then normalized legal name. Triggers: parse the contracts, OCR the PDFs, register contracts, find duplicate contracts, link amendments, which supplier is this contract for, re-parse."
parent_skill: spend-and-contract-leakage
---

# Parse and register contracts

Everything downstream assumes three facts this phase establishes: what each document **is**, which
**agreement family** it belongs to, and which **supplier** it is with. Get any of them wrong and the
pipeline runs cleanly and reconciles invoices against a superseded rate, a duplicate, an NDA, or
another supplier's contract.

Prerequisites: `phases.preflight: done`. Read `spend-leakage-best-practices` rules 3, 10, 17, 22 and
23 before running.

## What gets created

| Object | Kind | Holds |
|---|---|---|
| `STG_CONTRACT_DOCUMENTS`, `STG_VENDORS`, `STG_PURCHASE_ORDERS`, `STG_INVOICE_LINES` | views | canonical column names over the customer's tables (or the `SYNTH_*` sandbox tables) |
| `NORMALIZE_PARTY_NAME` | SQL UDF | legal-name normalization for vendor linking |
| `CONTRACT_PAGES` | table | one row per document page, with parse source, char count and parse error |
| `CONTRACT_REGISTRY` | table | one row per document: class, identity, duplicate status, family, vendor link |

SQL: `sql/01_staging_views.sql`, then `sql/02_parse_and_register.sql`. Both use placeholders from
`spend-leakage-project.yml`; substitute every one before running.

## The gate

State the objects above, then the cost in the units the functions bill in:

- **Files.** `AI_PARSE_DOCUMENT` bills per page. Report the page count from preflight for documents
  routed to `FILE` and not already in `CONTRACT_PAGES` with the same `content_md5`:

  ```sql
  SELECT COUNT(*) AS documents, SUM(page_count) AS pages_to_parse
  FROM STG_CONTRACT_DOCUMENTS d
  WHERE NOT EXISTS (SELECT 1 FROM CONTRACT_PAGES p
                    WHERE p.document_id = d.document_id AND p.content_md5 = d.content_md5);
  ```

  (On the first run `CONTRACT_PAGES` does not exist; drop the `NOT EXISTS`.)

- **Classification and identity.** `AI_CLASSIFY` reads the first 6,000 characters; `AI_EXTRACT`
  reads the first page, capped at 8,000 characters. Estimate tokens on a sample:

  ```sql
  SELECT SUM(AI_COUNT_TOKENS('ai_classify', LEFT(document_text, 6000))) AS classify_input_tokens
  FROM STG_CONTRACT_DOCUMENTS;
  ```

  If `AI_COUNT_TOKENS` does not accept the function name in this account, report character counts
  divided by four as a labelled approximation, not as a measurement.

- **Near-duplicate checks.** `AI_SIMILARITY` runs only on candidate pairs (same vendor, class and
  agreement number). On most corpora that is a handful of pairs.

Say that output tokens bill on top, never convert to currency, and confirm with `ask_user_question`.

## Why each design choice

### LAYOUT mode, page split

Rate cards are tables. `OCR` mode returns text in reading order, which flattens a four-column rate
table into a run of numbers whose association with item codes is then a guess. `LAYOUT` returns
Markdown with tables preserved, which is what the table extraction in Phase 3 reads. `page_split`
gives every term a page to cite and keeps long documents within the function's limits
(`AI_PARSE_DOCUMENT` accepts up to 2,000 pages and 100 MB; `AI_EXTRACT` on a file only 125 pages,
which is why extraction always runs on parsed text, not on the file).

### Content-hash caching

CLMs re-upload the same file under new ids and names. `content_md5` (the stage directory table's
`MD5` for files, `MD5(document_text)` for text) keys the cache: a document whose hash is already in
`CONTRACT_PAGES` is not reparsed. Reparsing unchanged documents is the most common reason a
leakage pipeline's cost doubles month over month.

### Failures are rows, not absences

`return_error_details => TRUE` makes `AI_PARSE_DOCUMENT` return `{value, error, metadata}` instead
of a bare NULL. A failed file gets a page row with `page_index = -1` and the error, so it appears in
verification as a failure to explain rather than as a contract that does not exist. Common causes:
`SNOWFLAKE_FULL` stage encryption, a password-protected PDF, a file over 100 MB. A signature page
with no text is a `LOW_TEXT_PAGE`, which is normal and not retried.

### Classification before anything commercial

The five classes are deliberately coarse; the only decision they drive is whether a document can
carry commercial terms (rule 17). If the customer's CLM already has a reliable document-type field,
compare it with the classifier on a sample, and if they agree, use the field and skip
`AI_CLASSIFY` — say so, and keep the field's value in `doc_class_raw` for audit.

Adjust labels to the customer's vocabulary (for example, splitting `ORDER_FORM_OR_SOW` into
`SOW` and `PURCHASE_AGREEMENT`) only if Phase 3 treats the new classes differently. Each added label
dilutes the classifier; keep the list well under twenty, as the function documentation advises.

### Deduplication: hash first, similarity only to confirm

Exact duplicates are found by hashing whitespace-collapsed, uppercased text. The earliest upload is
canonical; later copies are `DUPLICATE` and inherit the canonical copy's identity. The model calls
in step 3 run only on canonical documents.

Near duplicates — the same contract rescanned, with OCR noise — are pairs that share vendor, class
**and extracted agreement number** and exceed `parse.near_duplicate_similarity` on their opening
text. The agreement-number condition is essential: two consecutive annual SOWs from one supplier
are near-identical text and are different contracts. If a customer's contracts frequently lack
numbers, the near-duplicate check should require identical effective dates instead, and the
threshold should be validated on a reviewed sample before being trusted.

### Identity: four questions, first page

`AI_EXTRACT` reads the first page for the agreement number, the agreement it amends or is issued
under, the counterparty and the effective date. Each question demands `NOT_STATED` when absent, so a
NULL is a failure (rule 16). The buyer's own legal name is excluded in the counterparty question;
otherwise the extractor sometimes returns the customer as the counterparty, and every contract links
to no vendor.

### Families

A **governing** document is a canonical master agreement or order form/SOW. Its family id is its
agreement number, so the family id is human-readable and matches what procurement calls the
contract. An amendment joins the family of the agreement it names in `parent_agreement_number`. An
amendment whose parent cannot be found is an `ORPHAN_AMENDMENT`: it is reported and drives nothing,
because applying an amendment to the wrong agreement is worse than missing it.

Order forms issued under unnumbered terms (Fabrikam's "issued under the Fabrikam Cloud Subscription
Terms") are their own family. If the customer's practice is that many order forms share one master,
add the master as the family and the order forms as members — but only after confirming with
procurement which document governs price when they conflict.

### Vendor linking

Rule 10, in order: CLM vendor id that resolves in the vendor master; normalized legal name equal to
the normalized ERP name, with exactly one match; Jaro-Winkler at or above `vendor_name_jw_min` with
exactly one candidate (flagged `NAME_FUZZY` for review); otherwise unlinked. `AI_SIMILARITY` is not
used for names — embeddings put sibling legal entities next to each other.

`NORMALIZE_PARTY_NAME` drops dots and commas first, so `G.m.b.H.` becomes `GMBH`, then strips
legal-form suffixes. Extend the suffix list for the customer's jurisdictions (for example `KK`,
`OY`, `AB`, `SPZOO`), and check the result on the vendor master before relying on it:

```sql
SELECT NORMALIZE_PARTY_NAME(vendor_name) AS n, COUNT(*) AS vendors, ARRAY_AGG(vendor_id) AS ids
FROM STG_VENDORS GROUP BY 1 HAVING COUNT(*) > 1;
```

Any row returned is two ERP vendors that normalize to the same name. Name-based links to either are
ambiguous and the exact-match branch correctly refuses them; tell the user, because it usually means
duplicate vendor records, which is its own procurement finding.

## Running on files: the rendered corpus

On the sandbox, `{{PARSE_SOURCE}} = TEXT` reads `document_text`. After `build-contract-test-corpus`
has rendered the same contracts to PDFs and scans, rerun with `FILE` and a new `experiment_id`.
The answer key does not change, so the difference in Phase 5 between the two experiments is exactly
the cost of parsing: OCR noise in quotes, tables that did not survive, scanned signature pages.

## Verification at the gate

Run V1 to V6 at the end of `02_parse_and_register.sql` and show the results. On the sandbox:

| Check | Expected |
|---|---|
| V1 class and role | 7 `GOVERNING` (5 master, 2 order form/SOW), 1 `AMENDMENT`, 1 `DUPLICATE`, 1 `EXCLUDED_NON_COMMERCIAL` |
| V2 parse errors | none on text; on the rendered corpus, `LOW_TEXT_PAGE` only on signature pages |
| V3 governing per family | zero rows |
| V4 families | 7 families named by agreement number; `SYN-DOC-C001-A1` in `SYN-MSA-1001`; `SYN-DOC-C008` linked to `SYN-V008` by `NAME_NORMALIZED` |
| V5 AI failures | zero rows |
| V6 unlinked governing | zero rows |

On customer data, there is no expected value — report the distributions, and explain every V2, V5
and V6 row before marking the phase done.

Then write `phases.parse: done` and add every created object to `created_objects`.

## Re-running

- **New documents arrived:** rerun as is; the cache skips unchanged documents, and the registry is
  rebuilt over the whole population because duplicates and families are set-based.
- **Classifier labels or identity questions changed:** bump `prompt_version`, and delete the
  registry; pages stay cached.
- **Parse mode changed:** delete `CONTRACT_PAGES` rows for the affected documents, or the cache will
  keep the old parse.
