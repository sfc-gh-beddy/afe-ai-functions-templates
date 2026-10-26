# AI Value Plays: unstructured data -> P&L signal

Customers hold most of their untapped value in unstructured data: calls, tickets, emails, contracts, invoices, reviews, notes.
Each play in this repo is a CoCo plugin that finds that data in a customer's Snowflake account, extracts the signal with
Cortex AI Functions, ties it to an OpEx / CapEx / revenue lever, and stands up a pipeline + agent so the business can act on it.

## Play catalog
| Play | Primary lever | Typical data | Status |
|---|---|---|---|
| call-center-intelligence | OpEx (handle time, QA cost, deflection), revenue (save/upsell) | call audio, transcripts | scaffold |
| churn-signals | Revenue (retention) | tickets, survey verbatims, emails + usage | scaffold |
| entity-resolution | OpEx (data ops, duplicate spend), revenue (cross-sell) | CRM/ERP/vendor masters | scaffold |
| voice-of-customer | Revenue (product/pricing), OpEx (returns) | reviews, social, surveys | scaffold |
| document-intake | OpEx (manual processing), working capital | invoices, contracts, claims, forms | scaffold |
| ticket-triage | OpEx (routing, MTTR) | support / IT tickets | scaffold |
| asset-maintenance-notes | CapEx (deferral), OpEx (downtime) | work orders, technician notes, inspections | scaffold |
| spend-and-contract-leakage | OpEx (procurement), CapEx | contracts, POs, invoices | scaffold |
| icd10-code-extraction (HCLS) | Revenue (risk-adjustment recapture), care quality | clinical notes, charts | built: reference implementation |

## Every play follows the same lifecycle
1. **Discover**: find candidate unstructured columns and stages; check privileges, region and cross-region settings.
2. **Sample and size**: run the AI Functions on a sample; estimate tokens and monthly credits.
3. **Extract signal**: AI_CLASSIFY / AI_EXTRACT / AI_SENTIMENT / AI_SUMMARIZE_AGG / AI_TRANSCRIBE / AI_PARSE_DOCUMENT / AI_EMBED.
4. **Quantify value**: map the signal to a P&L lever with customer-supplied unit economics (`shared/references/value-model.md`).
5. **Operationalize**: incremental pipeline (stream -> task -> dynamic tables), semantic view, Cortex Agent for CoWork.
6. **Readout**: one-page value narrative + POC success criteria.

## Reference implementation
`plugins/icd10-code-extraction` is the most complete play and the pattern the others should grow into:
a router skill plus phase skills, a system-of-record preflight, best-practice guardrails, a resumable project state file,
a seeded sandbox, a synthetic test corpus, measured accuracy, and a dbt-or-SQL materialization choice.

## Layout
- `plugins/<play>/`: one CoCo plugin per play (`.cortex-plugin/plugin.json`, `skills/<play>/SKILL.md`).
- `shared/`: discovery SQL, cost estimation, value model and POC template shared by all plays.
- `docs/`: positioning, qualification, competitive notes.

## Install a play locally
`cortex plugin add ./plugins/<play>`
