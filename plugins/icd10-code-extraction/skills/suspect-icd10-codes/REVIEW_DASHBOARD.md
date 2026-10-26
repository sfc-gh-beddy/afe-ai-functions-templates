# Optional: a read-only review dashboard

The pipeline ends at `ICD10_SUSPECTS`. Review workflow is out of scope for this plugin — there is no
approval gate, no assignment, no write-back. But a coding lead will ask to *see* the output, and a
Streamlit-in-Snowflake app is the cheapest way to show it without exporting PHI anywhere.

**This is strictly read-only.** It `SELECT`s from the output table and writes nothing. The
`reviewed_by` / `review_status` / `review_date` / `review_notes` columns exist on the output table so
review can be added later without a migration — this app must not populate them. If the customer wants
a real review workflow, that is a separate build with an audit trail, and saying so is more useful than
half-implementing it here.

Offer it, do not assume it. It is not a build phase and the router does not gate it.

## What it should show

Four views, in this order of usefulness to a coder:

1. **Worklist**, filtered by `confidence_band` and defaulted to `HIGH`. Sorted by `raf_factor`
   descending, because that is the order in which review time pays for itself. Show `patient_id`,
   `hcc_category`, `icd10_code`, `coder_confidence`, `judge_score`, `raf_factor`, and the
   `provider_memo` — the memo is the whole point, since it is written to be readable in ten seconds.

2. **Evidence detail** for a selected suspect. `FLATTEN` the `evidence` array and show one row per
   finding with `document_id`, `finding`, `observed_on`, and `evidence_basis`. Make `document_id`
   resolve to the source document text, because an evidence citation a reviewer cannot open is not
   auditable. Show `clinical_reasoning` and `judge_notes` in full — the judge notes are frequently the
   most informative field on the row, especially when it recommended `REVISE`.

3. **Per-condition breakdown.** Counts and average judge score grouped by `hcc_category`, worst first.
   This is what tells a lead which condition to invest in.

4. **Experiment comparison**, when more than one `experiment_id` exists. Micro and macro F1 side by
   side with `experiment_name` and `prompt_hash`. Only meaningful if the suspecting layer is
   materialized `incremental` — see `DBT_MATERIALIZATION.md`.

## Things to get right

- **Filter on `confidence_band`, and default to `HIGH`.** Presenting `LOW` suspects first is the fastest
  way to lose a reviewer's trust in the whole pipeline.
- **Show `coder_confidence` and `judge_score` as separate columns.** They measure different things and a
  disagreement between them is a signal, not noise — the layered-defence case is exactly a low coder
  confidence plus a downgraded judge score.
- **Surface `evidence_basis`.** A suspect whose evidence is entirely `CLINICALLY_INFERRED` warrants a
  different kind of attention than one grounded in a documented lab value. This is why the enum exists
  rather than free-text reasoning.
- **Always show the model year next to a RAF figure.** A revenue number without its CMS model year is
  not a revenue number.
- **Never write PHI outside the account.** No CSV download button, no export, no caching to local disk.
  `st.download_button` on a suspect table is a data-exfiltration path with a friendly icon.
- **`environment.yml` in Streamlit-in-Snowflake rejects version specifiers** (`>`, `<`, `=`) in
  dependency names. The app fails to start and the error does not name the offending line.
- **Run it on a small warehouse and query the output table directly.** No AI calls belong in a dashboard
  — an `AI_COMPLETE` behind a widget re-bills inference on every rerender, and Streamlit reruns the whole
  script on every interaction.

## Building it

Load the **`developing-with-streamlit-in-snowflake`** skill, which owns the scaffold, deployment, and
theming. Do not hand-roll the deployment here. Point it at `ICD10_SUSPECTS` and the four views above.
