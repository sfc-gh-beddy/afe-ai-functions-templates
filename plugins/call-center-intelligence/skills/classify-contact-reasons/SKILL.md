---
name: classify-contact-reasons
description: "Phase 3 of the call-center-intelligence build. Assigns every eligible call a primary contact reason and optional secondary reasons with AI_CLASSIFY over the customer's opening turns using a versioned, described taxonomy table (generic default or customer-supplied), gates on the catch-all share and proposes new labels with AI_AGG for human approval, compares model reasons with agent dispositions, computes repeat contacts from metadata and asks the model only whether the call references a prior contact, separates escalation sources (transfer flag, supervisor request, retention routing), extracts resolution status with AI_EXTRACT, and scores opening and closing customer sentiment with aspect-level AI_SENTIMENT on bounded slices. Use for: contact reasons, call drivers, why customers call, reason codes, taxonomy, repeat contacts, FCR, escalations, supervisor requests, call sentiment."
parent_skill: call-center-intelligence
---

# Contact reasons, repeats, escalations, sentiment

Reads only `CALL_SEGMENTS_REDACTED` and `CALLS_IN_SCOPE`. Writes:

| Table | Grain | Contents |
|---|---|---|
| `CONTACT_TAXONOMY` | label | versioned taxonomy with descriptions |
| `CALL_REASONS` | call x run | primary reason, secondary reasons, disposition agreement |
| `CALL_OUTCOMES` | call x run | resolution status, references prior contact, supervisor request, escalation sources |
| `CALL_REPEATS` | call | metadata-based repeat flags |
| `CALL_SENTIMENT` | call x run | opening and closing customer sentiment, aspects |

Every output row carries `run_id`, `experiment_id`, `prompt_version`, `taxonomy_version`, and the hash of
what was sent.

---

## Step 1 — The taxonomy is a table

Generic default (`tax_v1`). Labels must match the sandbox answer key exactly. Descriptions stay under 25
words (documented AI_CLASSIFY limit) because they are billed on every call.

```sql
CREATE TABLE IF NOT EXISTS CONTACT_TAXONOMY (
    taxonomy_version VARCHAR,
    label            VARCHAR,
    description      VARCHAR,
    parent_label     VARCHAR,
    is_catch_all     BOOLEAN,
    self_service_fit VARCHAR,     -- HIGH | PARTIAL | LOW, customer-confirmed; used by the value readout
    active           BOOLEAN
);

INSERT INTO CONTACT_TAXONOMY
SELECT 'tax_v1', column1, column2, NULL, column3, column4, TRUE FROM VALUES
 ('Billing and payments',    'Questions or problems with charges, fees, refunds, invoices, or making a payment', FALSE, 'PARTIAL'),
 ('Cancel or downgrade',     'Customer wants to cancel, close, pause, or reduce their service or subscription',   FALSE, 'LOW'),
 ('Technical support',       'Service not working, outages, slow performance, equipment or technician appointments', FALSE, 'PARTIAL'),
 ('Account access',          'Login problems, locked accounts, password resets, or updating account security details', FALSE, 'HIGH'),
 ('Order and delivery',      'Status, tracking, or changes to an order, shipment, or equipment delivery',          FALSE, 'HIGH'),
 ('Plan change or upgrade',  'Customer wants to add features, upgrade, or change to a different plan or package', FALSE, 'PARTIAL'),
 ('Complaint about service', 'Formal complaint about staff, a past interaction, or service quality, beyond a single fix', FALSE, 'LOW'),
 ('General inquiry',         'General questions about products, policies, or hours not covered by another reason', FALSE, 'HIGH'),
 ('Other',                   'Misrouted calls, wrong numbers, or calls with no identifiable service reason',      TRUE,  'LOW');
```

`self_service_fit` defaults are placeholders; confirm with the customer before the value readout uses
them, and record that they were confirmed.

**Customer taxonomy.** If the customer supplies their own reason codes (`taxonomy.source: customer`):
insert them under a new `taxonomy_version`, write a description for each with the customer, keep an explicit
catch-all, and if there are more than about 20 labels use `parent_label` for two-level classification
(best-practices C2). Map the old generic labels to the new ones in a crosswalk table if the sandbox is still
used for evaluation.

Build the category array from the table — never hand-type it into the classify call:

```sql
SET taxonomy_version = 'tax_v1';
CREATE OR REPLACE TEMPORARY TABLE _categories AS
SELECT ARRAY_AGG(OBJECT_CONSTRUCT('label', label, 'description', description))
         WITHIN GROUP (ORDER BY label) AS cats
FROM CONTACT_TAXONOMY
WHERE taxonomy_version = $taxonomy_version AND active AND parent_label IS NULL;
```

(Use a regular table instead of a temporary one if this runs across scheduled tasks — best-practices O4.)

## Step 2 — Build the classification input from the opening

Contact reason is what the customer called about, stated at the start (best-practices C1):

```sql
CREATE OR REPLACE TABLE REASON_INPUT AS
SELECT s.call_id,
       LISTAGG(IFF(s.speaker_role = 'AGENT', 'Agent: ', 'Customer: ') || s.text_redacted, '\n')
         WITHIN GROUP (ORDER BY s.seq)                       AS opening_text,
       COUNT_IF(s.speaker_role = 'CUSTOMER')                 AS customer_turns_used
FROM CALL_SEGMENTS_REDACTED s
JOIN CALL_ELIGIBILITY e ON e.call_id = s.call_id AND e.text_eligible
WHERE s.speaker_role IN ('CUSTOMER', 'AGENT', 'UNKNOWN')
  AND (s.start_s IS NULL AND s.seq <= 6 OR s.start_s <= 120)
GROUP BY s.call_id;
```

The window (first six turns, or first two minutes when timestamps exist) includes agent turns because agents
often restate the issue ("so you were charged twice"). Tune the window on the sandbox, not on intuition; widen
it if the `Other` share is high because customers explain late.

For calls whose roles are `UNKNOWN` (full-text blobs without markers), the opening is still usable for
reasons: role-independent outputs do not require role eligibility.

Estimate before running:

```sql
SELECT COUNT(*) AS calls,
       SUM(AI_COUNT_TOKENS('ai_classify', opening_text, (SELECT cats FROM _categories))) AS est_input_tokens
FROM REASON_INPUT SAMPLE (200 ROWS);
-- Scale to the full count. Input-only estimate; AI_CLASSIFY adds its own prompt on top (documented).
```

## Step 3 — Classify

Primary reason: single-label. Secondary reasons: multi-label, run only when the user wants them, because it
is a second call per contact.

```sql
CREATE TABLE IF NOT EXISTS CALL_REASONS (
    call_id VARCHAR, primary_reason VARCHAR, secondary_reasons ARRAY,
    disposition_code VARCHAR, disposition_agrees BOOLEAN,
    classify_error VARCHAR,
    taxonomy_version VARCHAR, prompt_version VARCHAR, input_hash VARCHAR,
    run_id VARCHAR, experiment_id VARCHAR, classified_at TIMESTAMP_LTZ
);

INSERT INTO CALL_REASONS
SELECT r.call_id,
       p:value:labels[0]::STRING                                     AS primary_reason,
       IFF(:with_secondary, m:value:labels, NULL)                    AS secondary_reasons,
       c.disposition_code,
       UPPER(REPLACE(p:value:labels[0]::STRING, ' ', '_')) = UPPER(c.disposition_code) AS disposition_agrees,
       COALESCE(p:error::STRING, m:error::STRING)                    AS classify_error,
       $taxonomy_version, :prompt_version, SHA2(r.opening_text),
       :run_id, :experiment_id, CURRENT_TIMESTAMP()
FROM (
    SELECT ri.*,
           AI_CLASSIFY(ri.opening_text, (SELECT cats FROM _categories),
               {'task_description': 'Identify the main reason the customer contacted a subscription service company, based on the opening of a redacted phone call transcript.'},
               TRUE) AS p,
           IFF(:with_secondary,
               AI_CLASSIFY(ri.opening_text, (SELECT cats FROM _categories),
                   {'task_description': 'List every distinct service reason the customer raised in this redacted phone call opening.',
                    'output_mode': 'multi'},
                   TRUE),
               NULL) AS m
    FROM REASON_INPUT ri
    WHERE NOT EXISTS (SELECT 1 FROM CALL_REASONS x
                      WHERE x.call_id = ri.call_id AND x.run_id = :run_id AND x.classify_error IS NULL)
) r
JOIN CALLS_IN_SCOPE c ON c.call_id = r.call_id;
```

Notes:

- `return_error_details` (fourth argument, `TRUE`) wraps the result in `{value, error}`. Without it, an error is
  a `NULL` that becomes "no reason" (best-practices A1 applies to every AI function, not only transcription).
- Adapt `disposition_agrees` to the customer's disposition vocabulary with a mapping table; the expression above
  only works for the sandbox, whose codes are derived from the labels.
- Two-level taxonomies: classify against parents, then join to children of the chosen parent and classify again.
- `task_description` must stay under 50 words (documented). Do not mention example labels in it; that biases
  toward them.

## Step 4 — Gate on the catch-all and propose labels

```sql
SELECT primary_reason, COUNT(*) AS calls,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct,
       ROUND(100.0 * COUNT_IF(disposition_agrees) / COUNT(*), 1) AS pct_agree_with_disposition
FROM CALL_REASONS WHERE run_id = :run_id
GROUP BY 1 ORDER BY calls DESC;

SELECT COUNT(*) AS calls,
       COUNT_IF(primary_reason IS NULL)  AS no_reason,          -- must be 0 or explained by classify_error
       COUNT_IF(classify_error IS NOT NULL) AS errored
FROM CALL_REASONS WHERE run_id = :run_id;
```

If the catch-all share exceeds `taxonomy.max_other_share`, mine it — do not just widen descriptions blindly:

```sql
SELECT AI_AGG(ri.opening_text,
  'These are redacted openings of customer service calls that did not fit the existing contact reason list. '
  || 'Group them into at most six recurring reasons a contact center would want to track separately. '
  || 'For each, give a short label of three to five words and a one-sentence description. '
  || 'Do not include personal details. Ignore placeholders such as [NAME].') AS proposed_labels
FROM REASON_INPUT ri
JOIN CALL_REASONS r ON r.call_id = ri.call_id AND r.run_id = :run_id
WHERE r.primary_reason = 'Other'
  AND ri.call_id IN (SELECT call_id FROM CALL_REASONS WHERE run_id = :run_id
                     AND primary_reason = 'Other' ORDER BY RANDOM() LIMIT 300);
```

Show the proposal to the user. New labels are added under a new `taxonomy_version` only after they approve,
then `prompt_version` is bumped and the classification re-runs. The count of each proposed group is never taken
from the AI_AGG text (best-practices G1); re-classify to get counts.

## Step 5 — Repeat contacts are a metadata fact

```sql
CREATE OR REPLACE TABLE CALL_REPEATS AS
WITH ordered AS (
    SELECT call_id, customer_id, call_start_ts,
           LAG(call_id)       OVER (PARTITION BY customer_id ORDER BY call_start_ts) AS prior_call_id,
           LAG(call_start_ts) OVER (PARTITION BY customer_id ORDER BY call_start_ts) AS prior_start_ts,
           LEAD(call_start_ts) OVER (PARTITION BY customer_id ORDER BY call_start_ts) AS next_start_ts
    FROM CALLS_IN_SCOPE
    WHERE customer_id IS NOT NULL AND source_route NOT LIKE 'EXCLUDED%'
)
SELECT call_id, customer_id, prior_call_id,
       prior_start_ts IS NOT NULL
         AND DATEDIFF(hour, prior_start_ts, call_start_ts) <= 24 * :repeat_window_days AS is_repeat,
       next_start_ts IS NOT NULL
         AND DATEDIFF(hour, call_start_ts, next_start_ts) <= 24 * :repeat_window_days  AS generated_repeat,
       :repeat_window_days AS repeat_window_days
FROM ordered;
```

`generated_repeat` is the operationally useful flag: this call was followed by another within the window, so
it likely did not resolve the issue. It is the input for "which reasons and which agents generate callbacks".

If `definitions.repeat_same_reason_only` is true, join `CALL_REASONS` and require equal `primary_reason` on
both calls. State the definition in every report.

Calls with no `customer_id` cannot be repeats by definition. Report how many there are; the repeat rate is a
floor when that number is material.

## Step 6 — Outcomes: resolution, prior-contact reference, supervisor request

One AI_EXTRACT call per call over the whole redacted conversation, asking constrained yes/no or short-answer
questions (best-practices X1: strings only). Window long calls to the opening and the last few minutes.

```sql
CREATE OR REPLACE TABLE OUTCOME_INPUT AS
SELECT s.call_id,
       LISTAGG('[' || s.seq || '] ' || INITCAP(s.speaker_role) || ': ' || s.text_redacted, '\n')
         WITHIN GROUP (ORDER BY s.seq) AS convo
FROM CALL_SEGMENTS_REDACTED s
JOIN CALL_ELIGIBILITY e ON e.call_id = s.call_id AND e.text_eligible
GROUP BY s.call_id;

CREATE TABLE IF NOT EXISTS CALL_OUTCOMES (
    call_id VARCHAR, resolution_status VARCHAR, references_prior_contact VARCHAR,
    supervisor_requested VARCHAR, retention_routing VARCHAR,
    was_transferred BOOLEAN, raw_response VARIANT,
    prompt_version VARCHAR, run_id VARCHAR, experiment_id VARCHAR, extracted_at TIMESTAMP_LTZ
);

INSERT INTO CALL_OUTCOMES
WITH x AS (
    SELECT o.call_id,
           AI_EXTRACT(
             text => 'Redacted customer service call. Bracketed tokens such as [NAME] are redaction placeholders.\n'
                     || o.convo,
             responseFormat => {
               'resolution':  'Was the customer''s issue fully resolved by the end of this call? Answer exactly one of: resolved, partially, unresolved',
               'prior':       'Did the customer say they had contacted the company before about this same issue? Answer yes or no',
               'supervisor':  'Did the customer ask to speak to a supervisor or manager? Answer yes or no',
               'retention':   'Was the call routed or transferred to a retention, cancellation, or save team? Answer yes or no'
             }) AS r
    FROM OUTCOME_INPUT o
)
SELECT x.call_id,
       CASE LOWER(TRIM(x.r:response:resolution::STRING))
            WHEN 'resolved' THEN 'RESOLVED' WHEN 'partially' THEN 'PARTIAL'
            WHEN 'unresolved' THEN 'UNRESOLVED' ELSE 'UNPARSED' END,
       CASE LOWER(TRIM(x.r:response:prior::STRING))      WHEN 'yes' THEN 'YES' WHEN 'no' THEN 'NO' ELSE 'UNPARSED' END,
       CASE LOWER(TRIM(x.r:response:supervisor::STRING)) WHEN 'yes' THEN 'YES' WHEN 'no' THEN 'NO' ELSE 'UNPARSED' END,
       CASE LOWER(TRIM(x.r:response:retention::STRING))  WHEN 'yes' THEN 'YES' WHEN 'no' THEN 'NO' ELSE 'UNPARSED' END,
       c.was_transferred,
       x.r, :prompt_version, :run_id, :experiment_id, CURRENT_TIMESTAMP()
FROM x JOIN CALLS_IN_SCOPE c ON c.call_id = x.call_id;
```

The response path is `r:response:<key>` for AI_EXTRACT text extraction; confirm on one row first. Normalize
with an explicit mapping; never coerce an unexpected answer to `NO` (best-practices X1). Count `UNPARSED`.

The escalation columns stay separate (best-practices C6): `was_transferred` is a system fact,
`supervisor_requested` is what the customer asked for, `retention_routing` distinguishes a save transfer from
a complaint escalation.

## Step 7 — Sentiment on bounded slices

AI_SENTIMENT has a 2,048-token window; never send a whole call (best-practices S1).

```sql
CREATE OR REPLACE TABLE SENTIMENT_INPUT AS
WITH cust AS (
    SELECT s.call_id, s.seq, s.text_redacted,
           ROW_NUMBER() OVER (PARTITION BY s.call_id ORDER BY s.seq)      AS rn_first,
           ROW_NUMBER() OVER (PARTITION BY s.call_id ORDER BY s.seq DESC) AS rn_last
    FROM CALL_SEGMENTS_REDACTED s
    JOIN CALL_ELIGIBILITY e ON e.call_id = s.call_id AND e.role_eligible
    WHERE s.speaker_role = 'CUSTOMER'
)
SELECT call_id,
       LISTAGG(IFF(rn_first <= 3, text_redacted, NULL), ' ') WITHIN GROUP (ORDER BY seq) AS opening_customer,
       LISTAGG(IFF(rn_last  <= 3, text_redacted, NULL), ' ') WITHIN GROUP (ORDER BY seq) AS closing_customer
FROM cust GROUP BY call_id;

CREATE TABLE IF NOT EXISTS CALL_SENTIMENT (
    call_id VARCHAR, opening_overall VARCHAR, closing_overall VARCHAR,
    sentiment_shift VARCHAR, closing_aspects VARIANT, sentiment_error VARCHAR,
    run_id VARCHAR, experiment_id VARCHAR, scored_at TIMESTAMP_LTZ
);

INSERT INTO CALL_SENTIMENT
WITH s AS (
    SELECT call_id,
           AI_SENTIMENT(opening_customer, TRUE)                               AS o,
           AI_SENTIMENT(closing_customer,
                        ['agent', 'wait time', 'price', 'resolution', 'policy', 'product'], TRUE) AS c
    FROM SENTIMENT_INPUT
)
SELECT call_id,
       (SELECT f.value:sentiment::STRING FROM LATERAL FLATTEN(input => o:value:categories) f
        WHERE f.value:name::STRING = 'overall'),
       (SELECT f.value:sentiment::STRING FROM LATERAL FLATTEN(input => c:value:categories) f
        WHERE f.value:name::STRING = 'overall'),
       NULL,
       c:value:categories,
       COALESCE(o:error::STRING, c:error::STRING),
       :run_id, :experiment_id, CURRENT_TIMESTAMP()
FROM s;

UPDATE CALL_SENTIMENT SET sentiment_shift =
  CASE WHEN opening_overall = 'negative' AND closing_overall IN ('positive','neutral') THEN 'RECOVERED'
       WHEN opening_overall IN ('positive','neutral') AND closing_overall = 'negative' THEN 'DETERIORATED'
       WHEN opening_overall = closing_overall THEN 'STABLE'
       ELSE 'MIXED' END
WHERE run_id = :run_id;
```

If correlated subqueries over `FLATTEN` are rejected in your context, flatten in a CTE and pivot with
`MAX(IFF(name = 'overall', sentiment, NULL))` instead.

`AI_SENTIMENT(text, TRUE)` — text plus `return_error_details` with no categories — compiles, but the
documentation only shows `return_error_details` after `categories`. Run it on one row and confirm the result
has `value` and `error` keys; if it does not, pass a one-element categories array for the opening slice.

Aspect results: `unknown` means not mentioned; exclude it from aspect rates (best-practices S2). Aspect names
are at most 10 and 30 characters each. Calls whose language is outside AI_SENTIMENT's supported set get
`sentiment_error = 'UNSUPPORTED_LANGUAGE'` and are not scored.

Estimate first: `AI_COUNT_TOKENS('ai_sentiment', opening_customer)` plus the closing slice with categories on a
sample.

## Verification at the gate

```sql
-- Reasons: distribution, catch-all share, errors (above).

-- Repeats against metadata.
SELECT ROUND(100.0 * COUNT_IF(is_repeat) / COUNT(*), 1)        AS pct_repeat,
       ROUND(100.0 * COUNT_IF(generated_repeat) / COUNT(*), 1) AS pct_generated_repeat,
       MAX(repeat_window_days)                                 AS window_days
FROM CALL_REPEATS;

-- Model says "called before" vs metadata says repeat: disagreement is informative.
SELECT r.is_repeat, o.references_prior_contact, COUNT(*)
FROM CALL_REPEATS r JOIN CALL_OUTCOMES o ON o.call_id = r.call_id AND o.run_id = :run_id
GROUP BY 1, 2 ORDER BY 1, 2;

-- Escalation sources kept separate.
SELECT was_transferred, supervisor_requested, retention_routing, COUNT(*)
FROM CALL_OUTCOMES WHERE run_id = :run_id GROUP BY 1, 2, 3 ORDER BY 4 DESC;

-- Unparsed answers.
SELECT COUNT_IF(resolution_status = 'UNPARSED') AS res_unparsed,
       COUNT_IF(references_prior_contact = 'UNPARSED') AS prior_unparsed,
       COUNT_IF(supervisor_requested = 'UNPARSED') AS sup_unparsed
FROM CALL_OUTCOMES WHERE run_id = :run_id;

-- Sentiment coverage and shift.
SELECT sentiment_shift, COUNT(*) FROM CALL_SENTIMENT WHERE run_id = :run_id GROUP BY 1;
SELECT COUNT_IF(sentiment_error IS NOT NULL) AS sentiment_errors FROM CALL_SENTIMENT WHERE run_id = :run_id;
```

A model-detected "called before" on a call with no metadata repeat often means the prior contact was through
another channel or from an unidentified number — worth mentioning in the readout, not a defect.

Then `phases.reasons: done` and record objects.
