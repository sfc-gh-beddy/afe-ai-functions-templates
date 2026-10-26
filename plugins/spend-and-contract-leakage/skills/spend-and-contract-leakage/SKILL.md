---
name: spend-and-contract-leakage
description: "**[REQUIRED]** Use for ALL requests about finding spend leakage, contract leakage, or contract compliance gaps by comparing supplier contracts to purchase orders and invoices in Snowflake. Triggers: spend leakage, contract leakage, contract compliance, off-contract spend, maverick spend, rate variance, price variance, invoice overcharge, overbilling, invoice price audit, missed volume discount, volume tier, rebate leakage, tiered pricing not applied, renewal uplift, price increase above cap, escalator, auto-renewal, evergreen contract, notice period, renewal deadline, contract renewal calendar, expired contract spend, contract term extraction, extract contract terms, rate card extraction, contract abstraction, CLM data, contract intelligence, procurement savings, recover overcharges, recovery audit, AP audit, supplier audit, PO price mismatch, CapEx overspend, procurement OpEx savings, contract to invoice reconciliation, three-way match on price. This is the REQUIRED entry point for this work, even if the request seems simple. DO NOT hand-write the extraction prompts or reconciliation SQL; always invoke this skill first."
---

# Spend and Contract Leakage — Router

## What this builds and why

Organizations negotiate rates, volume tiers, renewal caps and notice windows into supplier contracts,
then pay invoices that a person matched to a PO and never to the contract. The contract terms live in
PDFs in a CLM system or a shared drive; the spend lives in ERP and AP tables. The gap between them is
leakage, and it takes four shapes:

- **Paid above contract** — rate variance, missed volume tiers, renewal uplift above the cap.
- **Paid without a contract** — off-contract spend and spend after a contract expired.
- **Committed without deciding** — auto-renewals that roll because nobody saw the notice deadline.
- **CapEx bought off the negotiated price** — equipment POs raised at list.

This plugin builds a pipeline over contracts and spend **already in Snowflake** that extracts the
commercial terms with Cortex AI functions, each term carrying the clause it came from, and then
reconciles those terms against POs and invoice lines **deterministically in SQL** to emit findings
with a dollar impact and cited clause evidence.

**Scope boundary.** Ingestion is out of scope; contracts are assumed landed (as files on a stage, as
text in a CLM export table, or both) and AP and PO data are assumed in tables. The pipeline ends at a
findings table, a semantic view and a Cortex Agent. It does not file supplier claims, change ERP
prices, or send non-renewal notices.

## Setup — do these before anything else

1. **Read** `PROJECT_STATE.md` (this directory). It defines `spend-leakage-project.yml`, the single
   state file every phase reads and writes. Resumability depends on honouring it.
2. **Load** `spend-leakage-system-of-record/SKILL.md`. Required first step in every session. It
   establishes what the account can run, where contracts and spend live, and the column mappings.
3. **Load** `spend-leakage-best-practices/SKILL.md`. Required. These rules prevent the failure modes
   where the pipeline runs clean and reports a confidently wrong dollar figure.
4. **Settle how the pipeline is built** — dbt project or plain SQL — and record
   `materialization.mode`. Ask once, at preflight, before anything is created. Read
   `DBT_MATERIALIZATION.md` (this directory) for the phase-to-model mapping, and delegate dbt
   deploy and execute mechanics to the **`dbt-projects-on-snowflake`** skill.

   Recommend dbt when the build will outlive the first readout: dbt tests become build-failing gates
   on the correctness rules (no finding without clause evidence, no finding summing across
   currencies, no rate applied outside its effective window). Recommend plain SQL for a time-boxed
   proof of value, and say plainly what is given up.

> **Confidentiality caution.** Contracts are commercially sensitive and frequently under NDA with the
> supplier. Pricing, rate cards and findings are more sensitive still: a findings table is a list of
> negotiating positions. Never write contract text, extracted terms or findings to a local file, a
> log, a ticket, or any destination outside the account. Show samples in the session only when the
> user asks, and prefer sandbox rows for demonstration.

## Intent detection

| Intent | Trigger phrases | Route |
|---|---|---|
| **BUILD** | "set up contract leakage", "find off-contract spend", "compare contracts to invoices", "start from scratch" | Run the phased build below |
| **RESUME** | "continue", "pick up where we left off", "what's left" | Read `phases`, report status, continue at the first phase not `done` |
| **SINGLE_PHASE** | "just extract the terms", "re-parse the PDFs", "rerun reconciliation", "regenerate the sandbox", "render the contracts" | Load that phase's skill directly, after confirming its prerequisite phases are `done` |
| **RENEWALS_ONLY** | "which contracts auto-renew soon", "renewal calendar", "notice deadlines" | Phases 0, 2, 3, then the renewal section of `reconcile-spend-to-contract` only |
| **EVALUATE** | "how accurate is it", "precision and recall", "does the dollar figure tie", "what does this cost per contract" | `evaluate-leakage-accuracy/SKILL.md` |
| **VALUE** | "what is this worth", "business case", "ROI", "readout", "POC criteria" | `leakage-value-readout/SKILL.md` (requires evaluation done) |
| **DEBUG** | "no findings", "too many findings", "the rate is wrong", "it missed the amendment", "renewal date is off", "dollar total looks too high" | `DIAGNOSING.md` (this directory) |
| **COMPARE** | "did the prompt change help", "compare runs" | `evaluate-leakage-accuracy/SKILL.md`, across `experiment_id` |
| **EXPLAIN** | "how does this work", "walk me through it" | Answer from this file. Create nothing. |

If intent is unclear, ask. Do not default to BUILD, because BUILD creates objects and spends tokens.

## The phased build

Each phase is a gate, and the gate protocol is not optional:

1. State what the phase will create — object names and types.
2. State rough cost when the phase calls AI functions over a table: pages for `AI_PARSE_DOCUMENT`
   and `AI_EXTRACT` on files, `AI_COUNT_TOKENS` for text inputs to `AI_COMPLETE`. Report pages and
   tokens, say output tokens bill on top, never convert to currency.
3. Confirm with `ask_user_question`.
4. Run it.
5. Show a verification query and its actual result.
6. Update `phases` and `created_objects` in `spend-leakage-project.yml`.

Never chain two gates without stopping.

| # | Phase | Skill | Creates | AI functions | Skippable |
|---|---|---|---|---|---|
| 0 | Preflight | `spend-leakage-system-of-record` | nothing | none (EXPLAIN_PRIVILEGES only) | no |
| 1 | Sandbox | `seed-spend-leakage-sandbox` | synthetic corpus + answer keys | none | yes, on real data with another accuracy method |
| 1b | Contract corpus | `build-contract-test-corpus` | rendered PDFs and scans on a stage | none | yes, if contracts are text-native |
| 2 | Parse and register | `parse-contract-documents` | parsed text, document registry, families | AI_PARSE_DOCUMENT, AI_CLASSIFY, AI_SIMILARITY | no |
| 3 | Extract terms | `extract-contract-terms` | header terms, rate lines, effective terms, term periods | AI_EXTRACT, AI_COMPLETE | no |
| 4 | Reconcile | `reconcile-spend-to-contract` | invoice-to-contract match, leakage findings | AI_SIMILARITY (matching fallback only) | no |
| 5 | Evaluate | `evaluate-leakage-accuracy` | term, finding and dollar accuracy; cost | none | no |
| 6 | Operationalize | `operationalize-leakage-pipeline` | streams, tasks or dynamic tables, semantic view, Cortex Agent | as phases 2-4, incrementally | yes, for a one-off readout |
| 7 | Value readout | `leakage-value-readout` | readout document and POC criteria | none | no, if a readout is the goal |

Evaluation precedes operationalization deliberately: scheduling a pipeline whose precision nobody
has measured schedules an unknown number of false supplier disputes.

### The phase order is a dependency chain

- **Parse before extract.** Term extraction on a document that has not been classified runs on NDAs
  and duplicates and extracts renewal terms from documents with no commercial exposure.
- **Register families before resolving terms.** An amendment's rate means nothing until it is linked
  to the agreement it amends. Without the family, the pipeline compares invoices to the superseded
  rate and every correctly-billed amended line is a false positive.
- **Extract before reconcile.** Obvious, but note the corollary: reconciliation is **pure SQL** on
  extracted, normalised, effective-dated terms. No model sees an invoice line and decides whether it
  is leakage. That decision is arithmetic and must be reproducible to the cent.
- **Evaluate before anyone sees a dollar figure.** The single most damaging output of this play is a
  leakage total that is wrong by a multiple — retroactive tiering, double-counted duplicates, summed
  currencies, or summed impact kinds. The harness reconciles the dollar total to the answer key.

### Strongly recommend the sandbox first

> The sandbox ships an answer key at three levels: the terms each contract states, the price each
> contract allows on each date, and 47 planted findings with exact dollar impact plus 23 distractors.
> That makes term accuracy, finding precision and recall, and dollar reconciliation measurable today.
> On real contracts nobody knows the true leakage until a recovery audit is done, so a pipeline run
> straight on production produces a number with no way to tell whether it is right.

If they still want real data, do it and mark `seed: skipped`. Their call. Suggest the labeling
approach in `evaluate-leakage-accuracy` (a reviewed sample of contracts and findings) so accuracy is
eventually measurable.

## Two in-pipeline guarantees

These are per-row output contract, not reporting concerns:

- **Every extracted term cites its clause.** Each term row carries `document_id`, `clause_ref`
  (section number where present), `page_index` where the source was a file, and a verbatim
  `evidence_quote`. The quote is **verified in SQL** to occur in the parsed text of that document;
  an unverifiable quote marks the term `UNVERIFIED` and it cannot drive a finding.
- **Every finding carries its evidence chain.** The contracted terms it relied on (each with its
  clause evidence), the invoice line or contract it is about, the arithmetic, the impact kind and the
  currency. A finding a procurement analyst cannot verify in one read is one they will not send to a
  supplier.

Separately, `evaluate-leakage-accuracy` measures the pipeline against ground truth. Per-row evidence
says where a number came from; the harness says how often the pipeline is right.

## Every run is a labeled experiment

Prompts, question wording for `AI_EXTRACT`, tolerances and match thresholds are all tuned by
iteration. Before Phase 3, set `experiment.run_id`, `experiment_id`, `experiment_name` and
`prompt_version` in the project file. They are selected into every terms and findings row, alongside
a `prompt_hash` computed from the assembled prompt and the `AI_EXTRACT` response format. Terms and
findings accumulate across experiments, so runs compare side by side.

## Verification queries at each gate

| Phase | Verification |
|---|---|
| Parse | documents by parse source and class; count with NULL or near-empty parsed text (investigate any); duplicate groups found |
| Extract | per term: count `EXTRACTED` / `NOT_STATED` / `FAILED` / `UNVERIFIED`; families with no effective term period (must be zero for commercial docs) |
| Reconcile | spend coverage: share of invoice amount matched to a family, off-contract, unmatched; findings by type and impact kind **per currency**; findings with empty evidence (must be zero) |
| Evaluate | term accuracy per field; finding precision and recall per type; dollar reconciliation per impact kind and currency; parse and extraction failure counts; pages and tokens per 1K documents |
| Operationalize | semantic view returns the same totals as the findings table; agent answers two scripted questions with cited evidence |

## When the user asks what this costs

Stay in pages and tokens. `AI_PARSE_DOCUMENT` and file-based `AI_EXTRACT` bill per page; a 60-page
MSA with 4 pages of commercial terms is the reason page filtering exists. The clause-level
`AI_COMPLETE` pass bills by tokens and is the largest variable cost on long contracts. Reconciliation
runs no models. Phase 5 reports the measured cost per 1K documents on this corpus; do not quote
figures from elsewhere as this account's numbers.

## Teardown

Read `created_objects` from `spend-leakage-project.yml` and drop exactly what is listed, after
naming the objects and confirming. Warn if `LEAKAGE_FINDINGS` has rows with a non-default
`review_status`: those may already be the basis of supplier conversations.
