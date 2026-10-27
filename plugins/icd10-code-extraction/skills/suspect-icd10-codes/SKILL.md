---
name: suspect-icd10-codes
description: "The coder agent and the scored output table. Runs one focused AI_COMPLETE per patient per target condition, carrying that condition's own clinical criteria and coding specificity rules retrieved from the knowledge store, with already-coded conditions suppressed against claims history. Enforces a schema-required output contract so every suspect carries a confidence score and cited evidence with a resolvable document_id and an EXPLICITLY_DOCUMENTED / CLINICALLY_INFERRED basis, joins the RAF factor for revenue impact, scores each suspect with an inline judge rubric, stamps experiment_id, prompt_version and prompt_hash on every row so runs are comparable and reproducible, and accounts for parse failures so silent recall loss is visible. Phase 5 of the icd10-extraction build."
parent_skill: icd10-extraction
---

# Suspect ICD-10 codes

This is where the pipeline earns its keep, and where most of its accuracy is decided. One focused model
call per patient per target condition, each carrying that condition's own criteria.

## Why one call per condition, not one call per patient

The tempting design is a single prompt asking "what conditions is this patient missing?". It performs
notably worse, for three reasons:

- **Criteria do not fit.** Asking about one condition lets the prompt carry that condition's full
  suspect, evaluate, and reject criteria plus its coding specificity rules. Asking about twenty means
  carrying none of them in useful detail.
- **Attention divides.** A single call ranks and prunes across conditions, and marginal-but-real
  findings lose to more obvious ones. A focused call assesses the evidence on its own terms.
- **Suppression becomes per condition.** Already-coded conditions can be excluded from the fan-out
  before any inference runs, so nothing is spent asking about what is already known.

The cost is a multiplier: patients times conditions. That is why Phase 2 routing and Phase 4
compression exist, and why the target condition list should be deliberate rather than exhaustive.

## Build the fan-out with suppression

```sql
CREATE OR REPLACE TABLE SUSPECT_CANDIDATES AS
SELECT
    ps.patient_id,
    ps.summary_text,
    ps.document_ids,
    t.hcc_code,
    t.hcc_category,
    gc.guidance_text,
    cr.raf_factor,
    '<model_year>' AS model_year
FROM PATIENT_SUMMARY ps
CROSS JOIN <target_conditions> t
JOIN GUIDELINE_CONTEXT gc
  ON gc.hcc_code = t.hcc_code AND gc.model_year = '<model_year>'
JOIN <condition_reference> cr
  ON cr.hcc_code = t.hcc_code AND cr.model_year = '<model_year>'
-- Suppression: the pipeline reports GAPS, not a restatement of what is
-- already coded. Note the code format on both sides must match --
-- 'HCC85' vs '85' is the usual cause of an empty output table.
WHERE NOT EXISTS (
    SELECT 1
    FROM <claims_history> ch
    WHERE ch.patient_id = ps.patient_id
      AND ch.hcc_mapped = t.hcc_code
      AND ch.service_date >= DATEADD(MONTH, -<lookback_months>, CURRENT_DATE())
);
```

Two things to state explicitly rather than leave implicit:

- **The claims lookback window is a policy decision**, not a technical default. Risk adjustment
  generally requires a condition to be documented within the current period, so a condition coded two
  years ago and not since may legitimately be a gap again. Ask; do not assume.
- **`GUIDELINE_CONTEXT` and the condition reference are inner-joined.** A condition missing from either
  silently disappears from the entire fan-out. Verify before running.

```sql
-- What did suppression remove, and does the fan-out cover every target?
-- "Zero suspects found" and "suppression removed everything" look identical in
-- the output table and have completely different fixes.
SELECT
    (SELECT COUNT(*) FROM PATIENT_SUMMARY) * (SELECT COUNT(*) FROM <target_conditions>)
                                                      AS theoretical_max,
    (SELECT COUNT(*) FROM SUSPECT_CANDIDATES)         AS after_suppression_and_joins,
    (SELECT COUNT(DISTINCT hcc_code) FROM SUSPECT_CANDIDATES) AS conditions_covered,
    (SELECT COUNT(*) FROM <target_conditions>)        AS conditions_targeted;
```

If `conditions_covered` is less than `conditions_targeted`, a join dropped a condition. Fix that before
spending anything on inference.

## The coder call

```sql
CREATE OR REPLACE TABLE SUSPECT_RAW AS
SELECT
    c.patient_id,
    c.hcc_code,
    c.hcc_category,
    c.raf_factor,
    c.model_year,
    AI_COMPLETE(
        model => '<extract_model>',
        prompt => CONCAT(
            'You are a clinical coding specialist assessing whether a patient has documented ',
            'evidence supporting a specific undocumented condition. Respond in JSON.\n\n',
            'TARGET CONDITION: ', c.hcc_category, ' (', c.hcc_code, ')\n\n',
            '=== CODING GUIDANCE FOR THIS CONDITION ===\n',
            c.guidance_text, '\n\n',
            '=== HOW TO DECIDE ===\n',
            'SUSPECT  - the documented evidence is sufficient to support this diagnosis per the ',
            'guidance above.\n',
            'EVAL     - findings warrant clinical evaluation but are NOT sufficient to assert the ',
            'diagnosis. Use this when evidence is suggestive but incomplete.\n',
            'NONE     - the evidence does not support this condition, OR the findings have a ',
            'documented alternative explanation, OR the condition is documented as resolved.\n\n',
            'RULES YOU MUST FOLLOW:\n',
            '1. Medication use alone is NEVER sufficient. A patient on a diuretic and a beta ',
            'blocker may have neither heart failure nor any cardiac condition.\n',
            '2. If the chart documents an alternative explanation for a finding, or states the ',
            'condition is resolved or excluded, return NONE. Read the exclusions section.\n',
            '3. Assign the MOST SPECIFIC ICD-10 code the documented evidence supports, per the ',
            'coding guidance above. Do not assign an unspecified code when the type, severity, ',
            'or acuity is documented. Put exactly ONE code in icd10_code. If the guidance directs ',
            'coding additional complications or manifestations separately, put those in ',
            'additional_icd10_codes as separate array elements. Never put more than one code in ',
            'a single field.\n',
            '4. Cite evidence ONLY from the document ids present in the summary below, tagged as ',
            '[doc: <id>]. Never invent a document id. If you cannot attribute a finding to a ',
            'document id, do not cite it.\n',
            '5. Confidence is 1-10 and reflects EVIDENCE STRENGTH: 9-10 definitive objective ',
            'confirmation; 7-8 multiple corroborating objective findings; 5-6 suggestive, ',
            'provider confirmation needed; 3-4 circumstantial; 1-2 speculative.\n',
            '6. For EACH cited finding, set evidence_basis to EXPLICITLY_DOCUMENTED when the ',
            'chart states the finding directly, or CLINICALLY_INFERRED when you reasoned to it from ',
            'other findings. Inference is legitimate, but it must be labelled as inference.\n\n',
            '=== PATIENT SUMMARY ===\n',
            'Available document ids: ', ARRAY_TO_STRING(c.document_ids, ', '), '\n\n',
            c.summary_text
        ),
        model_parameters => {'temperature': 0, 'max_tokens': 4096},
        response_format => {
            'type': 'json',
            'schema': {
                'type': 'object',
                '$defs': {
                    'finding': {
                        'type': 'object',
                        'properties': {
                            'document_id': {'type': 'string',
                                'description': 'Must be one of the document ids supplied in the prompt. Never invent.'},
                            'finding':     {'type': 'string',
                                'description': 'The clinical finding, including numeric values and units where present'},
                            'observed_on': {'type': 'string',
                                'description': 'Date of the finding if documented, else empty string'},
                            'evidence_basis': {'type': 'string',
                                'enum': ['EXPLICITLY_DOCUMENTED', 'CLINICALLY_INFERRED'],
                                'description': 'EXPLICITLY_DOCUMENTED if the chart states this finding directly; CLINICALLY_INFERRED if you reasoned to it from other findings.'}
                        },
                        'required': ['document_id', 'finding', 'evidence_basis']
                    }
                },
                'properties': {
                    'classification':     {'type': 'string', 'enum': ['SUSPECT', 'EVAL', 'NONE']},
                    'icd10_code':         {'type': 'string',
                        'description': 'Exactly ONE ICD-10-CM code, the primary and most specific code supported by cited evidence. Format like I50.22. Empty string if classification is NONE.'},
                    'additional_icd10_codes': {'type': 'array', 'items': {'type': 'string'},
                        'description': 'Any further ICD-10-CM codes for separately reportable complications or manifestations. One code per element. Empty array if none.'},
                    'condition_detail':   {'type': 'string',
                        'description': 'Specific condition name including type, severity and acuity where documented'},
                    'confidence':         {'type': 'number',
                        'description': 'Integer 1-10 reflecting strength of the cited evidence'},
                    'evidence':           {'type': 'array', 'items': {'$ref': '#/$defs/finding'}},
                    'clinical_reasoning': {'type': 'string',
                        'description': 'Why the cited evidence meets or fails the criteria in the guidance'},
                    'provider_memo':      {'type': 'string',
                        'description': 'Four to six lines a clinician can read in ten seconds: the code considered, key evidence with values and dates, recommended action, and what to document'}
                },
                'required': ['classification', 'confidence', 'evidence', 'clinical_reasoning']
            }
        },
        show_details => TRUE
    ) AS response
FROM SUSPECT_CANDIDATES c;
```

### What is load-bearing in that prompt

Do not trim these when editing:

- **`classification` as a three-value enum.** Collapsing `SUSPECT` and `EVAL` manufactures false
  positives out of genuine uncertainty, and reviewer trust drops fast when uncertain findings arrive
  presented as asserted diagnoses.
- **Rule 1, medication-only inference.** This is a classic coding error and models fall into it
  readily. It is the single highest-yield line in the prompt for precision.
- **Rule 2, documented alternative explanations.** Paired with the compression step preserving the
  exclusions section, this is what stops venous edema being coded as heart failure.
- **Rule 4 plus the explicit list of available document ids.** A model asked to cite provenance it was
  never given will fabricate it. Supplying the id list and constraining `document_id` as `required` is
  what makes citation real.
- **`required` on `confidence` and `evidence`.** These are the two guarantees the router promises. A
  schema-optional field is a field that sometimes comes back missing.
- **`evidence_basis` as a two-value enum, `required` on every finding.** Asking a model to distinguish
  what the chart *says* from what it *concluded* improves the reasoning by itself. Making it an enum
  rather than free text is what makes it queryable: a coder triaging a worklist can sort inferred-only
  suspects to the bottom, and the harness can measure precision separately for each basis. A suspect
  whose evidence is entirely `CLINICALLY_INFERRED` is a different object from one grounded in a
  documented lab value, and free-text reasoning cannot express that difference to a `WHERE` clause.

### Why a schema rather than "return only JSON"

A prompt that politely asks for JSON and parses with `TRY_PARSE_JSON` fails silently: a preamble or a
fenced code block yields `NULL`, and in a suspecting pipeline `NULL` is indistinguishable from *this
patient has no findings*. Recall leaks with nothing in the output to indicate it. A `response_format`
schema constrains generation token by token so the response cannot come back unparseable.

Note that `AI_COUNT_TOKENS` **underestimates** structured-output calls on Claude models: the schema
generates additional request content that is billed but not counted. Reconcile against
`cortex_ai_functions_usage_history` after the first real run rather than trusting the estimate.

## Score, then land the output

Confidence arrives from the coder as evidence strength. The judge adds a second, different signal:
would a reviewer accept this recommendation. Keep both — they mean different things, and silently
overwriting one with the other loses information.

```sql
CREATE OR REPLACE TABLE SUSPECT_JUDGED AS
SELECT
    p.*,
    AI_COMPLETE(
        model => '<judge_model>',
        prompt => CONCAT(
            'You are a quality reviewer for clinical coding recommendations. Respond in JSON.\n\n',
            'Score this recommendation on each dimension, 1-10:\n',
            'EVIDENCE_STRENGTH  - is the cited evidence sufficient for this diagnosis?\n',
            'CODING_ACCURACY    - is the ICD-10 code correct AND at the right specificity?\n',
            'MEMO_QUALITY       - is the provider memo clear, accurate and actionable?\n',
            'CLINICAL_VALIDITY  - would a coding reviewer accept this as audit-ready?\n\n',
            'Then give an overall score, weighted: evidence 40 percent, validity 30 percent, ',
            'coding 20 percent, memo 10 percent. Recommend APPROVE, REVISE or REJECT.\n\n',
            'Judge only what is cited. Evidence not cited does not exist for your purposes. ',
            'A recommendation citing findings that do not support the code must score low on ',
            'evidence strength regardless of how plausible the condition is.\n\n',
            '=== RECOMMENDATION ===\n',
            'Condition: ', p.hcc_category, ' (', p.hcc_code, ')\n',
            'ICD-10: ', COALESCE(p.icd10_code, 'none'), '\n',
            'Classification: ', p.classification, '\n',
            'Coder confidence: ', p.coder_confidence::STRING, '\n',
            'Cited evidence: ', TO_JSON(p.evidence), '\n',
            'Reasoning: ', COALESCE(p.clinical_reasoning, ''), '\n',
            'Memo: ', COALESCE(p.provider_memo, '')
        ),
        model_parameters => {'temperature': 0, 'max_tokens': 1024},
        response_format => {
            'type': 'json',
            'schema': {
                'type': 'object',
                'properties': {
                    'evidence_strength':  {'type': 'number'},
                    'coding_accuracy':    {'type': 'number'},
                    'memo_quality':       {'type': 'number'},
                    'clinical_validity':  {'type': 'number'},
                    'overall_score':      {'type': 'number'},
                    'recommendation':     {'type': 'string', 'enum': ['APPROVE','REVISE','REJECT']},
                    'reviewer_notes':     {'type': 'string'}
                },
                'required': ['evidence_strength','coding_accuracy','memo_quality',
                             'clinical_validity','overall_score','recommendation']
            }
        },
        show_details => TRUE
    ) AS judge_response
FROM SUSPECT_PARSED p
WHERE p.classification IN ('SUSPECT', 'EVAL');
```

Only judge what was actually flagged. Scoring the `NONE` rows spends the judge model on the majority of
the fan-out for no benefit.

## The output table

```sql
CREATE OR REPLACE TABLE ICD10_SUSPECTS (
    suspect_id            VARCHAR(64),
    patient_id            VARCHAR(50),
    hcc_code              VARCHAR(10),
    hcc_category          VARCHAR(100),
    -- VARCHAR(20), not (10). Leaves headroom, and makes a contract violation
    -- land as inspectable data rather than as a failed INSERT.
    icd10_code            VARCHAR(20),
    -- Separately reportable complications. Keep as ARRAY: the accuracy harness
    -- must check BOTH this and icd10_code, because the coder may legitimately
    -- report the expected code as a secondary manifestation.
    additional_icd10_codes ARRAY,
    -- Model-generated free text: declare UNBOUNDED VARCHAR. Snowflake charges
    -- nothing extra for it, and a tight limit buys nothing while guaranteeing
    -- an eventual "String is too long" INSERT failure on a verbose response.
    -- Judge notes in particular routinely exceed 2000 characters.
    condition_detail      VARCHAR,
    classification        VARCHAR(10),      -- SUSPECT | EVAL
    -- Two distinct scores. Do not collapse them.
    coder_confidence      INT,              -- evidence strength, from the coder
    judge_score           INT,              -- reviewer acceptability, from the judge
    confidence_band       VARCHAR(20),      -- HIGH | REVIEW | LOW
    -- Evidence stays VARIANT so individual findings remain queryable.
    -- Casting this to VARCHAR compiles, runs, and breaks every downstream FLATTEN.
    evidence              VARIANT,
    evidence_count        INT,
    clinical_reasoning    VARCHAR,
    provider_memo         VARCHAR,
    -- Revenue impact. RAF is meaningless without its model year.
    raf_factor            FLOAT,
    model_year            VARCHAR(10),
    judge_recommendation  VARCHAR(10),
    judge_notes           VARCHAR,
    -- How much of the evidence the model reasoned to rather than read. Lets a
    -- coder deprioritise inference-only suspects, and lets the harness measure
    -- precision separately by basis.
    inferred_evidence_count INT,
    -- Cost instrumentation, populated rather than stubbed.
    coder_tokens          INT,
    judge_tokens          INT,
    -- Provenance and lineage. run_id is the idempotency key for one invocation;
    -- the experiment columns are what make two runs comparable.
    run_id                VARCHAR(64),
    experiment_id         VARCHAR(64),
    experiment_name       VARCHAR,
    prompt_version        VARCHAR(20),
    -- Hash of the ASSEMBLED prompt text. This is the column that survives
    -- someone forgetting to bump prompt_version, which happens on most runs.
    prompt_hash           VARCHAR(64),
    -- Which model produced this row. Without it a comparison across model
    -- swaps is unattributable.
    coder_model           VARCHAR(100),
    judge_model           VARCHAR(100),
    generated_at          TIMESTAMP_LTZ,
    -- Reserved for a later review workflow. Nothing in this plugin writes
    -- these; they exist so review can be added without a migration.
    reviewed_by           VARCHAR(100) DEFAULT NULL,
    review_status         VARCHAR(20)  DEFAULT 'NOT_REVIEWED',
    review_date           TIMESTAMP_LTZ DEFAULT NULL,
    review_notes          VARCHAR       DEFAULT NULL
);
```

### Land it, with the provenance gate enforced in SQL

A JSON schema cannot express "the array must be non-empty" — `minItems` is unsupported. And it cannot
verify that a cited `document_id` is real. Both have to be enforced here.

> **Write the gate set-based.** The obvious form — a correlated scalar subquery inside `ARRAY_CONTAINS`
> within a `NOT EXISTS ... LATERAL FLATTEN` — **does not compile**. Snowflake rejects it with
> `Unsupported subquery type cannot be evaluated`. Join the valid document ids in first, then check
> citations with a grouped aggregate, as below.

```sql
-- Step 1: attach the set of document ids that are valid for each patient.
CREATE OR REPLACE TEMPORARY VIEW V_JUDGED AS
SELECT sj.*, ps.document_ids AS valid_doc_ids
FROM SUSPECT_JUDGED sj
JOIN PATIENT_SUMMARY ps ON ps.patient_id = sj.patient_id
WHERE sj.classification IN ('SUSPECT', 'EVAL');

-- Step 2: count bad citations and inferred findings per suspect with a grouped
-- aggregate, in one pass over the evidence.
CREATE OR REPLACE TEMPORARY VIEW V_CITATION_CHECK AS
SELECT j.patient_id, j.hcc_code,
       COUNT(*) AS cited_count,
       COUNT_IF(NOT ARRAY_CONTAINS(f.value:document_id::VARIANT, j.valid_doc_ids)) AS bad_citations,
       COUNT_IF(f.value:evidence_basis::STRING = 'CLINICALLY_INFERRED')            AS inferred_count
FROM V_JUDGED j, LATERAL FLATTEN(input => j.evidence) f
GROUP BY 1, 2;

-- Step 3: insert only what passes both gates.
INSERT INTO ICD10_SUSPECTS (
    suspect_id, patient_id, hcc_code, hcc_category, icd10_code, additional_icd10_codes,
    condition_detail, classification, coder_confidence, judge_score, confidence_band,
    evidence, evidence_count, clinical_reasoning, provider_memo,
    raf_factor, model_year, judge_recommendation, judge_notes, inferred_evidence_count,
    coder_tokens, judge_tokens,
    run_id, experiment_id, experiment_name, prompt_version, prompt_hash,
    coder_model, judge_model, generated_at
)
SELECT
    SHA2(j.patient_id || '::' || j.hcc_code || '::' || :run_id) AS suspect_id,
    j.patient_id, j.hcc_code, j.hcc_category, j.icd10_code, j.additional_icd10_codes,
    j.condition_detail, j.classification,
    j.coder_confidence,
    j.judge_response:structured_output[0]:raw_message:overall_score::INT AS judge_score,
    CASE
        WHEN j.judge_response:structured_output[0]:raw_message:overall_score::INT
             >= <high_confidence>   THEN 'HIGH'
        WHEN j.judge_response:structured_output[0]:raw_message:overall_score::INT
             >= <review_candidate>  THEN 'REVIEW'
        ELSE 'LOW'
    END AS confidence_band,
    j.evidence,
    ARRAY_SIZE(j.evidence) AS evidence_count,
    j.clinical_reasoning, j.provider_memo,
    j.raf_factor, j.model_year,
    j.judge_response:structured_output[0]:raw_message:recommendation::STRING,
    j.judge_response:structured_output[0]:raw_message:reviewer_notes::STRING,
    c.inferred_count,
    j.coder_tokens,
    j.judge_response:usage:total_tokens::INT,
    :run_id,
    :experiment_id,
    :experiment_name,
    :prompt_version,
    -- Hash the assembled prompt, not the template. Same expression must be used
    -- in SUSPECT_RAW so the two agree.
    SHA2(j.coder_prompt) AS prompt_hash,
    '<extract_model>',
    '<judge_model>',
    CURRENT_TIMESTAMP()
FROM V_JUDGED j
JOIN V_CITATION_CHECK c ON c.patient_id = j.patient_id AND c.hcc_code = j.hcc_code
-- Gate 1: no evidence, no suspect. An uncited code is unauditable.
WHERE ARRAY_SIZE(j.evidence) > 0
-- Gate 2: every cited document id must be real and belong to this patient.
  AND c.bad_citations = 0;
```

This requires one small addition upstream: `SUSPECT_RAW` must retain the assembled prompt text so it can
be hashed.

```sql
-- Bind the prompt once and select it alongside the response. Do NOT rebuild the
-- CONCAT in two places: a hash of a prompt that is not the prompt that ran is
-- worse than no hash at all.
SELECT ..., c.coder_prompt,
       AI_COMPLETE(model => '<extract_model>', prompt => c.coder_prompt, ...) AS response
FROM SUSPECT_CANDIDATES_WITH_PROMPT c;
```

### Why prompt_hash and not just prompt_version

`prompt_version` is a human promise and it gets broken — a rule is reworded mid-session and nobody bumps
the version, so two materially different runs carry the same label and the comparison is quietly
meaningless. `prompt_hash` is computed from the text that actually ran, so a run is reproducible from its
own output regardless. Keep both: the version is what a person reads, the hash is what is true.

When the two disagree — same `prompt_version`, different `prompt_hash` — trust the hash and say so.

**Route the rejects to the quality log rather than discarding them.** A hallucinated citation that
vanishes silently is a correctness problem you cannot see; one that lands in a log is one you can fix.

```sql
INSERT INTO PIPELINE_QUALITY_LOG (run_id, stage, issue, patient_id, hcc_code, detail)
SELECT :run_id, 'suspecting',
       CASE WHEN ARRAY_SIZE(j.evidence) = 0 THEN 'NO_EVIDENCE'
            ELSE 'FABRICATED_CITATION' END,
       j.patient_id, j.hcc_code, TO_JSON(j.evidence)
FROM V_JUDGED j
LEFT JOIN V_CITATION_CHECK c ON c.patient_id = j.patient_id AND c.hcc_code = j.hcc_code
WHERE ARRAY_SIZE(j.evidence) = 0 OR COALESCE(c.bad_citations, 0) > 0;
```

## Account for parse failures

```sql
INSERT INTO PIPELINE_QUALITY_LOG (run_id, stage, issue, detail)
SELECT :run_id, 'suspecting', 'UNPARSEABLE_RESPONSE',
       OBJECT_CONSTRUCT(
           'total_calls',       COUNT(*),
           'unparseable',       COUNT_IF(response:structured_output IS NULL),
           'missing_required',  COUNT_IF(
               response:structured_output[0]:raw_message:classification IS NULL)
       )::STRING
FROM SUSPECT_RAW;
```

A pipeline that cannot say how many model calls failed cannot make a recall claim. With a schema in
place this should be zero or near it; if it is not, the schema is not being applied or the model is
refusing.

## Verification at the gate

```sql
-- 1. Output shape by classification and band.
SELECT classification, confidence_band, COUNT(*) AS suspects,
       ROUND(AVG(coder_confidence), 1) AS avg_coder_conf,
       ROUND(AVG(judge_score), 1)      AS avg_judge_score
FROM ICD10_SUSPECTS WHERE run_id = :run_id
GROUP BY 1, 2 ORDER BY 1, 2;
```

```sql
-- 2. The two hard guarantees. Both must be zero.
SELECT COUNT_IF(coder_confidence IS NULL OR judge_score IS NULL) AS unscored,
       COUNT_IF(evidence_count = 0)                              AS uncited
FROM ICD10_SUSPECTS WHERE run_id = :run_id;
```

```sql
-- 3. Every cited document must resolve. Must be zero.
SELECT COUNT(*) AS untraceable_findings
FROM ICD10_SUSPECTS s, LATERAL FLATTEN(input => s.evidence) f
WHERE s.run_id = :run_id
  AND f.value:document_id::STRING NOT IN (SELECT document_id FROM EXTRACTED_DOCUMENTS);
```

```sql
-- 4. Specificity check. A high share of unspecified codes means the knowledge
--    store is not grounding specificity, which is a Phase 3 problem.
SELECT hcc_code,
       COUNT(*) AS suspects,
       COUNT_IF(icd10_code ILIKE '%.9' OR icd10_code ILIKE '%.9_') AS unspecified_codes
FROM ICD10_SUSPECTS WHERE run_id = :run_id
GROUP BY 1 ORDER BY unspecified_codes DESC;
```

```sql
-- 5. Revenue impact, RAF-weighted, banded by confidence.
SELECT confidence_band,
       COUNT(*)                     AS suspects,
       COUNT(DISTINCT patient_id)    AS patients,
       ROUND(SUM(raf_factor), 2)    AS total_raf_opportunity,
       MAX(model_year)              AS model_year
FROM ICD10_SUSPECTS WHERE run_id = :run_id AND classification = 'SUSPECT'
GROUP BY 1;
```

Present RAF as a **RAF sum, not dollars**. Converting to revenue requires the organization's own
benchmark rate and member months, which is their number to apply, not one to assume. State that
plainly rather than producing a figure that will be quoted back later.

```sql
-- 6. Read five suspects end to end, high band and low band. This is the check
--    that catches a pipeline producing well-formed nonsense.
SELECT patient_id, hcc_code, icd10_code, classification,
       coder_confidence, judge_score, provider_memo, evidence
FROM ICD10_SUSPECTS WHERE run_id = :run_id
ORDER BY judge_score DESC LIMIT 5;
```

Then record the output table in `created_objects` and set `phases.suspect: done`.

## Idempotency

Key everything on `run_id`. If this is scheduled, task auto-retry re-invokes the whole step, and a
non-idempotent insert double-charges frontier-model inference and double-inserts suspects — which then
inflates every count in Phase 6. Either delete the run's rows before re-inserting, or make the insert a
merge on `suspect_id`.

## This is the end of the pipeline

Output lands in `ICD10_SUSPECTS`. There is no reviewer application, approval gate, or feedback loop in
this plugin. The reviewer columns are present and defaulted so that work can be added later without a
migration, but nothing here writes them — do not imply to the user that a review workflow exists.

If the user asks to *see* the output rather than query it, `REVIEW_DASHBOARD.md` in this directory
describes a strictly read-only Streamlit-in-Snowflake view of the suspect table. Offer it; do not build
it unprompted, and do not present it as review workflow.
