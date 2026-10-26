---
name: reconcile-spend-to-contract
description: "Phase 4 of the spend-and-contract-leakage build. Reconciles AP invoice lines and POs against extracted, effective-dated contract terms in deterministic SQL and emits leakage findings with dollar impact, arithmetic and cited clause evidence: off-contract spend, expired-contract spend, rate variance (including CapEx equipment bought above the negotiated price), missed volume discounts with cumulative incremental tiers, renewal uplift above the cap, escalator ceilings, and auto-renewal notice deadlines missed or upcoming with trailing-spend exposure. One coverage status per line before any price check, SKU-less lines matched by description with a threshold and margin, per-currency and per-impact-kind totals, an exceptions table for everything it refuses to decide, and review decisions that survive reruns. Triggers: reconcile invoices to contracts, find overcharges, off-contract spend, maverick spend, missed volume discount, price variance, renewal calendar, notice deadlines, rerun reconciliation, why was this line flagged."
parent_skill: spend-and-contract-leakage
---

# Reconcile spend to contract

This is the phase that produces the number, so it is the phase with no models in it. Every finding
is arithmetic on terms that each cite a verified clause, and every total is reproducible to the cent
from the tables this phase writes. The one AI call is `AI_SIMILARITY`, used only to choose which rate
line a SKU-less invoice line refers to, and only when deterministic matching could not.

Prerequisites: `phases.extract: done`; `reconcile.as_of_date` and every `reconcile.*` parameter
confirmed with the user. Read best practices rules 1, 5 to 15, 18 and 20 before running; this phase
is where most of them are enforced.

## What gets created

| Object | Grain | Rebuilt or accumulated |
|---|---|---|
| `INVOICE_CONTRACT_MATCH` | invoice line: coverage status, family, term period, resolved SKU, price-check status | rebuilt |
| `INVOICE_ALLOWED_PRICE` | price-checkable invoice line: pricing basis, allowed price, tier breakdown | rebuilt |
| `LEAKAGE_FINDINGS` | finding: type, impact kind, amount, currency, arithmetic, evidence, review status | accumulated by `run_id` |
| `RECONCILE_EXCEPTIONS` | line or family the pipeline refused to judge, with the reason | accumulated by `run_id` |

SQL: `sql/01_reconcile.sql`. Compute `{{PARAM_HASH}}` as the SHA-256 of the substituted file, so a
finding records the exact tolerances and thresholds that produced it.

## The gate

State the objects. Cost: no inference except `AI_SIMILARITY` on SKU-less in-term lines that neither
an exact SKU nor description containment resolved, against the rate lines of their own family:

```sql
SELECT COUNT(*) AS sku_less_in_term_lines
FROM STG_INVOICE_LINES WHERE sku IS NULL AND service_period_start <= '{{AS_OF_DATE}}';
```

That count times the family's rate-line count is the upper bound on similarity calls; on most AP
data it is small. Restate the parameters the user is about to apply — as-of date, tolerance,
horizon, exposure window — since every one of them changes the output. Confirm with
`ask_user_question`.

## How a line becomes a finding

```
invoice line
  -> coverage         NO_CONTRACT | EXPIRED | PRE_TERM | AMBIGUOUS_FAMILY | TERMS_UNAVAILABLE | IN_TERM
  -> SKU resolution   EXACT_SKU | DESCRIPTION_CONTAINED | DESCRIPTION_SIMILARITY | AMBIGUOUS_SKU | NO_SKU_MATCH
  -> comparability    READY | CURRENCY_MISMATCH | UOM_MISMATCH
  -> pricing basis    TIERED | FIXED | ESCALATED | RENEWAL_CAP | UNPRICED_RENEWAL | TIER_RULE_NOT_APPLIED | NO_RATE_FOR_DATE
  -> comparison       billed - allowed > tolerance
  -> finding          type, impact kind, amount, currency, arithmetic, evidence
```

Every line exits at exactly one step. Lines that exit before a decision go to
`RECONCILE_EXCEPTIONS` with the reason, so the coverage report (V1) and the exceptions (V5) together
account for all spend.

### Coverage first

A line's vendor either has commercial families or it does not (`NO_CONTRACT` -> `OFF_CONTRACT`). If it
does, the family whose term periods cover the service date governs. Two covering families are
resolved by the PO's free-text contract reference only if it names exactly one of them; otherwise
`AMBIGUOUS_FAMILY`. No covering period, with a service date after the last one, is `EXPIRED` ->
`EXPIRED_CONTRACT_SPEND`; before the first one is `PRE_TERM`, an exception, because that is usually a
signed-but-not-yet-effective agreement rather than leakage.

An expired line is never also a rate variance (rule 8). The finding is that nothing was agreed for
the period; any price comparison would be to a price that no longer applied.

Term periods include rolled renewals. A contract that auto-renewed covers its renewal period, which is
why Fabrikam's November 2025 onward is `IN_TERM` and priced against the renewal cap, not reported as
expired.

### SKU resolution, within the family

1. **Exact SKU** against the family's rate lines.
2. **Description containment** for lines without a SKU: the rate line whose description's words all
   occur in the invoice description, choosing the one with the most words, and refusing a tie. This
   is deterministic and handles the common "Senior consultant - daily rate" against "Senior
   Consultant" / "Consultant" case without a model: both are contained, the longer wins.
3. **`AI_SIMILARITY`** only when neither resolved, accepted at `sku_similarity_min` with a margin of
   `sku_similarity_margin` over the runner-up. Below the margin the line is `AMBIGUOUS_SKU`.

Matching never crosses families. A description that matches another supplier's rate line is not
evidence of anything.

### Comparability

Currency and unit of measure must equal the rate line's. A mismatch is an exception with both sides
shown. No conversion happens here: a EUR invoice against a USD rate is a data or contract question,
and a per-case price against per-each billing is a unit question, and either one read as an
overcharge produces a finding off by a factor.

### Pricing basis and the allowed price

| Basis | Allowed price | Finding type |
|---|---|---|
| `TIERED` | per-tier units x tier price, cumulative within the accumulation period, incremental | `MISSED_VOLUME_DISCOUNT` |
| `FIXED` | the stated rate whose window covers the service date | `RATE_VARIANCE` |
| `ESCALATED` | stated rate x (1 + escalator)^anniversaries elapsed since the rate took effect, rounded to the cent | `RATE_VARIANCE` |
| `RENEWAL_CAP` | last stated rate x (1 + cap)^renewal number, rounded to the cent | `UPLIFT_OVER_CAP` |
| `UNPRICED_RENEWAL` | none — renewal price with no stated rate and no cap | exception |
| `TIER_RULE_NOT_APPLIED` | none — tier clause not incremental, or accumulation not by contract or calendar year | exception |
| `NO_RATE_FOR_DATE` | none — in term, but no stated rate covers the date | exception |

Notes that matter on customer data:

- **Retroactive tiers are an exception, not a calculation.** A retroactive clause reprices units
  already invoiced, which in practice is settled as a rebate or credit on a schedule the contract
  defines. Computing it per line would attribute the rebate to the crossing line and overstate that
  line. Report it, show both readings if procurement asks, and let them decide.
- **Escalator compounding** follows `escalator_compounding = ALLOWED_PRICE` (rule 15): the ceiling
  compounds whether or not the supplier took each increase. If the customer's legal reading is that
  increases not taken are forfeited, the `BILLED_PRICE` convention requires the prior year's billed
  price per SKU; add it as a variant of the `ESCALATED` branch and bump `prompt_version`.
- **Escalator anniversaries** are counted from the agreement effective date. If clause
  interpretation returned `CALENDAR_YEAR`, switch the anniversary expression to calendar years for
  that family before running; the default is the more common contract drafting.

### The comparison

```
tolerance per unit = LEAST(price_tolerance_abs, price_tolerance_rel_pct% x allowed unit price)
fixed:   overcharge = quantity x (billed unit - allowed unit),      flagged if billed - allowed > tolerance
tiered:  overcharge = quantity x billed unit - allowed amount,      flagged if per-unit difference > tolerance
```

The overcharge is capped at the line amount, and any line where the cap bit is reported as
`OVERCHARGE_EXCEEDS_LINE`, because that only happens with a unit or currency error (rule 6). The
finding records the tolerance it applied.

### Renewal findings

Evaluated on each auto-renewing family's **current** term period at the as-of date:

- notice deadline already passed -> `AUTO_RENEWAL_NOTICE_MISSED`;
- notice deadline within `renewal_horizon_days` -> `AUTO_RENEWAL_NOTICE_UPCOMING`.

Impact is `COMMITMENT_EXPOSURE`: trailing `exposure_window_months` of in-term invoiced spend under the
family. It is the size of what renews, not money lost; the readout values it only through the
customer's renegotiation assumption. The arithmetic states the deadline convention and the days to or
since the deadline.

A missed deadline is still actionable: many suppliers will agree a short extension or a
renegotiation rather than hold a customer to a renewal it did not want, and procurement needs to know
before the new term starts, not after.

### Evidence on every finding

`evidence` is an array of the terms the finding relied on, each with document, page, clause reference,
verbatim quote and status: the rate line's quote for price findings, plus the tier clause and its
per-tier breakdown, the escalator clause, or the renewal cap and auto-renewal clauses as applicable;
the term end and renewal clauses for expired spend; the renewal, notice and term clauses for renewal
findings; and, for off-contract spend, the registry statement that no governing document exists for
the vendor. `evidence_term_statuses` lists the distinct statuses; a finding containing `UNVERIFIED` or
`FAILED` is not emitted (rule 2).

### Review decisions survive reruns

`finding_id` is deterministic (rule 9). When a finding with the same id was reviewed in an earlier run,
its `review_status`, `reviewed_by` and `reviewed_at` carry forward. Nothing in this plugin sets review
status; it is defined so a procurement workflow can use it.

## Verification at the gate

Run V1 to V6 at the end of the SQL file and show the results.

| Check | Sandbox expectation |
|---|---|
| V1 coverage | Adventure (USD 71,000) `NO_CONTRACT`; Tailspin July to December 2025 `EXPIRED`; everything else `IN_TERM` and `READY` |
| V2 findings | the nine rows in the file's comment, e.g. `RATE_VARIANCE` USD OPEX 12 lines 16,800.00 and CAPEX 1 line 7,500.00; EUR 1,500.00 on its own row |
| V3 evidence | zero rows |
| V4 one per line | zero rows |
| V5 exceptions | zero rows |
| V6 tiers | March 2026 cumulative 80,000 to 120,000, overcharge 600.00 |

On customer data, lead the gate summary with V1 — the share of spend in each currency that reached a
price comparison — before any total from V2. Then V2 per kind and currency, and V5 with the largest
exception amounts. A finding total over a minority of spend is a different claim from one over most
of it, and the reader needs the first number to interpret the second.

Then write `phases.reconcile: done` and record created objects.

## Explaining one finding

When the user asks why a line was flagged, answer from the row, not from memory:

```sql
SELECT finding_type, impact_kind, impact_amount, impact_currency, arithmetic, evidence, tolerance_per_unit,
       pricing_basis, within_audit_window
FROM LEAKAGE_FINDINGS
WHERE run_id = '<run_id>' AND invoice_line_id = '<invoice_line_id>';
```

Show the arithmetic and the quotes. Do not paraphrase the clause; quote it.

## Things this phase deliberately does not do

- **Convert currencies.** Readout only, at customer rates, stated.
- **Judge contract interpretation disputes.** It flags against the extracted reading and cites the
  clause; legal decides whether the supplier owes it.
- **Net credits it cannot see.** If `spend.credit_memo_table` is configured, net credits against the
  lines they reverse in `STG_INVOICE_LINES` before running; otherwise every readout says credits were
  not netted.
- **Limit recovery to the audit window.** It records `within_audit_window` where the contract states
  one and the readout splits on it.
