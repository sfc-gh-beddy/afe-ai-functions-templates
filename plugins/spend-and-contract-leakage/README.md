# Spend and Contract Leakage

A guided build for a contract-to-spend reconciliation pipeline that runs entirely inside Snowflake,
on supplier contracts, purchase orders and invoices the organization already stores.

## The problem

Procurement negotiates rates, volume tiers, escalator limits, renewal caps and notice windows into
supplier contracts. Accounts payable then pays invoices that someone matched to a PO, rarely to the
contract. The terms live in PDFs in a CLM system or a shared drive; the spend lives in ERP and AP
tables. The gap between them is leakage, and it takes four shapes:

- **Paid above contract.** Rates higher than the rate card, volume tiers never applied, renewal
  prices above the cap, escalations beyond what the contract permits.
- **Paid without a contract.** Spend with suppliers that have no agreement, and spend that continued
  after an agreement expired.
- **Committed without deciding.** Contracts that auto-renewed because nobody saw the notice deadline.
- **CapEx bought off the negotiated price.** Equipment purchase orders raised at list.

All four are visible in data the organization already holds. Nothing needs to be acquired.

## What this plugin builds

```
Contracts (text or files)                       Invoices and POs
  -> parse and register                           |
       AI_PARSE_DOCUMENT (LAYOUT, page split)     |
       AI_CLASSIFY, dedupe, families, vendor link |
  -> extract terms with cited clauses             |
       AI_EXTRACT  header terms + verbatim quote  |
       AI_EXTRACT  rate-card and tier tables      |
       AI_COMPLETE clause interpretation          |
       quotes verified in SQL                     |
  -> term periods and effective-dated rates (SQL) |
  -> reconcile (pure SQL) <------------------------
       coverage, SKU match, tiers, escalators, renewal caps, notice deadlines
  -> findings: type, impact kind, amount, currency, arithmetic, cited clauses
  -> evaluation: term accuracy, finding precision/recall, dollar reconciliation, cost
  -> semantic view + Cortex Agent, scheduled pipeline, value readout
```

The deliverable is a findings table. Every row is one finding — rate variance, missed volume
discount, uplift over cap, off-contract spend, expired-contract spend, auto-renewal notice missed or
upcoming — with its dollar impact, the arithmetic, and the contract sentences it relied on, each
verified to occur in the parsed contract. A procurement analyst can check a finding in one read and
paste the clause into a supplier letter.

**No model decides whether a line is leakage.** Models read contracts; SQL compares numbers. That is
what makes the total reproducible to the cent and reconcilable to an answer key.

## What it does not build

- **Ingestion.** Contracts are assumed landed as files on a stage or as text in a CLM export table,
  and AP and PO data as tables.
- **Supplier claims, ERP price changes or non-renewal notices.** The pipeline ends at findings, a
  semantic view and an agent. Review columns on the findings table are defined and carried across runs
  so a workflow can be layered on later.

## Getting started

Ask for it in plain language. The router picks up phrases like:

- "find off-contract spend and overcharges against our supplier contracts"
- "compare our contracts to invoices"
- "which contracts auto-renew soon and what are the notice deadlines"
- "are we getting our volume discounts"

The build runs in gated phases. Each phase says what it will create and what it will cost in pages and
tokens, waits for confirmation, runs, and shows a verification query. State lives in
`spend-leakage-project.yml` in the working directory, so the build can be stopped and resumed.

**Start in the sandbox.** Phase 1 generates a synthetic corpus — ten contract documents including an
amendment, an NDA and a duplicate rescan, POs, and 120 invoice lines across 21 months in two
currencies — with an answer key at three levels: the terms each contract states, the price each
contract allows on each date, and 47 planted findings with exact dollar impact plus 23 distractors
that a careless pipeline flags. Term accuracy, finding precision and recall, and dollar
reconciliation are measurable on day one.

**If the customer's contracts are PDFs or scans** (they usually are), also run
`build-contract-test-corpus`. It renders the same contracts into digital PDFs, clean scans and graded
degraded scans, with schedules on their own pages and image-only signature pages, so parsing is
tested rather than skipped, against the same answer key.

## Skills

| Skill | Role |
|---|---|
| `spend-and-contract-leakage` | Entry point. Intent detection, phase gating, project state, dbt mapping, diagnosis guide. |
| `spend-leakage-system-of-record` | Preflight: function access, region and cross-region inference, models, contract and spend inventory, column mapping, confidentiality posture. |
| `spend-leakage-best-practices` | Correctness rules. Always loaded. Each rule names the sandbox trap that tests it. |
| `seed-spend-leakage-sandbox` | Synthetic contracts, POs and invoices with planted leakage and a quarantined answer key. |
| `build-contract-test-corpus` | Renders the sandbox contracts into PDFs and scans on a stage. Optional. |
| `parse-contract-documents` | Parse, classify, deduplicate, identify, form contract families, link vendors. |
| `extract-contract-terms` | Header terms, rate cards, tiers and clause rules with verified quotes; term periods and effective rates. |
| `reconcile-spend-to-contract` | Deterministic reconciliation to findings and exceptions. |
| `evaluate-leakage-accuracy` | Document, term and rate accuracy; finding precision and recall; dollar reconciliation; failures; cost per 1K documents. |
| `operationalize-leakage-pipeline` | Serving views, semantic view, Cortex Agent, scheduled task with a pinned as-of date. |
| `leakage-value-readout` | OpEx and CapEx levers from customer inputs only, ROI against measured cost, POC criteria. |

## Requirements

- A role with Cortex AI function access (`SNOWFLAKE.CORTEX_USER` or equivalent); preflight verifies
  this and reports the exact missing grant if not.
- `AI_EXTRACT` and `AI_PARSE_DOCUMENT` available natively in the account's region or through
  cross-region inference; preflight reports `CORTEX_ENABLED_CROSS_REGION` and treats enabling it as the
  customer's data-residency decision.
- A GA model for the clause-interpretation stage, checked with `SHOW CORTEX BASE MODELS`.
- For files: an internal stage with `SNOWFLAKE_SSE` encryption and a directory table.
- A warehouse (small or medium), and a database and schema the role can create objects in.

## A note on confidentiality

Every AI function call runs inside Snowflake; contract text does not leave the account boundary. The
only exception in the plugin is the corpus renderer, which runs locally on synthetic `SYN-` documents
only and refuses anything else. Contracts are frequently under NDA with the counterparty, and a
findings table is a list of negotiating positions; preflight reports who can read contracts and AP
today and asks who should read findings and use the agent before either is created.

## A note on numbers

The sandbox's prices, terms and leakage are invented for arithmetic clarity. They are not benchmarks,
and nothing in this plugin supplies a typical leakage rate, recovery rate or savings rate. The value
readout uses customer-supplied inputs only, labels each with its source, and keeps the three impact
kinds — recoverable overcharge, spend under management, commitment exposure — and each currency
separate.
