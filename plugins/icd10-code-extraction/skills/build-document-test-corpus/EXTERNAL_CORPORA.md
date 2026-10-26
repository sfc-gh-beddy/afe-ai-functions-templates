# External synthetic corpora

Options for realistic clinical note text when the generated sandbox is not varied enough. Assess fit
before importing — a corpus from the wrong care setting will look impressive and test the wrong thing.

## What to check before adopting any corpus

1. **Are there coding labels?** Almost always no. Most synthetic note corpora are corpora, not
   benchmarks. Without labels they cannot measure recall, only provide volume.
2. **What care setting?** Risk-adjustment coding gaps live in **ambulatory and primary care** encounters.
   A corpus of inpatient hospital notes is a different documentation genre.
3. **What coding system?** ICD-10-CM with CMS HCC mapping is US Medicare Advantage. ICD-10 variants,
   SNOMED, OPCS and national coding schemes do not map across.
4. **Text or documents?** Effectively always CSV text. Rendering to files is a separate step —
   see this skill's `SKILL.md`.
5. **Licence**, including derivative works if you render or modify it.
6. **Data quality.** Check for encoding corruption and empty rows before loading. Published corpora
   frequently ship with spreadsheet artefacts.

---

## NHS England — Synthetic Clinical Notes

The strongest openly available option at the time of writing.

| | |
|---|---|
| Paper | *A Pipeline for Generating Longitudinal Synthetic Clinical Notes Using Large Language Models*, Poulett et al., 2026, arXiv:2606.26879 |
| Data | `NHSEDataScience/synthetic_clinical_notes` on Hugging Face, under `silver/` |
| Code | `github.com/nhsengland/synthetic_clinical_notes` |
| Licence | MIT (code and dataset card); paper CC BY 4.0 |
| Size | ~2 MB. 1,602 notes, 50 patients with notes, 69 admissions |

### Actual shape, as verified rather than as documented

Three CSVs under `silver/`, not at the repository root — the dataset card lists them without the prefix,
so a naive fetch returns `Entry not found`.

```
silver/patients.csv                    69 rows   age, date_of_birth, full_name, gender_identity, nhs_number, person_id
silver/admissions.csv                  69 rows   admission_id, admission_method, admission_timestamp, admission_title,
                                                 bed_location, site_id, site_name, ward, patient_id, ...
silver/synthetic_clinical_notes.csv  1,602 rows  clinical_note_id, clean_note_text, note_subject, note_type,
                                                 creation_timestamp, admission_id, person_id
```

Note counts: ~32 notes per patient. Note length: minimum 6 characters, median 851, maximum 3,624.
The first column of each CSV carries a UTF-8 BOM — strip it or the first field name will not match.

### What is genuinely good about it

- **Real-world noise, deliberately injected.** Typos are present and look right in context
  ("Discusion", "dailt prvided", "Symmetrkical"). Clinical abbreviations are used naturally
  (TKR, OA, SpR, CN I-XII, FBC).
- **Clinician personas** give consistent per-author writing style across a patient journey — concise,
  narrative, bullet points, telegraphic notes, ABCDE structure.
- **Longitudinal coherence** with a temporal consistency check in the pipeline's own evaluation suite.
- **Genuinely thin notes exist naturally**, which is realistic and something generated corpora tend to
  miss.
- **Administrative and form documents are present** — `Pre-op Consent` and `Pre-op Checklist`, 66 notes
  between them. These are the most immediately useful part for this plugin: real, varied consent and
  checklist content for the T4 skip tier and the T3 form tier, far better than a handful of
  hand-written strings.
- The **pipeline itself is MIT licensed**, which is arguably more valuable than the dataset. Its
  admission-reason table is designed to be swapped, so it can be re-pointed at ambulatory encounters and
  a condition list of your choosing.

### What it does not give you

- **No ICD-10, HCC, or any diagnosis coding labels.** No ground truth. It cannot replace the answer key
  and it cannot measure recall. Use it as background, not as a benchmark.
- **UK inpatient secondary care.** The note type distribution is dominated by Orthopaedics Inpatients
  (263), Physiotherapy Documentation (262), Medicine Inpatients (242), ED (155), plus Anaesthetic,
  Theatre notes, Pre-op. Only 30 notes are outpatient. Ambulatory chronic-disease management — where
  risk-adjustment gaps actually accumulate — is essentially absent.
- **NHS identifiers and structures**: NHS numbers, wards, sites, admission methods. No claims history,
  so suppression cannot be tested.
- **No RAF, no HCC mapping, no US coding context.**
- **50 patients** is adequate for accuracy work and small for cost or scale testing.
- **Silver tier only.** The pipeline was clinician-reviewed; this data was not. Gold is planned, not
  released.
- GPT-4o generated. The paper itself cites a study finding GPT-4o had the highest hallucination rate
  among the models compared — worth knowing, though for background noise some hallucination is
  arguably realistic.

### Data quality — clean before loading

The dataset card says "some special characters may be incorrectly decoded". Verified, and slightly worse
than that implies:

- **7 notes contain the literal string `#NAME?`** — spreadsheet formula corruption, not a decode issue.
  0.4 percent of the corpus. Filter them out.
- **262 notes contain non-ASCII characters** from decode artefacts. Mostly cosmetic; normalise them.
- Strip the UTF-8 BOM from the first column of each CSV.

```python
# Minimum viable cleaning
import csv, unicodedata

def load(path):
    with open(path, newline="", encoding="utf-8-sig", errors="replace") as fh:
        return list(csv.DictReader(fh))

notes = [
    n for n in load("silver/synthetic_clinical_notes.csv")
    if n["clean_note_text"].strip() not in ("#NAME?", "#REF!", "#VALUE!", "#N/A", "")
    and len(n["clean_note_text"].strip()) >= 20
]
for n in notes:
    n["clean_note_text"] = unicodedata.normalize("NFKC", n["clean_note_text"])
```

That leaves 1,595 usable notes across 50 patients.

### Recommended use in this plugin

Do **not** use it as the primary sandbox. Use it for three specific jobs:

1. **Realistic background volume.** Load as `case_role = 'UNLABELED'`, `corpus_source = 'EXTERNAL_NHSE'`.
   Gives the pipeline a believable corpus to work through alongside the labeled cases, and produces a
   realistic tier mix.
2. **Real administrative and form content.** The Pre-op Consent and Pre-op Checklist notes are better
   T4 and T3 material than anything worth hand-writing.
3. **Style and noise reference for improving the generated sandbox.** Borrow the techniques rather than
   only the data: per-author personas, graded typo rates per staff member, an LLM validator loop for
   faithfulness, and a temporal coherence check. The generated sandbox has none of these and is
   noticeably cleaner than reality as a result.

Keep the labeled planted cases as the measurement instrument. See the hybrid design in `SKILL.md`.

### Attribution

Required if used. Cite the paper:

```bibtex
@misc{poulett2026pipelinegeneratinglongitudinalsynthetic,
  title  = {A Pipeline for Generating Longitudinal Synthetic Clinical Notes Using Large Language Models},
  author = {William Poulett and Alice Waterhouse and Ben Wallace and Scarlett Kynoch
            and Amaia Imaz Blanco and Michael Spence and Jonathan Pearson},
  year   = {2026},
  eprint = {2606.26879},
  archivePrefix = {arXiv},
  primaryClass  = {cs.AI},
  url    = {https://arxiv.org/abs/2606.26879}
}
```

---

## Other options worth knowing

- **Synthea** (`synthetichealth.github.io/synthea`) — open-source patient population simulator.
  Structured longitudinal records with conditions, medications, encounters and **coded diagnoses**, and
  it can emit US-context ambulatory care over a full lifespan. It generates structured data rather than
  narrative notes, but it is the best option when you need **coded** ground truth, and it can seed note
  generation. A UK adaptation exists but is primary-care focused. Worth serious consideration precisely
  because it supplies the codes the note corpora lack.
- **MedSyn** — knowledge-graph-guided synthetic medical text generation. Useful as a technique
  reference for grounding generation in an ontology.
- **De-identified real corpora** (MIMIC and similar) — genuinely real documentation, but access is
  credentialed with a data use agreement, and using them at a customer engagement is a legal question
  rather than a technical one. Do not assume they are usable.

## Generating your own instead

Frequently the better answer, because you control the condition list and can plant labels. The NHS
pipeline is MIT licensed and modular: its admission-reason table is explicitly designed to be swapped
for "an aggregate dataset of SNOMED or ICD coded reasons for admission". Re-pointing it at ambulatory
encounters with a target HCC list, and keeping its persona and typo augmentation, produces a corpus that
is both realistic and labeled — which neither source gives you on its own.

One correction if you adapt that pipeline: it cleans malformed LLM JSON with regex and then a repair
prompt. On Snowflake, use `AI_COMPLETE` with a `response_format` schema instead and the failure mode
disappears rather than being repaired. The paper acknowledges this directly — forced structured outputs
"reduced the risk of compilation failure drastically".
