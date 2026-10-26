---
name: icd10-extraction-best-practices
description: "Correctness rules every ICD-10 / HCC suspecting pipeline must follow. Always loaded by the icd10-extraction router. Catches silent failure modes — pipeline code that runs clean, returns plausible rows, and is quietly wrong. Covers AI_COMPLETE JSON contracts and parse-failure accounting, mandatory evidence provenance, VARIANT evidence typing, in-pipeline confidence scoring, CMS model-year pinning, already-coded suppression, real token instrumentation, dedup scope, PHI boundaries, the structured-output/prompt-object incompatibility, why OCR-quality scores are not a valid routing signal, the AI_PARSE_DOCUMENT return-type trap, accuracy-harness measurement bugs (asymmetric code normalisation, joining from predictions instead of ground truth, flat instead of hierarchical code matching, micro-only averaging), experiment tracking requiring an incremental materialization, prompt hashing, and dbt and Streamlit-in-Snowflake deployment traps."
parent_skill: icd10-extraction
---

# ICD-10 extraction — correctness rules

These are the rules that separate a pipeline which *appears* to work from one that is actually
right. Every item here has a failure mode where the SQL succeeds, the row count looks reasonable,
and the result is wrong. Apply them to every artifact this plugin generates.

---

## 1. Never ask `AI_COMPLETE` for JSON in prose. Use a schema.

**The failure:** a prompt ending in "Return ONLY valid JSON", parsed with `TRY_PARSE_JSON`. When the
model emits a preamble, a trailing comma, or a fenced code block, the parse yields `NULL`. In a
suspecting pipeline a `NULL` is read as *this patient has no findings* — identical to a genuine
negative. Recall leaks silently and nothing in the output indicates it happened.

**The rule:** pass a JSON schema to `response_format`, and mark every field the pipeline depends on
as `required`. Snowflake verifies each generated token against the schema, so the response cannot
come back unparseable.

```sql
AI_COMPLETE(
    model => :extract_model,
    prompt => :coder_prompt,
    model_parameters => {'temperature': 0, 'max_tokens': 4096},
    response_format => {
        'type': 'json',
        'schema': {
            'type': 'object',
            'properties': {
                'suspect_found':      {'type': 'boolean'},
                'icd10_code':         {'type': 'string',
                                       'description': 'Most specific ICD-10-CM code supported by the cited evidence'},
                'classification':     {'type': 'string', 'enum': ['SUSPECT', 'EVAL', 'NONE']},
                'confidence':         {'type': 'number',
                                       'description': 'Integer 1-10. Evidence strength for this code.'},
                'evidence':           {'type': 'array', 'items': {'$ref': '#/$defs/finding'}},
                'clinical_reasoning': {'type': 'string'}
            },
            '$defs': {
                'finding': {
                    'type': 'object',
                    'properties': {
                        'document_id': {'type': 'string',
                                        'description': 'Must be one of the document_id values supplied in the prompt. Do not invent.'},
                        'finding':     {'type': 'string'},
                        'observed_on': {'type': 'string'}
                    },
                    'required': ['document_id', 'finding']
                }
            },
            'required': ['suspect_found', 'classification', 'confidence', 'evidence']
        }
    },
    show_details => TRUE
)
```

Supporting rules:

- **`temperature: 0`** on every call. Non-zero temperature on an extraction task buys nothing and
  costs reproducibility — the same chart scored twice gives two answers.
- **Add "Respond in JSON" to the prompt text as well** for the coder and judge stages. Schema
  adherence degrades as reasoning complexity rises, and the redundancy is free.
- **Use a strong model where reasoning is complex.** Schema constraint keeps output *parseable*; it
  does not make a weak model clinically correct.
- **`TRY_COMPLETE`** if a hard model error would otherwise abort a batch statement.

**Schema constraints to respect** (violating these is an error, not a warning): property names allow
only letters, digits, hyphen, underscore, max 64 characters, no spaces. `minItems`, `maxItems`,
`minimum`, `maximum`, `minLength`, `maxLength`, and `format` are **not supported**. Date and time
types and `VARIANT` have no type-literal mapping.

## 2. Count parse failures. Always.

Because the schema makes failure rare rather than impossible, and because a rare silent failure is
still silent:

```sql
-- Must be part of every suspecting run, not an afterthought.
INSERT INTO pipeline_quality_log (run_id, stage, total_calls, unparseable_calls, refusals)
SELECT :run_id, 'suspecting',
       COUNT(*),
       COUNT_IF(response:structured_output IS NULL),
       COUNT_IF(response:structured_output[0]:raw_message:suspect_found IS NULL)
FROM suspect_raw;
```

A pipeline that cannot say how many model calls failed cannot make a recall claim.

## 3. Evidence must be traceable to a source document

**The failure:** the model returns evidence as free text — "BNP trending up, EF 35%" — with no
indication of which document said so. The suspect is then unauditable: a coder cannot verify it
without re-reading the entire chart, which defeats the purpose, and it will not survive an audit.

**The rules:**

- Every finding carries a `document_id`, enforced as `required` in the schema.
- The prompt must **supply** the document ids alongside the text they belong to, and instruct the
  model to cite only from that set. A model asked to cite provenance it was never given will
  fabricate it.
- A JSON schema cannot express "the array must be non-empty" — `minItems` is unsupported. Enforce it
  in SQL:

```sql
-- Reject any asserted suspect with no evidence, or with evidence that
-- references a document not in scope for this patient.
WHERE suspect_found
  AND ARRAY_SIZE(evidence) > 0
  AND NOT EXISTS (
      SELECT 1 FROM LATERAL FLATTEN(input => evidence) f
      WHERE f.value:document_id::STRING NOT IN (
          SELECT document_id FROM patient_documents pd WHERE pd.patient_id = s.patient_id
      )
  )
```

Route rejects to the quality log rather than dropping them, so hallucinated provenance is visible
rather than invisible.

## 4. Keep evidence as `VARIANT`, never `VARCHAR`

`TRY_PARSE_JSON(response):evidence::VARCHAR` compiles, runs, and produces a string that looks like
JSON. Every downstream `FLATTEN` then fails or, worse, silently returns nothing. Store the array as
`ARRAY` or `VARIANT` and let it stay queryable.

## 5. Confidence is produced in-pipeline, not reported later

Every row in the output table carries a confidence score at insert time. Two acceptable sources:

- the `confidence` field returned by the coder call, schema-`required`; and
- the weighted rubric score from the judge stage.

If both run, keep both columns and be explicit about which one drives banding — do not silently
overwrite one with the other, because they mean different things. The coder's confidence is *how
strong is this evidence*; the judge's score is *would a reviewer accept this recommendation*.

`confidence_score IS NULL` in the output table is a build defect. Assert it is zero at the gate.

## 6. Pin the CMS model year

RAF factors and HCC numbering change between model years. A pipeline built against an unpinned
reference silently produces wrong revenue figures the moment a model year rolls — the codes still
look right, the dollar impact is wrong.

Pin `cms.model_year` in `icd10-project.yml`, carry it as a column on the guideline tables and on the
output table, and include it in the verification output so a stale build is visible.

## 7. Suppress already-coded conditions, and verify the suppression

The point of the pipeline is **gaps**, not a restatement of the current coded picture. Suppress with
`NOT EXISTS` against claims history — and then check what the suppression actually removed, because
a broken join here silently empties the output:

- code format must match on both sides (`HCC85` versus `85` is the usual culprit);
- patient identifier types must match;
- the claims lookback window must be stated, not implied.

Report the suppressed count at the gate. "Zero suspects found" and "suppression removed everything"
look identical in the output table and have completely different fixes.

## 8. Instrument tokens for real — the data is already there

The reference cost story is usually asserted. It does not need to be: `show_details => TRUE` returns
actual usage per call.

```sql
SELECT response:usage:prompt_tokens::INT     AS prompt_tokens,
       response:usage:completion_tokens::INT AS completion_tokens,
       response:usage:total_tokens::INT      AS total_tokens
FROM suspect_raw;
```

For **billed** totals across a run, prefer the account view, which is the system of record:

```sql
SELECT function_name, model_name,
       SUM(token_credits)  AS credits,
       SUM(tokens)         AS tokens
FROM snowflake.account_usage.cortex_functions_query_usage_history
WHERE start_time >= :run_start
GROUP BY 1, 2;
```

Persist per-stage figures. Rules:

- Report **tokens**, never dollars. Do not look up pricing or convert to USD, even when asked
  directly for a cost figure.
- **`AI_COUNT_TOKENS` signature is `('ai_complete', '<model>', <text>)`** — function name first,
  lowercase, then model, then text. Getting this wrong does not raise an error; a bad function name
  returns `NULL`, so a broken estimate looks like an empty one. Pass `return_error_details => TRUE`
  while developing to see the actual error.
- It estimates **input only** — call it a floor and say output tokens bill on top.
- **On Claude models, structured output is materially underestimated.** `response_format` generates
  additional request content that is billed as input tokens but is *not* counted by
  `AI_COUNT_TOKENS`. Verified: the same text estimates identically with and without a schema
  attached, while the billed figure is higher. Since this plugin recommends structured output on the
  coder and judge stages, say so when presenting an estimate rather than letting the user discover
  it on the bill. Reconcile against `cortex_functions_query_usage_history` after the first real run.
- Accuracy by model family: Claude and Gemini are estimates within roughly 3 percent, OpenAI is
  near-exact, everything else is exact.
- Estimate before any batch run over a table column, and let the user choose to proceed, sample, or
  narrow scope.

## 9. Structured output and prompt objects are mutually exclusive

`AI_COMPLETE` with a prompt object — the form that takes `FILE` inputs for images and documents —
**cannot** take a `response_format` schema. This shapes the architecture: a document path that needs
structured output must first turn the file into text (`AI_PARSE_DOCUMENT`, or `AI_EXTRACT` for
known fields), then make a **separate** single-string `AI_COMPLETE` call with the schema attached.

Do not design a single multimodal call that returns structured suspects. It cannot work, and
discovering that after the tier engine is built is expensive.

## 10. Scope the dedup key to the patient

`MD5(LEFT(text, 500))` collides across patients: standard note templates produce identical opening
text for different people, and the second patient's document silently disappears. Always
`MD5(patient_id || '::' || LEFT(text, N))`, and prefer a content-bearing window over the first N
characters when documents share a long header.

## 11. Tune boilerplate patterns to this organization's forms

Skip patterns are not portable. A phrase that is pure noise in one organization appears inside the
standard note header in another, and an over-broad pattern will skip the entire corpus. Derive
patterns from the customer's actual high-frequency documents and show the user what each pattern
would skip, with counts, before committing it.

## 12. Window by tokens, not characters

`LEFT(document_text, 60000)` truncates mid-finding and discards the tail of long charts — where
progression evidence tends to live, because the timeline is ordered. Use `AI_COUNT_TOKENS` against
the target model's budget, and when a chart exceeds it, compress or segment rather than truncating.
If content must be dropped, drop from the least clinically relevant end and record that it happened.

## 13. PHI stays in the account

Every AI function here runs inside Snowflake, which is the point. Preserve that:

- Never write document text or extracted findings to a local file, a log, an issue tracker, a
  notebook output that gets committed, or any external endpoint.
- Report existing masking and row access policies on the source table and the output table. A
  suspect record inherits the sensitivity of the chart it came from and is frequently more readable
  than the chart — it is a clinical summary with a name attached.
- Prefer synthetic sandbox rows for any demonstration or screenshot.

## 14. Distinguish an asserted suspect from a candidate for evaluation

Collapsing "the evidence supports this diagnosis" and "this warrants a look" into one output class
manufactures false positives: findings correctly flagged as uncertain get read as asserted
diagnoses, and reviewer trust drops. Keep the classification distinct in the schema
(`SUSPECT` / `EVAL` / `NONE`) and carry it through to the output table and every report.

## 15. Do not invent a graded signal where the underlying behaviour is binary

**Measured, not assumed:** OCR quality is a tempting routing signal and it does not work. Rendering the
same clinical notes at graded degradation — 300 DPI clean through 100 DPI with heavy skew, gaussian
noise, contrast loss and JPEG artefacts — then OCR-ing them produced character-cleanliness ratios of
0.974, 0.975, 0.972, 0.962 and 0.968. Flat across the entire range, with zero OCR failures.

`AI_PARSE_DOCUMENT` degrades **discretely**: it reads the page or it returns almost nothing. So the only
reliable signal is near-empty output, and content classification plus metadata have to carry the
routing decision.

The general rule this stands for: before routing, banding, or thresholding on any derived score, plot it
against something you know to be true and confirm it actually varies. A threshold on a flat signal is
worse than no threshold, because it looks principled and behaves randomly.

## 16. `AI_PARSE_DOCUMENT` return type is not what the docs say

Documented as returning a JSON-formatted **string**, with `PARSE_JSON` recommended. On some accounts it
returns an **OBJECT**, and `PARSE_JSON(OBJECT)` is a compile error. Always wrap:

```sql
PARSE_JSON(TO_VARCHAR(AI_PARSE_DOCUMENT(...)))
```

This works either way. Writing the documented form and testing on one account is how this ships broken
to the next one.

## 17. Never length-constrain a column that holds model-generated text

Declare `VARCHAR` with **no length** for anything a model writes: reasoning, memos, reviewer notes,
condition descriptions. Snowflake stores unbounded `VARCHAR` no differently from a constrained one, so
the limit buys nothing and guarantees an eventual `String is too long` failure on a verbose response.

Measured: `judge_notes VARCHAR(2000)` failed on the first real run — a judge explaining a coding
disagreement routinely exceeds 2,000 characters. `icd10_code VARCHAR(10)` failed too, when the model
packed two codes into one field.

Corollary on code fields: give `icd10_code` real headroom (`VARCHAR(20)`) even though a code is short.
A contract violation then lands as inspectable data rather than aborting the insert, and you can see
what the model actually did.

## 18. One value per field, and say so in the schema

A field described as "the most specific ICD-10 code" while the prompt says "code each documented
complication" is a contradictory contract, and the model will resolve it by packing multiple codes into
one string. That is the model behaving reasonably given conflicting instructions.

Fix the contract rather than parsing the string: one `icd10_code` for the primary code, plus an
`additional_icd10_codes` **array** for separately reportable manifestations, with both described
explicitly. Then make the accuracy harness check both — otherwise a correct answer reported as a
secondary code scores as a specificity miss.

## 19. Orchestration correctness

If the build is scheduled:

- No `TEMPORARY` tables shared between tasks. Each task runs in its own session; a temp table
  created in a parent is invisible to a child and the reference fails at runtime.
- Verify every column referenced in a batch predicate actually exists on the table. A predicate on a
  nonexistent column fails the root task on first run, which is a bad first impression of the build.
- Create objects in the schema they are read from. An object created after an unqualified schema
  switch lands somewhere other than where the reader expects.
- Make the run idempotent, keyed on a run identifier. Task auto-retry re-invokes the whole step; a
  non-idempotent step double-charges inference and double-inserts suspects.

## 20. Normalise both sides of an accuracy comparison with one expression

The most damaging bug an accuracy harness can carry is asymmetric normalisation, because it reports a
confidently wrong number and nothing looks broken.

`UPPER(TRIM(gt_codes))` on a delimited ground-truth string trims **the ends of the whole string**, not
each element. Split `"E11.9, I10"` afterwards and the second element is `" I10"` with a leading space.
Set intersection is exact, so every code after the first silently fails to match and recall reads as
roughly halved on multi-code patients.

Split first, then normalise each element, using the same expression on both sides. Then add a
round-trip verification query that asserts a known delimited ground-truth value matches its predicted
codes — before quoting any metric.

## 21. Join accuracy from ground truth, never from predictions

Build the evaluation from ground truth outward with a `FULL OUTER JOIN`. If it builds from emitted
suspects and `LEFT JOIN`s ground truth, a patient the pipeline returned nothing for — or whose response
failed to parse — is absent from evaluation entirely and contributes **zero false negatives**. Total
extraction failure then reports as perfect recall on the rows that survived.

Any upstream `WHERE ... IS NOT NULL` filter compounds this by removing exactly the failures the harness
most needs to count.

## 22. Score ICD-10 hierarchically: exact, category, miss

`E11.9` compared to `E11.65` as exact strings scores a full miss **plus** a full false positive.
Clinically it is a specificity difference and operationally it is coder rework, so double-penalising it
both overstates the failure and hides the real one.

Score three outcomes — exact match, category match on `SPLIT_PART(code, '.', 1)` with wrong specificity,
and missed entirely — and report all three. The category-only count is the most actionable number the
harness produces, and it points at knowledge-store coverage rather than at the prompt.

## 23. Report micro and macro averages together

Micro pools every code into one confusion matrix, so a few many-code patients dominate it. Macro
averages per-patient scores, so every patient counts equally. A pipeline that is strong on complex
charts and weak on simple ones shows good micro and poor macro — and simple charts are most of a real
panel.

Report both, with `STDDEV` and `MIN`/`MAX` of the per-patient F1. A macro F1 whose stddev approaches its
mean is not a pipeline with that F1; it is a pipeline that works on some charts and not others.

## 24. Experiment tracking requires an incremental materialization

Stamping `experiment_id` on every row does nothing if the suspecting and evaluation layers are `table`
materializations: every run drops and recreates, only one experiment exists at rest, and every
comparison query returns a single row while appearing to work perfectly.

Use `incremental` with `unique_key` including `run_id`, so a re-run merges in place and is idempotent
while a new `experiment_id` accumulates alongside the old.

## 25. Hash the prompt that actually ran

`prompt_version` is a human promise and it gets broken — a rule is reworded and nobody bumps the
version, so two materially different runs carry the same label. Persist `prompt_hash`, computed from the
**assembled** prompt text, and bind that same text into the `AI_COMPLETE` call rather than rebuilding the
`CONCAT` in two places. A hash of a prompt that is not the prompt that ran is worse than no hash.

When `prompt_version` matches but `prompt_hash` differs, trust the hash and say so.

## 26. Parsing an `AI_COMPLETE` response on a non-schema path

Only relevant on paths not using `response_format`, but these cost hours when hit:

- **`COALESCE` on `choices[0]:messages` and `choices[0]:message`.** The field name varies by model
  version. Reading only one returns `NULL` on the other, which is indistinguishable from an empty
  finding.
- **Strip markdown code fences before `TRY_PARSE_JSON`.** Models wrap JSON in ` ```json ` fences readily,
  and the fence makes the whole response unparseable.

Both are arguments for using `response_format` and `structured_output` in the first place, which is
rule 1.

## 27. dbt and Streamlit deployment traps

- **dbt writes to `<DATABASE>.<SCHEMA>_<SCHEMA>`** when a `+schema:` is set alongside a target schema —
  dbt concatenates rather than replacing. Override `generate_schema_name` rather than working around
  the doubled name downstream.
- **Never set `authenticator: externalbrowser`** in a profile used by native dbt on Snowflake. It
  triggers a `SHOW PARAMETER` error, and the session is already authenticated.
- **Use `TRY_COMPLETE`, not `COMPLETE`, in any model that calls a model over a table.** One erroring row
  otherwise fails the whole model and everything downstream of it.
- **Never commit a real `profiles.yml`, and never default the role to `ACCOUNTADMIN`.** A dbt run role
  should be least-privilege; in a healthcare deployment an `ACCOUNTADMIN` default is a finding, not a
  nit.
- **Streamlit-in-Snowflake `environment.yml` rejects version specifiers** (`>`, `<`, `=`) in dependency
  names. The app fails to start with an error that does not name the offending line.
