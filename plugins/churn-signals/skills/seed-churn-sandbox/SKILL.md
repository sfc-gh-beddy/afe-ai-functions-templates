---
name: seed-churn-sandbox
description: "Generate a deterministic synthetic B2B customer base for the churn-signals play: accounts with ARR and segment, 18 months of usage, support tickets, survey verbatims, emails and CSM call notes with planted churn reasons, renewal outcomes as legitimate training labels, a quarantined answer key (per-interaction true reasons, latent cohorts including silent churners and saved accounts), deliberate distractors that look risky but are not, and three planted label-leakage traps (outcome-derived CRM columns, post-cutoff notices and exit surveys, post-churn zero usage). Makes reason precision/recall and model AUC/lift measurable on day one. Phase 1 of the churn-signals build. Triggers: seed churn sandbox, synthetic churn data, churn test data, labeled churn set, regenerate the sandbox."
parent_skill: churn-signals
---

# Seed the churn sandbox

## Why not just point at real data

Two of the three things this play claims need ground truth that real data does not have on day one:

- **Reason accuracy.** Nobody has labeled why each ticket signals risk. Without labels, the
  classifier's output is plausible-looking and unmeasured.
- **Leakage-free model accuracy.** Real CRMs leak in ways that are only obvious once you know where
  to look. The sandbox plants the three most common leaks so the audit can be shown catching them,
  and so a leaky model's AUC can be put next to an honest one on the same data.

It also lets the whole build be demonstrated before anyone grants access to customer support data.

## Configure before generating

Ask once, record in `churn-project.yml`, then substitute into `sql/01_seed_sandbox.sql`:

| Placeholder | Meaning | Default |
|---|---|---|
| `{{DB}}` | target database | from `target.database` |
| `{{SCHEMA}}` | sandbox schema -- plays the customer's data | `SANDBOX` |
| `{{EVAL_SCHEMA}}` | answer key schema -- quarantine | `SANDBOX_EVAL` |
| `{{N_ACCOUNTS}}` | accounts | `1000` |
| `{{ANCHOR_DATE}}` | the sandbox's "today" | a recent month end |
| `{{HORIZON_DAYS}}` | prediction horizon | `prediction.horizon_days` (90) |

Size guidance. About two thirds of accounts have an observed renewal (labeled); churn is roughly 15-20%
of those, and the TEST split is the latest 30% by time. At 600 accounts TEST holds only ~20 churners,
which makes AUC intervals wide. Use **1000-1500** for model work; 400 is enough for reason accuracy
alone. Interactions run about 6-7 per account, so 1000 accounts is roughly 6,500 interactions --
estimate tokens with `extract-churn-signals/sql/00_size_and_render.sql` before extracting.

**Determinism.** Every random choice is a hash of `(account_id, salt)`, not `RANDOM()`. The same
parameters produce byte-identical data, so experiments on "the sandbox" are comparable across days
and people. Record the parameters; `SYN_MANIFEST` stores them too.

## What gets created

In `{{SCHEMA}}` -- what a customer's account would hold:

| Table | Contents |
|---|---|
| `SYN_REASON_TAXONOMY` | 8 churn reasons + `NONE`, with AI_CLASSIFY-ready labels and descriptions |
| `SYN_ACCOUNTS` | name `(Synthetic)`, segment, industry, region, ARR, seats, contract start, renewal date, CSM, **`CRM_STATUS` and `CRM_CANCEL_REASON` (leak trap 1)** |
| `SYN_RENEWAL_OUTCOMES` | observed renewals: `RENEWED`/`CHURNED`, `notice_date`, `recorded_at` -- the legitimate training labels |
| `SYN_USAGE_MONTHLY` | 18 months of active users, seats, logins; **zero after a churned renewal (leak trap 3)** |
| `SYN_INTERACTIONS` | tickets, survey verbatims, emails, call notes, with realistic channel framing |

In `{{EVAL_SCHEMA}}` -- the answer key:

| Table | Contents |
|---|---|
| `SYN_ACCOUNT_TRUTH` | latent cohort, primary and secondary reason, usage-decline flag, prediction cutoff |
| `SYN_INTERACTION_LABELS` | per interaction: `case_type`, `true_reasons` array, `has_retention_risk`, `is_after_cutoff` |
| `SYN_MANIFEST` | generation parameters and generator version |

## The answer key is quarantined -- but the renewal outcomes are not

Two kinds of truth, treated differently on purpose:

- **Renewal outcomes are legitimate labels.** Every customer has renewal history; the model trains on
  it. `SYN_RENEWAL_OUTCOMES` lives with the customer-like data.
- **Per-interaction reasons and cohorts are the answer key.** No customer has them. They live in
  `{{EVAL_SCHEMA}}`, and only `evaluate-churn-accuracy` reads them. Grant the pipeline role no access
  to `{{EVAL_SCHEMA}}` if roles are separable; at minimum, grep every generated pipeline SQL file for
  the eval schema name before running it.

## How the signals are planted

Latent cohorts per account:

| Cohort | Who | Text | Usage |
|---|---|---|---|
| `VOCAL` | churners (about 85%) | 2-4 pre-cutoff signal interactions of the primary reason, alternating with a secondary reason when present | declines in 70% |
| `SILENT` | churners (about 15%) | **no** pre-cutoff signal -- text cannot find them | declines in 70% |
| `SAVED` | retained, at risk | 1-2 genuine signal interactions | declines in 40% |
| `DISTRACTOR` | retained | 1-2 risky-sounding interactions that are not risk | declines in 10% |
| `HEALTHY` | retained | routine only; 10% get one distractor | declines in 10% |

Every account gets 3-6 routine noise interactions. Every observed churner also gets 1-2 **post-outcome**
interactions (non-renewal notice, offboarding/data-export request, exit survey) dated between notice
and just after renewal -- after the cutoff, carrying the primary reason in explicit language. Those are
leak trap 2, and also the best source for the closed-churn reason analysis.

Churn propensity differs by segment (SMB highest, Enterprise lowest), and price/value and product gap
are weighted double among reasons, so per-reason support is uneven -- which is what makes macro
averages informative.

Usage decline is timed to the six months before renewal, so with a 90-day horizon about half the
decline is visible before the cutoff. That makes usage a real but partial signal, and `SAVED`
accounts with declining usage make the model's job non-trivial. This is what keeps the honest AUC
away from 1.0.

## Distractors are written to be hard

Each distractor template defeats a specific naive approach (see best-practices rule 19): a past
competitor evaluation, a resolved bug, an expansion pricing question, a champion handover with a named
successor, "budgets are tight but you're protected", a price increase that is "still worth it", a
cancelled *meeting*, and an audit data export. A keyword filter on "cancel", "competitor", "price" or
"export" flags all of them.

## Run it

1. Substitute placeholders. Confirm `{{SCHEMA}}` and `{{EVAL_SCHEMA}}` with the user -- the script
   uses `CREATE OR REPLACE` on its own tables.
2. Gate: state the objects it creates (tables above, plus temporary helpers it drops itself). It makes
   no AI calls.
3. Run `sql/01_seed_sandbox.sql`.
4. Record every created table in `created_objects.tables`, and set `sources.*` in
   `churn-project.yml` to the sandbox mapping below so later phases need no questions:

```yaml
sources:
  interactions: {table: <DB>.<SCHEMA>.SYN_INTERACTIONS, id_col: INTERACTION_ID, account_col: ACCOUNT_ID,
                 text_col: BODY, channel_col: CHANNEL, created_col: CREATED_AT}
  accounts:     {table: <DB>.<SCHEMA>.SYN_ACCOUNTS, id_col: ACCOUNT_ID, name_col: ACCOUNT_NAME,
                 owner_col: CSM_NAME, arr_col: ARR_USD, segment_col: SEGMENT,
                 contract_start_col: CONTRACT_START_DATE, renewal_col: RENEWAL_DATE,
                 outcome_derived_cols: [CRM_STATUS, CRM_CANCEL_REASON, CRM_LAST_MODIFIED_AT]}
  outcomes:     {table: <DB>.<SCHEMA>.SYN_RENEWAL_OUTCOMES, outcome_col: OUTCOME, churn_value: CHURNED,
                 notice_col: NOTICE_DATE, recorded_col: RECORDED_AT}
  usage:        {table: <DB>.<SCHEMA>.SYN_USAGE_MONTHLY, month_col: USAGE_MONTH, active_col: ACTIVE_USERS,
                 seats_col: SEATS_PURCHASED, logins_col: LOGINS}
extraction:
  taxonomy_source: <DB>.<SCHEMA>.SYN_REASON_TAXONOMY
```

## Verification before declaring the phase done

Show the results, not a claim.

```sql
-- Cohorts, churn and observation
SELECT segment, cohort, outcome_observed, COUNT(*) AS accounts, SUM(IFF(is_churner, 1, 0)) AS churners
FROM {{EVAL_SCHEMA}}.SYN_ACCOUNT_TRUTH
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;

-- Interactions by case type and channel; answer key covers every interaction
SELECT k.case_type, i.channel, COUNT(*) AS n,
       COUNT_IF(k.is_after_cutoff) AS after_cutoff
FROM SYN_INTERACTIONS i
JOIN {{EVAL_SCHEMA}}.SYN_INTERACTION_LABELS k USING (interaction_id)
GROUP BY 1, 2 ORDER BY 1, 2;

SELECT (SELECT COUNT(*) FROM SYN_INTERACTIONS)                          AS interactions,
       (SELECT COUNT(*) FROM {{EVAL_SCHEMA}}.SYN_INTERACTION_LABELS)    AS labels;   -- must match

-- Planted structure holds: SIGNAL rows all before cutoff, POST_OUTCOME rows all after
SELECT case_type,
       COUNT_IF(is_after_cutoff)     AS after_cutoff,
       COUNT_IF(NOT is_after_cutoff) AS before_cutoff
FROM {{EVAL_SCHEMA}}.SYN_INTERACTION_LABELS
GROUP BY 1 ORDER BY 1;
-- Expect SIGNAL and DISTRACTOR: after_cutoff = 0. POST_OUTCOME: before_cutoff = 0.
-- NOISE spans both (routine traffic continues for retained accounts).

-- Labels available for training
SELECT outcome, COUNT(*) FROM SYN_RENEWAL_OUTCOMES GROUP BY 1;

-- Leak trap 3 is present (it should be: the audit has to catch it)
SELECT COUNT(*) AS zero_usage_months_after_churn
FROM SYN_USAGE_MONTHLY u
JOIN SYN_RENEWAL_OUTCOMES o ON o.account_id = u.account_id AND o.outcome = 'CHURNED'
WHERE u.usage_month >= DATE_TRUNC(month, o.renewal_date) AND u.active_users = 0;

-- Spot-read a few interactions per case type. Read them for realism, not
-- just for counts.
SELECT k.case_type, i.channel, i.subject, LEFT(i.body, 200) AS body
FROM SYN_INTERACTIONS i
JOIN {{EVAL_SCHEMA}}.SYN_INTERACTION_LABELS k USING (interaction_id)
QUALIFY ROW_NUMBER() OVER (PARTITION BY k.case_type ORDER BY i.interaction_id) <= 2;
```

If the TEST-split churner count (roughly a third of observed churners after embargo) is under about 30,
say the AUC interval will be wide and offer to regenerate larger.

## Honest limits of the sandbox

Say these when presenting sandbox numbers:

- Templates are clean, single-topic and English. Real tickets are long, multi-topic, misspelled,
  multilingual, and full of agent text. Sandbox reason accuracy is an upper bound on real accuracy.
- The reason mix, churn rate and cohort proportions are generator parameters, not benchmarks. Never
  present them as typical of anything.
- Text-to-churn relationships are planted, so the text uplift on the sandbox shows the pipeline
  *can* use text signal -- not how much signal the customer's text holds. Only their data answers that.

## Keep it synthetic and obviously synthetic

All ids start `SYN-`, all account names end `(Synthetic)`, and every person, company, competitor and
feature name is fabricated. Never mix sandbox rows into a table that holds real customer data, and never
copy real interaction text into templates to "make it more realistic" -- that turns the sandbox into a
customer-data artifact.

## Teardown

Drop exactly the tables listed in `created_objects` for this phase, both schemas, after confirming. The
sandbox schemas can be dropped whole only if `created_objects` shows this plugin created them.
