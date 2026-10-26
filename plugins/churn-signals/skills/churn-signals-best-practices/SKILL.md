---
name: churn-signals-best-practices
description: "Correctness rules every churn-signals pipeline must follow. Always loaded by the churn-signals router. Catches silent failure modes -- code that runs clean, returns plausible rows, and is wrong. Covers label leakage above all (point-in-time features, the as_of cutoff, outcome-derived CRM columns, post-cutoff text, usage after churn, label-known-at-prediction, time split with embargo, single-feature separation screening, suspicious AUC), the said-at versus loaded-at timestamp, agent replies versus customer voice, account join correctness, AI_CLASSIFY multi-label contracts (a sanctioned no-risk label, label descriptions, case sensitivity, return_error_details, unmapped labels), AI_SENTIMENT aspect limits and its 2,048-token window, AI_COMPLETE structured output and verbatim evidence grounding, gating the expensive stage, past-versus-active competitor and resolved-versus-open distractors, model-registry signatures and named-argument scoring, calibration before summing expected ARR, measuring text uplift against a usage-only baseline, reason-accuracy harness bugs, ARR double counting across reasons, experiment tracking, prompt hashing, and token accounting."
parent_skill: churn-signals
---

# Churn signals -- correctness rules

Every rule here has a failure mode where the SQL succeeds, the row counts look reasonable, and the
result is wrong. Most of them make the output look **better** than it is, which is why they survive
review. Apply them to every artifact this plugin generates.

Rules 1-10 are about leakage. They are first because a leaked churn model is worse than no model: it
demos beautifully, is believed, and fails silently in production where the leaked column does not
yet exist.

---

## 1. Every feature is computed as of a cutoff, strictly before it

**The failure:** features computed over "all interactions" or "the last 3 months" with no reference
date. For a churned account that window contains the non-renewal notice, the exit survey and the
post-churn zero usage. The model learns to read them, scores 0.99 AUC, and in production -- where
those rows do not exist yet at prediction time -- it has nothing.

**The rule:** each training row is `(account_id, as_of_date)` with `as_of_date = renewal_date -
horizon_days`. Every feature uses only data with a timestamp **strictly less than** `as_of_date`. The
spine defines the cutoff; every feature join carries `created_at < sp.as_of_date`. Carry the max
timestamp actually used (`max_text_ts_used`, `max_usage_month_used`) on every row and assert it.

Scoring uses exactly the same code with `as_of_date = today`. One feature-building path, two spines.
A second, "simpler" scoring query is how training and serving diverge.

## 2. Use the timestamp of when the customer said it

`created_at` must be when the message was written. Not `updated_at` (a ticket closed after churn is
updated after churn), not `_loaded_at` (a historical backfill makes old text look new or vice versa),
not survey `sent_at` (the response came later). Preflight records the column and its comparison with
any load timestamp. If the only timestamp available is a load time, say so: point-in-time correctness
is then unverifiable and AUC must be presented as an upper bound.

## 3. Outcome-derived columns are never features

`CRM_STATUS`, `CANCEL_REASON`, `CHURN_DATE`, `CLOSED_LOST_*`, a current `HEALTH_SCORE` or
`RISK_FLAG`, a CSM's "at risk" checkbox, a renewal opportunity stage. These are written because of
the outcome. Their current value is the label.

- Build `ACCOUNT_FEATURES` from an **explicit column allowlist**. Never `SELECT a.*`.
- List outcome-derived columns at preflight in `sources.accounts.outcome_derived_cols`; the leakage
  audit greps the feature table for them and for a name pattern.
- A historized version of such a field, with an effective date, can be a legitimate feature --
  point-in-time. Its current snapshot never is.

## 4. Post-cutoff text belongs in reason analytics, not in the model

The notice of non-renewal and the exit survey are the clearest statements of **why** a customer left.
`CHURN_REASONS_CLOSED` includes them deliberately, with an `is_post_cutoff` flag. The model features
exclude them by the cutoff. These are two different products from the same table; do not "fix" the
reason view by applying the model cutoff, and do not "improve" the model by removing it.

## 5. Usage months must be complete before the cutoff

A month is usable when `DATEADD(month, 1, usage_month) <= as_of_date`. Without that, the partial
current month (low because it is partial) and, for churners, the zero after the renewal date, become
predictors. If the usage source restates months after the fact, the value at `as_of_date` is not the
value in the table today -- note it as a known limitation.

## 6. The label must not have been known at prediction time

If a customer gave notice before `as_of_date`, predicting their churn is a lookup. The audit checks
`notice_date <= as_of_date` and `recorded_at <= as_of_date`. When notice routinely precedes the horizon
(e.g. 120-day notice clauses with a 90-day horizon), the honest fix is a longer horizon. Excluding
those rows from evaluation is acceptable if stated; scoring them as model wins is not.

## 7. Split by time, with an embargo. Never randomly.

Accounts renew on cycles, and churn drivers shift (a price change, an outage, a competitor launch). A
random split trains on next quarter to predict last quarter. Use the latest renewals as TEST. Then
drop from TRAIN any row whose label was observed (`renewal_date`) on or after the first TEST
`as_of_date` -- otherwise the model was trained on outcomes that had not happened when the test
predictions would have been made. `01_build_features.sql` marks those rows `EMBARGO`.

One row per account-renewal; an account with several renewals in history contributes several rows,
all on the same side of the time split by construction.

## 8. Screen single-feature separation before training

Any single feature with an AUC above about 0.95 (or below 0.05) on TRAIN is a leak until proven
otherwise. The audit computes a tie-aware Mann-Whitney AUC per feature. Real churn signals are
individually weak; it is their combination that predicts.

## 9. A suspiciously good model is a finding to investigate, not a result to present

Combined AUC above roughly 0.95 on real data triggers `DIAGNOSING.md` #1 before anything is shown.
On the sandbox, run the leaky demo and put the two numbers next to each other: it is the most
persuasive slide in the readout, because every customer's previous churn model attempt failed this
way.

## 10. Do not tune on TEST

Choosing hyperparameters, features, thresholds or taxonomy wording by looking at TEST metrics turns
TEST into training data. Tune on a validation slice carved from the end of TRAIN; look at TEST once
per experiment. Threshold bands in Phase 7 are chosen from the lift table and then frozen for the
next scoring run, not re-chosen every week to look good.

---

## 11. Only the customer's voice

Agent replies, auto-acknowledgements, CSAT survey question text, email signatures, legal footers and
quoted previous messages are not the customer speaking. "I understand you are considering
cancelling" in an agent reply, or "Reply STOP to cancel" in a footer, produce false churn signals at
scale. Filter by author/direction in staging and strip boilerplate tuned to this customer's templates.
For email, drop quoted reply chains (`On ... wrote:` and below).

## 12. Confirm the account join, and dedup within the account

A wrong `account_id` mapping is silent and catastrophic. Preflight measures the join rate and confirms
the key. Content dedup is scoped to the account -- `MD5(account_id || '::' || normalized_text)` --
because templated survey answers ("Great product!") are identical across customers, and a global
dedup deletes every customer but the first.

## 13. AI_CLASSIFY needs a sanctioned "no risk" label

In `output_mode: 'multi'`, the classifier returns at least one label. With no category meaning
"nothing here", every routine ticket is forced into a reason. Include `'no retention risk'` with a
description, and when it comes back alongside a real reason, keep the real reasons and count the
conflict (`none_conflict`). Report the conflict rate; a high rate means the descriptions overlap.

## 14. Build AI_CLASSIFY categories from the taxonomy, with descriptions, as a rendered literal

- Labels are plain English, no abbreviations or special characters, mutually exclusive (documented
  guidance). Keep twenty or fewer; the docs note accuracy may drop beyond that.
- **Categories are case sensitive.** Keep one convention (lowercase) and normalize on the join back to
  codes with one expression. Count returned labels that do not map (`unmapped_label_count`); it must
  be zero.
- Use label **objects with descriptions** that say what separates neighbours: price-or-value versus
  budget-cuts, evaluating-a-competitor versus a past evaluation, support-experience versus
  reliability. Descriptions, `task_description` (50 words or fewer) and examples all add input tokens
  to every call -- budget them.
- Render the categories to a literal from `REASON_TAXONOMY`, record its SHA2, and bump
  `prompt_version` whenever it changes. A taxonomy edited after extraction silently desynchronizes the
  code mapping.

## 15. Pass `return_error_details => TRUE`

Without it, AI_CLASSIFY and AI_SENTIMENT return NULL on an error, and a NULL reads exactly like "no
risk". With it, the result is `{value, error}` and failures are countable. Every run logs failures per
stage to `PIPELINE_QUALITY_LOG`. A pipeline that cannot say how many rows failed cannot make a recall
claim.

## 16. Respect AI_SENTIMENT's limits

At most ten aspects, each at most 30 characters; an `overall` entry is always returned in addition.
Results are one of `positive`, `negative`, `neutral`, `mixed`, `unknown` -- and `unknown` means the
aspect was **not mentioned**, which is not neutral. Count it separately. The function is documented as
optimized for inputs up to 2,048 tokens, and longer inputs **return an error**. Window long emails and
call transcripts by tokens (`AI_COUNT_TOKENS`), not characters, and aggregate per interaction
(worst aspect sentiment wins), rather than dropping them.

## 17. Evidence is structured, verbatim, and checked

- `AI_COMPLETE` with a `response_format` JSON schema and every dependent field `required`;
  `temperature: 0`; "Respond in JSON" in the prompt as well. Schema keywords `minItems`, `maxItems`,
  `minLength`, `format` and friends are not supported; enforce such constraints in SQL.
- The quote must be **copied, not paraphrased**. Check it with `CONTAINS` against the normalized body.
  Ungrounded quotes are nulled and counted, never shown. Do not loosen the check to raise the
  grounding rate -- a paraphrase on a CSM's screen attributed to a customer is a credibility problem.
- Keep the evidence array `VARIANT`. Never cast to `VARCHAR` and parse later.
- Never length-constrain a column holding model text (`VARCHAR(500)` truncates silently or errors).

## 18. Gate the expensive stage on the cheap one

The evidence call runs only where AI_CLASSIFY found a reason. That is the main cost lever and it is
also why classifier precision matters for cost, not only for CSM trust: every false flag buys an
evidence call. Measure the flag rate on the sample before running the full table.

## 19. Distractors are the precision test

Four patterns produce most false churn signals in real data, and the sandbox plants each:

- **Past competitor evaluation** ("we looked at X and decided to stay") is not an active competitor
  risk.
- **Resolved issue** ("frustrating, but you fixed it in an hour") is not a reliability risk.
- **Expansion pricing** ("what would 30% more seats cost?") is not a price objection.
- **Champion handover with a named successor** is not champion loss.

`concern_resolved` and the few-shot examples target these. The Phase 7 false-flag rate on the
`DISTRACTOR` case type is the number that says whether CSMs will trust the queue.

## 20. Silent churners exist. Do not hide them, do not claim them.

Some churners never complain. Text cannot find them; usage sometimes can. The at-risk table labels
those rows `risk_basis = 'USAGE_ONLY'` rather than suppressing them for lack of evidence, and the
readout reports text's contribution on the accounts it can actually see. Claiming text finds churn it
cannot see is the overstatement that loses the room.

---

## 21. Measure text against a usage-only baseline

The play's claim is that text adds signal over the usage data the customer already has. Train
usage-only, text-only and combined on the same rows and split, and report all three with bootstrap
intervals. If the uplift interval includes zero, say that plainly. Do not report the combined AUC
alone.

## 22. Register with an explicit signature; score by name

Let the registry infer names and the output keys become `output_feature_N`; let SQL pass features
positionally and a reordered feature table silently feeds the wrong column into the wrong input.

- Log with `signatures={'predict_proba': ...}` inferred from a DataFrame with named columns, and
  explicit output names (`P_RETAINED`, `P_CHURN`).
- Before scoring, run `SHOW FUNCTIONS IN MODEL <name> VERSION <v>` and confirm inputs and outputs.
- Call `MODEL(<name>, <version>)!PREDICT_PROBA(...)` with **named** arguments, every one of them (named
  and positional cannot be mixed), and always with an explicit version -- never the default, which
  can change.
- Compute AUC in SQL from the registered model's output on TEST and compare with the training
  script. A mismatch means the evaluated artifact is not the deployed one.

## 23. Calibrate before anyone sums expected ARR at risk

`arr * p_churn` summed across accounts is only meaningful if probabilities are calibrated.
`scale_pos_weight` (used for the class imbalance) improves ranking and distorts probabilities upward.
Phase 7 shows predicted versus observed rate per decile. If they diverge, present the ranking and the
banded counts, not a summed dollar figure -- or calibrate first.

## 24. Small test sets need intervals

A test split with thirty churners has an AUC interval that can span 0.15. Report the bootstrap
interval with every AUC, the count of positives, and refuse to compare two models whose intervals
overlap heavily as if one were better.

---

## 25. Reason-accuracy harness: join from truth, normalize once, report both averages

- **Join from the answer key**, `LEFT JOIN` predictions. An interaction the pipeline dropped is a
  false negative; joining from predictions makes total failure invisible.
- **One normalization expression** for both sides (upper-case codes through the taxonomy).
- **Per-reason** precision/recall/F1 plus **micro and macro**. Macro exposes the rare reasons
  (champion loss, business change) that micro averages away.
- Report the distractor false-flag rate and per-channel recall alongside -- survey verbatims and call
  notes behave differently from tickets.

## 26. Lost ARR is attributed once per account

An account with three reasons is not three lost accounts. `CHURNED_ARR_BY_REASON` assigns each churned
account's ARR to its most-mentioned reason. For a multi-reason view, show mention counts, not summed
ARR. Summing `arr_lost` over reason rows overstates lost revenue by the average number of reasons per
account -- and it is the number most likely to end up on a slide.

## 27. Experiment tracking needs accumulating tables and recorded identity

Raw AI responses, scores and model metrics accumulate keyed on `run_id` / `score_run_id` /
`experiment_id`. Every output row carries `prompt_version`, the prompt or categories hash computed at
run time, the model name and version, and `feature_version`. `ACCOUNT_FEATURES.extraction_run_id`
names the extraction it was built from. When `prompt_version` matches and the hash differs, trust the
hash and say so.

## 28. Tokens and credits, measured

- `AI_COUNT_TOKENS` estimates **input** tokens only. AI_CLASSIFY and AI_SENTIMENT add their own prompt
  on top; structured output adds request content on some model families that the estimate does not
  count. Present estimates as floors.
- A wrong function name in `AI_COUNT_TOKENS` returns NULL rather than an error; a NULL estimate reads
  as zero. Check for NULLs.
- Billed truth is `SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY`, attributed with
  `QUERY_TAG`. Set the tag on every stage. The view lags; re-run later if empty.
- Report credits and tokens per 1K interactions. Never convert to currency unless the customer gives
  their credit price, and then only in the value readout.

## 29. Operational correctness

- Incremental extraction drains the stream into an inbox with a plain `INSERT` (DML advances the
  offset); rows are extracted from the inbox idempotently keyed on `interaction_id`, so a failed AI
  call delays rows instead of losing them.
- Do not wrap DDL (`CREATE TEMPORARY TABLE`) in an explicit transaction expecting atomicity -- DDL
  commits implicitly.
- Tasks are created suspended. Resuming starts recurring spend and is its own confirmed step after
  Phase 7.
- Cap rows per run (`MAX_BATCH`) so a backlog cannot produce one unexpectedly large bill.
- The incremental path must use the same prompts, categories literal and grounding check as the batch
  path that was evaluated.

## 30. Customer data stays in the account

Interaction text, evidence quotes, narratives and account names never go to a local file, log, ticket
or external destination. Evidence quotes can contain personal names and contact details; if the
at-risk audience is broader than the source audience, redact them (`AI_REDACT`) before display and
restrict `AT_RISK_ACCOUNTS` by role or row-access policy per the preflight decision.
