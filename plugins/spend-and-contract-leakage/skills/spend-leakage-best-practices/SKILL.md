---
name: spend-leakage-best-practices
description: "Correctness rules for a spend and contract leakage pipeline. Always loaded by the spend-and-contract-leakage router before any phase runs. Covers the silent failure modes that make the pipeline run cleanly and report a wrong dollar figure: model-judged leakage instead of SQL arithmetic, unverified clause quotes, duplicate contracts doubling totals, amendment precedence and effective-date windows, invoice date versus service date, retroactive versus incremental volume tiers, coverage short-circuiting price checks, vendor linking by fuzzy name, cross-currency comparison and summing, summing impact kinds, CURRENT_DATE drift, renewal term rolling, escalator and renewal-cap ceilings, NOT_STATED versus FAILED, tolerances, notice-deadline conventions, audit windows, credit memo netting, answer-key quarantine, page and token cost control, and commercial confidentiality. Triggers: best practices, correctness rules, why is the total wrong, how should tiers be applied, what can go wrong."
parent_skill: spend-and-contract-leakage
---

# Correctness rules

These rules exist because each failure they prevent is **silent**: the pipeline completes, the
findings table fills, and the number is wrong. Most of them are encoded as verification queries in
the phase skills and as dbt tests in `DBT_MATERIALIZATION.md`. When a rule and a user request
conflict, say which rule and why, then do what the user decides.

The sandbox plants a trap for most rules. The trap is named under each rule so the evaluation harness
result can be traced back to the rule that was broken.

---

## Part A — what the models do and do not decide

### Rule 1. Reconciliation is arithmetic. No model decides whether a line is leakage.

Models read contracts. SQL compares numbers. The moment a model is shown an invoice line and a
contract clause and asked "is this an overcharge", the finding is no longer reproducible to the cent,
the dollar total cannot be reconciled, and a supplier can dispute the method rather than the number.

- AI functions run on **contract documents only**: parse, classify, extract terms, interpret clauses.
- The one AI call permitted on spend data is `AI_SIMILARITY` between an invoice line description and a
  contracted rate-line description, used **only** to pick which rate line applies when there is no
  SKU, and only above a threshold with a margin over the runner-up (rule 11). It returns a score; SQL
  decides.
- Never run `AI_COMPLETE` over invoice lines. It is also the largest avoidable token cost in this play.

### Rule 2. Every term cites a verbatim clause, and the quote is verified in SQL.

Each extracted term carries `document_id`, `page_index` (for files), `clause_ref` where the document
numbers its clauses, and `evidence_quote`. Verification is a string check, not a model check:

```sql
quote_verified =
    LENGTH(evidence_quote) >= {{QUOTE_MIN_CHARS}}
AND CONTAINS(
        REGEXP_REPLACE(UPPER(page_or_full_text), '\\s+', ' '),
        REGEXP_REPLACE(UPPER(evidence_quote),    '\\s+', ' '))
```

Whitespace and case are normalized because OCR reflows lines; nothing else is. A quote that does not
occur in the source marks the term `UNVERIFIED`, and an `UNVERIFIED` term **cannot drive a finding**.
The finding row stores the statuses of every term it used (`evidence_term_statuses`) so this is
testable.

Why it matters: a model that fills a rate from its prior rather than the page produces a confident,
wrong price. The quote check catches it in one comparison. It also gives the analyst the sentence to
paste into the supplier letter.

### Rule 3. Deduplicate before forming families. A duplicate never governs.

CLMs ingest the same contract repeatedly: a rescan, a countersigned copy, an email attachment. Each
copy that survives produces a second set of effective rates, and any join that does not pick one
**doubles every finding for that supplier**.

- Exact duplicates: hash of whitespace-collapsed, uppercased text.
- Near duplicates (rescans with OCR noise): `AI_SIMILARITY` between documents of the same vendor and
  class, above `parse.near_duplicate_similarity`, confirmed by identical extracted agreement number.
  Similarity alone is not enough — two annual SOWs from one supplier are near-identical and are
  **not** duplicates.
- The earliest-uploaded copy is canonical; the others get `is_duplicate_of` and
  `family_role = 'DUPLICATE'`.

Trap: `SYN-DOC-C001-DUP`. Not deduplicated, every Northwind finding is raised twice and the recoverable
total rises by USD 16,800.

### Rule 4. Amendments supersede by effective date, and effective windows never overlap.

An amendment's rate replaces the base rate **from the amendment's effective date**, not from its
upload date and not for all time. Resolution, per `(family, sku, tier)`:

1. Order all stated rates by document effective date; amendments outrank the agreement they amend.
2. Each rate's window ends the day before the next-ranked rate for the same key begins.
3. A rate the amendment states is "unchanged" keeps its original window.
4. The final window ends at the end of the term period the governing document defines (rule 13).

Assert no overlaps (`DBT_MATERIALIZATION.md`, `no_overlapping_windows`). An overlap means two prices
are valid on one date, and which one wins is then decided by join order.

Trap: Northwind JAN-STD. Ignoring the amendment flags three correctly billed months at 44.00 and
over-states April to September by 6 x 400 x 2.00 = USD 4,800.

### Rule 5. The effective rate is selected by service date, not invoice date.

Rates change on contract dates; invoices arrive weeks later. Use the service-period start (or
delivery date for goods). If the customer's AP has no service date, use invoice date, record that in
the project file, and mark findings within 60 days of a rate change as `DATE_BASIS_INVOICE` so the
analyst checks them. Never mix the two bases in one run.

---

## Part B — the arithmetic

### Rule 6. Overcharge is quantity times unit-price delta, bounded by the line amount.

```
overcharge = quantity x (billed_unit_price - allowed_unit_price)       -- fixed and escalated rates
overcharge = billed_amount - allowed_amount                            -- tiered, where allowed is a per-tier sum
```

Use `quantity x delta` rather than `line_amount - quantity x allowed_price` on fixed rates, because
line amounts often fold in tax, freight or rounding. Then assert `overcharge <= line_amount`. A
finding larger than the line it is about is a unit-of-measure or currency error, never leakage.

Unit of measure must match before any comparison. A contract priced per case of 12 against invoices
per each is an `UOM_MISMATCH` exception, not a 1,100% overcharge. Do not convert units unless the
contract states the conversion.

### Rule 7. Volume tiers: cumulative within the contract year, incremental unless the clause says otherwise.

Three decisions, each of which moves the total by a multiple:

1. **What accumulates.** Quantity of that SKU under that family, across invoices, ordered by service
   date then invoice line id, reset at the start of each contract year as the clause defines it — not
   the calendar year, not the invoice.
2. **Incremental or retroactive.** Incremental: only units past the threshold get the tier price.
   Retroactive: once a threshold is crossed, all units in the period reprice, usually via a rebate or
   true-up. These differ by a large factor at the crossing.
3. **Silence.** If the clause does not say, **do not choose**. Emit `TIER_RULE_NOT_STATED` to
   `RECONCILE_EXCEPTIONS` with both computations and let procurement read the contract.

Per line, with tiers as half-open ranges `[tier_min, next_tier_min)`:

```sql
units_in_tier = GREATEST(0, LEAST(cum_after, tier_upper) - GREATEST(cum_before, tier_min))
allowed_amount = SUM(units_in_tier x tier_price)
```

The contract's `100,000 to 499,999` style ranges are inclusive integer ranges; convert them to
half-open on the next tier's minimum, never on `tier_max + 1` from a parsed value that may be wrong.

Trap: Contoso March 2026. Incremental is USD 600.00; retroactive is 3,600.00. A tier applied from the
first unit flags January and February too.

### Rule 8. Coverage is decided first, and short-circuits the price check.

Every invoice line gets exactly one coverage status before any price is compared:

| Status | Meaning | Finding |
|---|---|---|
| `NO_CONTRACT` | vendor has no commercial contract family | `OFF_CONTRACT` |
| `EXPIRED` | family exists, service date is after the last term period and no renewal applies | `EXPIRED_CONTRACT_SPEND` |
| `PRE_TERM` | service date is before the family's effective date | exception, not leakage — often a letter of intent period |
| `IN_TERM` | a term period covers the service date | proceed to price |
| `AMBIGUOUS_FAMILY` | two active families for the vendor and nothing selects one | exception |

An `EXPIRED` line is never also a `RATE_VARIANCE`, even if its price differs: the problem is that no
price was agreed for that period. Counting both double-counts the line.

Trap: Tailspin July to December 2025 — right price, wrong period. Reported as `RATE_VARIANCE` it is
both a false positive and a false negative.

### Rule 9. One finding per line per type, with a deterministic id.

`finding_id = SHA2(finding_type || '|' || contract_family_id || '|' || COALESCE(invoice_line_id, term_period_end::VARCHAR))`.
The same leakage found by two runs gets the same id, so analyst review decisions survive reruns, and
a uniqueness test catches any join fan-out.

### Rule 10. Vendor identity is linked deliberately, in a fixed order.

1. The CLM vendor id, if present **and** it resolves in the ERP vendor master.
2. The extracted counterparty legal name, normalized (uppercase, punctuation removed, legal suffixes
   such as LLC, INC, CORP, CO, LTD, GMBH, AG, SA, BV removed, whitespace collapsed), equal to the
   normalized ERP name.
3. `JAROWINKLER_SIMILARITY` of normalized names at or above `vendor_name_jw_min`, **and** exactly one
   ERP vendor above the threshold. Flag the link `NAME_FUZZY` for review.
4. Otherwise unlinked. An unlinked governing contract is reported, never guessed.

The PO's free-text contract reference is evidence for choosing between families of an already-linked
vendor; it is never a key.

Do not use `AI_SIMILARITY` for vendor names. Embedding similarity places "Northwind Facility
Services" and "Northwind Logistics" close together; they are different legal entities with different
contracts.

Trap: `SYN-DOC-C008` has no CLM vendor link and the counterparty is spelled
`PROSEWARE CONSULTING G.m.b.H.`. It must link to `SYN-V008` by normalized name. Failing the link turns
six correctly billed EUR lines and one overcharge into off-contract spend.

### Rule 11. SKU-less lines are matched to a rate line by description only above a threshold and a margin.

When the invoice carries no SKU, compute `AI_SIMILARITY(line_description, rate_line_description)`
against the rate lines of the matched family only (never across families), and accept the best match
only if it is at least `sku_similarity_min` **and** beats the second best by `sku_similarity_margin`.
"Senior consultant" and "Consultant" are close; the margin is what stops a senior rate being compared
to a junior line. Otherwise `AMBIGUOUS`, exception, no finding. Unit of measure must also agree.

### Rule 12. Never compare across currencies, never sum across currencies.

A EUR invoice compared to a rate stored without its currency reads as an overcharge or an undercharge
by the exchange rate. Every rate line carries its currency; a currency mismatch between invoice line
and rate line is an exception. Totals are always grouped by currency. Conversion, if the customer
wants it, happens only in the readout, at customer-supplied rates, with the rate date stated.

Trap: Proseware is invoiced in EUR. Planted EUR 1,500.00 must stay EUR.

### Rule 13. Impact kinds are never summed.

| `impact_kind` | What it is | How it becomes value |
|---|---|---|
| `RECOVERABLE_OVERCHARGE` | money paid above contract | supplier claim, within the audit window |
| `SPEND_UNDER_MANAGEMENT` | spend with no valid contract | customer's savings rate on bringing it under contract |
| `COMMITMENT_EXPOSURE` | trailing spend under a renewal at risk | avoided commitment or renegotiation leverage |

A headline that adds them is wrong by construction: exposure is not money lost, and unmanaged spend
is not an overcharge. Every total in the session, the semantic view and the readout is per kind and
per currency.

---

## Part C — dates and terms

### Rule 14. The as-of date is a pinned parameter, and term periods are rolled.

Renewal findings and trailing exposure depend on "today". `CURRENT_DATE()` appears nowhere in
business logic: the run reads `reconcile.as_of_date`, so a rerun reproduces its findings and the
sandbox key stays valid.

Term rolling: from the initial term, while `auto_renewal` is true, generate renewal periods of
`renewal_term_months` until a period ends after the as-of date. The renewal finding is evaluated on
**the period containing the as-of date**, with `notice_deadline = DATEADD(day, -notice_days, period_end)`.

- Deadline passed and the period ends after as-of: `AUTO_RENEWAL_NOTICE_MISSED` — the next term will
  start unless something is done outside the notice process.
- Deadline within `renewal_horizon_days` after as-of: `AUTO_RENEWAL_NOTICE_UPCOMING`.

Trap: Fabrikam's initial term already rolled once. Compared to the initial term's deadline, it is
"missed by a year"; on the current term it is missed by 59 days, which is the actionable fact.

### Rule 15. Escalators and renewal caps define a ceiling, not a price.

"May increase by up to 3% on each anniversary" means the allowed price in year n is at most
`base x 1.03^n`, compounding on the fee in effect. Billing below the ceiling is compliant. Two
conventions must be recorded, not improvised:

- `escalator_compounding = ALLOWED_PRICE` compounds on the previous year's ceiling (the supplier is
  assumed to be entitled to increases it did not take). `BILLED_PRICE` compounds on what was actually
  billed. The difference only appears after a year in which the supplier billed under the ceiling.
- A renewal uplift cap applies to the renewal term's price relative to the immediately preceding
  term. If the rate card does not cover the renewal term, the allowed price is the preceding term's
  allowed price times `(1 + cap)`. If there is no cap, a renewal price increase is **not** leakage —
  it is an `UNPRICED_RENEWAL` exception for procurement to review.

Escalator and cap percentages are rounded to the cent on the resulting price, never on the
percentage.

Traps: Wide World 2026 at 5,150.00 is exactly the permitted escalator — nine false positives without
the rule. Fabrikam's renewal at 9,200.00 against a 5% cap on 8,000.00 is USD 800.00 a month over.

### Rule 16. NOT_STATED, FAILED and UNVERIFIED are different answers.

| Status | Meaning | Effect |
|---|---|---|
| `EXTRACTED` | value present, normalized, quote verified | usable |
| `NOT_STATED` | the model affirmatively answered that the contract does not state it | usable as an absence (e.g. no cap) |
| `FAILED` | NULL response, error, or a value that did not normalize | **not** usable; blocks dependent findings and is counted |
| `UNVERIFIED` | value present, quote not found in source | **not** usable |

The extraction prompt requires the literal `NOT_STATED` for absence so that an empty or NULL response
can be classified as `FAILED`. Treating NULL as "not stated" converts every extraction error into
"this contract has no renewal clause".

Trap: Contoso and Proseware explicitly do not renew. `auto_renewal = FALSE` must be extracted with a
quote, not inferred from absence.

### Rule 17. Only commercial documents get commercial terms.

Classify before extracting. NDAs, DPAs, insurance certificates and W-9s routinely contain "term",
"renewal" and "notice" language with no spend attached. Extract only `extract.commercial_classes`.

Trap: `SYN-DOC-N008`, a mutual NDA that auto-renews. A renewal finding on it is a false positive.

### Rule 18. Tolerance is explicit and small.

`allowed_delta_per_unit = LEAST(price_tolerance_abs, price_tolerance_rel_pct / 100 x contracted_unit_price)`.
The absolute bound absorbs cent rounding on large unit prices; the relative bound stops the absolute
one from swallowing real variances on small unit prices (a 0.03 delta on a 0.15 glove is 20%). Both
are customer decisions recorded in the project file, and the finding stores the tolerance applied.

Trap: Northwind 2025-06 at 42.01. A zero tolerance flags it.

### Rule 19. State the notice-deadline convention on every renewal finding.

"At least sixty days before the end of the term" can be read as counting or not counting the end
date, and business-day clauses exist. This plugin computes calendar days back from the period end
date and writes `notice_convention = 'CALENDAR_DAYS_BEFORE_PERIOD_END'` on the finding. Where a
clause says business days or requires receipt rather than dispatch, extraction captures that in the
quote and the finding is flagged for legal review rather than recalculated.

---

## Part D — what makes the number defensible

### Rule 20. Recoverable means recoverable within the audit window, net of credits.

Many contracts limit the look-back for overcharge claims ("audit Supplier invoices for twenty-four
months after payment"). Extract the audit window as a term where present. The readout splits
`RECOVERABLE_OVERCHARGE` into within-window and outside-window using the customer's payment dates
where available, or invoice dates with that stated. Outside-window overcharge still has value as
negotiating evidence; it is not a recovery.

Net credit memos and negative lines against the lines they reverse before computing overcharges.

### Rule 21. The answer key is quarantined.

The sandbox keys live in `{{EVAL_SCHEMA}}`. No pipeline query, prompt, retrieved context, semantic
view or agent reads them; only `evaluate-leakage-accuracy` does. `plant_note` is never fed to a model:
it states the answer. A pipeline that has seen the key scores perfectly and means nothing.

### Rule 22. Control cost by pages and by windows, never by sampling invoices.

- `AI_PARSE_DOCUMENT` and file `AI_EXTRACT` bill per page; `AI_EXTRACT` counts each page of a PDF as
  970 tokens. Parse once, cache by content hash, never reparse an unchanged document.
- For long agreements, locate the commercial pages on the first pass (headings such as "Schedule",
  "Pricing", "Fees", "Rate Card", "Term", "Renewal") and use `page_filter` for any second file pass.
- Send `AI_COMPLETE` the clause window (the paragraph and its neighbours), not the whole contract.
  Estimate with `AI_COUNT_TOKENS` at the gate.
- Report pages and tokens. Never convert to currency in the session; credit prices vary by contract.
- Measure actual cost from `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` filtered by
  `QUERY_TAG` or `QUERY_ID`. Do not use `CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY`: it has no timestamp
  column and is no longer updated.

### Rule 23. AI functions return NULL on error by default. Keep the error.

`AI_PARSE_DOCUMENT` and `AI_CLASSIFY` accept a `return_error_details` argument that returns an object
with `value` and `error`; use it in pipeline SQL so a failure is recorded with its reason. For
`AI_EXTRACT`, inspect the `error` field of the response. For `AI_COMPLETE` with a JSON schema, a NULL
is `FAILED`. Every phase's verification query reports failures as a count; a nonzero count is
explained before the phase is marked done.

### Rule 24. Contract text and findings stay in the account.

Never write contract text, extracted prices or findings to a local file, a log, a ticket, a chat
message or any external destination. Show samples only when asked, from the sandbox where possible.
The semantic view exposes findings and terms, not full contract text, and the agent's instructions
forbid quoting more of a contract than the cited clause.

---

## Quick reference: rule to sandbox trap

| Rule | Trap | Harness symptom when broken |
|---|---|---|
| 3 | `SYN-DOC-C001-DUP` | Northwind findings doubled; dollar error +16,800 USD |
| 4 | Northwind Amendment 1 | 3 FPs, April-September over-stated by 4,800 USD |
| 7 | Contoso March crossing | March over by 3,000; Jan-Feb FPs |
| 8 | Tailspin after expiry | 6 type confusions |
| 10 | Proseware C008 | 6 lines off-contract; EUR RV missed |
| 11 | Proseware no SKU | RV missed or junior rate compared |
| 12 | Proseware EUR | EUR total summed into USD |
| 14 | Fabrikam rolled term | ARN missed or wrong deadline; drift between days |
| 15 | Wide World escalator; Fabrikam cap | 9 FPs; uplift missed |
| 16 | Contoso, Proseware "does not renew" | renewal FPs |
| 17 | NDA N008 | renewal FP |
| 18 | Northwind 42.01 | 1 FP |
