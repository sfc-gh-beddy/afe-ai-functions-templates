---
name: spend-leakage-system-of-record
description: "Preflight discovery for a spend and contract leakage build. Establishes what the account can run and what already exists before anything is created: Cortex AI function access via EXPLAIN_PRIVILEGES, model availability via SHOW CORTEX BASE MODELS, the CORTEX_ENABLED_CROSS_REGION setting, region support for AI_EXTRACT and AI_PARSE_DOCUMENT, the contract inventory (CLM tables, stages, file versus text-native split, page counts), the vendor master, PO and AP invoice-line tables with confirmed column mappings, credit memos, multi-currency and CapEx identification, existing pipeline objects, and commercial-confidentiality posture (who can read contracts, who should read findings). Triggers: preflight, what can this account run, where are our contracts, map the invoice columns, check Cortex access. Always loaded first by the spend-and-contract-leakage router."
parent_skill: spend-and-contract-leakage
---

# Preflight — what this account can run, and where contracts and spend live

Run this before creating anything. It exists to prevent four bad outcomes, each of which produces a
pipeline that runs cleanly and reports a wrong number:

1. building around a function or model the account cannot call;
2. mapping the wrong invoice column to the date that selects the effective rate;
3. reconciling one supplier's spend against another supplier's contract because vendor identity was
   assumed rather than checked;
4. promising a cost profile the corpus will not deliver — a 60-page MSA parsed in full is the most
   common way this play becomes expensive.

Report findings as a compact summary and write settled values into `spend-leakage-project.yml`. Do not
create objects in this phase. Never run a query that returns contract text, prices or invoice lines
to the session unless the user asks for a sample; counts and column profiles are enough.

---

## 1. Cortex AI function access

`EXPLAIN_PRIVILEGES` analyzes the statement without executing it — no credits, no model calls.

```sql
SELECT
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_PARSE_DOCUMENT(TO_FILE('@x/a.pdf'), {'mode':'LAYOUT','page_split':TRUE})$$, missing_only => TRUE) AS ai_parse_document,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_EXTRACT(text => 'x', responseFormat => {'k':'q'})$$,                       missing_only => TRUE) AS ai_extract,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COMPLETE('claude-sonnet-4-6','x')$$,                                       missing_only => TRUE) AS ai_complete,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_CLASSIFY('x', ['a','b'])$$,                                                 missing_only => TRUE) AS ai_classify,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_SIMILARITY('x','y')$$,                                                      missing_only => TRUE) AS ai_similarity,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COUNT_TOKENS('ai_complete','claude-sonnet-4-6','x')$$,                      missing_only => TRUE) AS ai_count_tokens;
```

`{"authorized": true}` means the role can call it. Otherwise:

| Function | Needed for | If unavailable |
|---|---|---|
| `AI_EXTRACT` | header terms, rate-card tables, document identity | **hard stop** for the extract phase; `AI_COMPLETE` with a JSON schema can substitute, at higher token cost and with the evidence quote still required |
| `AI_COMPLETE` | clause interpretation (tier rules, escalators, amendment deltas) | **hard stop** — these clauses are not answerable by single-value extraction |
| `AI_PARSE_DOCUMENT` | contracts stored as files | blocker only if contracts are files; text-native CLM exports skip it |
| `AI_CLASSIFY` | document class (agreement, amendment, SOW, NDA) | degrade to an `AI_EXTRACT` question; note the accuracy cost |
| `AI_SIMILARITY` | near-duplicate scans, SKU-less invoice description matching | degrade to `JAROWINKLER_SIMILARITY` and say plainly that description matching will miss paraphrases |
| `AI_COUNT_TOKENS` | pre-run token estimates | not a blocker; estimates unavailable |

Remediation is a grant, surfaced to the user, never worked around:

```sql
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <role>;
```

If the check itself errors, note that access was not verified and continue.

## 2. Region, cross-region inference and models

`AI_EXTRACT` and `AI_PARSE_DOCUMENT` are natively available in a published list of regions and
reachable from other regions only through cross-region inference. Contracts frequently sit in
regulated regions, and the cross-region setting is a data-residency decision the customer must make
knowingly, not one this build makes for them.

```sql
SELECT CURRENT_REGION() AS region, CURRENT_ACCOUNT() AS account;
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
```

Record `models.cross_region` with the observed value. If it is `DISABLED` and the region is not in
the native list for a function the corpus needs, stop and tell the user: enabling it is an
`ACCOUNTADMIN` decision with residency implications, and the alternative is building in a supported
region. If it is enabled, say so on the readout, because the contracts' text will be processed in
another region.

Only the `AI_COMPLETE` stage takes a model name. Check it:

```sql
SHOW CORTEX BASE MODELS;

SELECT "name", "lifecycle_status", "in_region_availability", "legacy_date", "eol_date"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "lifecycle_status" = 'GA'
ORDER BY "name";
```

Do not pin a model whose `lifecycle_status` is `LEGACY`, `EOL` or blank. Clause interpretation —
"do tiers apply retroactively", "is this escalator compounding", "what rate does this amendment
replace" — is a reasoning task over legal drafting, so prefer the strongest GA model available.
Weaker models adhere to the JSON schema less reliably as the clause gets more complex. Pin it in
`models.clause_interpret` with `verified_on`. If the preferred model is unavailable, say which is
being used instead and that it will be measured in Phase 5, not assumed equivalent.

## 3. Find the contracts

Contracts arrive in one of three shapes, often mixed. Find candidates rather than asking the user to
recall a fully qualified name:

```sql
SELECT table_catalog, table_schema, table_name, row_count,
       ROUND(bytes / POWER(1024, 3), 2) AS gb
FROM information_schema.tables
WHERE table_type = 'BASE TABLE'
  AND (table_name ILIKE '%CONTRACT%' OR table_name ILIKE '%AGREEMENT%'
    OR table_name ILIKE '%CLM%'      OR table_name ILIKE '%AMENDMENT%'
    OR table_name ILIKE '%SOW%'      OR table_name ILIKE '%ORDER_FORM%')
ORDER BY row_count DESC NULLS LAST
LIMIT 25;

SHOW STAGES;
```

For a candidate stage, inventory files without reading them:

```sql
-- Directory tables must be enabled on the stage: ALTER STAGE ... SET DIRECTORY = (ENABLE = TRUE)
-- is a change the user approves, not something preflight does.
SELECT SPLIT_PART(LOWER(relative_path), '.', -1) AS ext,
       COUNT(*) AS files,
       ROUND(SUM(size) / POWER(1024, 2), 1) AS mb,
       MAX(size) / POWER(1024, 2) AS max_mb
FROM DIRECTORY(@<stage>)
GROUP BY 1 ORDER BY files DESC;

SHOW STAGES LIKE '<stage_name>';   -- check the encryption type column
```

Check two things that break `AI_PARSE_DOCUMENT` and `AI_EXTRACT` on files outright:

- **Stage encryption.** AI functions do not work on internal stages with `SNOWFLAKE_FULL`
  encryption, on user or table stages, or on stages with double-quoted names. A new internal stage
  needs `ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')`.
- **Size and length.** `AI_PARSE_DOCUMENT` accepts files up to 100 MB and 2,000 pages;
  `AI_EXTRACT` on a file accepts up to 125 pages and 100 MB. Count files over 125 pages: those must
  go through parse first and extraction on the parsed text, never `AI_EXTRACT` on the file.

Then map columns and write `contracts` in the project file. Required: a document id and either text
or a stage-relative path. Valuable: the CLM's vendor link, title, upload timestamp, page count.

## 4. File versus text-native split and page budget

This number decides whether parsing is the dominant cost.

```sql
SELECT COUNT(*) AS documents,
       COUNT_IF(<text_col> IS NOT NULL AND LENGTH(<text_col>) > 500) AS text_native,
       COUNT_IF(<text_col> IS NULL OR LENGTH(<text_col>) <= 500)     AS needs_parse,
       SUM(IFF(<text_col> IS NULL OR LENGTH(<text_col>) <= 500, <page_count_col>, 0)) AS pages_to_parse,
       MEDIAN(<page_count_col>) AS median_pages,
       MAX(<page_count_col>)    AS max_pages
FROM <contracts_source_table>;
```

Report pages, not credits. Then say plainly what drives the number: long MSAs with short commercial
schedules are where `page_filter` on the second pass pays off (see `parse-contract-documents`).

## 5. How complete is the CLM's vendor link?

```sql
SELECT COUNT(*) AS documents,
       COUNT(<vendor_id_col>) AS with_vendor_link,
       ROUND(100.0 * COUNT(<vendor_id_col>) / NULLIF(COUNT(*), 0), 1) AS pct_linked,
       COUNT(DISTINCT <vendor_id_col>) AS vendors
FROM <contracts_source_table>;

-- Do CLM vendor ids actually exist in the ERP vendor master?
SELECT COUNT(DISTINCT c.<vendor_id_col>) AS clm_vendors,
       COUNT(DISTINCT v.<vendor_id_col_erp>) AS resolvable_in_erp
FROM <contracts_source_table> c
LEFT JOIN <vendors_table> v ON v.<vendor_id_col_erp> = c.<vendor_id_col>;
```

A CLM vendor id that does not resolve in the ERP master is as good as NULL. Low link coverage is
normal; it means vendor linking will lean on extracted counterparty names (rule 10 in best practices),
and the readout must report link method coverage.

## 6. Spend: vendors, POs, invoice lines

```sql
SELECT table_schema, table_name, row_count
FROM information_schema.tables
WHERE table_name ILIKE '%INVOICE%' OR table_name ILIKE '%AP_%'
   OR table_name ILIKE '%PURCHASE_ORDER%' OR table_name ILIKE '%PO_%'
   OR table_name ILIKE '%VENDOR%' OR table_name ILIKE '%SUPPLIER%'
   OR table_name ILIKE '%CREDIT_MEMO%'
ORDER BY row_count DESC NULLS LAST
LIMIT 40;
```

Profile the invoice-line table before mapping. The questions that matter:

```sql
SELECT
    COUNT(*)                                              AS lines,
    COUNT(<sku_col>)                                      AS with_sku,
    COUNT(<po_col>)                                       AS with_po,
    COUNT(<service_start_col>)                            AS with_service_date,
    COUNT(DISTINCT <currency_col>)                        AS currencies,
    COUNT_IF(<quantity_col> IS NULL OR <quantity_col> = 0) AS no_quantity,
    COUNT_IF(<amount_col> < 0)                            AS negative_lines,
    COUNT_IF(ABS(<quantity_col> * <unit_price_col> - <amount_col>) > 0.01) AS qty_price_amount_mismatch,
    MIN(<invoice_date_col>) AS first_invoice, MAX(<invoice_date_col>) AS last_invoice
FROM <invoice_lines_table>;
```

Interpret each:

- **`with_service_date` low.** The effective rate is selected by the date the goods or service were
  provided, not the invoice date. If only invoice date exists, a December service billed in January
  is priced at January's rate. Record the choice and flag it on every finding near a rate change.
- **`with_sku` low.** Description matching (`AI_SIMILARITY`) carries the price comparison, which is
  slower, costs tokens, and produces `AMBIGUOUS` lines. Coverage will be lower; say so up front.
- **`currencies` > 1.** Totals are reported per currency. Do not convert unless the customer supplies
  rates and a rate date convention, and then convert only in the readout, never in findings.
- **`negative_lines` > 0.** Credits are in the same table. They must be netted against the line they
  reverse before overcharges are computed, or a refunded overcharge is reported again.
- **`qty_price_amount_mismatch` > 0.** Freight, tax or discount is folded into the amount. Compare
  unit price to contracted price, and recompute the overcharge as `quantity x price delta`, never as
  `line_amount - allowed_amount` on those lines.

Then CapEx identification — the lever split in the readout depends on it:

```sql
SELECT <gl_col> AS gl_account, <capex_flag_col> AS capex_flag, COUNT(*) AS lines, SUM(<amount_col>) AS amount
FROM <invoice_lines_table>
GROUP BY 1, 2 ORDER BY amount DESC
LIMIT 40;
```

If there is no flag, ask the user for the GL rule and write it to `spend.capex_gl_rule`. Do not infer
CapEx from GL names.

Confirm the full `spend` mapping with the user before proceeding. The two mappings that matter most
are `service_start_col` and `invoice_vendor_id_col`; get either wrong and every finding is wrong.

## 7. Existing pipeline objects

```sql
SELECT table_schema, table_name, row_count, created
FROM information_schema.tables
WHERE table_name ILIKE '%LEAKAGE%' OR table_name ILIKE '%CONTRACT_TERM%'
   OR table_name ILIKE '%RATE_LINE%' OR table_name ILIKE '%CONTRACT_REGISTRY%'
   OR table_name ILIKE 'SYNTH_%'
ORDER BY created DESC;

SHOW SEMANTIC VIEWS;
SHOW AGENTS;
```

Surface anything found with its row count and creation date and ask whether to reuse, rename or
replace. If a `LEAKAGE_FINDINGS` table exists with non-default `review_status` values, never replace
it: analysts have acted on those rows.

## 8. Commercial confidentiality posture

Contracts are under NDA with the counterparty more often than not, and a findings table is a list of
the buyer's negotiating positions. Report the controls that exist before creating tables that hold
both.

```sql
SHOW GRANTS ON TABLE <contracts_source_table>;
SHOW GRANTS ON TABLE <invoice_lines_table>;

SELECT policy_name, policy_kind, ref_column_name
FROM TABLE(information_schema.policy_references(
    ref_entity_name => '<fully_qualified_contracts_table>', ref_entity_domain => 'TABLE'));
```

Report:

- which roles can read contracts today and which can read AP — these are usually different
  populations (legal and procurement versus finance), and findings combine both;
- whether masking or row access protects either source, and whether the same protection should
  extend to `CONTRACT_HEADER_TERMS`, `CONTRACT_RATE_LINES` and `LEAKAGE_FINDINGS`;
- whether the agent in Phase 6 should be visible to anyone beyond procurement — it can answer "what
  do we pay supplier X per hour", which is often more sensitive than the contract itself.

Do not create policies here. Record the decision and honour it when tables are created.

## 9. Warehouse

```sql
SHOW WAREHOUSES LIKE '<candidate>';
```

Snowflake recommends no larger than MEDIUM for `AI_EXTRACT`; larger warehouses do not increase its
throughput. Reconciliation is plain SQL over invoice lines and benefits from size only on very large
AP tables. Recommend a small or medium warehouse with a short auto-suspend.

## 10. Materialization and as-of date

Ask once: dbt project or plain SQL (see the router). Record `materialization.mode`.

Ask for the as-of date of the first customer run and write `reconcile.as_of_date`. For the sandbox it
is `2026-09-30`.

---

## Output of this phase

A short summary: functions authorized, region and cross-region status, the pinned clause model, the
contract inventory (documents, file versus text, pages to parse, files over 125 pages), vendor-link
coverage, the spend mapping with SKU, service-date and PO coverage, currencies, credit handling,
CapEx rule, existing objects, and confidentiality decisions. Then the settled values written into
`spend-leakage-project.yml` and `phases.preflight: done`.

Anything unresolved stays absent from the state file. An absent key means the next phase asks.
