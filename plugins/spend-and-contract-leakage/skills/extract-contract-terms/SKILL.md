---
name: extract-contract-terms
description: "Phase 3 of the spend-and-contract-leakage build. Extracts the commercial terms every leakage finding depends on, each with cited clause evidence verified in SQL: header terms (effective date, initial term end, auto-renewal, renewal term, non-renewal notice, renewal uplift cap, annual escalator cap, currency, payment terms, termination for convenience, early termination fee, audit window) with AI_EXTRACT value-plus-quote pairs; rate cards and volume-tier tables with AI_EXTRACT table extraction and evidence lines located in SQL; prose pricing and clause interpretation (incremental versus retroactive tiers, accumulation period, escalator basis, amendment price changes and effective dates) with schema-constrained AI_COMPLETE on clause windows; then derives rolled term periods with notice deadlines and effective-dated rates with amendment precedence in pure SQL. Triggers: extract contract terms, abstract the contracts, pull the rate card, find renewal dates, notice periods, volume tiers, escalators, what did the amendment change, contract abstraction."
parent_skill: spend-and-contract-leakage
---

# Extract terms with cited evidence

This phase turns contract text into the inputs the reconciliation needs: what each contract allows
a supplier to charge, on which dates, under which renewal and notice terms. Its output contract is
strict: **every term carries the sentence it came from, and that sentence is verified to exist in the
parsed text.** A term that cannot be verified cannot drive a finding.

Prerequisites: `phases.parse: done`; `experiment.run_id`, `experiment_id`, `prompt_version` set;
`models.clause_interpret` pinned and verified; `reconcile.as_of_date` set. Read best practices rules
2, 4, 7, 14, 15, 16 and 22.

## What gets created

| Object | Grain | Accumulates by experiment |
|---|---|---|
| `CONTRACT_HEADER_TERMS` | family x term (12 terms) | yes |
| `CONTRACT_RATE_LINES` | stated price line (rate card row, tier row, prose price, amendment change) | yes |
| `CONTRACT_CLAUSE_RULES` | document; raw schema-constrained JSON | yes |
| `CONTRACT_TERM_PERIODS` | family x term period (initial, then rolled renewals) | rebuilt |
| `CONTRACT_EFFECTIVE_RATES` | family x SKU x tier x effective window | rebuilt |

SQL: `sql/01_extract_terms.sql`. Before running, substitute placeholders and compute
`{{PROMPT_HASH}}` as the SHA-256 of the substituted file (`shasum -a 256`), so every row can say
exactly which prompt and question wording produced it even if someone forgets to bump
`prompt_version`.

## The gate

State the objects, then the cost:

- **Header terms and tables** run `AI_EXTRACT` on the parsed text of governing documents: 24 entity
  questions and 2 table questions per document (a table question counts as 10 entity questions
  toward the limit of 100 per call). Input is the full parsed text; billing is by input and output
  tokens.
- **Clause interpretation** runs `AI_COMPLETE` on the pricing and renewal **window** of each
  governing document (the keyword-matched lines and their neighbours) and on the full text of each
  amendment. Estimate it:

  ```sql
  SELECT COUNT(*) AS documents,
         SUM(AI_COUNT_TOKENS('ai_complete', '{{MODEL}}', full_text)) AS full_text_tokens
  FROM CONTRACT_REGISTRY
  WHERE family_role IN ('GOVERNING', 'AMENDMENT');
  ```

  Report this as an upper bound: the window is a fraction of the full text on long agreements, and
  the prompt adds a fixed few hundred tokens per document. Output is capped at 2,048 tokens per call.
- **Prose pricing** runs `AI_COMPLETE` only on governing documents whose tables produced no verified
  rate line.

Confirm with `ask_user_question`, then run.

## Why it is built this way

### Value and quote, asked together

Each header term is two `AI_EXTRACT` questions: the value, in a fixed format (ISO date, whole
number, `TRUE`/`FALSE`, three-letter currency), and the sentence that states it, word for word.
Then SQL checks the quote occurs in the document after collapsing whitespace and case. The check is
cheap and catches the failure that matters most: a value filled from the model's expectations of a
typical contract rather than from this one.

The questions are written to separate terms that contracts conflate:

- **Escalator versus renewal cap.** "Up to 3% on each anniversary" is an in-term escalator;
  "renewal fees will not increase by more than 5%" is a renewal cap. The escalator question says
  explicitly not to answer with a renewal cap.
- **Termination for convenience versus cure period.** "Thirty days to cure a breach" is not a
  termination-for-convenience notice.
- **"Expires" versus "renews".** `auto_renewal` is `TRUE` only on explicit automatic renewal, and
  `FALSE` on explicit expiry or "renewal requires a written agreement". Silence is `NOT_STATED`, which
  reconciliation treats as no auto-renewal but reports as an exception, because silence in a
  contract that has been invoiced past its end date is worth a human look.

### Statuses that keep failure visible

`EXTRACTED`, `NOT_STATED`, `FAILED`, `UNVERIFIED` (rule 16). `NOT_STATED` requires the model to have
answered the literal `NOT_STATED`; a NULL, an error or a value that does not normalize is `FAILED`.
This is what stops an extraction error from reading as "this contract has no renewal clause".

### Rate cards: table extraction, then evidence located in SQL

`AI_EXTRACT` table extraction returns each column as an array. Table rows have no natural quote, so
SQL finds the evidence: the first parsed line that contains the price digits **and** the item code
(or, for tier rows, the tier minimum; or the description when there is no code). That line becomes
`evidence_quote`. A row whose line cannot be found is `UNVERIFIED` — usually a table split across
pages, or a price the model reformatted.

Prices are normalized by removing currency tokens, separators and whitespace and then **requiring a
plain decimal**. "see Section 2.2" becomes `NON_NUMERIC`, not a price of 2.2; when the same SKU has
tier rows it is marked `SUPERSEDED_BY_TIERS` and dropped without counting as a failure. Currency is
taken from the price string where it carries a symbol or code, else from the contract's currency
term — never assumed to be the buyer's home currency (rule 12).

Units are normalized to `HOUR`, `DAY`, `EACH`, `MONTH`, `YEAR`, or kept as stated. Reconciliation
refuses to compare a line whose unit differs from the rate's unit (rule 6). Add the customer's unit
vocabulary to the mapping when preflight shows others (cases, pallets, kilograms, licenses).

### Prose pricing: AI_COMPLETE, only where tables found nothing

Subscriptions and managed services often state price in a sentence: "Fees: $8,000.00 per month".
Table extraction finds nothing there, and that is correct. For governing documents with no verified
rate line, a schema-constrained `AI_COMPLETE` reads the pricing window and returns rate lines with an
evidence quote that must both occur in the document **and contain the price**. The prompt forbids
computing or inferring prices.

### Clause interpretation: the questions extraction cannot answer

Four things decide the arithmetic and are not single values:

| Field | Values | Why it matters |
|---|---|---|
| `tier_application` | `INCREMENTAL`, `RETROACTIVE`, `NOT_STATED` | changes the missed-discount total by a multiple at the crossing (rule 7) |
| `tier_accumulation_period` | `CONTRACT_YEAR`, `CALENDAR_YEAR`, `PER_ORDER`, `PER_INVOICE`, `NOT_STATED` | what resets the cumulative count |
| `escalator_basis` | `ANNIVERSARY_OF_EFFECTIVE_DATE`, `CALENDAR_YEAR`, `NOT_STATED` | when an escalated ceiling starts |
| `amendment_changes` | per item: `REPLACED`, `UNCHANGED`, `ADDED`, `REMOVED`, new price, effective date, quote | amendment precedence (rule 4) |

Each comes back through a JSON schema with `enum` constraints, `required` on every field and
`additionalProperties: false` (which OpenAI-family models require and others tolerate), at
temperature 0. A NULL response is `FAILED` and counted.

The model sees the **clause window**, not the contract: lines matching pricing, tier, escalation,
renewal and amendment keywords, plus one line either side. On a 60-page MSA this is the difference
between a few thousand tokens and a hundred thousand. If a customer's contracts phrase these
clauses without any of the keywords, extend the regex in `_X_WINDOWS` rather than switching to full
text, and measure the change in Phase 5.

Amendment price changes become rate lines with `source_kind = 'AMENDMENT'` and are verified like any
other quote. `UNCHANGED` entries are kept as `NO_PRICE_CHANGE` so it is visible that the amendment
was read and deliberately left that price alone.

### Term periods: rolled, pinned, conventional

`CONTRACT_TERM_PERIODS` starts from the effective date and initial term end (or a verified amended
term end), then, while the contract auto-renews, adds renewal periods of `renewal_term_months` until
a period starts after the as-of date. The **current** period is the one containing the as-of date,
and its `notice_deadline` is `period_end` minus `notice_days` calendar days, with that convention
written on the row (rule 19). A family missing either date gets no periods and is reported by V5;
reconciliation will not invent coverage for it.

### Effective rates: precedence, then non-overlapping windows

Base rates span the initial term. An amendment rate starts on the amendment's effective date (from
clause interpretation, else the amendment's document effective date) and closes the window of the
rate it replaces the day before. An amendment that does not restate a unit or currency inherits it
from the base row it replaces. The result is checked for overlapping windows (V4), which must be zero.

Renewal-term and escalated prices are **not** rows in this table. They are ceilings derived per
invoice line during reconciliation from the term periods and the cap and escalator terms, so the
derivation is visible on each finding rather than hidden in a precomputed rate.

`tier_upper_exclusive` is the next tier's minimum, so tier arithmetic uses half-open ranges and a
mis-parsed `tier_max` cannot open a gap or overlap between tiers.

## Verification at the gate

Run V1 to V7 at the end of the SQL file and show the results.

| Check | Sandbox expectation |
|---|---|
| V1 header term status | 84 rows (7 families x 12 terms); zero `FAILED`, zero `UNVERIFIED` |
| V2 rate lines | `GLOVE-NIT` rate-card row `SUPERSEDED_BY_TIERS`; Fabrikam priced by `PROSE` (its item code and price are on different lines, so any table row is `UNVERIFIED`); Wide World by either path, since its SKU and price share a sentence; Northwind `JAN-STD` replaced in an `AMENDMENT` row, `JAN-DEEP` `NO_PRICE_CHANGE` |
| V3 effective rates | 14 rows matching the rate key: `JAN-STD` 42.00 to 2025-12-31 then 44.00 from 2026-01-01; three `GLOVE-NIT` tiers with upper bounds 100,000 and 500,000; `SENIOR-CONS` and `CONS` in EUR |
| V4 overlaps | zero rows |
| V5 families without periods | zero rows |
| V6 term periods | Fabrikam current period 2025-11-01 to 2026-10-31, deadline 2026-08-02; Northwind and Wide World current period 0, deadline 2026-11-01 |
| V7 clause failures | zero rows |

Phase 5 scores all of this against the key. Here, on the sandbox, compare V3 and V6 to the
expectations by eye and stop if they differ: reconciliation on wrong rates produces wrong findings
at full confidence.

On customer data, also show a sample of five `EXTRACTED` terms with their quotes to the user — only
if they ask, and from documents they are entitled to read — so a human sees what "cited evidence"
looks like before trusting a total.

Then write `phases.extract: done` and record created objects.

## Iterating

Every change to a question, the clause prompt, the window regex or the unit mapping is a new
`prompt_version` and a new `experiment_id`. Phase 5 compares experiments side by side. The tables
accumulate by experiment, so the previous run's terms remain for comparison until explicitly
deleted.

Common improvements, in the order they usually pay off:

1. Add the customer's own synonyms to questions ("Subscription Term", "Contract Period", "Service
   Term") once a reviewed sample shows misses.
2. Extend the unit mapping.
3. Re-parse documents whose rate cards came back `UNVERIFIED` in `LAYOUT` mode if they were parsed in
   `OCR` mode, or with `AI_EXTRACT` `config => {'scale_factor': 2}` on the file when the table is in
   small print (this doubles tokens per page and halves the page limit).
4. Move to a stronger clause model only if Phase 5 shows clause-rule errors, not by default.
