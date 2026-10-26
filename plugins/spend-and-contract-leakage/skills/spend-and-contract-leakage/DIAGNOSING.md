# Diagnosing a leakage pipeline that is not producing what you expect

Work these in order. The first four explain most reports, and two of them — inflated totals and
missing findings — look like good news or a clean supplier base rather than like bugs.

Every query below uses the canonical object names from `created_objects`; read the real names from
`spend-leakage-project.yml` before running.

## 1. The dollar total looks too high

Treat a surprisingly large total as a defect until each of these is ruled out. A recovery figure
taken to a CFO and then walked back costs the play its credibility.

```sql
-- a. Were impact kinds or currencies summed together?
SELECT impact_kind, impact_currency, COUNT(*) AS findings, SUM(impact_amount) AS total
FROM LEAKAGE_FINDINGS
WHERE run_id = '<run_id>'
GROUP BY 1, 2 ORDER BY 1, 2;
```

Any total quoted to the user must come from one row of this result. If someone added the rows, that
is the bug.

```sql
-- b. Is any invoice line driving more than one finding?
SELECT invoice_line_id, ARRAY_AGG(finding_type) AS types, COUNT(*) AS n
FROM LEAKAGE_FINDINGS
WHERE run_id = '<run_id>' AND invoice_line_id IS NOT NULL
GROUP BY 1 HAVING COUNT(*) > 1;
```

Expect zero. A line that is both `EXPIRED_CONTRACT_SPEND` and `RATE_VARIANCE` is counted twice; the
coverage check must short-circuit the price check (best practices rule 8).

```sql
-- c. Did a duplicate contract survive deduplication?
SELECT contract_family_id, COUNT_IF(family_role = 'GOVERNING') AS governing_docs
FROM CONTRACT_REGISTRY
GROUP BY 1 HAVING governing_docs > 1;
```

Expect zero. Two governing documents for a family produce two effective rates per SKU, and a join
that does not pick one doubles every line.

```sql
-- d. Was a volume tier applied retroactively?
SELECT invoice_line_id, quantity, cum_qty_before, cum_qty_after,
       allowed_amount, line_amount, line_amount - allowed_amount AS overcharge
FROM INVOICE_ALLOWED_PRICE
WHERE pricing_basis = 'TIERED'
ORDER BY contract_family_id, service_period_start;
```

On the sandbox the March 2026 Contoso line must show 600.00, not 3,600.00. If the contract says
tiers apply retroactively, the clause rule row must say so and cite it; the default is incremental
only when the clause says incremental. If the clause is silent, the line goes to
`RECONCILE_EXCEPTIONS` as `TIER_RULE_NOT_STATED` rather than being priced either way.

```sql
-- e. Are credit memos netted?
SELECT COUNT(*) FROM <credit_memo_table>;   -- if spend.credit_memo_table is configured
```

An overcharge the supplier already credited is not recoverable. If AP stores credits separately and
the pipeline does not read them, say so on every readout.

## 2. Far fewer findings than expected

```sql
-- a. How much spend was actually reconciled?
SELECT coverage_status, sku_match_method, impact_currency,
       COUNT(*) AS lines, SUM(line_amount) AS amount
FROM INVOICE_CONTRACT_MATCH
GROUP BY 1, 2, 3 ORDER BY amount DESC;
```

A large `NO_SKU_MATCH`, `AMBIGUOUS` or `CURRENCY_MISMATCH` share means most spend never reached a
price comparison. That is a coverage problem, not a clean supplier base. Report coverage alongside any
finding total; a total over 30% of spend is a different claim from a total over 95%.

```sql
-- b. Were terms lost to extraction failure rather than absent from the contract?
SELECT term_name, status, COUNT(*) AS n
FROM CONTRACT_HEADER_TERMS
WHERE experiment_id = '<experiment_id>'
GROUP BY 1, 2 ORDER BY 1, 2;
```

`FAILED` and `UNVERIFIED` are not `NOT_STATED`. A contract whose renewal clause failed to extract
silently produces no renewal finding. Any `FAILED` count above zero needs the raw response inspected.

```sql
-- c. Did vendor linking fail?
SELECT vendor_link_method, COUNT(*) AS docs,
       COUNT_IF(vendor_id IS NULL AND family_role = 'GOVERNING') AS unlinked_governing
FROM CONTRACT_REGISTRY GROUP BY 1;
```

An unlinked governing contract makes all of that supplier's spend look `OFF_CONTRACT` — so this
failure shows up as **too many** off-contract findings and **too few** price findings at once. On the
sandbox, `SYN-DOC-C008` must link to `SYN-V008` by `NAME_NORMALIZED`.

## 3. Correctly billed lines are flagged (false positives)

Check in this order, because each is cheaper to rule out than the next.

1. **Amendment precedence.** Northwind 2026-01 to 2026-03 at 44.00 are correct. If they are flagged,
   the amendment was not linked to its family, or its effective date was not used to close the prior
   rate's window.

   ```sql
   SELECT contract_family_id, sku, unit_price, effective_from, effective_to, source_document_id, precedence_rank
   FROM CONTRACT_EFFECTIVE_RATES
   WHERE contract_family_id = 'SYN-MSA-1001' AND sku = 'JAN-STD'
   ORDER BY effective_from;
   ```

   Expect two non-overlapping rows: 42.00 to 2025-12-31 and 44.00 from 2026-01-01.

2. **Escalators.** Wide World 2026 at 5,150.00 is the permitted 3%. A finding here means the escalator
   rule was not extracted, or was extracted and not applied to the allowed price.
3. **Tolerance.** Northwind 2025-06 at 42.01. A finding here means the comparison has no tolerance.
4. **Tier threshold.** Contoso January and February at 0.18 are correct. A finding here means tier 2
   was applied from the first unit.
5. **Non-commercial documents.** A renewal finding on the NDA means classification let it through.
6. **"Expires" read as "auto-renews".** Contoso and Proseware explicitly do not renew. A renewal
   finding on either means the `auto_renewal` question was answered from the word "renewal" rather
   than from the clause.

## 4. Renewal dates or deadlines are wrong

```sql
SELECT contract_family_id, period_no, period_kind, period_start, period_end,
       notice_days, notice_deadline, is_current_period
FROM CONTRACT_TERM_PERIODS
ORDER BY contract_family_id, period_no;
```

- **Only the initial term exists for an auto-renewing contract.** Term rolling did not run, so a
  contract that already renewed once is compared against a deadline that passed a year ago. On the
  sandbox, Fabrikam must show a renewal period 2025-11-01 to 2026-10-31 marked current, with deadline
  2026-08-02.
- **Deadline off by a day.** Decide once whether "at least N days before the end of the term" counts
  the end date. This plugin computes `DATEADD(day, -notice_days, period_end)`, matching the answer
  key, and states that convention on every renewal finding so an analyst can apply their own.
- **Deadline moves between runs.** Something is using `CURRENT_DATE()`. Every renewal computation
  must read `reconcile.as_of_date`.
- **Date extracted in the wrong format.** `01/02/2026` is ambiguous. The extraction question asks for
  ISO dates, and normalization rejects anything `TRY_TO_DATE` cannot parse as `YYYY-MM-DD`; a row
  that parsed under a different format mask is a bug.

## 5. Rate lines are wrong or missing

```sql
SELECT r.document_id, r.sku, r.description, r.unit_of_measure, r.unit_price, r.tier_min_qty, r.tier_max_qty,
       r.status, r.quote_verified
FROM CONTRACT_RATE_LINES r
WHERE r.experiment_id = '<experiment_id>'
ORDER BY 1, 2, r.tier_min_qty;
```

- **No rows for a document with a rate card.** The rate card is probably in a schedule on a page that
  parsed poorly, or a table that `OCR` mode flattened. Re-parse that document in `LAYOUT` mode and
  check the page text contains the table as Markdown.
- **Prices with currency symbols or thousands separators left in.** Normalization strips `$`, `EUR`,
  and `,` and then requires `TRY_TO_NUMBER` to succeed; a failure sets `status = 'FAILED'` rather than
  a NULL price that later compares as "no rate".
- **"See Section 2.2" as a price.** Contoso's GLOVE-NIT price is a pointer to the tier table. The
  table extraction returns the pointer text; the tier table supplies the prices. A rate line whose
  price is non-numeric and whose SKU has tier rows is expected and is dropped in favour of the tiers.

## 6. Parse failures

```sql
SELECT parse_source, parse_status, COUNT(*) AS docs, SUM(page_count) AS pages
FROM CONTRACT_REGISTRY GROUP BY 1, 2;

SELECT document_id, page_index, char_count, parse_error
FROM CONTRACT_PAGES
WHERE parse_error IS NOT NULL OR char_count < 200
ORDER BY document_id, page_index;
```

`AI_PARSE_DOCUMENT` returns NULL on failure by default; the parse SQL passes
`return_error_details => TRUE` so the reason is kept. Common causes: the stage uses
`SNOWFLAKE_FULL` encryption (AI functions require `SNOWFLAKE_SSE`), the file is over 100 MB, the file
is encrypted or password-protected, or the page is a signature image with no text (which is fine —
note it, do not retry it).

## 7. The answer key disagrees with what the contract says

On the sandbox this is never the contract's fault. Read the `plant_note` on the key row yourself (do
not paste it into a prompt), then check whether the pipeline's interpretation or the key's is the one
the clause supports. If the key is wrong, fix the seed SQL and rerun `02_verify_seed.sql`. Do not
adjust a pipeline to match a key you have not checked.

## 8. Cost is higher than expected

```sql
SELECT function_name, model_name,
       SUM(credits) AS credits,
       COUNT(DISTINCT query_id) AS queries
FROM SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY
WHERE query_tag LIKE '<query_tag_prefix>:%:<run_id>'
GROUP BY 1, 2 ORDER BY credits DESC;
```

The view can lag by up to 24 hours. Do not use `CORTEX_FUNCTIONS_QUERY_USAGE_HISTORY` for this; it is
no longer updated and has no timestamp to bound it. The usual causes, in order: parsing every page of
long MSAs when only the schedules carry prices (use `page_filter` once the commercial pages are
known), reparsing unchanged documents (see `DBT_MATERIALIZATION.md`), and sending the full contract
to `AI_COMPLETE` instead of the clause windows.
