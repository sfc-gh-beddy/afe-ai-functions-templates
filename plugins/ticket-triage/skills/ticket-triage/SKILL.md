---
name: ticket-triage
description: "Auto-classify, prioritize and route support/IT tickets and find deflection candidates."
metadata:
  author: Bracken Eddy
  version: "0.1.0"
---

# ticket-triage

**P&L lever:** OpEx (routing, MTTR)
**AI Functions:** AI_CLASSIFY, AI_EXTRACT, AI_FILTER

Status: scaffold. Follows the shared lifecycle in the repo README (discover -> sample and size -> extract -> quantify -> operationalize -> readout).

## Workflow
1. Discover candidate data (shared/sql/discover_unstructured.sql). Confirm the business owner and the decision this signal should change.
2. Sample 500-1,000 rows; run the extraction; estimate tokens with AI_COUNT_TOKENS and project monthly credits.
3. Define the extraction schema (references/schema.md), review the sample output with the customer.
4. Quantify value with shared/references/value-model.md using customer-supplied inputs only.
5. Build the incremental pipeline, semantic view and Cortex Agent.
6. Produce the readout and POC criteria (shared/references/poc-template.md).

## Discovery questions
- TODO

## Gotchas
- Check CORTEX_ENABLED_CROSS_REGION and model availability in the customer's region before demoing.
