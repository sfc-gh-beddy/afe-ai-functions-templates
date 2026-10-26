---
name: seed-spend-leakage-sandbox
description: "Generate a synthetic contract, purchase order and invoice corpus with planted leakage and a labeled answer key, so a spend and contract leakage pipeline can be built, demonstrated and accuracy-tested before touching real supplier contracts or AP data. Creates a vendor master, ten contract documents (agreements, an amendment that changes a rate mid-term, an NDA, a duplicate scan), POs, 120 invoice lines, and quarantined keys for document class, header terms, rate cards with effective windows and volume tiers, and 47 planted leakage findings plus 23 distractors with exact dollar impacts. Triggers: seed the sandbox, synthetic contracts, test data for leakage, answer key, planted leakage, demo data for procurement. Phase 1 of the spend-and-contract-leakage build."
parent_skill: spend-and-contract-leakage
---

# Seed the sandbox

Generate a synthetic procurement corpus with **ground truth at three levels**: the terms each contract
states, the prices each contract allows on each date, and the leakage findings — with exact dollar
impact — that a correct pipeline must raise. This is what lets the evaluation harness report term
extraction accuracy, finding precision and recall, and dollar reconciliation on day one, before a
legal or procurement data review completes.

## Why not just point at real contracts

You can, and the phase is skippable. Be honest about what is given up. On real data nobody knows the
true leakage total until a recovery audit has been done, and recovery audits are slow, partial and
often contingency-priced. Without a labeled set:

- **Recall is unmeasurable.** Missed leakage is the expensive failure, and it is invisible.
- **The dollar figure cannot be reconciled.** A pipeline that applies a volume tier retroactively
  reports several times the true missed-discount amount, and on real data that number looks like
  good news rather than a bug.
- **Term extraction errors propagate silently.** A notice period extracted as 30 days instead of 90
  moves a renewal deadline by two months, and no downstream query knows.

## What gets created

| Object | Schema | Purpose |
|---|---|---|
| `SYNTH_VENDORS` | sandbox | ERP vendor master, 8 vendors, spellings that differ from contracts |
| `SYNTH_CONTRACT_DOCUMENTS` | sandbox | 10 contract documents as text, with a `file_path` for the rendered corpus |
| `SYNTH_PURCHASE_ORDERS` | sandbox | 7 POs, free-text contract reference, one CapEx PO |
| `SYNTH_INVOICE_LINES` | sandbox | 120 invoice lines across 21 months, USD and EUR |
| `SYNTH_DOCUMENT_KEY` | eval | Expected document class and family; duplicate marking |
| `SYNTH_TERM_KEY_WIDE` / `SYNTH_TERM_KEY` | eval | 11 header terms x 7 families = 77 scored values |
| `SYNTH_RATE_KEY` | eval | 14 rate rows with effective windows and tiers |
| `SYNTH_LEAKAGE_KEY` | eval | 47 planted findings, 23 distractors, impact and impact kind |
| `SYNTH_EXPECTED_TOTALS` | eval | Literal totals, so the key itself is verifiable |

`sql/01_seed_sandbox.sql` builds it; `sql/02_verify_seed.sql` checks it. Both use `{{DB}}`,
`{{SCHEMA}}` and `{{EVAL_SCHEMA}}` placeholders — read them, substitute the values from
`spend-leakage-project.yml`, and run. Do not run unmodified.

At the gate, state the object list, note that **no AI functions run in this phase** (zero inference
tokens), confirm with `ask_user_question`, then run.

## The as-of date is part of the ground truth

Renewal findings depend on "today". The corpus is anchored to **2026-09-30**, and the key's renewal
expectations are computed against it. Record `reconcile.as_of_date: 2026-09-30` in the project file
for sandbox runs. A pipeline that uses `CURRENT_DATE()` on the sandbox will produce different
renewal findings every day and the harness will report drift that is not real. On customer data,
`as_of_date` is the run date — but it is still a pinned parameter, never an implicit
`CURRENT_DATE()` scattered through the SQL.

## The planted leakage, and the trap each one tests

| Vendor | Finding type | Lines | Impact | What it tests |
|---|---|---|---|---|
| Northwind (V001) | `RATE_VARIANCE` | 12 | USD 16,800 | Rate card from a markdown table; **amendment precedence** — the 2026 contracted rate is 44.00 from Amendment 1, not 42.00 |
| Contoso (V002) | `MISSED_VOLUME_DISCOUNT` | 7 | USD 7,800 | Cumulative tier tracking across invoices; **incremental, not retroactive** tier application (Section 2.3) |
| Fabrikam (V003) | `UPLIFT_OVER_CAP` | 11 | USD 8,800 | Renewal pricing cap applied to a **renewed** term the rate card does not list |
| Litware (V004) | `RATE_VARIANCE` | 1 | USD 7,500 | **CapEx** GL routing; PO already carried the wrong price |
| Adventure (V005) | `OFF_CONTRACT` | 6 | USD 71,000 | Non-PO spend with no contract at all |
| Tailspin (V006) | `EXPIRED_CONTRACT_SPEND` | 6 | USD 62,400 | Right price, wrong period — must **not** be called a rate variance |
| Proseware (V008) | `RATE_VARIANCE` | 1 | EUR 1,500 | **Currency**, no SKU on invoice (description match), vendor-name normalisation |
| Fabrikam (V003) | `AUTO_RENEWAL_NOTICE_MISSED` | contract | USD 109,200 exposure | **Term rolling** — the initial term already renewed once; the deadline is on the current term |
| Northwind, Wide World | `AUTO_RENEWAL_NOTICE_UPCOMING` | contract | USD 233,400 / 61,350 exposure | Notice-window arithmetic against a pinned as-of date |

## The distractors, and the over-call each one catches

| Distractor | Count | A pipeline that flags it is... |
|---|---|---|
| Northwind 2025-06 at 42.01 | 1 | ...comparing without a price tolerance |
| Northwind 2026-01..03 at 44.00 | 3 | ...ignoring Amendment 1 |
| Wide World 2026 at 5,150 | 9 | ...ignoring the permitted 3% anniversary escalator |
| Proseware compliant months | 5 | ...failing the currency or vendor-name link |
| Contoso Jan-Feb at 0.18 | 2 | ...applying tier 2 before the threshold was reached |
| Contoso, Proseware renewal | 2 | ...treating "expires" as "auto-renews" |
| The NDA | 1 | ...extracting renewal terms from a non-commercial document |

And two document-level traps that do not appear as findings but corrupt everything if missed:

- **`SYN-DOC-C001-DUP`** is a byte-identical rescan of the Northwind MSA with no CLM vendor link. If
  it is not deduplicated, every Northwind finding is raised twice and the dollar total doubles.
- **`SYN-DOC-C008`** has `clm_vendor_id = NULL` and spells the counterparty
  `PROSEWARE CONSULTING G.m.b.H.`. The link to vendor `SYN-V008` must come from the extracted
  counterparty name.

## Impact kinds are never summed

The key carries three `impact_kind` values, and the harness and readout keep them separate:

- `RECOVERABLE_OVERCHARGE` — money already paid above contract. Recoverable through a supplier
  claim, subject to the contract's audit window.
- `SPEND_UNDER_MANAGEMENT` — spend with no valid contract. Not an overcharge; the value comes from
  a customer-supplied savings rate on bringing it under contract.
- `COMMITMENT_EXPOSURE` — the size of a renewal at risk. Not money lost; the value is avoided
  commitment or renegotiation leverage.

Adding the three together produces a headline number that is wrong by construction. The literal
totals in `SYNTH_EXPECTED_TOTALS` are per kind and per currency for that reason.

## The answer key is quarantined

- It lives in `{{EVAL_SCHEMA}}`, never in the sandbox schema the pipeline reads.
- No pipeline query joins it. Only `evaluate-leakage-accuracy` reads it.
- It never appears in a prompt, in retrieved context, or in a semantic view.
- `plant_note` is a human explanation. Never feed it to a model — it states the answer.

A `SELECT *` across the database is enough to leak it. Verification query 8 checks the sandbox
schema contains nothing key-shaped.

## Verification before declaring the phase done

Run `sql/02_verify_seed.sql` and show the results. Each query states its expected output. The ones
that matter most:

1. **Row counts** — 8 / 10 / 7 / 120 / 77 / 14 / 70.
2. **Planted totals match the literal expectations** — zero rows returned.
3. **Every key row resolves to an invoice line** — zero rows; a dangling key row is a phantom
   false negative.
4. **Naive rate-card overcharge is 25,650.00**, not the correct 24,300.00 — the 1,350 difference is
   the escalator distractor, visible before the pipeline is even built. Show the user this: it is
   the clearest one-query explanation of why the reconcile phase is more than a join.
5. **Tier crossing in March** at cumulative 120,000.
6. **Trailing-12-month exposures** 233,400 / 109,200 / 61,350.
7. **Exactly one duplicate pair.**
8. **Nothing key-shaped in the sandbox schema.**

Then write `phases.seed: done`, `reconcile.as_of_date: 2026-09-30`, and record every created object
in `created_objects`.

## Text rows are not files

The sandbox stores contracts as `document_text`. That exercises term extraction and reconciliation,
and it does **not** exercise `AI_PARSE_DOCUMENT` — the step where scanned signature pages, tables
that span pages, and rate cards rendered as images break. If preflight shows the customer's
contracts are PDFs (they almost always are), also run `build-contract-test-corpus`, which renders
these same contracts into PDFs and degraded scans at the `file_path` values above, so the parse
phase runs against real files with the same answer key.

## Keep it synthetic, and keep it obviously synthetic

- Every identifier is prefixed `SYN-`; every company name is a stock sample name; the buyer is
  "Synthetic Holdings Corp."
- Prices and terms are invented for arithmetic clarity. They are not benchmarks and must never be
  quoted as typical rates, typical leakage percentages, or typical recovery values.
- Do not model the corpus on a specific customer's suppliers, categories or contract templates.
  The customer's real taxonomy comes from preflight.

## Extending the corpus

When the customer's preflight shows a pattern the sandbox lacks, add a plant for it rather than
assuming the pipeline handles it. Common additions, each needing a key row with an exact impact:

- **Unit-of-measure mismatch** — contract per case of 12, invoice per each.
- **Freight or fuel surcharge** prohibited by a "no other charges" clause (the Northwind MSA has
  one in Section 3.3; add a surcharge line to test it).
- **Early-payment discount not taken** — "2/10 net 30" with payment on day 25. Requires payment
  dates, which this sandbox does not carry.
- **Multiple active contracts for one vendor** — a local agreement and a global one with different
  rates; tests the precedence rule's tie-break.

## Teardown

The sandbox should be dropped once real data is wired in; synthetic findings sitting beside real
ones will eventually be summed by accident. Drop exactly what `created_objects` lists.
