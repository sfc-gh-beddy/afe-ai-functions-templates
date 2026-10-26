---
name: seed-intake-sandbox
description: "Generate a synthetic document-intake sandbox with an exact field-level answer key, so the classify/extract/validate pipeline can be built, demonstrated, and accuracy-tested before touching real invoices, contracts, or claims. Creates a vendor master (with locale and bank last-4), purchase orders, a policy register, a counterparty register, posted-invoice history, several hundred invoices rendered from a truth table in each vendor's number and date locale, and hand-authored hard cases (payment-redirection bank change, normalized-number duplicate, byte duplicate, broken line arithmetic, ambiguous dd/mm date, credit note with parenthesized negative, unknown and inactive vendor, PO variance, non-PO invoice, multi-document file, contract, in- and out-of-coverage claims, W-9, out-of-scope newsletter). Writes a document-level key (expected type and decision) and a field-level key (expected value, PRESENT/NOT_PRESENT, posts flag). Phase 1 of the document-intake build."
parent_skill: document-intake
---

# Seed the sandbox

Generate a corpus where the right answer for every field of every document is known. That makes the
evaluation phase report real field accuracy, STP rate, and — the one that matters — **false-STP rate**
on day one, and lets the pipeline be demonstrated before anyone approves access to real AP or claims
documents.

## Why the generator renders from a truth table

The reference pattern for these plays hand-authors a small labeled set. That works for clinical
suspecting, where each case needs bespoke evidence. Intake is different: the interesting variation is
in **formatting** (locales, number styles, PO formats) and in **business rules**, both of which a
generator produces exactly. So:

- **Generated invoices** (default 300) are rendered from `SYN_INVOICE_TRUTH`. The text and the answer
  key both derive from the same row, so the key is exact by construction, and the set is large enough
  that one wrong field moves a rate by a fraction of a point rather than ten points.
- **Hard cases** (16) are hand-authored, each targeting one failure mode a generator would not produce
  naturally. Their keys are hand-written and reviewed.

## Configure before generating

Ask for these; write them to `intake-project.yml` under `corpus`.

| Parameter | Default | Notes |
|---|---|---|
| `N_INVOICES` | 300 | Generated invoices. More is cheap to generate and costs pages to extract — size for the eval budget. |
| `SEED` | 42 | Reproducibility. The same seed regenerates the same corpus. |
| Types in scope | from preflight | Drop hard cases for types not in scope rather than leaving them unlabeled. |
| Schemas | `{{SCHEMA}}` and `{{EVAL_SCHEMA}}` | The answer keys go to the eval schema. |

## What gets created

| Object | Schema | Purpose |
|---|---|---|
| `SYN_VENDOR_MASTER` | sandbox | 8 vendors across US/DE/FR/GB with `number_locale`, `date_locale`, tax ID (digits only), bank last-4 and hash, terms, status (one INACTIVE) |
| `SYN_PURCHASE_ORDERS` | sandbox | One PO per generated invoice slot, stored with leading zeros (`0045001001`) — invoices print them stripped |
| `SYN_POLICIES` | sandbox | 3 policies: two active, one lapsed |
| `SYN_COUNTERPARTIES` | sandbox | Contract counterparty register |
| `SYN_POSTED_INVOICES` | sandbox | Posted history, with normalized invoice numbers, for duplicate detection |
| `SYN_DOCUMENTS` | sandbox | Document text as a digital-born PDF would carry it, plus `file_name`, `channel`, `received_at`, `page_count` |
| `SYN_INVOICE_TRUTH` | **eval** | Typed truth for generated invoices |
| `SYN_DOC_ANSWER_KEY` | **eval** | Expected type, expected decision, expected reason per document |
| `SYN_FIELD_ANSWER_KEY` | **eval** | Expected canonical value, `PRESENT`/`NOT_PRESENT`, `posts` flag per document x field |

`sql/01_seed_sandbox.sql` is the template. Substitute the placeholders, read it, then run it statement
by statement through the gate. Do not run it unmodified.

## The answer keys are quarantined

- They live in `{{EVAL_SCHEMA}}`. The pipeline role should not even have `SELECT` on that schema.
- No pipeline query joins them. Only `evaluate-intake-accuracy` reads them.
- They never appear in an extraction `responseFormat` description, a classifier label description,
  or a few-shot example. A schema question that hard-codes a sandbox vendor name will score perfectly
  in the sandbox and mean nothing.

Note that `SYN_INVOICE_TRUTH` is in the eval schema even though the generator reads it to render text —
the generator runs once, under the seeding role, before the pipeline exists.

## How the key encodes what matters

**`expected_status`.** `NOT_PRESENT` means the field is genuinely absent from the document (no PO on a
non-PO invoice, no police report number on a water-damage claim). A NULL extraction is then *correct*.
Without this column the harness cannot tell a correct NULL from a missed field (best-practices rule 6).

**Canonical values.** Amounts are stored as fixed two-decimal strings (`1463.70`, `-312.00`), dates as
ISO (`2026-04-03`), identifiers as printed. The harness pushes both sides through the pipeline's
normalizers before comparing; the canonical form is what a correct normalization produces.

**`posts`.** `TRUE` marks fields a downstream system consumes (amounts, dates, invoice number, vendor,
currency, PO, policy number). A wrong value in a posting field on an `AUTO_APPROVED` document is a
false STP. A wrong `payment_terms` string on an approved invoice is a data-quality miss, not a wrong
posting.

**Decision and reason.** The document key records the expected decision and the rule that should fire.
The harness checks both: an exception for the *wrong* reason (for example, H01 flagged for low score
instead of `VENDOR_BANK_MATCH`) means the right outcome happened by accident.

## The hard cases and what each one tests

| Case | Tests | Expected |
|---|---|---|
| H01 bank change | remittance account differs from vendor master — the payment-redirection signature | `EXCEPTION` / `VENDOR_BANK_MATCH` |
| H02 duplicate, renumbered | `0010000` vs posted `INV-010000`, same vendor — normalized business duplicate | `EXCEPTION` / `DUP_VENDOR_INVOICE` |
| H03 bad arithmetic | lines sum to 1,950.00, subtotal printed 1,590.00 — high scores, wrong document | `EXCEPTION` / `LINES_SUM_TO_SUBTOTAL` |
| H04 ambiguous date | `03.04.2026` from a DMY vendor — resolvable only through vendor locale | `AUTO_APPROVED` with `2026-04-03`, or `EXCEPTION` if locale is not wired; **never** `2026-03-04` |
| H05 credit note | parenthesized negative, separate type | type `credit_note`, total `-312.00` |
| H06 unknown vendor | not in master | `EXCEPTION` / `VENDOR_MATCH` |
| H07 PO variance | PO exists for the vendor, invoice total far above it | `EXCEPTION` / `PO_AMOUNT_TOLERANCE` |
| H08 inactive vendor | vendor status INACTIVE | `EXCEPTION` / `VENDOR_ACTIVE` |
| H09 non-PO clean | missing PO is `NOT_PRESENT`, must not block | `AUTO_APPROVED` |
| H10 multi-document | invoice plus packing slip in one file | `EXCEPTION` / `MULTI_DOCUMENT` |
| H11 contract | contains amounts but is not an invoice; typed contract fields | type `contract`, `AUTO_APPROVED` |
| H12 claim, covered | loss date within active policy | `AUTO_APPROVED` |
| H13 claim, lapsed | policy lapsed before loss date | `EXCEPTION` / `POLICY_COVERS_LOSS` |
| H14 W-9 | tax form; TIN must match master and be masked downstream | `AUTO_APPROVED` |
| H15 newsletter | out of scope; must not be forced into a type | `REJECTED` / `OUT_OF_SCOPE` |
| H16 byte duplicate | identical file content to a generated invoice | `REJECTED` / `DUP_FILE_HASH` |

Plus `SYN-DOC-000001`: a generated invoice that is already in posted history, so it is expected as
`EXCEPTION` / `DUP_VENDOR_INVOICE`. That is deliberate — it tests that history is consulted, not just
the current batch.

## Formatting variety that the generator guarantees

- Two number locales (`1,463.70` and `1.463,70`) and three date locales (`MM/DD/YYYY`, `DD.MM.YYYY`,
  ISO). Verification 6.5 confirms every combination exists, and 6.6 confirms there are generated
  invoices whose day is 12 or less under a numeric-date locale — every one of which is ambiguous
  without the vendor's locale.
- Four invoice-number styles (`INV-010004`, `0010005`, `A10006`, `#10007`) to exercise document-number
  normalization.
- PO numbers stored with leading zeros, printed without.
- Tax IDs stored digits-only, printed with a hyphen.
- Three tax regimes (US sales tax rate, DE 19 percent, FR and GB 20 percent).

## Verification before declaring the phase done

The SQL file ends with seven checks. Run them and show results. What each catches:

| Check | Catches |
|---|---|
| 6.1 key/doc coverage | a document with no expected outcome, which silently drops out of STP |
| 6.2 truth arithmetic | a generator bug that would make correct extractions fail arithmetic rules |
| 6.3 printed-verbatim check | renderer/key drift: the key says one thing, the document prints another |
| 6.4 decision mix | a key with no exceptions or no rejects cannot measure false STP or over-rejection |
| 6.5 locale coverage | normalization untested on one convention |
| 6.6 ambiguous dates exist | the dd/mm trap untested |
| 6.7 duplicate controls | duplicate rules untestable |

Then set `phases.seed: done`, record created objects, and record `corpus.sandbox_docs`.

## What the sandbox cannot tell you

- **It is text, not files.** `SYN_DOCUMENTS.document_text` is what a clean digital PDF would carry. It
  exercises classification and text-input extraction. It does **not** exercise file-input
  `AI_EXTRACT`, page metering, OCR on scans, or layout. Run `build-intake-test-corpus` to render these
  same rows into PDFs and scans; the field key carries over unchanged because the content is identical.
- **Synthetic vendors are tidier than real ones.** Real invoices have logos, multi-page line tables,
  handwritten annotations, stamps ("PAID", "RECEIVED"), and remittance stubs. Sandbox accuracy
  demonstrates the pipeline is wired correctly; it does not forecast production accuracy. A keyed
  sample of real documents does that (see `evaluate-intake-accuracy`).
- **The hard-case keys are hand-authored.** If the pipeline consistently disagrees with one, check the
  key before changing the pipeline, and record which was wrong.

## Keep it obviously synthetic

- Every identifier starts with `SYN-`; party names are fabricated; addresses use "Synthetic Lane" and
  `ZZ 00000`; tax IDs are in an obviously fake `90-0000xxx` range; bank details are last-4 only.
- The W-9 is labelled `(SYNTHETIC SAMPLE)` in its text.
- Never load sandbox rows into a schema that holds real documents. Teardown drops exactly the objects
  in `created_objects`.
