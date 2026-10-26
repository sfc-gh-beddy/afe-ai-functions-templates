---
name: seed-icd10-sandbox
description: "Generate a synthetic clinical corpus with a labeled answer key so an ICD-10 / HCC suspecting pipeline can be built, demonstrated, and accuracy-tested before touching PHI. Creates patients, demographics, claims history with deliberate coding gaps, clinical notes with planted evidence signals, realistic administrative noise and duplicates, and ground-truth labels for the accuracy harness. Configurable panel size, site count, and target conditions. Phase 1 of the icd10-extraction build."
parent_skill: icd10-extraction
---

# Seed the sandbox

Generate a synthetic clinical corpus with **ground truth**. This is what makes the accuracy harness
produce real recall and precision numbers on day one, and it lets the whole build be demonstrated
before a PHI access review completes.

The corpus is deliberately constructed so the right answers are known: specific patients carry
specific planted evidence for specific conditions, and those conditions are deliberately absent from
their claims history. A correct pipeline finds them. An incorrect one does not, and the harness says
which.

## Why not just point at real charts

You can, and Phase 1 is skippable. But be honest about what is given up: on real data there is no
ground truth until someone builds a labeled set, which is weeks of clinician time. Without it, the
pipeline produces suspects with no way to know how many real conditions it missed — and *missed*
conditions are the entire value proposition. Recall is unmeasurable, so the only feedback available
is coders rejecting false positives, which measures precision alone and looks like the pipeline is
worse than it is.

## Configure before generating

Ask for these, defaulting sensibly. Write them into `icd10-project.yml`.

| Parameter | Default | Notes |
|---|---|---|
| Panel size | 500 patients | Enough for a believable distribution; small enough to run cheaply |
| Patients with planted signals | 11 | The labeled set. Keep it small — every one is hand-authored |
| Sites | 5 | Exercises site-level grouping without bloating the generator |
| Target conditions | 5 | Must match `cms.target_hccs`. More conditions means more fan-out cost |
| Noise ratio | ~30% of documents | Consent forms, duplicates, billing forms — the skip tier needs something to skip |
| Scanned-document share | 20% | Documents with no text, forcing the OCR path, so routing is exercised |

**The condition set must match the knowledge store.** A planted signal for a condition that has no
coding guidance cannot be found, and it will read as a pipeline failure when it is a configuration
mismatch. Cross-check against Phase 3 before generating.

## What gets created

| Object | Purpose |
|---|---|
| `SYNTH_PATIENTS` | Demographics, site, panel status, next appointment |
| `SYNTH_CLAIMS_HISTORY` | Already-coded conditions, with deliberate gaps for planted signals |
| `SYNTH_DOCUMENTS` | Clinical documents: notes, reports, plus administrative noise and duplicates |
| `SYNTH_ANSWER_KEY` | Ground truth. **Never joined into the pipeline** — validation only |
| `SYNTH_CONDITION_REFERENCE` | Condition codes, ICD-10 sets, RAF weights, pinned to a model year |

`sql/01_seed_sandbox.sql` in this directory is the template. Read it, substitute the configured
values and the target database and schema, and run it. Do not run it unmodified — it is written with
placeholders.

## The answer key is quarantined

This matters more than it sounds. The answer key must never be reachable from the pipeline:

- It lives in its own schema, or carries a name prefix that makes accidental inclusion obvious.
- No pipeline query joins it. Only `evaluate-icd10-accuracy` reads it.
- It is never included in a prompt, in retrieved context, or in the knowledge store.

A pipeline that has seen its own answer key produces meaningless accuracy figures, and the leak is
easy to introduce and hard to notice — a `SELECT *` over a schema is enough.

## How planted signals are constructed

Each labeled patient gets clinical documentation that a competent coder would call sufficient, spread
across multiple documents and dates so the pipeline has to assemble evidence rather than pattern-match
one sentence. The pattern for each:

1. **Objective findings** — a test result with a value, in a report document.
2. **Corroborating findings** — symptoms or exam findings, in a visit note on a different date.
3. **Treatment signal** — a medication or intervention consistent with the condition.
4. **A trend where the condition warrants one** — a value moving across three dates, which is what
   distinguishes progression from a single abnormal result.
5. **Absence from claims history** — the whole point. The condition is not coded.

Deliberately include harder cases, because a corpus of only obvious cases produces flattering and
useless accuracy numbers:

- **Borderline cases** that should classify as warranting evaluation rather than as an asserted
  suspect. These test whether the pipeline distinguishes the two, which is a common failure.
- **Distractor cases** with findings that superficially suggest a condition but have a documented
  alternative explanation — evidence with a non-cardiac cause, a condition documented as resolved.
  These are how precision gets measured. A pipeline that flags them is over-calling.
- **One condition already correctly coded** with supporting evidence present, to verify suppression
  works and the pipeline reports gaps rather than restating the known picture.

Record the expected classification for every labeled patient, not just the expected code — otherwise
the harness cannot tell a correct `EVAL` from a missed `SUSPECT`.

## Noise must look like real noise

The skip tier is a cost lever, and it cannot be validated against a corpus with nothing to skip.
Generate:

- **Administrative forms** — consent, privacy notices, financial responsibility, release of
  information. These carry no clinical signal and should route to skip.
- **Near-duplicates** — the same note content under a different document id, sometimes with a
  different date. Tests the dedup key, and specifically tests that dedup is patient-scoped: include
  documents from *different* patients that share identical opening text, since an unscoped
  `MD5(LEFT(text, N))` key will wrongly collapse them.
- **Genuinely thin documents** — a one-line addendum. Real corpora are full of these and they should
  not be treated as extraction failures.
- **Scanned documents** — rows with `NULL` text and a file path, forcing the OCR path.

## Verification before declaring the phase done

Run these and show the results. Every one has a specific failure it catches.

```sql
-- 1. Every labeled patient must actually be missing their planted condition
--    from claims. If not, suppression will correctly hide them and the
--    harness will report a recall failure that is really a seed bug.
SELECT ak.patient_id, ak.expected_hcc
FROM SYNTH_ANSWER_KEY ak
JOIN SYNTH_CLAIMS_HISTORY ch
  ON ch.patient_id = ak.patient_id AND ch.hcc_mapped = ak.expected_hcc;
-- Expect zero rows.
```

```sql
-- 2. Every labeled patient must have documents to reason over.
SELECT ak.patient_id, COUNT(d.document_id) AS docs
FROM SYNTH_ANSWER_KEY ak
LEFT JOIN SYNTH_DOCUMENTS d ON d.patient_id = ak.patient_id
GROUP BY 1
HAVING COUNT(d.document_id) = 0;
-- Expect zero rows.
```

```sql
-- 3. Every expected condition must exist in the reference table, or it can
--    never be found.
SELECT ak.expected_hcc
FROM SYNTH_ANSWER_KEY ak
LEFT JOIN SYNTH_CONDITION_REFERENCE cr ON cr.hcc_code = ak.expected_hcc
WHERE cr.hcc_code IS NULL;
-- Expect zero rows.
```

```sql
-- 4. Corpus shape: is there actually noise to skip and scans to OCR?
SELECT document_type,
       COUNT(*) AS docs,
       COUNT_IF(document_text IS NULL) AS scanned,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS pct
FROM SYNTH_DOCUMENTS
GROUP BY 1 ORDER BY docs DESC;
```

```sql
-- 5. Cross-patient duplicate text exists, so the dedup-scope bug is testable.
SELECT MD5(LEFT(document_text, 500)) AS text_hash,
       COUNT(DISTINCT patient_id) AS distinct_patients
FROM SYNTH_DOCUMENTS
WHERE document_text IS NOT NULL
GROUP BY 1
HAVING COUNT(DISTINCT patient_id) > 1;
-- Expect at least one row. Zero means the dedup-scope trap is untested.
```

Then write `phases.seed: done` and record the created objects.

## Keep it synthetic, and keep it obviously synthetic

- Names and identifiers must be transparently fabricated, with a distinguishing prefix on every
  identifier so a synthetic row can never be mistaken for a real one.
- No real addresses, no real provider identifiers, nothing resembling a live member id format.
- The clinical content should be medically coherent — nonsense notes make the pipeline look better
  than it is, because there is nothing to reason through.
- Do not model the corpus on a specific real organization's document taxonomy. Use generic document
  types and source system names, and let the customer's real taxonomy come from preflight.

## Teardown

The sandbox is disposable and should be dropped once real data is wired in, since it otherwise sits
alongside real suspects and will eventually get queried by accident. Record the objects in
`created_objects` so teardown drops exactly what was created.
