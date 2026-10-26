---
name: document-intake-best-practices
description: "Correctness rules every document intake pipeline (invoices, contracts, claims, forms) must follow. Always loaded by the document-intake router. Catches silent failure modes where extraction runs clean, scores look high, and wrong values post anyway. Covers AI_EXTRACT scores semantics (named-argument only, aggregate-only for lists and tables, not a calibrated probability), per-field thresholds instead of a global one, validation-before-posting, false-STP as the headline risk, amount/date/currency normalization traps (decimal comma, dd/mm ambiguity, parenthesized negatives), asymmetric normalization in accuracy harnesses, missing-versus-wrong field accounting, AI_CLASSIFY returning no confidence and NULL on error, document-input classification being Preview, page metering and scale_factor cost, parse-and-extract double billing, page limits (125 for AI_EXTRACT, 2000 for AI_PARSE_DOCUMENT), stage encryption and directory tables, the AI_PARSE_DOCUMENT return-type trap, duplicate invoice detection, multi-document PDFs, idempotent incremental runs, schema hashing, sensitive-field handling (bank accounts, tax IDs, claimant PII), and dbt deployment traps."
parent_skill: document-intake
---

# Document intake — correctness rules

Every rule here has a failure mode in which the SQL succeeds, the counts look reasonable, the
dashboard shows a high straight-through-processing rate, and the result is wrong. In this play "wrong"
has a direct cost: an amount posted to a ledger, a payment released to the wrong bank account, a claim
opened against the wrong policy. Apply these to every artifact the plugin generates.

---

## 1. The headline risk is false STP, not low STP

A pipeline with a 40 percent STP rate and zero wrong posts is a success that can be tuned upward. A
pipeline with a 90 percent STP rate and 2 percent wrong posts has automated an error stream into the
ledger, and nobody will see it until reconciliation or an audit.

**The rule:** every accuracy report leads with **false-STP rate** — documents that were
`AUTO_APPROVED` and have at least one wrong value in a field that posts — alongside the STP rate. A
threshold change that raises STP is only accepted if the false-STP rate on the labeled set does not
rise. Never present STP alone.

## 2. `scores` are only returned with named arguments

`AI_EXTRACT(file, responseFormat)` positional syntax compiles and runs, and returns **no** `scoring`
object. Every `x:scoring:scores:<field>:score` path is then `NULL`, and a threshold test written as
`score >= 0.9` evaluates to `NULL` — which is falsey in a `WHERE` and truthy-looking nowhere. Depending
on how the decision is written, that either sends every document to exceptions (annoying) or, if the
decision is written as `NOT (score < 0.9)`, approves everything (dangerous).

```sql
-- Correct: named arguments, scores requested explicitly.
AI_EXTRACT(
    file           => TO_FILE('@<stage>', d.relative_path),
    responseFormat => :invoice_schema,
    scores         => TRUE
)
```

And write threshold logic so a missing score **fails closed**:

```sql
COALESCE(score, 0) >= min_score      -- missing score means not confident
```

Never `NOT (score < min_score)`. Assert at the extraction gate that `COUNT_IF(score IS NULL AND value
IS NOT NULL) = 0`.

## 3. A score is a ranking signal, not a probability

Documented: a higher score means a higher likelihood the value is correct, and scores are comparable
for the same entity across documents. Not documented, and not to be assumed: that `0.95` means "right
95 percent of the time", or that scores are comparable **across fields**. A date field and an amount
field can sit at very different score levels for the same true accuracy.

So:

- Thresholds are **per document type, per field**, and they are set from the measured
  score-versus-correctness curve in `evaluate-intake-accuracy`, not chosen by intuition.
- The starting values in `intake-project.yml` are placeholders and are labelled as such.
- Never describe a field score to a business user as a probability or a percentage confidence.

## 4. List and table scores are aggregate

For list and table extraction, `scoring` returns one score for the whole list or table. Per-row and
per-cell scores are not available. A line-item table scored 0.91 can still contain one wrong amount
on one row.

**The rule:** line items never auto-approve on their score alone. They auto-approve only when the
arithmetic closes — line amounts sum to subtotal, subtotal plus tax equals total within tolerance —
and, when PO data exists, they match PO lines. Arithmetic is the per-cell check the score cannot be.

## 5. Validation decides; the model never does

There is exactly one path to `INTAKE_APPROVED`: a row in `DOCUMENT_DECISION` with
`decision = 'AUTO_APPROVED'`, produced by SQL rules over normalized values and scores. Do not:

- ask `AI_COMPLETE` "is this invoice valid";
- let a high score on `total_amount` override a failed arithmetic check;
- add a convenience path that copies extracted rows directly to the approved table "for testing".

Assert at the validation gate:

```sql
SELECT COUNT(*) AS approved_without_decision
FROM INTAKE_APPROVED a
LEFT JOIN DOCUMENT_DECISION d ON d.document_id = a.document_id AND d.run_id = a.run_id
WHERE d.decision IS DISTINCT FROM 'AUTO_APPROVED';
-- Must be zero.
```

## 6. Missing is not the same as wrong, and both are not the same as absent

Three distinct outcomes per field, and collapsing them hides the failure mode:

| Outcome | Meaning | Correct pipeline behaviour |
|---|---|---|
| `NOT_PRESENT` | the document genuinely does not carry the field (no PO number on a non-PO invoice) | not an error unless the field is required for this type |
| `NOT_EXTRACTED` | the field is on the document and the extractor returned NULL or empty | exception if required; recall loss in eval |
| `WRONG` | a value came back and it is not the truth | the dangerous one — precision loss, false-STP risk |

The answer key must record `NOT_PRESENT` explicitly (see the sandbox), or the harness cannot tell a
correct NULL from a missed field. Do not assume an absent field always comes back as JSON null: treat
an empty string and placeholder strings such as `"None"`, `"null"`, `"N/A"`, `"-"` as NULL with one
shared expression (`NULLIF_PLACEHOLDER` in `extract-document-fields`) before scoring or validating, and
check the actual distribution of returned values for each field on the first run.

## 7. Normalize amounts with one function, and flag ambiguity instead of guessing

`AI_EXTRACT` returns strings (string is the only supported scalar type). `"1.234,56"`, `"$1,234.56"`,
`"(1,200.00)"`, and `"45.10-"` are all real invoice renderings. Casting with `TRY_TO_NUMBER` on the raw
string returns NULL for most of them and the wrong number for some.

The rule: one UDF, used by validation **and** by the accuracy harness, that

- strips currency symbols and spaces;
- treats the last `.` or `,` followed by exactly one or two trailing digits as the decimal separator;
- treats `(…)`, a leading minus, or a trailing minus as negative;
- flags `^[0-9]{1,3}[.,][0-9]{3}$` (for example `"1.234"`) as **ambiguous** — it is either one thousand
  two hundred thirty-four or one point two three four — and routes it to exceptions unless the
  vendor's locale is known.

The tested implementation is in `extract-document-fields/SKILL.md`. Do not write a second one.

## 8. Dates: `03/04/2026` is two dates

Both `MM/DD/YYYY` and `DD/MM/YYYY` parse `03/04/2026` successfully, to different days. A pipeline that
tries one format first silently picks whichever it tried first, and every invoice from a vendor in the
other convention gets a due date a month or more off — which is exactly the field that drives
early-pay discount capture and late-fee avoidance.

The rule: parse unambiguous formats first (ISO, month names); for slash or dot numeric dates, parse
both ways; if both succeed and differ, the field is `AMBIGUOUS` unless a per-vendor or per-region
convention is recorded in reference data. Ambiguous dates on a payment-driving field are blocking.

Also check plausibility: invoice date not in the future beyond `tolerances.future_date_days`, due date
not before invoice date, claim loss date within policy effective and expiry dates.

## 9. Currency must be explicit, never inferred from the symbol alone

`$` is at least a dozen currencies. When the document states an ISO code, use it. When it only shows a
symbol, take the currency from the vendor master or PO and record that it was inferred; if neither
exists, the currency is unresolved and a total in an unresolved currency does not post.

## 10. Classify before extract, and always keep an "other" label

Running the invoice schema on a contract returns confident-looking nonsense: a "total" pulled from a
liability cap, an "invoice date" that is the effective date. The schema is chosen by type, so the type
has to be right first.

- Always include `document_types.out_of_scope_label` in the label list, with a description, so a
  document that fits nothing is not forced into the nearest type.
- Label names are plain English, mutually exclusive, no abbreviations (the documented guidance) —
  `insurance_claim_form`, not `FNOL`.
- **`AI_CLASSIFY` returns labels, not a confidence.** There is no score to threshold. If the business
  needs a type-confidence signal, derive it from agreement between two cheap signals (for example
  classify-on-first-page and a metadata rule such as the intake channel), and send disagreements to
  exceptions.

## 11. `AI_CLASSIFY` returns NULL on error — count it

By default, a row `AI_CLASSIFY` cannot process returns `NULL` and the batch continues. A `NULL` type
then falls out of every `WHERE document_type = 'invoice'` filter downstream, and the document vanishes
— not rejected, not excepted, just gone.

Pass `return_error_details => TRUE` (the fourth positional argument), read `:value:labels[0]` and
`:error`, and map errors to an explicit `UNCLASSIFIED` route that lands in the exceptions queue. Assert
zero NULL types at the classify gate.

The same applies to `AI_PARSE_DOCUMENT` (third argument) and to `AI_EXTRACT`'s `error` field in its
response. Every AI step in this pipeline records its error, and every error becomes an exception row.

## 12. Document input to `AI_CLASSIFY` is Preview — default to text

`AI_CLASSIFY` on a FILE is documented as Preview, single-label only, no few-shot examples, English
only, with its own limits (100 pages, 22 MB, 2000x2000 px images), and the region table lists it under
cross-region only. Do not build the production path on it without saying so.

The default path classifies **text**: the first page or two of `AI_PARSE_DOCUMENT` output (with
`page_filter`) for scans, or the text layer when one exists. Record the choice in
`ai.classify_input`.

## 13. Pages are the meter — know which calls bill for them

| Call | Billing basis (documented) |
|---|---|
| `AI_PARSE_DOCUMENT` | per page processed; image files count as one page each; HTML/TXT per 3,000-character chunk |
| `AI_EXTRACT` on a file | per page at 970 tokens per page for paged formats and per image file, plus prompt and output tokens; multiplied by `scale_factor` |
| `AI_EXTRACT` on text | input and output tokens |
| `AI_CLASSIFY` | tokens, including its own added prompt, label descriptions and examples |

Consequences:

- **`page_split: TRUE` does not reduce pages billed** — it changes the response shape. Only
  `page_filter` limits what is processed. Use `page_filter` for classification samples.
- **Parsing and then extracting from the same file bills the pages twice.** If the parse output is not
  used for anything except classification, parse only the first pages. If the full text is needed (for
  example contracts going to a search service), consider extracting from the parsed **text** instead
  of the file — but measure field accuracy both ways first, because file input sees layout and text
  input does not.
- **`scale_factor` multiplies page tokens and divides the page limit** (2.0 doubles tokens per page and
  caps a document at 62 pages). Raise it only for a measured accuracy gain on small-print documents,
  and only for the document types that need it.

## 14. Page and size limits differ by function — check before you route

| Function | Pages | Size | Other |
|---|---|---|---|
| `AI_EXTRACT` | 125 (divided by `scale_factor`) | 100 MB | max 100 entity questions; a table question counts as 10; 512 output tokens per entity question |
| `AI_PARSE_DOCUMENT` | 2,000 | 100 MB | page resolution up to 10000x10000 px |
| `AI_CLASSIFY` (document input) | 100 | 22 MB | images up to 2000x2000 px |

A 300-page contract fails `AI_EXTRACT` outright. Route by page count from directory metadata or a
cheap parse with `page_filter`, and for long documents extract from targeted pages or from parsed text.
A document that exceeds a limit is an exception with the reason, never a silent NULL.

## 15. Stage prerequisites

- The stage needs a **directory table** (`DIRECTORY = (ENABLE = TRUE)`) to enumerate files with
  `DIRECTORY(@stage)`, and the directory must be refreshed (or auto-refreshed) or new files are
  invisible to the pipeline.
- Encryption must be server-side or client-side; a stage created with an unsupported configuration
  produces file-format errors that read like corrupt files.
- Use `TO_FILE('@db.schema.stage', relative_path)` with the fully qualified stage. An unqualified
  stage name resolves against the session schema and fails inside a task.

## 16. `AI_PARSE_DOCUMENT` return type: always `PARSE_JSON(TO_VARCHAR(...))`

Documented as a JSON string; observed on some accounts as an OBJECT, where `PARSE_JSON(OBJECT)` is a
compile error. `PARSE_JSON(TO_VARCHAR(AI_PARSE_DOCUMENT(...)))` works either way. With
`return_error_details => TRUE` the function returns an OBJECT with `value`, `error`, and `metadata`, so
read `:value` directly. Pick one form per pipeline and do not mix them.

## 17. Never `LEFT(text, N)` a document before extraction or classification

Invoice totals, remittance bank details, signature blocks and contract termination clauses live at the
**end** of documents. Truncating by characters keeps the letterhead and drops the payload. For
classification, sample the first pages deliberately (type is usually evident on page one). For
extraction, use the file or the full parse output; for very long contracts, select pages by content,
not by position.

## 18. Duplicates are a payment risk, not a cost optimization

A duplicate invoice that auto-approves is a duplicate payment. Two checks, both blocking:

- **file-level:** identical content (hash of the file's `MD5` from the directory table, or of the
  parsed text) already processed;
- **business-level:** same normalized vendor, normalized invoice number, and total already seen in
  this corpus **or** in `reference.posted_invoices`. Normalize invoice numbers (strip spaces, leading
  zeros, `#`, `INV-` prefixes consistently) before comparing — `INV-0042` and `42` are the same invoice
  to the vendor.

Scope the business-level check to the vendor. An unscoped invoice-number match collapses two vendors'
invoice `1001` into one and wrongly rejects the second.

## 19. One PDF can contain several documents

Mailroom scans and email attachments frequently bundle an invoice, a packing slip and a remittance
advice in one file, or several invoices back to back. Extracting once per file returns one invoice's
header with another's total.

At classification, sample each page (cheap, `page_filter` per page) when a file has more than a few
pages, and if page-level types change, mark the file `MULTI_DOCUMENT` and route it to exceptions (or to
a split step) rather than extracting it as one.

## 20. Normalize both sides of an accuracy comparison with the same expression

The answer key holds clean typed values; the pipeline holds strings. Comparing them with different
normalization — `TRIM` on one side, the amount UDF on the other, `UPPER` on only one — produces an
accuracy number that is confidently wrong and usually pessimistic. The harness calls the **same**
normalization functions the pipeline uses, on both sides, and includes a round-trip check on known
values before quoting any metric.

## 21. Join accuracy from the answer key outward

Build field evaluation from the answer key with a `FULL OUTER JOIN` to extracted fields. A `LEFT JOIN`
from extracted rows drops documents whose extraction errored, and those documents contribute zero
misses — total failure on a scan type reports as perfect accuracy on the documents that survived.

## 22. Report exact and normalized match, per field and per type

- **Exact match** — byte-equal after trim. Shows what a downstream system receives raw.
- **Normalized match** — equal after the shared normalizers (amounts to DECIMAL(18,2), dates to DATE,
  identifiers stripped of punctuation and case). Shows whether the pipeline understood the document.

A large exact/normalized gap is a formatting issue fixable in SQL; a low normalized rate is an
extraction problem. Report both, per field, per document type, per render kind (digital, clean scan,
degraded scan). An aggregate across all fields hides that `total_amount` is 99 percent and
`vendor_tax_id` is 60 percent.

## 23. Experiments require incremental extraction and evaluation layers

Stamping `experiment_id` on rows does nothing if extraction and evaluation are `CREATE OR REPLACE
TABLE` each run — only one experiment exists at rest, and comparisons return one group while appearing
to work. Use `MERGE` (or dbt `incremental` with `unique_key` including `run_id`) so a re-run of the same
run is idempotent and a new experiment accumulates.

## 24. Hash the schema that actually ran

`schema_version` is a promise someone forgets to keep. Persist `schema_hash = SHA2(TO_JSON(schema))`
computed from the exact `responseFormat` object passed to `AI_EXTRACT`, bound from one place. When the
version matches and the hash differs, trust the hash.

## 25. Idempotency and orchestration

- Key every run on `run_id`; task auto-retry re-invokes the step, and a non-idempotent insert
  double-extracts (double-bills pages) and double-queues exceptions.
- Process each file once per schema version: the incremental predicate is "no row in `EXTRACTED_FIELDS`
  for this `(document_id, schema_hash)`", not "file arrived since last run" — arrival timestamps lie
  when files are re-uploaded.
- No `TEMPORARY` tables shared between tasks; each task runs in its own session.
- Fully qualify every object and stage referenced inside a task or dynamic table.

## 26. Sensitive fields get handled as sensitive from the first table

Invoices carry remittance bank account and routing numbers and tax IDs; W-9s carry SSNs or EINs;
claims carry claimant names, addresses, dates of birth, and sometimes medical detail.

- Extract bank account fields only if validation needs them (it usually needs only a comparison to the
  vendor master); store the last four digits plus a hash for comparison, not the full number, unless the
  customer explicitly requires otherwise.
- **A remittance bank account that differs from the vendor master is a blocking exception** — it is the
  signature of payment-redirection fraud, and it is the single most valuable validation rule in AP.
- Report existing masking and row access policies on the source and the output tables at preflight.
- Never place extracted values in prompts to other models, logs, files, or messages outside the account.

## 27. Exceptions must be actionable

An exception row that says "low confidence" sends a reviewer to re-key the whole document, which is
the manual process again. Each queue row lists every failing field with: extracted value, normalized
value, score, the threshold, the rule that failed, and the reference value it was compared against.
Reviewers then correct one field, not eleven, and their corrections flow to `REVIEW_CORRECTIONS` as
new labeled data for the next threshold tuning.

## 28. dbt and deployment traps

- dbt concatenates a `+schema:` onto the target schema (`PIPELINE_PIPELINE`). Override
  `generate_schema_name`.
- Never `authenticator: externalbrowser` in a profile used by dbt on Snowflake.
- Never default a run role to `ACCOUNTADMIN`; never commit a real `profiles.yml`.
- Models that call AI functions are `table` or `incremental`, never `view` — a view re-invokes and
  re-bills extraction every time anything selects from it.
