---
name: adjudicate-match-pairs
description: "Phase 4 of the entity-resolution build. Sends only the REVIEW band of scored pairs to AI_COMPLETE with a JSON-schema response_format, temperature 0, return_error_details and show_details, asking for a MATCH / NO_MATCH / UNSURE decision, a separate relationship (same entity, parent/subsidiary, sibling location, product variant, unrelated), a confidence, and structured attribute-level reasons. Prompts are stored and hashed, record order is randomized by pair hash, identifiers and raw tax ids are never shown, a swapped-order probe measures position bias, failures are counted rather than read as NO_MATCH, reasons are validated in SQL, and acceptance requires SAME_ENTITY plus a confidence threshold. Covers when snowflake-decision can replace AI_COMPLETE and how to verify it. Use when adjudicating match candidates with an LLM, explaining match decisions, or diagnosing model over-merging."
parent_skill: entity-resolution
---

# Adjudicate match pairs

The model sees only the pairs the scorer could not decide. Its job is narrow: decide identity, say
what the relationship is when it is not identity, and give reasons a steward can check. It does not
decide thresholds, does not cluster, and never writes golden values.

`sql/01_adjudicate.sql` is the template.

## Gate: what this phase creates, and what it costs

| Object | Type | Notes |
|---|---|---|
| `ER_ADJ_PROMPTS` | table, accumulates by `run_id` | Assembled prompt text and `prompt_hash` per pair and order |
| `ER_MATCH_DECISIONS_RAW` | table, accumulates | Full `AI_COMPLETE` result as VARIANT |
| `ER_MATCH_DECISIONS` | table, accumulates | Parsed decision, relationship, confidence, reasons, outcome, token usage |
| `ER_PIPELINE_QUALITY_LOG` | rows appended | Failures, missing reasons, invalid reasons |

Build the prompts (section 1), then run section 2 and show the user, per entity type: number of calls
(review pairs, capped at `adjudicate.max_pairs_per_run`, plus the swap-probe sample) and the
`AI_COUNT_TOKENS` input-token floor. Say that output tokens bill on top and that JSON-schema overhead is
billed as input but may not be counted by the estimate. Then confirm.

If the cap binds, the template samples the review band uniformly by hash rather than taking the
highest-scoring pairs. Taking the top of the band would adjudicate the easy cases and leave the hard
ones unseen, and every metric downstream would be biased toward looking good.

## Model choice

The task is careful comparison of short structured records against explicit rules — a mid-to-strong
instruction-following model with reliable structured output. Preflight pins `adjudicate.model` after
confirming it is `GA` and available in the region (or via cross-region inference). The value in
`er-project.yml` is illustrative until preflight records `verified_on`.

Do not silently substitute. If the preferred model is unavailable or `LEGACY`, say which model is used
instead and treat the change as a new experiment.

### `snowflake-decision`

The documentation's October 2026 release note announces **Snowflake Decision** as a private preview: a
`snowflake-decision` model used through `AI_COMPLETE` that evaluates content against user-defined
questions — choice questions that return a selected option with per-option probabilities and a
confidence, rubric scores, and true-or-false assessments that return a probability. That shape fits
this phase well: a choice question over `MATCH` / `NO_MATCH` / `UNSURE`, a second choice over the
relationship, and a true-or-false assessment such as "these records refer to the same legal entity",
with calibrated probabilities feeding the acceptance threshold directly. The regional availability
table also lists a `snowflake-decision-fast` model.

What was **not** verifiable from public documentation while writing this plugin: the request format
(the detailed page is limited-access), whether it can return free-text reasons alongside the
probabilities, and its region coverage beyond the availability table. So:

1. Preflight checks whether the account can see the model (`SHOW CORTEX BASE MODELS IN SCHEMA
   SNOWFLAKE.MODELS` and a `EXPLAIN_PRIVILEGES` probe). If not, use `AI_COMPLETE` with the schema
   below — that is the default and it is fully specified here.
2. If the account is enrolled, get the request format from the account's preview documentation, write
   it into this phase as a separate code path, and set `adjudicate.engine: snowflake_decision`. Do not
   construct the request from the release note's prose.
3. If it does not return reasons, run it for the decision and probabilities and keep reasons from an
   `AI_COMPLETE` call on the pairs that will actually be shown to stewards — reasons are still required
   for every accepted model match (rule 21).
4. Compare the two engines as experiments on the same review band with `evaluate-match-accuracy`.
   Report precision, recall, review-band resolution rate, and tokens. Do not assume either is better.

## The prompt

Built in SQL, stored in `ER_ADJ_PROMPTS`, hashed, and the stored text is what is bound into the call.
It contains:

- the entity noun (customer organization, supplier organization, product as exact sellable item)
- the identity rules: same legal entity only; parents, subsidiaries, sister companies, franchisees and
  separately registered branches are not the same entity; product size, pack and color variants are
  not the same item; missing is not different; system comparisons are authoritative; formatting,
  abbreviations, suffixes and typos are normal for duplicates; use `UNSURE` when the evidence does not
  support a confident call
- the two records, labeled `Record 1` and `Record 2`, in an order chosen by hash of the pair
- system comparisons computed in SQL — tax id, phone, domain for parties; GTIN, MPN, size for products —
  stated as `identical`, `different`, or `not available on both`
- "Respond in JSON"

What it never contains: record ids, source keys, raw tax ids, bank or payment fields, cluster ids,
anything from the answer key. Showing the source system name is deliberate — duplicates across systems
are expected, and two records in the same system are slightly less likely to be duplicates — but a
source-system name that encodes the answer (for example a system called `DEDUP_OUTPUT`) must be
removed.

### Why the relationship is separate from the decision

A single `MATCH` / `NO_MATCH` field makes the model collapse "related" into one side or the other.
Asking for the relationship separately lets the model say "these are related, and not the same
entity" — which is the right answer for siblings and franchises, and is exactly the information an
account team wants for a single customer view (a parent and its subsidiaries are one account
hierarchy, not one record). Only `decision = MATCH` with `relationship = SAME_ENTITY` produces a merge
edge. The other relationships are carried to the relationship output in `build-golden-records`.

## The schema

The JSON schema in section 3 requires `decision`, `relationship`, `confidence`, `reasons`, and
`summary`, with enums on the categorical fields and on each reason's `attribute` and `effect`. It
deliberately avoids `minimum`, `maximum`, `minItems`, which are documented as unsupported and raise
errors. Range and non-emptiness are enforced in SQL instead.

## Calling and parsing

- `temperature: 0`, `max_tokens: 1024`.
- `show_details => TRUE` for per-call usage.
- `return_error_details => TRUE`: the documented return is an object with `value` and `error`; a failed
  row has `value` NULL and an error message, and does not stop the statement. The return type is a
  typed `OBJECT(value VARIANT, error VARCHAR)`, which the template casts to `VARIANT` for storage.
- Idempotent: rows that already have a non-null response for this `run_id`, pair and order are not
  called again, so a retry after a partial failure re-bills nothing that succeeded.
- Reuse across runs (section 3a): a pair whose assembled prompt is byte-identical to one already
  answered by the same model copies that response instead of calling again. The prompt carries every
  input the model sees, so identical `prompt_hash` means an identical question. This is what keeps
  scheduled runs proportional to change volume. Skip 3a for runs whose purpose is to re-ask (a
  temperature or model-version experiment with an unchanged prompt), and never put run-specific text
  (dates, run ids) into the prompt, or reuse never fires. The section 2 estimate counts every prompt, so
  it is a ceiling when reuse applies; report how many rows 3a filled.

Parse with the single defensive accessor (rule 20) that handles `value` wrapping and the
`structured_output[0].raw_message` shape shown in the structured-outputs reference. Then verify the
accessor: a row with no error but no parsed decision is an accessor bug, and the gate checks for it.

## Outcomes

| Outcome | Condition | Effect downstream |
|---|---|---|
| `MODEL_MATCH` | `MATCH`, `SAME_ENTITY`, confidence at or above `thresholds.model_accept_confidence`, at least one reason, no invalid reasons | merge edge |
| `MODEL_NO_MATCH` | `NO_MATCH` at or above the confidence threshold | no edge; relationship recorded |
| `STEWARD_REVIEW` | `UNSURE`, low confidence, `MATCH` with a non-identity relationship, no reasons, or a reason naming an attribute that was not in the prompt | no edge; queued for a person |
| `MODEL_FAILED` | NULL or unparseable | no edge; counted; never read as `NO_MATCH` |

Confidence here is the model's self-reported probability. It is useful for routing, not as a measure
of accuracy — `evaluate-match-accuracy` reports whether `MODEL_MATCH` at a given confidence is actually
right, and the acceptance threshold should be set from that, not from the model's own number.

## Position bias

Section 1 adds a swapped-order copy of `adjudicate.position_swap_sample` pairs. Section 5c reports the
flip rate. A non-trivial flip rate means boundary decisions depend on presentation order: raise
`model_accept_confidence`, strengthen the rules in the prompt, or try a stronger model — and record the
flip rate in the readout, because a steward reviewing these pairs should know.

## Gate verification

From section 5:

- accessor mismatch — must be zero
- outcome, decision and relationship distribution with average confidence
- position-bias flip rate
- real prompt and completion tokens from `show_details`; reconcile with
  `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY` later (account usage views are not
  real-time)
- ten decisions with reasons, read in the session — not summarized

Also report from `ER_PIPELINE_QUALITY_LOG`: failures, decisions without reasons, decisions with invalid
reasons. All three are lost or unusable decisions, and all three count against recall in evaluation.

Write `phases.adjudicate: done` and the created objects.

## When to skip this phase

If the review band is empty after calibration, or the user wants every review pair to go to stewards
instead of the model, mark `adjudicate: skipped`. Golden records are then built from rule and score
edges only, and review pairs are listed for stewards with their features. Say plainly that recall on
the review band will be whatever stewards resolve.
