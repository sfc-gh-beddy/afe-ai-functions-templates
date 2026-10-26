# Churn Signals

A guided build for finding churn reasons and at-risk accounts in the unstructured customer data a
company already stores in Snowflake, joined to usage and ARR, with a Snowflake ML churn model that
uses the extracted text as features.

## The problem

Customers explain why they are unhappy long before they leave -- in support tickets, survey comments,
emails to their account manager, and the notes a CSM writes after a difficult call. That text is read
once by whoever answered it and is never joined to the renewal. The consequences:

- **Churn arrives as a surprise.** Health scores built on usage alone catch accounts that stopped
  logging in, not accounts that are actively evaluating a competitor while their usage is still fine.
- **Nobody knows why ARR was lost.** The CRM cancel-reason picklist is filled in after the fact and is
  frequently "Other". Product and pricing decisions are made without the customers' own reasons.

Both close with data that is already in the account.

## What this plugin builds

```
tickets / surveys / emails / call notes
  -> AI_SENTIMENT (retention aspects) + AI_CLASSIFY (multi-label reason taxonomy)
  -> AI_COMPLETE on flagged rows only: verbatim evidence quote, churn intent, resolved, competitor
  -> point-in-time account features: text signals + usage + ARR, under a leakage audit
  -> XGBoost churn model in the Snowflake ML Model Registry, compared with a usage-only baseline
  -> SQL batch scoring: AT_RISK_ACCOUNTS with probability, band, ARR at stake, reasons, cited evidence
  -> CHURNED_ARR_BY_REASON over closed churn, next to the CRM picklist
  -> incremental refresh (stream, inbox, task), semantic view, Cortex Agent for CoWork
```

Every at-risk row carries a probability from a named model version and cites the specific interactions
behind it -- each one dated before the prediction point and quoted verbatim -- so a CSM can act without
re-reading the account's history. Accounts at risk on usage alone are labeled as such rather than
hidden.

## The accuracy story

Three things are measured, not asserted:

- **Reason precision and recall** per reason, micro and macro, against a labeled answer key -- including
  the false-flag rate on interactions written to look risky when they are not.
- **Model AUC, lift and calibration** on held-out renewals, split by time, computed in SQL from the
  registered model's own output -- with the uplift over a usage-only model stated plainly, even when it
  is small.
- **Cost** in credits per 1K interactions, from account usage history.

**Label leakage** is treated as the primary risk. Features are computed strictly before each
prediction point; an audit checks for post-cutoff text and usage, labels known at prediction time, split
overlap, outcome-derived CRM columns and single features that separate the labels too well -- and
blocks training if anything fails. The sandbox plants three common leaks and can train a deliberately
leaky model next to the honest one, so the difference is visible on the customer's screen.

## What it does not build

- **Ingestion.** Interactions, usage and renewal history are assumed landed.
- **Call audio.** Transcribe first (see the call-center-intelligence play for `AI_TRANSCRIBE`); this
  play reads transcripts and notes as text.
- **A CSM workflow app.** The pipeline ends at `AT_RISK_ACCOUNTS`; review columns are defined and
  defaulted so one can be layered on without a migration.
- **The save play.** It tells a CS team who to call and why. Whether the call works is theirs.

## Getting started

Ask in plain language. The router picks up phrases like:

- "why are our customers churning -- can we use the support tickets?"
- "build a churn model from our tickets and NPS comments"
- "give me a save list for next quarter's renewals"
- "how much ARR did we lose by reason last year?"

The build runs in nine gated phases. Each says what it will create and roughly what it will cost in
tokens, waits for confirmation, runs, and shows a verification query. State lives in
`churn-project.yml` so the build can be stopped and resumed.

**Start in the sandbox.** Phase 1 generates a deterministic synthetic customer base -- accounts, usage,
renewals, and tickets/surveys/emails/notes with planted reasons, look-alike distractors, silent
churners and leakage traps -- with a quarantined answer key. Reason precision/recall and model AUC are
measurable on day one, before anyone grants access to real support data.

## Skills

| Skill | Role |
|---|---|
| `churn-signals` | Entry point. Intent detection, phase gating, `PROJECT_STATE.md`, `DBT_MATERIALIZATION.md`, `DIAGNOSING.md`. |
| `churn-signals-system-of-record` | Preflight: AI function access, models and cross-region, registry privileges, interaction sources, account join, renewal labels, outcome-derived columns, data posture. |
| `churn-signals-best-practices` | Correctness rules, always loaded. Leakage first. |
| `seed-churn-sandbox` | Synthetic data with a labeled answer key and planted leakage traps. |
| `extract-churn-signals` | Taxonomy workshop, sizing, AI_SENTIMENT / AI_CLASSIFY / AI_COMPLETE extraction with grounding. |
| `build-account-features` | Point-in-time features and the leakage audit that gates training. |
| `train-churn-model` | Usage-only vs text-only vs combined XGBoost; registry logging with explicit signature. |
| `score-at-risk-accounts` | SQL batch scoring, at-risk list with evidence, churn reasons, incremental pipeline, semantic view, agent. |
| `evaluate-churn-accuracy` | Reason P/R/F1, distractor false flags, AUC/lift/calibration, leaky contrast, credits per 1K. |
| `churn-value-readout` | Revenue-retention value range from customer inputs, POC criteria, one-page narrative. |

## Requirements

- A role with `SNOWFLAKE.CORTEX_USER` (or equivalent) -- preflight verifies with `EXPLAIN_PRIVILEGES`
  and reports the exact missing grant.
- A warehouse and a schema where the role can create tables, views, models, streams and tasks.
- A GA model in the account's region for the evidence stage -- verified with `SHOW CORTEX BASE MODELS`.
- Python with `snowflake-ml-python`, `xgboost` and `scikit-learn` for training (local or a Snowflake
  Notebook).
- Renewal outcome history for the model. Without it, the play still delivers churn reasons.

## A note on customer data

Every AI function call runs inside Snowflake. Evidence quotes and narratives concentrate customer
statements, sometimes with personal names, next to account names and ARR; preflight reports existing
policies and asks who should read the at-risk list, and the build applies that decision -- including
optional redaction of quotes -- when the table is created.
