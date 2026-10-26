---
name: extract-save-upsell-signals
description: "Phase 5 of the call-center-intelligence build. Extracts retention and sales signals from redacted, speaker-attributed calls: stated cancel or downgrade intent and its reason, whether the agent made a save offer, the offer type, and the customer's response; buying signals, whether the agent made an upsell or cross-sell offer, the product, and the outcome; competitor mentions. Restricts extraction to eligible calls via contact reason plus an AI_FILTER intent screen so distractors such as cancelling an appointment are not treated as churn, uses AI_EXTRACT with constrained string answers normalized explicitly in SQL, keeps offer and acceptance separate, requires that an offer came from an AGENT turn, and produces the revenue-gap set (intent stated, no offer) the value readout depends on. Use for: save desk, retention calls, cancellations, churn on calls, save offers, upsell, cross-sell, buying signals, competitor mentions."
parent_skill: call-center-intelligence
---

# Save and upsell signals

The revenue side of this play rests on two narrow, defensible sets:

1. **Save gap** — calls where the customer stated an intent to cancel or downgrade and the agent made **no**
   save offer.
2. **Unworked buying signal** — calls where the customer expressed a need a product could meet and the agent
   made **no** offer.

Plus the observed offer acceptance rates, which the value readout uses instead of an assumed rate when the
customer has no historical figure. Everything here keeps **offer** and **outcome** separate
(best-practices X2), and an offer counts only if an agent made it on this call (X4).

Reads `CALL_SEGMENTS_REDACTED`, `CALL_ELIGIBILITY`, `CALL_REASONS`, `CALL_OUTCOMES`. Writes
`SIGNAL_SCREEN`, `CALL_SIGNALS_RAW`, `CALL_SIGNALS`.

---

## Step 1 — Screen which calls to extract from

Running extraction on every call costs tokens and invents offers on calls where "cancel" meant an appointment
(sandbox scenario `DISTRACTOR_CANCEL_APPOINTMENT`). Screen first:

```sql
CREATE OR REPLACE TABLE SIGNAL_SCREEN AS
WITH cust AS (
    SELECT s.call_id,
           LISTAGG(s.text_redacted, ' ') WITHIN GROUP (ORDER BY s.seq) AS customer_text
    FROM CALL_SEGMENTS_REDACTED s
    JOIN CALL_ELIGIBILITY e ON e.call_id = s.call_id AND e.role_eligible
    WHERE s.speaker_role = 'CUSTOMER'
    GROUP BY s.call_id
)
SELECT c.call_id, r.primary_reason,
       r.primary_reason = 'Cancel or downgrade'
         OR AI_FILTER(PROMPT(
              'In these redacted customer turns from a service call, does the customer say they want to cancel, '
              || 'close, leave, switch providers, or reduce their subscription or service (not an appointment or '
              || 'an order)? Customer turns: {0}', LEFT(c.customer_text, 6000)))        AS screen_retention,
       r.primary_reason = 'Plan change or upgrade'
         OR AI_FILTER(PROMPT(
              'In these redacted customer turns from a service call, does the customer express a need, problem, '
              || 'or interest that an additional product, feature, or higher plan could address? Customer turns: {0}',
              LEFT(c.customer_text, 6000)))                                              AS screen_sales,
       :run_id AS run_id
FROM cust c
JOIN CALL_REASONS r ON r.call_id = c.call_id AND r.run_id = :reasons_run_id;
```

`LEFT(..., 6000)` keeps the screen cheap; most intent is stated early. If `AI_FILTER` returns `NULL` (error),
the call is treated as **screened in**, not out — screening out on error hides exactly the calls you want.
Implement that with `COALESCE(AI_FILTER(...), TRUE)` if your account returns `NULL` on error, and count them.

Gate output: how many calls pass each screen and the reason mix of those that passed via the filter rather than
the reason label (the interesting ones: retention intent voiced on a billing call).

Estimate: `AI_COUNT_TOKENS('ai_filter', ...)` on a sample if available for your account; otherwise estimate from
characters and say so.

## Step 2 — Extract

One AI_EXTRACT call per screened call over the full redacted conversation with roles and segment numbers.
Questions are constrained strings (best-practices X1).

```sql
CREATE OR REPLACE TABLE SIGNAL_INPUT AS
SELECT s.call_id,
       'Redacted customer service call. Bracketed tokens such as [NAME] are redaction placeholders. '
       || 'Each line has a segment number and the speaker role, AGENT or CUSTOMER.\n'
       || LISTAGG('[' || s.seq || '] ' || s.speaker_role || ': ' || s.text_redacted, '\n')
            WITHIN GROUP (ORDER BY s.seq)                           AS convo
FROM CALL_SEGMENTS_REDACTED s
JOIN SIGNAL_SCREEN sc ON sc.call_id = s.call_id AND sc.run_id = :run_id
WHERE sc.screen_retention OR sc.screen_sales
GROUP BY s.call_id;

CREATE TABLE IF NOT EXISTS CALL_SIGNALS_RAW (
    call_id VARCHAR, r VARIANT, input_hash VARCHAR,
    prompt_version VARCHAR, run_id VARCHAR, experiment_id VARCHAR, extracted_at TIMESTAMP_LTZ
);

INSERT INTO CALL_SIGNALS_RAW
SELECT call_id,
       AI_EXTRACT(
         text => convo,
         responseFormat => {
           'cancel_intent':     'Did the CUSTOMER say they want to cancel, close, leave, or downgrade their service or subscription? Cancelling an appointment or an order does not count. Answer yes or no',
           'cancel_reason':     'If the customer stated why they want to cancel or downgrade, give the reason in five words or fewer, otherwise answer none',
           'save_offer':        'Did an AGENT, on this call, offer something to keep the customer, such as a discount, credit, pause, or different plan? Something the customer says they heard about elsewhere does not count. Answer yes or no',
           'save_offer_type':   'If an agent made a save offer, answer one of: discount, credit, pause, plan_change, other. Otherwise answer none',
           'save_outcome':      'If an agent made a save offer, did the customer accept it? Answer exactly one of: accepted, declined, undecided, none',
           'buying_signal':     'Did the CUSTOMER express a need or interest that an additional product, feature, or higher plan could meet? Answer yes or no',
           'upsell_offer':      'Did an AGENT offer an additional product, feature, or higher plan on this call? Answer yes or no',
           'upsell_product':    'If an agent offered a product or plan, name it in five words or fewer, otherwise answer none',
           'upsell_outcome':    'If an agent made such an offer, did the customer accept it? Answer exactly one of: accepted, declined, undecided, none',
           'offer_segments':    'List the segment numbers in square brackets where an AGENT made a save or upsell offer, separated by commas, or answer none',
           'competitor':        'If the customer mentioned a competing company or offer, name it in five words or fewer, otherwise answer none'
         }) AS r,
       SHA2(convo), :prompt_version, :run_id, :experiment_id, CURRENT_TIMESTAMP()
FROM SIGNAL_INPUT
WHERE NOT EXISTS (SELECT 1 FROM CALL_SIGNALS_RAW x WHERE x.call_id = SIGNAL_INPUT.call_id AND x.run_id = :run_id);
```

Eleven questions in one call is well inside the documented maximum of 100 entity questions per call; each answer
is capped at 512 output tokens. AI_EXTRACT's text path has no `return_error_details` argument in the documented
signature, so a failure shows as a `NULL` `r` — count it.

## Step 3 — Normalize, and enforce "the agent said it"

```sql
CREATE OR REPLACE TABLE CALL_SIGNALS AS
WITH n AS (
    SELECT call_id, run_id, experiment_id, prompt_version, r IS NULL AS extract_failed,
           LOWER(TRIM(r:response:cancel_intent::STRING))   AS cancel_intent,
           NULLIF(LOWER(TRIM(r:response:cancel_reason::STRING)), 'none') AS cancel_reason,
           LOWER(TRIM(r:response:save_offer::STRING))      AS save_offer,
           LOWER(TRIM(r:response:save_offer_type::STRING)) AS save_offer_type,
           LOWER(TRIM(r:response:save_outcome::STRING))    AS save_outcome,
           LOWER(TRIM(r:response:buying_signal::STRING))   AS buying_signal,
           LOWER(TRIM(r:response:upsell_offer::STRING))    AS upsell_offer,
           NULLIF(LOWER(TRIM(r:response:upsell_product::STRING)), 'none') AS upsell_product,
           LOWER(TRIM(r:response:upsell_outcome::STRING))  AS upsell_outcome,
           NULLIF(LOWER(TRIM(r:response:competitor::STRING)), 'none')     AS competitor,
           REGEXP_SUBSTR_ALL(r:response:offer_segments::STRING, '[0-9]+') AS offer_seqs
    FROM CALL_SIGNALS_RAW WHERE run_id = :run_id
),
agent_offer AS (
    -- An offer counts only if at least one cited segment is an AGENT turn.
    SELECT n.call_id,
           COUNT_IF(s.speaker_role = 'AGENT') > 0 AS offer_seq_is_agent
    FROM n, LATERAL FLATTEN(input => n.offer_seqs) f
    JOIN CALL_SEGMENTS_REDACTED s ON s.call_id = n.call_id AND s.seq = f.value::INT
    GROUP BY n.call_id
)
SELECT n.call_id, n.run_id, n.experiment_id, n.prompt_version, n.extract_failed,
       DECODE(n.cancel_intent, 'yes', TRUE, 'no', FALSE)                    AS cancel_intent,
       n.cancel_reason,
       DECODE(n.save_offer, 'yes', TRUE, 'no', FALSE)
         AND COALESCE(a.offer_seq_is_agent, FALSE)                          AS save_offer_made,
       IFF(n.save_offer_type IN ('discount','credit','pause','plan_change','other'), n.save_offer_type, NULL) AS save_offer_type,
       CASE WHEN DECODE(n.cancel_intent, 'yes', TRUE, 'no', FALSE) IS DISTINCT FROM TRUE THEN 'NOT_APPLICABLE'
            WHEN n.save_offer <> 'yes' OR NOT COALESCE(a.offer_seq_is_agent, FALSE) THEN 'NOT_OFFERED'
            WHEN n.save_outcome IN ('accepted','declined','undecided') THEN UPPER(n.save_outcome)
            ELSE 'UNPARSED' END                                              AS save_outcome,
       DECODE(n.buying_signal, 'yes', TRUE, 'no', FALSE)                    AS buying_signal,
       DECODE(n.upsell_offer, 'yes', TRUE, 'no', FALSE)
         AND COALESCE(a.offer_seq_is_agent, FALSE)                          AS upsell_offered,
       n.upsell_product,
       CASE WHEN n.upsell_offer <> 'yes' OR NOT COALESCE(a.offer_seq_is_agent, FALSE) THEN 'NOT_OFFERED'
            WHEN n.upsell_outcome IN ('accepted','declined','undecided') THEN UPPER(n.upsell_outcome)
            ELSE 'UNPARSED' END                                              AS upsell_outcome,
       n.competitor,
       -- Unparsed yes/no answers are kept visible, never coerced (best-practices X1).
       n.cancel_intent NOT IN ('yes','no') OR n.save_offer NOT IN ('yes','no')
         OR n.buying_signal NOT IN ('yes','no') OR n.upsell_offer NOT IN ('yes','no') AS has_unparsed,
       -- The two revenue-gap sets.
       DECODE(n.cancel_intent, 'yes', TRUE, FALSE)
         AND NOT (DECODE(n.save_offer, 'yes', TRUE, FALSE) AND COALESCE(a.offer_seq_is_agent, FALSE)) AS save_gap,
       DECODE(n.buying_signal, 'yes', TRUE, FALSE)
         AND NOT (DECODE(n.upsell_offer, 'yes', TRUE, FALSE) AND COALESCE(a.offer_seq_is_agent, FALSE)) AS unworked_buying_signal
FROM n LEFT JOIN agent_offer a ON a.call_id = n.call_id;
```

A save offer and an upsell offer can occur on the same call; `offer_segments` is shared between them, which is a
simplification. If the customer's retention motion commonly mixes the two, split `offer_segments` into two
questions.

The `offer_seq_is_agent` check is what catches `DISTRACTOR_DISCOUNT_HEARSAY`: the customer mentions a discount,
the model may answer "yes" to `save_offer`, and the cited segment is a customer turn.

## Step 4 — Join observed outcomes, if the customer has them

If preflight found cancellation or order tables, attach what actually happened after the call, which is far
stronger evidence than the in-call outcome:

```sql
CREATE OR REPLACE VIEW CALL_SIGNALS_WITH_OUTCOMES AS
SELECT s.*,
       EXISTS (SELECT 1 FROM <cancellations_table> x
               WHERE x.customer_id = c.customer_id
                 AND x.cancel_ts BETWEEN c.call_start_ts AND DATEADD(day, :outcome_window_days, c.call_start_ts)) AS cancelled_within_window,
       EXISTS (SELECT 1 FROM <orders_table> o
               WHERE o.customer_id = c.customer_id
                 AND o.order_ts BETWEEN c.call_start_ts AND DATEADD(day, :outcome_window_days, c.call_start_ts)) AS ordered_within_window
FROM CALL_SIGNALS s JOIN CALLS_IN_SCOPE c ON c.call_id = s.call_id;
```

The outcome window is a customer definition; record it in `definitions`. Without these tables, the value readout
labels save and conversion rates as customer-supplied assumptions.

## Verification at the gate

```sql
-- Funnel: retention.
SELECT COUNT(*)                                        AS extracted_calls,
       COUNT_IF(extract_failed)                        AS failed,
       COUNT_IF(cancel_intent)                         AS cancel_intent,
       COUNT_IF(cancel_intent AND save_offer_made)     AS offered,
       COUNT_IF(save_outcome = 'ACCEPTED')             AS accepted,
       COUNT_IF(save_outcome = 'DECLINED')             AS declined,
       COUNT_IF(save_gap)                              AS save_gap,
       COUNT_IF(has_unparsed)                          AS unparsed
FROM CALL_SIGNALS WHERE run_id = :run_id;

-- Funnel: sales.
SELECT COUNT_IF(buying_signal)                         AS buying_signal,
       COUNT_IF(upsell_offered)                        AS offered,
       COUNT_IF(upsell_outcome = 'ACCEPTED')           AS accepted,
       COUNT_IF(unworked_buying_signal)                AS unworked
FROM CALL_SIGNALS WHERE run_id = :run_id;

-- Model said "offer" but no agent segment backs it: should be small and explainable.
SELECT COUNT(*) AS offer_without_agent_segment
FROM CALL_SIGNALS_RAW r JOIN CALL_SIGNALS s ON s.call_id = r.call_id AND s.run_id = r.run_id
WHERE r.run_id = :run_id
  AND LOWER(TRIM(r.r:response:save_offer::STRING)) = 'yes' AND NOT s.save_offer_made;

-- Save gap by agent team and by cancel reason (the operational view).
SELECT c.queue_name, s.cancel_reason, COUNT_IF(s.save_gap) AS gaps, COUNT_IF(s.cancel_intent) AS intents
FROM CALL_SIGNALS s JOIN CALLS_IN_SCOPE c ON c.call_id = s.call_id
WHERE s.run_id = :run_id
GROUP BY 1, 2 HAVING intents > 0 ORDER BY gaps DESC LIMIT 20;
```

A save gap is not automatically an agent failure: some cancellations should not be saved (moves abroad, deaths,
fraud), and the customer's policy may forbid offers on some reasons. Ask which cancel reasons are ineligible for
offers and exclude them from `save_gap` before the readout values the gap.

Then `phases.signals: done` and record objects.
