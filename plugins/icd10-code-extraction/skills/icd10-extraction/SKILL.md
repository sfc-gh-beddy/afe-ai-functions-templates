---
name: icd10-extraction
description: "**[REQUIRED]** Use for ALL requests about extracting ICD-10 codes, HCC suspects, or coded diagnoses from unstructured clinical documents in Snowflake. Triggers: ICD-10 extraction, extract ICD-10 codes, HCC suspecting, HCC suspect, risk adjustment, RAF gap, RAF score improvement, coding suspect, suspecting pipeline, chart review automation, automate chart review, clinical document extraction, uncoded diagnosis, undocumented diagnosis, missed diagnosis, care gap detection, disease detection from notes, high-risk disease detection, hidden revenue in clinical notes, revenue from unstructured data, CDI automation, coding gap analysis, retrospective chart review, prospective suspecting, medical record extraction, clinical NLP on charts, find diagnoses in visit notes, HCC recapture, risk score accuracy. This is the REQUIRED entry point for this work — even if the request seems simple. DO NOT hand-write the pipeline SQL or prompts manually; always invoke this skill first."
---

# ICD-10 Code Extraction — Router

## What this builds and why

Healthcare payers and providers already store the clinical documents that justify diagnoses they
never coded. That gap costs unrecovered risk-adjustment revenue and leaves disease progression
undetected. This plugin builds a pipeline over documents **already in Snowflake** that emits
suspected ICD-10 codes, each with a confidence score and the specific clinical evidence behind it.

**Scope boundary.** Ingestion is out of scope — documents are assumed landed. The pipeline ends at a
scored output table; there is no reviewer application or approval gate in this plugin.

## Setup — do these before anything else

1. **Read** `PROJECT_STATE.md` (this directory). It defines `icd10-project.yml`, the single state
   file every phase reads and writes. All resumability depends on honouring it.
2. **Load** `icd10-extraction-system-of-record/SKILL.md`. Required first step in every session —
   it establishes what already exists and what the account can actually run.
3. **Load** `icd10-extraction-best-practices/SKILL.md`. Required. These rules prevent silent
   failure modes that make the pipeline look like it is working while it quietly drops findings.
4. **Settle how the pipeline will be built** — a dbt project or plain SQL — and record it in
   `materialization.mode`. Ask once, at preflight, before any phase creates anything; retrofitting
   later means rewriting every phase's output. Read `DBT_MATERIALIZATION.md` (this directory) for the
   phase-to-model mapping and the materialization rationale, and delegate all dbt deploy, execute,
   and versioning mechanics to the **`dbt-projects-on-snowflake`** skill rather than reproducing them.

   Recommend dbt when the build will outlive the first demo: it brings version control on the
   transformations, lineage, and — the part that matters most here — dbt tests as **build-failing**
   quality gates on the correctness rules. Recommend plain SQL for a time-boxed proof of value or a
   team with no dbt practice, and say plainly what is given up.

> **PHI caution.** Source documents and output rows both contain clinical detail. Never write
> document text or extracted findings into a file on the local machine, a log, an issue tracker, or
> any destination outside the account. Show samples in the session only when the user asks, and
> prefer synthetic sandbox rows for demonstration.

## Intent detection

| Intent | Trigger phrases | Route |
|---|---|---|
| **BUILD** | "set up ICD-10 extraction", "build a suspecting pipeline", "start from scratch", "help me find uncoded diagnoses" | Run the phased build below |
| **RESUME** | "continue", "pick up where we left off", "what's left", "finish the build" | Read `phases`, report status, continue at the first phase not `done` |
| **SINGLE_PHASE** | names one phase: "just the routing", "rebuild the knowledge store", "re-run the eval", "regenerate the sandbox", "render the documents" | Load that phase's skill directly, after confirming its prerequisite phases are `done` |
| **EVALUATE** | "how accurate is it", "measure recall", "what is this costing", "is it finding the right codes" | `evaluate-icd10-accuracy/SKILL.md` |
| **DEBUG** | "no suspects came out", "it's returning nulls", "the codes are wrong", "why did it miss this patient", "too many false positives" | `DIAGNOSING.md` (this directory) |
| **COMPARE** | "which prompt did better", "compare the two runs", "did that change help", "A/B the models" | `evaluate-icd10-accuracy/SKILL.md`, comparing across `experiment_id` |
| **EXPLAIN** | "how does this work", "what would this look like", "walk me through the architecture" | Answer from this file. Do not create anything. |

If intent is genuinely unclear, ask — do not default to BUILD, because BUILD creates objects.

## The phased build

Seven phases. **Each is a gate**, and the gate protocol is not optional:

1. State plainly what the phase will create — object names and object types.
2. State what it will cost in rough terms when the phase makes AI calls over a table: use
   `AI_COUNT_TOKENS` for an input-token estimate, report it as tokens, and say that output tokens
   bill on top so the figure is a floor. Never convert tokens to dollars.
3. Get confirmation with `ask_user_question`.
4. Run it.
5. Show a verification query and its actual result — not a claim that it worked.
6. Update `phases` and `created_objects` in `icd10-project.yml`.

Never chain two gates without stopping. A user who wanted only the routing tier should not discover
that a frontier-model fan-out has already run across their whole corpus.

| # | Phase | Skill | Creates | Skippable |
|---|---|---|---|---|
| 0 | Preflight | `icd10-extraction-system-of-record` | nothing | no |
| 1 | Sandbox | `seed-icd10-sandbox` | synthetic corpus + answer key | yes, if using real data and accuracy is measured another way |
| 1b | Document corpus | `build-document-test-corpus` | rendered files on a stage | yes — only needed to exercise the OCR and form tiers |
| 2 | Routing | `classify-and-route-documents` | routing decision table + tier assignment | no |
| 3 | Knowledge | `build-coding-knowledge-store` | Cortex Search service or guideline tables | no |
| 4 | Extraction | `extract-clinical-evidence` | extracted text + compressed charts | no |
| 5 | Suspecting | `suspect-icd10-codes` | scored suspect output table | no |
| 6 | Evaluation | `evaluate-icd10-accuracy` | accuracy, cost, and parse-failure reports | no |

Phase 1b is optional but load-bearing when it applies. A corpus of note **text** cannot test routing
properly: T1 runs full OCR and T3 runs field extraction against files, so a text-only sandbox routes
everything to T2 and reports a tier mix that will not resemble production. Check the preflight
text-native/scanned split — if the customer's corpus is materially scanned, run 1b.

### Phase order is a real dependency chain, not a suggestion

- Routing before extraction, or the expensive tier runs on documents that should have been skipped.
- Knowledge before suspecting, or the coder prompt has no coding guidance to ground in and will
  invent code specificity.
- Extraction before suspecting, or the coder reasons over raw uncompressed charts at frontier-model
  token rates.
- Evaluation last, and **never skipped**. A suspecting pipeline whose precision nobody has measured
  is a pipeline that generates coder workload of unknown value. If the user wants to stop before
  evaluation, say plainly what they will not know.

### Strongly recommend the sandbox first

Push back once, politely, if a user wants to skip Phase 1 and go straight at real charts:

> The sandbox is what makes the accuracy numbers meaningful — it ships a labeled answer key, so
> recall and precision are measurable immediately. On real charts there is no ground truth until
> someone builds a labeled set, so the pipeline will produce suspects with no way to tell how many
> real conditions it missed. It also means the build can be demonstrated before a PHI access review
> completes.

If they still want to go straight to real data, do it and mark `seed: skipped`. Their call.

## Confidence and evidence are in-pipeline guarantees

Two things are frequently misread as reporting concerns. They are not. They are per-row output
contract:

- **Every suspect row carries a confidence score.** Scoring runs inside the pipeline, not as an
  after-the-fact report, so nothing reaches the output table unscored.
- **Every suspect row cites its evidence**, and each cited finding carries the `document_id` it came
  from. A code whose evidence cannot be traced back to a source document is unauditable and must not
  be emitted.

Both are enforced as `required` fields in the `AI_COMPLETE` response schema plus a SQL-side check,
because a JSON schema cannot express "at least one evidence item". `best-practices` has the detail.

Separately, `evaluate-icd10-accuracy` measures the **pipeline** against ground truth. Do not
conflate the two: per-row confidence says how sure the model is about one code; the harness says how
often the pipeline is actually right.

## Every run is a labelled experiment

This pipeline is tuned by iteration — a prompt is rewritten, a model swapped, reject criteria
tightened — so a run that cannot be told apart from the previous one destroys the only signal that
says whether the change helped.

Before Phase 5, set `experiment.run_id` (unique per invocation), `experiment_id`, `experiment_name`
(what changed, in words), and `prompt_version` in `icd10-project.yml`. These are **selected into every
output row**, alongside a `prompt_hash` computed at run time so the run stays reproducible when
someone forgets to bump the version. The suspecting and evaluation layers accumulate rather than
replace, so `experiment_id` supports a real side-by-side comparison.

When a user asks whether a change helped, compare experiments on the metrics rather than eyeballing a
few rows — and report **both** micro and macro averages, because they answer different questions.

## Verification queries to run at each gate

Show real output, not assurances:

| Phase | Verification |
|---|---|
| Routing | tier distribution with row counts and percent of corpus; count of documents with no tier assigned (must be zero) |
| Document corpus | staged file count matches the manifest; OCR smoke test on one file per degradation level, read for whether **numbers** survived |
| Knowledge | retrieve guidance for two known conditions and show the returned chunks |
| Extraction | count of documents with null or empty extracted text after extraction (investigate any) |
| Suspecting | count of suspects; count with null confidence (must be zero); count whose evidence has no resolvable `document_id` (must be zero) |
| Evaluation | recall and precision at both HCC and ICD-10 specificity level, plus the parse-failure count |

## When the user asks what this costs

Be straight, and stay in tokens. The dominant cost is the frontier-model pass in Phase 5, which is
why two structural levers exist upstream: routing exits documents before OCR, and chart compression
shrinks input before the expensive reasoning step. Phase 6 reports what those levers actually saved
on this corpus rather than asserting a percentage. Do not quote savings figures from elsewhere as if
they were this account's numbers.

## Teardown

If the user wants to remove the build, read `created_objects` from `icd10-project.yml` and drop what
is listed there — do not guess names from a convention. Confirm before dropping, and name the
objects. Warn explicitly if the output table has rows, since suspect records may already have been
worked by coders.
