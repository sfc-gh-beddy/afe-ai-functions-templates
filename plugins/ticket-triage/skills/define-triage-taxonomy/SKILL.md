---
name: define-triage-taxonomy
description: "Build the versioned label sets a ticket triage pipeline classifies against: category, impact, urgency, priority matrix and resolver queue, each label with a description of 25 words or fewer, plus a category-to-queue mapping and a disjoint few-shot example set. Derives candidates from the customer's historical category and assignment-group distributions, flags form-default categories and low-support queues, drafts descriptions with AI_SUMMARIZE_AGG over sample tickets for SME review, validates AI_CLASSIFY constraints (case, word limits, label count), and stores everything under a taxonomy_version that every output row carries. Phase 2 of the ticket-triage build. Triggers: define categories, queue list, assignment groups, taxonomy, label set, priority matrix, impact urgency."
parent_skill: ticket-triage
---

# Define the triage taxonomy

Classification quality is bounded by the taxonomy far more than by the model. A queue list with two
teams that do the same work, a category that is really the form default, or a priority scheme nobody
can state in a sentence will cap accuracy whatever prompt or model is used. And a label set that
changes between experiments makes their metrics incomparable.

This phase produces **reviewed, versioned label tables**. It creates small tables only; the optional
description-drafting step makes AI calls over a sample, and that step goes through the gate.

## What gets created

| Object | Purpose |
|---|---|
| `TAXONOMY_LABELS` | One row per label per dimension (`category`, `impact`, `urgency`, `queue`), with description, active flag, historical support, `taxonomy_version` |
| `PRIORITY_MATRIX` | The customer's impact x urgency -> priority policy, versioned |
| `CATEGORY_QUEUE_MAP` | Deterministic routing knowledge: category (optionally + product) -> queue, or -> candidate queue set |
| `TAXONOMY_EXAMPLES` | Few-shot examples for `AI_CLASSIFY`, from a source disjoint from evaluation |

In `materialization.mode: dbt` these are **seeds** (CSV files in the project) so a taxonomy change is a
reviewed diff. In `sql` mode they are tables created from reviewed `INSERT` statements.

```sql
CREATE TABLE IF NOT EXISTS <db>.<schema>.TAXONOMY_LABELS (
    taxonomy_version VARCHAR,
    dimension        VARCHAR,     -- category | impact | urgency | queue
    label            VARCHAR,     -- canonical, case-exact string passed to AI_CLASSIFY
    description      VARCHAR,     -- 25 words or fewer
    active           BOOLEAN,
    hist_support     NUMBER,      -- tickets in the last 12 months, for low-support flags
    notes            VARCHAR,
    created_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS <db>.<schema>.PRIORITY_MATRIX (
    taxonomy_version VARCHAR,
    impact           VARCHAR,
    urgency          VARCHAR,
    priority         VARCHAR
);

CREATE TABLE IF NOT EXISTS <db>.<schema>.CATEGORY_QUEUE_MAP (
    taxonomy_version VARCHAR,
    category         VARCHAR,
    product          VARCHAR,     -- NULL = any product
    queue            VARCHAR,     -- set when the rule is deterministic
    candidate_queues ARRAY,       -- set when the model must choose among a few
    rule_note        VARCHAR
);

CREATE TABLE IF NOT EXISTS <db>.<schema>.TAXONOMY_EXAMPLES (
    taxonomy_version VARCHAR,
    dimension        VARCHAR,
    example_id       VARCHAR,     -- source ticket id; excluded from evaluation
    input            VARCHAR,
    labels           ARRAY,
    explanation      VARCHAR
);
```

## Step 1 — look at what history says

All of these are aggregates over the source; no ticket text is printed.

```sql
-- Category distribution with reassignment rate. The top row is often a default.
SELECT <hist_category_col> AS category,
       COUNT(*) AS tickets,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
       ROUND(AVG(<reassignment_count_col>), 2) AS avg_reassign
FROM <source_table>
WHERE <created_at_col> >= DATEADD(MONTH, -12, CURRENT_DATE())
GROUP BY 1 ORDER BY 2 DESC;
```

```sql
-- Category x final queue. Rows that put >90% of a category in one queue are
-- deterministic rules; spread rows are where the model has to decide.
SELECT <hist_category_col> AS category, <hist_queue_col> AS queue, COUNT(*) AS tickets,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY <hist_category_col>), 1) AS pct_of_category
FROM <source_table>
WHERE <created_at_col> >= DATEADD(MONTH, -12, CURRENT_DATE())
GROUP BY 1, 2
QUALIFY pct_of_category >= 5
ORDER BY 1, 3 DESC;
```

```sql
-- Low-support queues: candidates to merge, or to accept as unmeasurable.
SELECT <hist_queue_col> AS queue, COUNT(*) AS tickets
FROM <source_table>
WHERE <created_at_col> >= DATEADD(MONTH, -12, CURRENT_DATE())
GROUP BY 1
HAVING COUNT(*) < 30
ORDER BY 2;
```

Use these to propose, and then **ask the user to confirm** with `ask_user_question`:

- **Category set.** Drop form defaults (`Inquiry / Help`, `Other`, `General`) as labels; a ticket that
  fits nothing goes to `UNCLASSIFIED` explicitly. Merge categories that history routes identically and
  that agents cannot tell apart. Aim for twenty or fewer per `AI_CLASSIFY` call (docs warn accuracy
  may drop beyond that); if there are more, make the category two-level and classify the top level first.
- **Queue set.** Queues are teams; ask which still exist (reorganizations leave dead groups in history),
  which are being merged or split, and which are escalation-only (tier-3 queues that never receive
  first assignment should not be first-assignment labels).
- **Impact and urgency definitions.** Use the customer's own if they have them; ITIL-style wording is a
  reasonable starting point only if they say so.
- **Priority matrix.** The customer's matrix, verbatim. If none exists, propose one, mark it
  `proposed`, and get explicit approval — the matrix is policy, not a modelling choice.
- **Multi-intent policy.** Primary-intent routing with a multi-intent flag (default), or multi-label
  category. See best-practices rule 8.

In the sandbox, the expected answer is fixed: the eight categories, seven queues and the
`SYNTH_PRIORITY_POLICY` matrix listed in `seed-ticket-sandbox`. Use those strings exactly.

## Step 2 — descriptions, drafted from data and reviewed by a person

A label without a description is a name the model has to interpret. A good description says what is
**in** and what is commonly confused and **out**, in 25 words or fewer (the documented limit), because
descriptions are paid as input tokens on every classified row.

Drafting from a sample of each historical group with `AI_SUMMARIZE_AGG` gives the SME something concrete
to edit. This step makes AI calls — estimate, gate, then run:

```sql
-- Input-token floor for the drafting step (sample of up to 40 tickets per queue).
WITH s AS (
    SELECT <hist_queue_col> AS queue, CONCAT_WS(' ', <subject_col>, LEFT(<body_col>, 600)) AS txt
    FROM <source_table>
    WHERE <created_at_col> >= DATEADD(MONTH, -6, CURRENT_DATE())
    QUALIFY ROW_NUMBER() OVER (PARTITION BY <hist_queue_col> ORDER BY RANDOM()) <= 40
)
SELECT SUM(AI_COUNT_TOKENS('ai_complete', '<classify_fallback_model>', txt)) AS approx_input_tokens
FROM s;
```

`AI_SUMMARIZE_AGG` does not take a model argument, so this uses the fallback model's tokenizer as an
approximation; say so.

```sql
-- Draft queue descriptions. Output is a DRAFT for SME review, never written
-- straight into TAXONOMY_LABELS.
WITH s AS (
    SELECT <hist_queue_col> AS queue, CONCAT_WS(' ', <subject_col>, LEFT(<body_col>, 600)) AS txt
    FROM <source_table>
    WHERE <created_at_col> >= DATEADD(MONTH, -6, CURRENT_DATE())
      AND <reassignment_count_col> = 0      -- tickets that went to the right queue first time
    QUALIFY ROW_NUMBER() OVER (PARTITION BY <hist_queue_col> ORDER BY RANDOM()) <= 40
)
SELECT queue, AI_SUMMARIZE_AGG(txt) AS draft_scope
FROM s
GROUP BY queue;
```

Restricting to tickets with zero reassignments draws the scope from tickets that were routed correctly
first time, which describes what the queue actually handles rather than what lands there by mistake.

Then turn each `draft_scope` into a description of 25 words or fewer, show the full set to the user in
one table, and let them edit. Rules of thumb for good descriptions:

- Lead with the distinguishing noun: "Remote access: VPN client, gateway and certificate errors. Not
  office Wi-Fi."
- Name the most common confusion explicitly and exclude it ("Not office Wi-Fi", "Not access requests").
- For urgency, state the anti-pattern: "Business harm timing, not requester tone; capitals or 'urgent' are
  not evidence."
- For impact, anchor on scope: "Many users, a whole site, or a customer-facing service" for `HIGH`.

Example — the sandbox label set, as a reviewed artefact:

```sql
INSERT INTO <db>.<schema>.TAXONOMY_LABELS (taxonomy_version, dimension, label, description, active, notes)
SELECT 'tx_v1', column1, column2, column3, TRUE, NULL FROM VALUES
('category','Access and Identity',      'Passwords, account lockouts, MFA, and requests for access to drives or applications.'),
('category','Network and VPN',          'Remote access VPN client or gateway, office Wi-Fi and network connectivity. Not printers.'),
('category','Hardware',                 'Laptops, batteries, monitors and peripherals failing or damaged. Not printers.'),
('category','Software and Applications','Installing or fixing desktop software and licences. Not email, Teams or finance applications.'),
('category','Email and Collaboration',  'Outlook, mail delivery, calendars and Teams meetings or audio.'),
('category','Business Applications',    'Finance application, reports, invoice posting and the customer payments portal.'),
('category','Printing',                 'Printers offline, jammed, missing, or needing to be added. Not network or VPN outages.'),
('category','Security',                 'Phishing emails, suspicious sign-ins, compromised accounts and malware.'),
('impact',  'HIGH',   'Many users, a whole team or site, or any customer-facing service affected.'),
('impact',  'MEDIUM', 'A small group, or one user whose role blocks a business process for others.'),
('impact',  'LOW',    'One user, with no effect on others or on customers.'),
('urgency', 'HIGH',   'Work or revenue is stopped now with no workaround. Requester tone, capitals or the word urgent are not evidence.'),
('urgency', 'MEDIUM', 'Work is degraded or a workaround exists; harm grows within a day.'),
('urgency', 'LOW',    'A request or minor inconvenience that can wait days without harm.'),
('queue','SERVICE_DESK',      'First-line how-to questions and requests resolvable by guidance, without changing systems.'),
('queue','IDENTITY_ACCESS',   'Account locks needing admin action, access grants after approval, identity changes.'),
('queue','NETWORK_OPS',       'VPN gateway and client faults, Wi-Fi, network outages and connectivity.'),
('queue','END_USER_COMPUTING','Laptop and peripheral hardware, printers, software installation and device repair.'),
('queue','MESSAGING_COLLAB',  'Outlook faults, mail delivery and flow, Teams service problems.'),
('queue','BUSINESS_APPS',     'Finance application errors and performance, payments portal and business reports.'),
('queue','SECURITY_OPS',      'Phishing, suspicious sign-ins, compromised accounts and security incidents.');
```

## Step 3 — validate the label sets against the documented constraints

Run every time a label set is written. Each row returned is a defect.

```sql
SELECT taxonomy_version, dimension, label, 'description over 25 words' AS defect,
       ARRAY_SIZE(SPLIT(TRIM(REGEXP_REPLACE(description, '\\s+', ' ')), ' ')) AS words
FROM <db>.<schema>.TAXONOMY_LABELS
WHERE taxonomy_version = :taxonomy_version
  AND ARRAY_SIZE(SPLIT(TRIM(REGEXP_REPLACE(description, '\\s+', ' ')), ' ')) > 25
UNION ALL
SELECT taxonomy_version, dimension, label, 'leading/trailing whitespace in label', NULL
FROM <db>.<schema>.TAXONOMY_LABELS
WHERE taxonomy_version = :taxonomy_version AND label <> TRIM(label)
UNION ALL
SELECT taxonomy_version, dimension, MIN(label), 'labels differ only by case', COUNT(*)
FROM <db>.<schema>.TAXONOMY_LABELS
WHERE taxonomy_version = :taxonomy_version
GROUP BY taxonomy_version, dimension, UPPER(label)
HAVING COUNT(DISTINCT label) > 1
UNION ALL
SELECT taxonomy_version, dimension, NULL, 'more than 20 active labels in one dimension', COUNT(*)
FROM <db>.<schema>.TAXONOMY_LABELS
WHERE taxonomy_version = :taxonomy_version AND active
GROUP BY taxonomy_version, dimension
HAVING COUNT(*) > 20
UNION ALL
SELECT taxonomy_version, dimension, NULL, 'fewer than 2 active labels', COUNT(*)
FROM <db>.<schema>.TAXONOMY_LABELS
WHERE taxonomy_version = :taxonomy_version AND active
GROUP BY taxonomy_version, dimension
HAVING COUNT(*) < 2;
```

```sql
-- Priority matrix must cover every impact x urgency combination exactly once.
SELECT i.label AS impact, u.label AS urgency, COUNT(m.priority) AS rows_in_matrix
FROM (SELECT label FROM <db>.<schema>.TAXONOMY_LABELS
      WHERE taxonomy_version = :taxonomy_version AND dimension = 'impact' AND active) i
CROSS JOIN (SELECT label FROM <db>.<schema>.TAXONOMY_LABELS
            WHERE taxonomy_version = :taxonomy_version AND dimension = 'urgency' AND active) u
LEFT JOIN <db>.<schema>.PRIORITY_MATRIX m
  ON m.taxonomy_version = :taxonomy_version AND m.impact = i.label AND m.urgency = u.label
GROUP BY 1, 2
HAVING COUNT(m.priority) <> 1;
-- Expect zero rows.
```

```sql
-- Every queue referenced by the map exists in the label set.
SELECT m.category, m.queue
FROM <db>.<schema>.CATEGORY_QUEUE_MAP m
LEFT JOIN <db>.<schema>.TAXONOMY_LABELS t
  ON t.taxonomy_version = m.taxonomy_version AND t.dimension = 'queue' AND t.label = m.queue
WHERE m.taxonomy_version = :taxonomy_version AND m.queue IS NOT NULL AND t.label IS NULL;
```

## Step 4 — category-to-queue map

From the category x queue crosstab in step 1, write one row per category:

- `queue` set when history and the user agree the category routes to one team (the deterministic
  rule; `queue_source = 'RULE'` downstream);
- `candidate_queues` set when it legitimately splits (e.g. `Access and Identity` -> `SERVICE_DESK` for
  how-to, `IDENTITY_ACCESS` for admin action). The classifier then chooses among only those, which is
  both cheaper and more accurate than choosing among all queues.

A product column narrows further when the customer's routing genuinely depends on product (the finance
application team versus the payments team). Leave it `NULL` otherwise.

In the sandbox: `Network and VPN` -> `[SERVICE_DESK, NETWORK_OPS]` (how-to versus fault), `Access and
Identity` -> `[SERVICE_DESK, IDENTITY_ACCESS]`, `Printing` -> `[SERVICE_DESK, END_USER_COMPUTING]`,
`Email and Collaboration` -> `[SERVICE_DESK, MESSAGING_COLLAB]`, `Hardware` and `Software and
Applications` -> `END_USER_COMPUTING`, `Business Applications` -> `BUSINESS_APPS`, `Security` ->
`SECURITY_OPS`.

## Step 5 — few-shot examples, from a disjoint source

`AI_CLASSIFY` accepts `examples` (`input`, `labels`, `explanation`). Two or three per confusable pair of
labels helps more than many per easy label. Sources, in order of preference:

1. tickets an SME labels for this purpose, recorded by id and **excluded from evaluation**;
2. in the sandbox, `SYNTH_FEWSHOT_POOL` (the `EXAMPLE` split);
3. never the answer key, never the evaluation holdout, never a ticket that will be scored.

Every example's `example_id` must appear in the harness's exclusion list. Examples cost input tokens on
every row; keep the set small and measure whether it helped (an experiment, not an assumption).

## Versioning

Write `taxonomy.version` in `triage-project.yml` and on every row of every taxonomy table. Any change —
adding, removing, renaming, merging a label, editing a description or example — is a new version.
Classification output from an older version is stale; the router warns before evaluation if versions
differ.

## Verification before declaring the phase done

- the step 3 queries return zero rows;
- a table of the final label sets, descriptions and support counts, shown to the user, with their
  explicit confirmation recorded;
- in the sandbox, the label strings match `SYNTH_ANSWER_KEY` exactly:

```sql
SELECT 'queue' AS dim, a.true_queue AS label
FROM <db>.<eval_schema>.SYNTH_ANSWER_KEY a
WHERE NOT EXISTS (SELECT 1 FROM <db>.<schema>.TAXONOMY_LABELS t
                  WHERE t.taxonomy_version = :taxonomy_version AND t.dimension = 'queue' AND t.label = a.true_queue)
UNION
SELECT 'category', a.true_category
FROM <db>.<eval_schema>.SYNTH_ANSWER_KEY a
WHERE NOT EXISTS (SELECT 1 FROM <db>.<schema>.TAXONOMY_LABELS t
                  WHERE t.taxonomy_version = :taxonomy_version AND t.dimension = 'category' AND t.label = a.true_category);
-- Expect zero rows. This is the one place outside evaluation that reads the
-- answer key, and it reads label STRINGS only, to prevent a scoring mismatch.
```

Then `phases.taxonomy: done` and the created tables in `created_objects`.
