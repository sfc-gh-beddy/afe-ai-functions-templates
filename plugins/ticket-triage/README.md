# Ticket Triage

A guided build for a support and IT ticket triage pipeline that runs entirely inside Snowflake, on
tickets the organization already stores.

## The problem

Service desks and support organizations sit on large volumes of tickets: customer cases, IT
incidents, service requests, email-to-case threads, chat transcripts. Most of the cost in handling
them is not the fix. It is everything before the fix:

- **Routing time.** A ticket lands in a general queue, a dispatcher reads it, guesses a category,
  and assigns it. When the guess is wrong the ticket is reassigned, sometimes several times, and the
  clock keeps running. Every reassignment ("ping-pong") adds handling time and lengthens time to
  resolution.
- **Mis-prioritization.** A production outage written up politely sits behind a loud password reset.
  A priority that is wrong in either direction costs: under-prioritized incidents breach SLA,
  over-prioritized noise burns the on-call rotation.
- **Repeat work.** The same issue arrives fifty times during an incident, each one triaged and
  investigated independently. A known issue with a published workaround is rediscovered by every
  agent who picks up a new ticket about it.
- **Avoidable contacts.** A meaningful share of tickets have an answer already sitting in the
  knowledge base. They never needed an agent.

All four are visible in the ticket text that is already in the account. Nothing needs to be acquired.

## What this plugin builds

```
Existing tickets
  -> normalize and redact       thread flattening, signature/disclaimer stripping, optional AI_REDACT
  -> classify                   category / priority / queue against the customer's taxonomy
  -> extract entities           product, version, error code/message, asset id, affected user count
  -> link                       embeddings: duplicate clusters, parent incident, known-issue match
  -> ground and suggest         Cortex Search over KB + resolved tickets; cited suggested resolution
  -> deflection candidates      only where the cited source actually resolves the ask
  -> scored triage output       every row: labels, confidence, links, citations, run identity
```

The deliverable is a triage output table plus a semantic view and a Cortex Agent over it. Every row
carries the predicted category, priority and queue with confidence, the extracted entities, any
duplicate or known-issue link with its similarity score, and, where one applies, a suggested
resolution that cites the knowledge article or resolved ticket it came from.

## What it does not build

- **Ingestion.** Tickets are assumed to be landed in Snowflake already, from the ITSM or CRM system of
  record. Use the Snowflake ingestion and connector skills for that.
- **Write-back to the ITSM tool.** The pipeline ends at the output table. Reassigning a ticket,
  changing its priority, or auto-replying to a customer is an action in the source system, owned by
  that system's workflow. Columns for reviewer decisions are defined so a write-back or a
  human-in-the-loop workflow can be layered on without a migration, but nothing here writes them.
- **An auto-close bot.** Deflection candidates are recommendations with evidence. Whether any of them
  is sent to an end user automatically is a customer policy decision, and the readout says what
  precision would have to be for that to be safe.

## Getting started

Ask for it in plain language. The router picks up phrases like:

- "help me auto-route our support tickets"
- "set up ticket triage on our ServiceNow data"
- "find tickets we could have deflected with the knowledge base"
- "our tickets bounce between queues, can AI fix that"
- "link duplicate incidents to the parent outage"

The build runs in gated phases. Each phase says what it will create, estimates input tokens where it
makes AI calls over a table, waits for confirmation, runs, and shows a verification query. State lives
in `triage-project.yml` in the working directory, so the build can be stopped and resumed.

**Start in the sandbox.** Phase 1 generates a synthetic ticket corpus with a labeled answer key:
true category, priority and queue for every ticket, planted duplicate clusters with a known parent,
known-issue links, and deflection labels tied to specific knowledge articles. That means routing
precision and recall, the priority confusion matrix, and deflection precision are measurable on day
one, before anyone has to agree on how to label real tickets.

**Settle the taxonomy before classifying.** Phase 2 turns the customer's real category and queue
lists into label sets with descriptions. Classification quality is bounded by the taxonomy far more
than by the model, and the most common reason a triage pilot "fails" is that it was scored against a
queue list nobody uses.

## Skills

| Skill | Role |
|---|---|
| `ticket-triage` | Entry point. Intent detection, phase gating, resumable state. |
| `ticket-triage-system-of-record` | Preflight: function and model availability, cross-region, ticket inventory and column mapping, label quality, privileges, PII posture. |
| `ticket-triage-best-practices` | Correctness rules. Always loaded. |
| `seed-ticket-sandbox` | Synthetic tickets, KB articles and a labeled answer key. Runnable SQL. |
| `define-triage-taxonomy` | Category / priority / queue label sets with descriptions, derived from the customer's history. |
| `build-resolution-knowledge-store` | Cortex Search over KB articles and resolved-ticket resolutions. |
| `classify-and-route-tickets` | Normalization, classification, priority, queue and entity extraction. |
| `link-duplicates-and-known-issues` | Embedding-based duplicate clustering and known-issue linking. |
| `suggest-resolutions-and-deflection` | Grounded, cited resolution suggestions and deflection candidates. |
| `operationalize-triage-pipeline` | Stream -> task / dynamic tables, semantic view, Cortex Agent. |
| `evaluate-triage-accuracy` | Per-queue precision/recall/macro-F1, priority confusion matrix, link and deflection precision, cost per 1K tickets, parse-failure accounting. |
| `triage-value-readout` | Routing time, MTTR and deflection value from customer-supplied inputs; POC criteria. |

## Requirements

- A role with Cortex AI function access (`SNOWFLAKE.CORTEX_USER` or equivalent). Preflight verifies
  this and reports the exact missing grant if not.
- `CREATE CORTEX SEARCH SERVICE` on the target schema for the knowledge store.
- A warehouse, and a database and schema the role can create objects in.
- Model availability in the account's region, or `CORTEX_ENABLED_CROSS_REGION` set by an account
  administrator. Verified at preflight.

## A note on PII

Tickets carry names, email addresses, phone numbers, account numbers, IP addresses, hostnames and,
far more often than anyone expects, pasted passwords and API keys. Every AI function call here runs
inside Snowflake; ticket text does not leave the account boundary. Preflight reports existing masking
and row access policies, and the normalization step can run `AI_REDACT` before text reaches a
generative prompt or a search index. A knowledge store built from resolved tickets is a new place
that sensitive text lives, and is governed as one.
