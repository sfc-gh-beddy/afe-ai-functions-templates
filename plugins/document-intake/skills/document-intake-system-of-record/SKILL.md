---
name: document-intake-system-of-record
description: "Preflight discovery for a document intake build (invoices, contracts, claims, forms). Establishes what the account can run and what already exists before anything is created: Cortex AI function access via EXPLAIN_PRIVILEGES, regional availability of AI_EXTRACT / AI_PARSE_DOCUMENT / AI_CLASSIFY and the CORTEX_ENABLED_CROSS_REGION setting, document stage inventory (directory table, encryption, file types, page counts, text-layer versus scanned split), reference data for validation (vendor master, POs, receipts, policies, posted-invoice history) and its join keys, existing pipeline objects, sensitive-data posture (bank details, tax IDs, claimant PII; masking and row access policies), and warehouse sizing. Always loaded first by the document-intake router."
parent_skill: document-intake
---

# Preflight — what this account can run, and what is already here

Run before creating anything. It prevents four bad outcomes: building on a function the region cannot
call, discovering after OCR that the stage cannot be read, promising validation against reference data
that does not exist or does not join, and quoting a cost profile this corpus will not deliver.

Report findings as a compact summary and write settled values to `intake-project.yml`. Create nothing.
Run queries against **metadata** (directory tables, information schema, counts). Do not read document
contents or reference-data values beyond what is needed to confirm a join key format, and show none of
it unless asked.

---

## 1. Function access

`EXPLAIN_PRIVILEGES` analyzes the statement without running the functions — no credits.

```sql
SELECT
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_EXTRACT(text => 'x', responseFormat => {'k':'q'})$$,                  missing_only => TRUE) AS ai_extract,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_PARSE_DOCUMENT(TO_FILE('@~/x.pdf'), {'mode':'OCR'})$$,                missing_only => TRUE) AS ai_parse_document,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_CLASSIFY('x', ['invoice','contract'])$$,                               missing_only => TRUE) AS ai_classify,
  EXPLAIN_PRIVILEGES(statement => $$SELECT AI_COUNT_TOKENS('ai_classify', 'x', ['invoice','contract'])$$,            missing_only => TRUE) AS ai_count_tokens;
```

| Function | Needed for | If unavailable |
|---|---|---|
| `AI_EXTRACT` | field extraction with scores | **hard stop** — this is the pipeline |
| `AI_PARSE_DOCUMENT` | text for classifying scans; full text for contracts | blocker only if the corpus has scans without a text layer, or contracts that need full text |
| `AI_CLASSIFY` | document type routing | fall back to metadata rules plus `AI_EXTRACT` asking "what type of document is this"; say the tradeoff |
| `AI_COUNT_TOKENS` | estimating classify and text-extract tokens | not a blocker; page-based estimates still work |

Remediation — surface the grant, never work around it:

```sql
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE <role>;
```

If `EXPLAIN_PRIVILEGES` itself errors, record "access not verified" and continue; it is best-effort.

## 2. Region and cross-region inference

Availability differs by function **and** by input type. From the function reference at the time of
writing (re-check the live docs pages, since these lists change):

- `AI_EXTRACT` lists a set of AWS and Azure regions natively and supports cross-region.
- `AI_PARSE_DOCUMENT` is native in select regions and available everywhere through cross-region
  inference.
- `AI_CLASSIFY` text input is broadly available; image input in fewer regions; **document input is
  Preview and listed under cross-region only**.

```sql
SELECT CURRENT_REGION() AS region, CURRENT_ACCOUNT() AS account;
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
```

Record `ai.cross_region`. Interpret:

| Value | Meaning for this build |
|---|---|
| `DISABLED` | only functions native to this region run. If `AI_EXTRACT` is not native here, this is a blocker — say so and name the parameter. |
| `AWS_GLOBAL`, `AZURE_US`, etc. | inference may run in another region within that scope. This is a **data residency** decision for the customer, not a technical setting to flip. |
| `ANY_REGION` | any region. Same residency caveat, stronger. |

Never change this parameter. If a change is needed, name it (`ALTER ACCOUNT SET
CORTEX_ENABLED_CROSS_REGION = ...`, which requires ACCOUNTADMIN) and let the customer's admin decide,
noting that claims and invoice documents may be subject to residency requirements.

If a fallback `AI_COMPLETE` step is planned (for example, to resolve a vendor name to a master record
when fuzzy match fails), confirm the model:

```sql
SHOW CORTEX BASE MODELS;
SELECT "name", "lifecycle_status", "in_region_availability", "legacy_date", "eol_date"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "lifecycle_status" = 'GA'
ORDER BY "name";
```

Do not pin a `LEGACY`, `EOL`, or blank-status model. Record `ai.complete_model` and `ai.verified_on`.
Most builds need no `AI_COMPLETE` at all, and that is the better design.

## 3. Find the documents

If the user named a stage, inspect it. Otherwise list candidates:

```sql
SHOW STAGES IN ACCOUNT;
SELECT "database_name", "schema_name", "name", "type", "url", "directory_enabled"
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" ILIKE ANY ('%DOC%','%INVOICE%','%AP%','%CLAIM%','%CONTRACT%','%INBOUND%','%SCAN%','%MAIL%')
ORDER BY 1, 2, 3;
```

Then for the chosen stage:

```sql
DESCRIBE STAGE <db>.<schema>.<stage>;
```

Check, and report each as pass or blocker:

- **Directory table enabled** (`DIRECTORY = (ENABLE = TRUE)`). Without it the pipeline cannot enumerate
  files or detect new ones. Enabling it is an `ALTER STAGE` the owner must approve.
- **Encryption** — server-side or client-side encryption is required by the document functions.
- **Directory freshness** — when was it last refreshed; is `AUTO_REFRESH` configured for an external
  stage. A stale directory means the pilot silently processes last month's files.

Inventory by file type and size, from metadata only:

```sql
SELECT
    LOWER(REGEXP_SUBSTR(relative_path, '\\.([A-Za-z0-9]+)$', 1, 1, 'e')) AS ext,
    COUNT(*)                                        AS files,
    ROUND(SUM(size) / POWER(1024, 3), 2)            AS gb,
    ROUND(AVG(size) / 1024, 0)                      AS avg_kb,
    COUNT_IF(size > 100 * POWER(1024, 2))           AS over_100mb,
    MIN(last_modified)                              AS oldest,
    MAX(last_modified)                              AS newest
FROM DIRECTORY(@<db>.<schema>.<stage>)
GROUP BY 1
ORDER BY files DESC;
```

Files over 100 MB fail both `AI_EXTRACT` and `AI_PARSE_DOCUMENT`. Unsupported extensions (for example
`.msg`, `.zip`, `.xlsx` for `AI_EXTRACT`) need a decision before anything runs: convert upstream, skip
with a logged reason, or route to exceptions.

Look at folder structure — prefixes frequently encode channel, business unit, or document type, and
that is the cheapest routing signal available:

```sql
SELECT SPLIT_PART(relative_path, '/', 1) AS top_folder,
       SPLIT_PART(relative_path, '/', 2) AS second_folder,
       COUNT(*) AS files
FROM DIRECTORY(@<db>.<schema>.<stage>)
GROUP BY 1, 2 ORDER BY files DESC LIMIT 40;
```

If documents arrive through a table rather than a stage (a file path column, possibly pre-extracted
text from an existing OCR system), map `documents.source_table`, `id_col`, `path_col`, `text_col`,
`received_at_col`, and `channel_col`. Confirm the mapping with the user.

## 4. Page counts and the text-layer split — the cost profile

Two numbers determine cost: total pages, and how many of them are image-only (need OCR) versus carry a
text layer. File size is a weak proxy. Measure on a **sample**, with the gate protocol, because this
step itself calls `AI_PARSE_DOCUMENT`:

> This samples N files and parses only the first page of each with `page_filter`, which bills one page
> per file. `metadata.pageCount` in the response gives the full page count without parsing the rest.

```sql
-- Sample, first page only. Bills ~1 page per file (image files always count as 1).
CREATE OR REPLACE TEMPORARY TABLE PREFLIGHT_PAGE_SAMPLE AS
SELECT
    d.relative_path,
    d.size,
    AI_PARSE_DOCUMENT(
        TO_FILE('@<db>.<schema>.<stage>', d.relative_path),
        {'mode': 'OCR', 'page_filter': [{'start': 0, 'end': 1}]},
        TRUE
    ) AS r
FROM DIRECTORY(@<db>.<schema>.<stage>) d
WHERE d.relative_path ILIKE ANY ('%.pdf', '%.png', '%.jpg', '%.jpeg', '%.tif', '%.tiff')
SAMPLE (200 ROWS);

SELECT
    COUNT(*)                                                  AS sampled,
    COUNT_IF(r:error IS NOT NULL)                             AS parse_errors,
    -- pageCount is documented both inside value and alongside it; read either.
    SUM(COALESCE(r:value:metadata:pageCount, r:metadata:pageCount)::INT)            AS total_pages_in_sample,
    ROUND(AVG(COALESCE(r:value:metadata:pageCount, r:metadata:pageCount)::INT), 1)  AS avg_pages,
    MAX(COALESCE(r:value:metadata:pageCount, r:metadata:pageCount)::INT)            AS max_pages,
    COUNT_IF(COALESCE(r:value:metadata:pageCount, r:metadata:pageCount)::INT > 125) AS over_extract_page_limit,
    COUNT_IF(LENGTH(r:value:pages[0]:content::STRING) < 40)   AS near_empty_first_page
FROM PREFLIGHT_PAGE_SAMPLE;
```

Report average and maximum pages, documents over 125 pages (cannot go through `AI_EXTRACT` whole),
and near-empty first pages (blank cover sheets, fax headers, or unreadable images). Read the errors.

To estimate the text-layer share without paying for OCR, use the customer's own signal if one exists
(an upstream OCR flag, a "scanned" folder, the intake channel). If none exists, say the split is
unknown and that classification and extraction will treat every file as potentially scanned — which
is correct, because `AI_EXTRACT` and `AI_PARSE_DOCUMENT` both handle digital and scanned input; the
split mainly changes what classification costs.

Extrapolate: `files_on_stage x avg_pages` is the page volume for one full pass. State it in pages.

## 5. Document type mix

Before designing schemas, find out what is actually on the stage. Folder names, file names, and the
intake channel are free signals:

```sql
SELECT
    CASE
        WHEN relative_path ILIKE ANY ('%invoice%', '%inv_%', '%/ap/%')         THEN 'likely_invoice'
        WHEN relative_path ILIKE ANY ('%contract%', '%agreement%', '%msa%')    THEN 'likely_contract'
        WHEN relative_path ILIKE ANY ('%claim%', '%fnol%', '%loss%')           THEN 'likely_claim'
        WHEN relative_path ILIKE ANY ('%w9%', '%w-9%', '%tax%')                THEN 'likely_tax_form'
        ELSE 'unknown'
    END AS path_hint,
    COUNT(*) AS files
FROM DIRECTORY(@<db>.<schema>.<stage>)
GROUP BY 1 ORDER BY files DESC;
```

These hints are for scoping the conversation only. They are never a routing rule until validated in
Phase 2 against classifier output. Ask the business owner which types are in scope for the POC; record
them in `document_types.in_scope`. Fewer types done well beats every type done badly — invoices alone
is a legitimate first scope.

## 6. Reference data for validation

Validation is where the value is protected. Each rule family needs reference data, and each piece of
reference data needs a join key whose **format** matches what extraction will produce.

```sql
SELECT table_catalog, table_schema, table_name, row_count
FROM <db>.information_schema.tables
WHERE table_type = 'BASE TABLE'
  AND table_name ILIKE ANY ('%VENDOR%','%SUPPLIER%','%PAYEE%','%PURCHASE_ORDER%','%PO_%','%RECEIPT%',
                            '%GRN%','%POLICY%','%POLICIES%','%CONTRACT%','%COUNTERPART%','%INVOICE%','%AP_%')
ORDER BY row_count DESC NULLS LAST
LIMIT 40;
```

For each candidate, describe it and confirm with the user:

| Reference | Enables | Key to confirm |
|---|---|---|
| vendor master | vendor match, tax ID check, **remittance bank change detection**, currency default | vendor id; name; tax id format (with or without hyphens); bank last-4 or hash |
| purchase orders | PO existence, vendor-PO consistency, amount tolerance | PO number format (leading zeros, prefixes) |
| goods receipts | three-way match | PO line keys |
| posted invoice history | duplicate detection against history | vendor id + invoice number normalization |
| policy register | claim policy validity, loss date within coverage | policy number format |
| contract register / counterparties | contract counterparty match | legal entity naming |

Check key formats **by shape**, not by reading values:

```sql
SELECT
    COUNT(*)                                                      AS rows_total,
    COUNT_IF(REGEXP_LIKE(<po_col>, '^[0-9]+$'))                   AS digits_only,
    COUNT_IF(REGEXP_LIKE(<po_col>, '^0[0-9]+$'))                  AS leading_zero,
    COUNT_IF(REGEXP_LIKE(<po_col>, '^[A-Za-z]+[-_ ]?[0-9]+$'))    AS prefixed,
    MIN(LENGTH(<po_col>)) AS min_len, MAX(LENGTH(<po_col>)) AS max_len
FROM <purchase_orders_table>;
```

Record the observed format. A PO master holding `0004500123` and invoices printing `4500123` match
nothing unless the normalizer strips leading zeros on both sides.

If a reference source does not exist, write the key as absent and say plainly which rules will not
run. No vendor master means no bank-change detection, and that should be said out loud, because it is
the rule that stops payment fraud.

## 7. Existing pipeline objects

```sql
SELECT table_schema, table_name, row_count, created
FROM <target_db>.information_schema.tables
WHERE table_name ILIKE ANY ('%EXTRACT%','%INTAKE%','%EXCEPTION%','%DOC_CLASS%','%PARSE%')
ORDER BY created DESC;

SHOW SEMANTIC VIEWS IN DATABASE <target_db>;
SHOW AGENTS IN DATABASE <target_db>;
```

Surface anything found with row count and creation date, and ask: reuse, rename, or replace.

Also ask whether the customer already runs OCR or an IDP product upstream. If they do, its output (text
layer, extracted fields) is both a cheaper input and a **baseline to measure against** — the POC should
compare field accuracy and STP rate against the incumbent on the same documents.

## 8. Sensitive-data posture

```sql
SELECT policy_name, policy_kind, ref_entity_name, ref_column_name
FROM TABLE(<db>.information_schema.policy_references(
    ref_entity_name   => '<fully_qualified_reference_table>',
    ref_entity_domain => 'TABLE'));

SHOW GRANTS ON STAGE <db>.<schema>.<stage>;
```

Report:

- which roles can read the stage today, and which should read extracted fields — usually narrower,
  because extraction turns an image nobody queries into a table everybody can;
- whether bank account and tax ID columns in the vendor master are masked, and therefore whether
  validation's role can even compare them (a masked comparison silently fails every match);
- for claims: whether documents may carry health information, and what that implies for who may read
  `EXTRACTED_FIELDS` and the exceptions queue.

Do not create policies in this phase. Record the decision the user makes and honour it when Phase 3
creates the tables.

## 9. Warehouse

```sql
SHOW WAREHOUSES LIKE '<candidate>';
```

The function docs recommend no larger than MEDIUM for `AI_EXTRACT` and `AI_PARSE_DOCUMENT`; a larger
warehouse does not speed them up. Use a dedicated SMALL or MEDIUM warehouse with short auto-suspend,
and set a `QUERY_TAG` per phase so billed usage in `CORTEX_AI_FUNCTIONS_USAGE_HISTORY` can be
attributed to the phase that spent it:

```sql
ALTER SESSION SET QUERY_TAG = 'doc_intake:<experiment_id>:<phase>';
```

---

## Output of this phase

A short summary: functions authorized; region and cross-region setting with any residency caveat;
stage readiness (directory, encryption, freshness); file inventory with page estimate and limit
violations; type mix and in-scope types; reference data available with key formats and the rules each
enables or disables; existing objects; sensitive-data posture; warehouse. Then write the settled values
into `intake-project.yml` and set `phases.preflight: done`.

Unresolved items stay absent. An absent key means the next phase asks.
