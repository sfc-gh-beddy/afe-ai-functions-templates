---
name: seed-ticket-sandbox
description: "Generate a synthetic support and IT ticket corpus with a labeled answer key so a ticket triage pipeline can be built, demonstrated and accuracy-tested before touching real tickets. Creates tickets across eight categories and seven resolver queues with true category, impact, urgency, priority and queue; planted duplicate clusters (including two separate outages with near-identical wording to test the time window); known issues linked to KB articles; deflectable tickets tied to a specific article; deflection distractors, access-request and lexical traps, tone-versus-urgency traps, quiet major incidents, multi-intent, subject-only, non-English and fake-secret tickets; deliberately noisy historical labels (default categories, wrong first assignment, reassignments); email threads with signatures and quoted replies; leaky work notes and close notes; a KB with draft and retired articles; and a disjoint few-shot pool. Runnable SQL under sql/. Phase 1 of the ticket-triage build."
parent_skill: ticket-triage
---

# Seed the sandbox

Generate a synthetic ticket corpus with **ground truth**. This is what lets the accuracy harness produce
real per-queue precision and recall, a priority confusion matrix, duplicate-link precision and deflection
precision on day one, and lets the whole build be demonstrated before anyone has to agree how real tickets
should be labeled.

The corpus is constructed so the right answers are known: every ticket is a variant of a **scenario** whose
correct category, impact, urgency, priority, queue, product, error code, known issue and deflectability are
fixed in advance. A correct pipeline recovers them. An incorrect one does not, and the harness says where.

## Why not just point at real tickets

You can, and Phase 1 is skippable. Be honest about what is given up: real tickets carry historical labels,
but those labels record what the current process did — the form default category, the assignment group the
ticket ended in after being bounced, a priority edited after the outage — not what was correct. Scoring
against them measures agreement with past mistakes. Building a trusted labeled holdout on real data takes an
SME's time; `evaluate-triage-accuracy` describes how, and the sandbox lets the pipeline be proven correct
first so that time is spent on measurement rather than debugging.

## Configure before generating

Ask for these, defaulting sensibly. Write them into `triage-project.yml`.

| Parameter | Default | Notes |
|---|---|---|
| Target database / schema | from `target` | The pipeline reads `{{SCHEMA}}` |
| Eval schema | `target.eval_schema` | Answer key and generator truth. **Must differ from the sandbox schema.** |
| Scale | 3 (about 1,150 tickets) | Multiplies non-cluster volume (1 is about 400). Clusters stay fixed so their timing remains tight. Max 6 (generator row cap). Below 3, several queues have too little support to score. |

The label sets are fixed by the scenario catalogue: eight categories (`Access and Identity`, `Network and
VPN`, `Hardware`, `Software and Applications`, `Email and Collaboration`, `Business Applications`,
`Printing`, `Security`), seven queues (`SERVICE_DESK`, `IDENTITY_ACCESS`, `NETWORK_OPS`,
`END_USER_COMPUTING`, `MESSAGING_COLLAB`, `BUSINESS_APPS`, `SECURITY_OPS`), impact and urgency
`HIGH`/`MEDIUM`/`LOW`, and priority `P1`-`P4` derived through `SYNTH_PRIORITY_POLICY`. The taxonomy phase
derives the label tables from the historical columns — **and must reproduce these labels exactly, case
included**, or the harness will score a label-string mismatch as a model failure. Check before running
phase 4.

## What gets created

| Object | Schema | Purpose |
|---|---|---|
| `SYNTH_TICKETS` | sandbox | Tickets with subject, description, channel, requester, timestamps, and **noisy** historical category, priority, first and final assignment group, reassignment count and close notes |
| `SYNTH_TICKET_COMMENTS` | sandbox | Requester follow-ups (pre-assignment, legitimate input) and agent reassignment notes (post-assignment, leakage trap) |
| `SYNTH_KB_ARTICLES` | sandbox | 13 articles: how-to, known-issue, process and policy, including one draft and one retired |
| `SYNTH_KNOWN_ISSUES` | sandbox | Three open known issues, each with a product, error code and article |
| `SYNTH_PRIORITY_POLICY` | sandbox | The "customer's" impact x urgency matrix |
| `SYNTH_FEWSHOT_POOL` | sandbox | Labeled examples from the `EXAMPLE` split only, for `AI_CLASSIFY` few-shot |
| `SYNTH_SCENARIOS` | eval | Scenario catalogue with truth |
| `SYNTH_TICKET_GEN` | eval | Generated tickets with truth and the undecorated core text |
| `SYNTH_ANSWER_KEY` | eval | Ground truth per ticket. **Never joined into the pipeline.** |

`sql/01_seed_sandbox.sql` in this directory is the template. Read it, substitute `{{DB}}`, `{{SCHEMA}}`,
`{{EVAL_SCHEMA}}` and `{{SCALE}}`, show the user the object list, confirm at the gate, and run it. It makes no
AI function calls, so it costs warehouse time only. Do not run it unmodified.

## The answer key is quarantined

- Truth is generated into the eval schema and the pipeline-visible tables are **projected from it without
  truth columns**. Nothing in the sandbox schema carries a true label.
- No pipeline query joins the eval schema. Only `evaluate-triage-accuracy` reads it.
- It is never included in a prompt, a few-shot example, retrieved context or the knowledge store. Few-shot
  examples come from `SYNTH_FEWSHOT_POOL`, whose tickets are `split = 'EXAMPLE'` and are excluded from every
  metric.

Grant the pipeline role no privileges on the eval schema if the sandbox is shared; that turns an accidental
join into an error instead of a leak.

## What the scenarios test

Each `case_role` exists because a specific failure mode needs a ticket that exposes it:

| case_role | Planted in | Catches |
|---|---|---|
| `STANDARD` | most scenarios | ordinary routing accuracy per queue |
| `DEFLECTABLE` | S01, S03, S05, S09, S12 | deflection recall; correct article citation |
| `DEFLECT_DISTRACTOR` | S02 | on-topic-but-not-answerable: user already followed KB-SYN-0001 and is admin-locked. Flagging it is a deflection false positive (best-practices rule 11) |
| `ACCESS_REQUEST` | S04 | on topic for a PROCESS article that resolves nothing by self-service |
| `KNOWN_ISSUE` | S06, S10, S13, S23 | known-issue linking; S13 is linked but **not** deflectable (the workaround is applied by the app team), which tests that linking and deflection are kept separate |
| `DUPLICATE_CLUSTER` | S07, S11, S27 | duplicate clustering and parent identification. **S07 and S27 are two separate VPN outages 30 days apart with near-identical wording** — only the time window separates them. Merging them is an over-clustering failure |
| `LEXICAL_TRAP` | S08 | "printer offline" must not link to or classify as the VPN "offline/unreachable" tickets |
| `TONE_TRAP` | S17 | shouting capitals and URGENT on a P4 mouse ticket (rule 6) |
| `QUIET_P1` | S18 | a politely worded "FYI, no rush" payments outage affecting all customers is P1 |
| `MULTI_INTENT` | S21 | VPN fault plus an access request; primary label scored, secondary reported |
| `SUBJECT_ONLY` | S22 | `NULL` description; catches the `CONCAT` null trap (rule 14) |
| `NON_ENGLISH` | S23 | Spanish text with the same truth as S10; exposes language handling |
| `SECRET_PASTE` | S26 | fake pasted passwords (`SYN-FAKE-...`); tests redaction before indexing |

Two further traps are structural rather than per-scenario:

- **Close notes name the fix and the queue**, and **agent work notes after first assignment name the
  correct queue**. A classifier fed either will score implausibly well; the harness's leakage check
  (`evaluate-triage-accuracy`) looks for exactly that.
- **Historical labels are corrupted** the way real ones are: about a quarter of categories at the default
  `Inquiry / Help`, about a fifth first-assigned to the service desk and then reassigned, a few closed in the
  wrong queue, and some priorities left at a default. Agreement with these is reported separately from
  accuracy.

## Verification before declaring the phase done

Run these and show the results. Each catches a specific seed bug that would otherwise surface later as a
pipeline "failure".

```sql
-- 1. Every ticket has exactly one answer-key row, and nothing else.
SELECT
  (SELECT COUNT(*) FROM <db>.<schema>.SYNTH_TICKETS)                AS tickets,
  (SELECT COUNT(*) FROM <db>.<eval_schema>.SYNTH_ANSWER_KEY)        AS answer_rows,
  (SELECT COUNT(*) FROM <db>.<schema>.SYNTH_TICKETS t
     LEFT JOIN <db>.<eval_schema>.SYNTH_ANSWER_KEY a USING (ticket_id)
   WHERE a.ticket_id IS NULL)                                       AS unlabeled;
-- Expect tickets = answer_rows and unlabeled = 0.
```

```sql
-- 2. Corpus shape by true queue and priority. Every queue present; P1 present.
SELECT true_queue, true_priority, COUNT(*) AS tickets
FROM <db>.<eval_schema>.SYNTH_ANSWER_KEY
WHERE split = 'EVAL'
GROUP BY 1, 2 ORDER BY 1, 2;
```

```sql
-- 3. No truth column leaked into the pipeline schema.
SELECT table_name, column_name
FROM <db>.information_schema.columns
WHERE table_schema = '<SCHEMA>'
  AND (column_name ILIKE 'TRUE\\_%' OR column_name ILIKE '%CASE_ROLE%'
       OR column_name ILIKE '%CLUSTER%' OR column_name ILIKE '%DEFLECTABLE%')
  AND table_name <> 'SYNTH_FEWSHOT_POOL';
-- Expect zero rows. SYNTH_FEWSHOT_POOL carries labels by design (EXAMPLE split only).
```

```sql
-- 4. Planted clusters are tight in time, and the two VPN outages are apart.
SELECT dup_cluster_id, COUNT(*) AS tickets,
       MIN(t.created_at) AS first_at, MAX(t.created_at) AS last_at,
       DATEDIFF(MINUTE, MIN(t.created_at), MAX(t.created_at)) AS span_minutes
FROM <db>.<eval_schema>.SYNTH_ANSWER_KEY a
JOIN <db>.<schema>.SYNTH_TICKETS t USING (ticket_id)
WHERE dup_cluster_id IS NOT NULL
GROUP BY 1 ORDER BY first_at;
-- Expect three clusters, each spanning under ~100 minutes; CL-S07 and CL-S27 about 30 days apart.
```

```sql
-- 5. Every deflectable ticket points at a PUBLISHED article; every known issue exists.
SELECT a.ticket_id, a.deflect_article_id, k.workflow_state
FROM <db>.<eval_schema>.SYNTH_ANSWER_KEY a
LEFT JOIN <db>.<schema>.SYNTH_KB_ARTICLES k ON k.article_id = a.deflect_article_id
WHERE a.is_deflectable AND (k.article_id IS NULL OR k.workflow_state <> 'published');
-- Expect zero rows.

SELECT DISTINCT a.true_known_issue_id
FROM <db>.<eval_schema>.SYNTH_ANSWER_KEY a
LEFT JOIN <db>.<schema>.SYNTH_KNOWN_ISSUES ki ON ki.known_issue_id = a.true_known_issue_id
WHERE a.true_known_issue_id IS NOT NULL AND ki.known_issue_id IS NULL;
-- Expect zero rows.
```

```sql
-- 6. Historical labels are actually noisy (otherwise the "noisy label" lesson is untested).
SELECT
  ROUND(100 * AVG(IFF(t.category = a.true_category, 1, 0)), 1)               AS pct_hist_category_correct,
  ROUND(100 * AVG(IFF(t.first_assignment_group = a.true_queue, 1, 0)), 1)    AS pct_first_queue_correct,
  ROUND(100 * AVG(IFF(t.assignment_group = a.true_queue, 1, 0)), 1)          AS pct_final_queue_correct,
  ROUND(100 * AVG(IFF(t.reassignment_count > 0, 1, 0)), 1)                   AS pct_reassigned
FROM <db>.<schema>.SYNTH_TICKETS t
JOIN <db>.<eval_schema>.SYNTH_ANSWER_KEY a USING (ticket_id);
-- Expect each "correct" figure clearly below 100.
```

```sql
-- 7. Normalization has work to do: email tickets carry footers and quoted replies.
SELECT channel,
       COUNT(*) AS tickets,
       COUNT_IF(description IS NULL) AS subject_only,
       COUNT_IF(description ILIKE '%-----Original Message-----%') AS with_quoted_reply,
       ROUND(AVG(LENGTH(description))) AS avg_chars
FROM <db>.<schema>.SYNTH_TICKETS
GROUP BY 1 ORDER BY 2 DESC;
```

```sql
-- 8. Leakage traps are present (so the harness's leakage check has something to find).
SELECT
  (SELECT COUNT(*) FROM <db>.<schema>.SYNTH_TICKET_COMMENTS
    WHERE author_type = 'AGENT' AND comment_text ILIKE '%reassigning to%')   AS leaky_work_notes,
  (SELECT COUNT(*) FROM <db>.<schema>.SYNTH_TICKETS
    WHERE close_notes ILIKE '%KB-SYN-%' OR close_notes ILIKE '%Workaround applied by%') AS leaky_close_notes;
-- Expect both above zero.
```

Then write `phases.seed: done`, record the created objects (both schemas) in `created_objects`, and point
`tickets` and `knowledge` in `triage-project.yml` at the sandbox tables with this mapping:

| state key | sandbox column |
|---|---|
| `source_table` | `SYNTH_TICKETS` |
| `id_col` / `created_at_col` / `resolved_at_col` | `TICKET_ID` / `CREATED_AT` / `RESOLVED_AT` |
| `subject_col` / `body_col` | `SUBJECT` / `DESCRIPTION` |
| `comments_table` / `comments_ticket_id_col` / `comments_text_col` | `SYNTH_TICKET_COMMENTS` / `TICKET_ID` / `COMMENT_TEXT` |
| `comments_at_col` / `comments_author_type_col` / `first_assigned_at_col` | `COMMENTED_AT` / `AUTHOR_TYPE` / `SYNTH_TICKETS.FIRST_ASSIGNED_AT` |
| `channel_col` / `requester_col` | `CHANNEL` / `REQUESTER_ID` |
| `hist_category_col` / `hist_priority_col` / `hist_queue_col` | `CATEGORY` / `PRIORITY` / `ASSIGNMENT_GROUP` |
| `first_queue_source` | `SYNTH_TICKETS.FIRST_ASSIGNMENT_GROUP` |
| `reassignment_count_col` / `resolution_notes_col` | `REASSIGNMENT_COUNT` / `CLOSE_NOTES` |
| `kb_source_table` / `kb_id_col` / `kb_title_col` / `kb_body_col` / `kb_status_col` | `SYNTH_KB_ARTICLES` / `ARTICLE_ID` / `TITLE` / `BODY` / `WORKFLOW_STATE` |

## Keep it synthetic, and obviously synthetic

- Every identifier carries a `SYN-` prefix; people and companies are transparently fabricated; phone
  numbers are zeros; the pasted "passwords" are `SYN-FAKE-` tokens.
- Ticket content is technically coherent — nonsense tickets make classification look better than it is,
  because there is nothing to disambiguate.
- Do not model the corpus on a specific real organization's taxonomy or a specific ITSM product's field
  names. The customer's real taxonomy comes from preflight and the taxonomy phase.

## Limits of this corpus — say them out loud

- Scale is small. Per-queue F1 on tens of tickets has wide uncertainty; the harness reports support counts
  for that reason. Use the sandbox to prove the pipeline **correct**, not to forecast production accuracy.
- Variants are template-based, so lexical diversity is lower than real tickets. Real tickets are messier;
  expect real-data accuracy to be lower and measure it on a holdout before quoting it.
- The non-English slice is one language and a handful of tickets.

## Teardown

The sandbox is disposable and should be dropped once real data is wired in; otherwise it sits alongside real
output and eventually gets queried by accident. Drop exactly what `created_objects` lists — both schemas'
objects.
