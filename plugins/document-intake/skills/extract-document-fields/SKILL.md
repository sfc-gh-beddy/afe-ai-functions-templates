---
name: extract-document-fields
description: "Phase 3 of the document-intake build: extract typed fields with per-field confidence from every document classified for extraction. Defines one AI_EXTRACT JSON-schema responseFormat per document type (invoice with line-item table, credit note, contract, insurance claim form, W-9 tax form), calls AI_EXTRACT with named arguments and scores => TRUE on the file (or on AI_PARSE_DOCUMENT text for documents over the page limit), persists the raw response with schema_hash and run identity, flattens to one row per document x field with raw value, score, and normalized value via shared normalizer UDFs (amounts, dates with vendor locale, document numbers, tax IDs, party names, currency), flattens line-item tables, and verifies scores, errors and nulls at the gate. Use for invoice field extraction, contract metadata extraction, claim form extraction, AI_EXTRACT schema design, or confidence scores."
parent_skill: document-intake
---

# Extract fields with per-field confidence

Input: `DOC_CLASSIFICATION` rows with `route = 'EXTRACT'`. Output: `EXTRACT_RAW` (one response per
document and schema version), `EXTRACTED_FIELDS` (one row per document and field), and
`EXTRACTED_LINE_ITEMS`. Nothing is validated or posted here.

## Before anything: the normalizers

Create the shared UDFs from `sql/01_normalizers.sql`. They are used here, in validation, and in the
accuracy harness — on both sides of every comparison. Run the test cases at the bottom of this file
after creating them, and show the results at the gate.

## Schema design rules

From the `AI_EXTRACT` reference and from what breaks in practice:

- **JSON-schema format, one object per type.** Top level is an object; sub-objects are strings, arrays
  (lists), or tables (`type: object` with `column_ordering` and array columns). String is the only
  scalar — every amount and date comes back as text and is normalized in SQL.
- **The `description` is the question.** Describe what is printed, where, and what to exclude. "The
  final amount due including tax, labelled TOTAL, TOTAL DUE, Amount Due, or Gesamt; not the subtotal,
  not a balance brought forward" outperforms "total".
- **Ask for the raw printed form, not a reformatted one.** Do not ask the model to convert
  `1.463,70` into `1463.70` or `03.04.2026` into ISO — that moves locale interpretation into the model,
  where it is invisible and unscored. Extract as printed; normalize in SQL with the vendor's locale.
- **Ask for absent fields explicitly.** "If no purchase order number is printed, return an empty
  value" reduces invented PO numbers on non-PO invoices. Then `NULLIF_PLACEHOLDER` handles whatever
  placeholder comes back.
- **Limits:** at most 100 entity questions per call; a table question counts as 10; 512 output tokens
  per entity question, 4,096 per table. The invoice schema below weighs 13 + 10 = 23.
- **Never put sandbox values in descriptions.** A description naming a sandbox vendor scores perfectly
  on the sandbox and means nothing.
- **Version and hash every schema.** The schema object is bound once (a session variable or a dbt var)
  and that same object is both hashed and passed to the call.

## The schemas

### Invoice

```sql
SET invoice_schema = $${
  "schema": {
    "type": "object",
    "properties": {
      "invoice_number":   {"type": "string", "description": "The supplier's invoice number or reference, exactly as printed, labelled Invoice No, Invoice #, Invoice Number or Rechnungsnr. Not a PO number, account number, or order number."},
      "invoice_date":     {"type": "string", "description": "The invoice issue date exactly as printed, labelled Invoice Date, Date or Datum. Not the due date or a delivery date."},
      "due_date":         {"type": "string", "description": "The payment due date exactly as printed, labelled Due Date, Payment Due or Faellig. Empty if not printed."},
      "vendor_name":      {"type": "string", "description": "The legal name of the supplier issuing the invoice, usually in the header or letterhead. Not the bill-to customer."},
      "vendor_tax_id":    {"type": "string", "description": "The supplier tax identification number exactly as printed (Tax ID, EIN, VAT No, USt-IdNr). Empty if not printed."},
      "po_number":        {"type": "string", "description": "The buyer purchase order number exactly as printed, labelled PO, PO Number or Purchase Order. Empty if no purchase order number is printed."},
      "currency":         {"type": "string", "description": "The currency of the invoice amounts as a code or symbol exactly as printed near the total, for example USD, EUR, GBP or $."},
      "subtotal_amount":  {"type": "string", "description": "The amount before tax exactly as printed, labelled Subtotal, Net or Zwischensumme. Empty if not printed."},
      "tax_amount":       {"type": "string", "description": "The total tax amount exactly as printed, labelled Tax, VAT, GST or MwSt. Not the tax rate. Empty if not printed."},
      "total_amount":     {"type": "string", "description": "The final amount due including tax exactly as printed, labelled TOTAL, TOTAL DUE, Amount Due or Gesamt. Not the subtotal and not a balance brought forward."},
      "payment_terms":    {"type": "string", "description": "The payment terms exactly as printed, for example NET 30 or 2/10 NET 30. Empty if not printed."},
      "remit_account_last4": {"type": "string", "description": "The last four digits of the bank account the supplier asks to be paid into, from remittance or banking details. Only the last four digits. Empty if not printed."},
      "bank_details_change_notice": {"type": "string", "description": "Any statement that the supplier's banking or remittance details have changed, quoted briefly. Empty if there is no such statement."},
      "line_items": {
        "type": "object",
        "description": "The invoice line item table listing goods or services, with description, quantity, unit price and line amount columns",
        "column_ordering": ["description", "quantity", "unit_price", "line_amount"],
        "properties": {
          "description": {"type": "array", "description": "Description"},
          "quantity":    {"type": "array", "description": "Qty or Quantity or Menge"},
          "unit_price":  {"type": "array", "description": "Unit Price or Rate or Preis"},
          "line_amount": {"type": "array", "description": "Amount or Line Total or Betrag"}
        }
      }
    }
  }
}$$;
```

`bank_details_change_notice` is deliberate: a payment-redirection letter usually says so in words. It
is not a posting field; it is a validation input that blocks auto-approval when non-empty.

### Credit note

```sql
SET credit_note_schema = $${
  "schema": {
    "type": "object",
    "properties": {
      "credit_note_number":        {"type": "string", "description": "The credit note or credit memo number exactly as printed."},
      "referenced_invoice_number": {"type": "string", "description": "The original invoice number this credit refers to, exactly as printed. Empty if not printed."},
      "issue_date":                {"type": "string", "description": "The credit note date exactly as printed."},
      "vendor_name":               {"type": "string", "description": "The legal name of the supplier issuing the credit."},
      "currency":                  {"type": "string", "description": "The currency code or symbol exactly as printed near the total."},
      "total_amount":              {"type": "string", "description": "The total credit amount exactly as printed, including any minus sign or parentheses."}
    }
  }
}$$;
```

Keep parentheses and minus signs in the raw value — `NORM_AMOUNT` interprets them. A credit note total
that normalizes to a **positive** number is a validation failure (`CREDIT_NOTE_SIGN`), because posting
it as positive doubles the liability instead of reducing it.

### Contract

```sql
SET contract_schema = $${
  "schema": {
    "type": "object",
    "properties": {
      "counterparty_name":    {"type": "string", "description": "The legal name of the other party to the agreement, that is not SYN Demo Buyer Co or the customer organization."},
      "effective_date":       {"type": "string", "description": "The effective date or commencement date of the agreement exactly as written."},
      "initial_term_months":  {"type": "string", "description": "The length of the initial term in months, as a number. Convert years to months only if the term is stated in years."},
      "auto_renewal":         {"type": "string", "description": "YES if the agreement renews automatically, NO if it does not."},
      "notice_period_days":   {"type": "string", "description": "The number of days of notice required for non-renewal or termination for convenience, as a number."},
      "annual_fee_amount":    {"type": "string", "description": "The annual or recurring fee amount exactly as written, without the currency word."},
      "liability_cap_amount": {"type": "string", "description": "The aggregate limitation of liability amount exactly as written. Empty if uncapped or not stated."},
      "governing_law":        {"type": "string", "description": "The governing law jurisdiction, for example Delaware or England and Wales."},
      "currency":             {"type": "string", "description": "The currency of the fees as a code, for example USD."}
    }
  }
}$$;
```

Replace `SYN Demo Buyer Co` with the customer's own legal entity names for a real build (those are not
sandbox *answers*; they tell the model which party to exclude). The two contract fields that ask the
model to **compute** (`initial_term_months` from years, numbers from words) are the exception to "ask
for the printed form"; contracts write terms in words, and validation re-checks them for plausibility.

Contracts are where the 125-page `AI_EXTRACT` limit bites. See "Long documents" below.

### Insurance claim form

```sql
SET claim_schema = $${
  "schema": {
    "type": "object",
    "properties": {
      "policy_number":         {"type": "string", "description": "The insurance policy number exactly as printed."},
      "policyholder_name":     {"type": "string", "description": "The name of the policyholder or insured."},
      "loss_date":             {"type": "string", "description": "The date the loss or incident occurred exactly as printed. Not the date the form was signed or received."},
      "loss_type":             {"type": "string", "description": "The type or cause of loss as written, for example water damage or theft."},
      "estimated_loss_amount": {"type": "string", "description": "The estimated amount of loss or damage exactly as printed."},
      "police_report_number":  {"type": "string", "description": "The police or fire report number exactly as printed. Empty if not provided or marked N/A."}
    }
  }
}$$;
```

Claim forms frequently carry personal and sometimes health information in free-text description
boxes. The schema does not extract the narrative description, deliberately. Add it only if a
downstream decision needs it, and apply the governance decision from preflight to the column.

### W-9 tax form

```sql
SET w9_schema = $${
  "schema": {
    "type": "object",
    "properties": {
      "legal_name":         {"type": "string", "description": "Line 1 name as shown on the tax return."},
      "tin":                {"type": "string", "description": "The taxpayer identification number (EIN or SSN) exactly as printed in Part I."},
      "tax_classification": {"type": "string", "description": "The federal tax classification that is checked or written, for example C Corporation or Limited liability company."}
    }
  }
}$$;
```

`tin` is sensitive. `EXTRACTED_FIELDS.raw_value` for it is masked by policy (or stored only as hash +
last four) per the preflight decision. Validation compares `NORM_TAX_ID(tin)` with the vendor master
under a role that may see both.

## Estimate before running

File-based `AI_EXTRACT` meters ~970 tokens per page for paged formats and per image file, multiplied
by `scale_factor`, plus prompt and output tokens (documented). So the page count from classification
is the estimate:

```sql
SELECT document_type,
       COUNT(*)                                           AS docs,
       SUM(page_count)                                    AS pages,
       SUM(page_count) * 970 * :scale_factor              AS est_page_tokens_floor
FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION
WHERE route = 'EXTRACT'
  AND NOT EXISTS (SELECT 1 FROM {{DB}}.{{SCHEMA}}.EXTRACT_RAW r
                  WHERE r.document_id = DOC_CLASSIFICATION.document_id
                    AND r.schema_hash = SHA2(TO_JSON(PARSE_JSON(
                          CASE document_type WHEN 'invoice' THEN $invoice_schema
                                             WHEN 'credit_note' THEN $credit_note_schema
                                             WHEN 'contract' THEN $contract_schema
                                             WHEN 'insurance_claim_form' THEN $claim_schema
                                             WHEN 'w9_tax_form' THEN $w9_schema END))))
GROUP BY 1 ORDER BY pages DESC;
```

Say it is a floor (prompt and output tokens bill on top). Offer to run a sample of 50 documents per
type first.

## Run extraction

```sql
ALTER SESSION SET QUERY_TAG = 'doc_intake:<experiment_id>:extract';

CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.EXTRACT_RAW (
    document_id     VARCHAR,
    document_type   VARCHAR,
    relative_path   VARCHAR,
    page_count      INT,
    input_mode      VARCHAR,          -- FILE | PARSED_TEXT
    scale_factor    FLOAT,
    run_id          VARCHAR,
    experiment_id   VARCHAR,
    experiment_name VARCHAR,
    schema_version  VARCHAR,
    schema_hash     VARCHAR,
    response        VARIANT,          -- full AI_EXTRACT output: response, scoring, error
    extracted_at    TIMESTAMP_LTZ
);
```

One statement per type, so the schema is a constant per call and per-type cost is visible in the usage
view:

```sql
INSERT INTO {{DB}}.{{SCHEMA}}.EXTRACT_RAW
SELECT
    c.document_id, c.document_type, c.relative_path, c.page_count,
    'FILE', :scale_factor,
    :run_id, :experiment_id, :experiment_name, :schema_version,
    SHA2(TO_JSON(PARSE_JSON($invoice_schema))) AS schema_hash,
    AI_EXTRACT(
        file           => TO_FILE('@{{STAGE_FQN}}', c.relative_path),
        responseFormat => PARSE_JSON($invoice_schema),
        config         => {'scale_factor': :scale_factor},
        scores         => TRUE                 -- named-argument form ONLY; positional returns no scores
    ),
    CURRENT_TIMESTAMP()
FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION c
WHERE c.route = 'EXTRACT'
  AND c.document_type = 'invoice'
  AND NOT EXISTS (
      SELECT 1 FROM {{DB}}.{{SCHEMA}}.EXTRACT_RAW r
      WHERE r.document_id = c.document_id
        AND r.schema_hash = SHA2(TO_JSON(PARSE_JSON($invoice_schema)))
  );
```

Repeat for `credit_note`, `contract`, `insurance_claim_form`, and `w9_tax_form` with their schemas.

### Text rows (the sandbox, or a customer table with an existing text layer)

`SYN_DOCUMENTS` and customer tables with pre-extracted OCR text have no file to pass. Use the text
form; `text` and `file` cannot be combined in one call:

```sql
INSERT INTO {{DB}}.{{SCHEMA}}.EXTRACT_RAW
SELECT c.document_id, c.document_type, c.relative_path, c.page_count, 'TEXT', NULL,
       :run_id, :experiment_id, :experiment_name, :schema_version,
       SHA2(TO_JSON(PARSE_JSON($invoice_schema))),
       AI_EXTRACT(text => d.document_text, responseFormat => PARSE_JSON($invoice_schema), scores => TRUE),
       CURRENT_TIMESTAMP()
FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION c
JOIN {{DB}}.{{SCHEMA}}.SYN_DOCUMENTS d USING (document_id)
WHERE c.route = 'EXTRACT' AND c.document_type = 'invoice'
  AND NOT EXISTS (SELECT 1 FROM {{DB}}.{{SCHEMA}}.EXTRACT_RAW r
                  WHERE r.document_id = c.document_id
                    AND r.schema_hash = SHA2(TO_JSON(PARSE_JSON($invoice_schema))));
```

Text input bills input and output tokens rather than pages. Estimate with
`AI_COUNT_TOKENS` only for functions it supports — its documented function list does not include
`AI_EXTRACT`, so for text extraction state that the estimate is the document character count divided
by roughly four, labelled as a rough convention, and reconcile against the usage view after a sample.
Text-path and file-path results on the same content are the comparison `build-intake-test-corpus
--from-sandbox` exists to make; keep `input_mode` on every row so evaluation can split by it.

The `NOT EXISTS` on `(document_id, schema_hash)` is the incremental predicate and the cost control:
a re-run is free for unchanged documents, and a schema change re-extracts deliberately. `config` with
`scale_factor` 1.0 is the default and may be omitted; raise it **per type** only for a measured gain.

### Long documents

A document over `FLOOR(125 / scale_factor)` pages was routed to `EXCEPTION` by classification. For
contracts this is common and the right fix is not "reject", it is a text path:

1. `AI_PARSE_DOCUMENT` in `LAYOUT` mode with `page_split` (up to 2,000 pages) — bills every page.
2. Select the pages that carry the terms (sections matching `TERM`, `FEES`, `LIABILITY`, `GOVERNING
   LAW`, `RENEWAL`, plus the first page for parties and dates).
3. `AI_EXTRACT(text => <selected pages>, responseFormat => ..., scores => TRUE)` and record
   `input_mode = 'PARSED_TEXT'`.

```sql
-- Text-path extraction for long contracts. text and file cannot be combined in one call.
INSERT INTO {{DB}}.{{SCHEMA}}.EXTRACT_RAW
SELECT p.document_id, 'contract', p.relative_path, p.page_count, 'PARSED_TEXT', 1.0,
       :run_id, :experiment_id, :experiment_name, :schema_version,
       SHA2(TO_JSON(PARSE_JSON($contract_schema))),
       AI_EXTRACT(text => p.selected_text, responseFormat => PARSE_JSON($contract_schema), scores => TRUE),
       CURRENT_TIMESTAMP()
FROM (
    SELECT c.document_id, c.relative_path, c.page_count,
           ARRAY_TO_STRING(ARRAY_AGG(pg.value:content::STRING)
                           WITHIN GROUP (ORDER BY pg.value:index::INT), '\n\n') AS selected_text
    FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION c,
         LATERAL FLATTEN(input => PARSE_JSON(TO_VARCHAR(AI_PARSE_DOCUMENT(
             TO_FILE('@{{STAGE_FQN}}', c.relative_path), {'mode': 'LAYOUT', 'page_split': TRUE}
         ))):pages) pg
    WHERE c.document_type = 'contract' AND c.route_reason = 'EXCEEDS_EXTRACT_PAGE_LIMIT'
      AND (pg.value:index::INT = 0
           OR REGEXP_LIKE(pg.value:content::STRING,
                '.*(TERM|RENEW|FEES?|PAYMENT|LIMITATION OF LIABILITY|GOVERNING LAW|TERMINATION).*', 'is'))
    GROUP BY 1, 2, 3
) p;
```

Then move those documents to `route = 'EXTRACT'` with reason `EXTRACTED_FROM_TEXT`. Measure contract
field accuracy on both paths on the rendered corpus before relying on the text path: text input loses
layout, and a liability cap in a table cell may read differently.

## Flatten to fields

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS (
    document_id       VARCHAR,
    document_type     VARCHAR,
    run_id            VARCHAR,
    experiment_id     VARCHAR,
    schema_version    VARCHAR,
    schema_hash       VARCHAR,
    field_name        VARCHAR,
    raw_value         VARCHAR,        -- as returned, after NULLIF_PLACEHOLDER
    score             FLOAT,          -- from scoring.scores.<field>.score
    field_kind        VARCHAR,        -- AMOUNT | DATE | DOC_NUMBER | TAX_ID | PARTY | CURRENCY | TEXT | INTEGER | YESNO
    normalized_value  VARCHAR,        -- canonical text form (amount '1463.70', date '2026-04-03')
    normalize_status  VARCHAR,        -- OK | NULL | AMBIGUOUS | RESOLVED_BY_LOCALE | LOCALE_CONFLICT | UNPARSEABLE | SYMBOL_ONLY
    extract_error     VARCHAR,
    vendor_id_hint    VARCHAR,        -- vendor matched by name/tax id, used for locale lookup
    extracted_at      TIMESTAMP_LTZ
);
```

Field kinds are a small config table so the normalizer choice is data, not a `CASE` buried in SQL:

```sql
CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.FIELD_CATALOG (document_type VARCHAR, field_name VARCHAR, field_kind VARCHAR) AS
SELECT * FROM VALUES
 ('invoice','invoice_number','DOC_NUMBER'), ('invoice','invoice_date','DATE'), ('invoice','due_date','DATE'),
 ('invoice','vendor_name','PARTY'), ('invoice','vendor_tax_id','TAX_ID'), ('invoice','po_number','DOC_NUMBER'),
 ('invoice','currency','CURRENCY'), ('invoice','subtotal_amount','AMOUNT'), ('invoice','tax_amount','AMOUNT'),
 ('invoice','total_amount','AMOUNT'), ('invoice','payment_terms','TEXT'), ('invoice','remit_account_last4','TEXT'),
 ('invoice','bank_details_change_notice','TEXT'),
 ('credit_note','credit_note_number','DOC_NUMBER'), ('credit_note','referenced_invoice_number','DOC_NUMBER'),
 ('credit_note','issue_date','DATE'), ('credit_note','vendor_name','PARTY'), ('credit_note','currency','CURRENCY'),
 ('credit_note','total_amount','AMOUNT'),
 ('contract','counterparty_name','PARTY'), ('contract','effective_date','DATE'), ('contract','initial_term_months','INTEGER'),
 ('contract','auto_renewal','YESNO'), ('contract','notice_period_days','INTEGER'), ('contract','annual_fee_amount','AMOUNT'),
 ('contract','liability_cap_amount','AMOUNT'), ('contract','governing_law','TEXT'), ('contract','currency','CURRENCY'),
 ('insurance_claim_form','policy_number','DOC_NUMBER'), ('insurance_claim_form','policyholder_name','PARTY'),
 ('insurance_claim_form','loss_date','DATE'), ('insurance_claim_form','loss_type','TEXT'),
 ('insurance_claim_form','estimated_loss_amount','AMOUNT'), ('insurance_claim_form','police_report_number','DOC_NUMBER'),
 ('w9_tax_form','legal_name','PARTY'), ('w9_tax_form','tin','TAX_ID'), ('w9_tax_form','tax_classification','TEXT');
```

Locale comes from the vendor master, so the vendor is resolved first (by tax ID, then by normalized
name), and its `number_locale` / `date_locale` feed the normalizers. Claim forms and contracts use the
customer's default locale from `intake-project.yml` (record it at preflight; absent means NULL, which
makes ambiguous values `AMBIGUOUS` — the safe outcome).

```sql
INSERT INTO {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS
WITH raw AS (
    SELECT r.* FROM {{DB}}.{{SCHEMA}}.EXTRACT_RAW r WHERE r.run_id = :run_id
),
vendor AS (
    -- Resolve the vendor once per document, tax id first (exact), then normalized name.
    SELECT r.document_id,
           COALESCE(vt.vendor_id, vn.vendor_id) AS vendor_id,
           COALESCE(vt.number_locale, vn.number_locale, :default_number_locale) AS number_locale,
           COALESCE(vt.date_locale,   vn.date_locale,   :default_date_locale)   AS date_locale
    FROM raw r
    LEFT JOIN {{VENDOR_MASTER}} vt
           ON {{DB}}.{{SCHEMA}}.NORM_TAX_ID(vt.tax_id) = {{DB}}.{{SCHEMA}}.NORM_TAX_ID(r.response:response:vendor_tax_id::STRING)
    -- Normalize BOTH sides with the same UDF; do not trust a pre-computed
    -- name column in the master to have used the same rules.
    LEFT JOIN {{VENDOR_MASTER}} vn
           ON {{DB}}.{{SCHEMA}}.NORM_PARTY_NAME(vn.vendor_name)
            = {{DB}}.{{SCHEMA}}.NORM_PARTY_NAME(r.response:response:vendor_name::STRING)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY r.document_id ORDER BY vt.vendor_id NULLS LAST, vn.vendor_id NULLS LAST) = 1
),
fields AS (
    SELECT r.document_id, r.document_type, r.run_id, r.experiment_id, r.schema_version, r.schema_hash,
           fc.field_name, fc.field_kind,
           {{DB}}.{{SCHEMA}}.NULLIF_PLACEHOLDER(r.response:response[fc.field_name]::STRING) AS raw_value,
           r.response:scoring:scores[fc.field_name]:score::FLOAT                           AS score,
           r.response:error::STRING                                                         AS extract_error,
           v.vendor_id, v.number_locale, v.date_locale
    FROM raw r
    -- Driven from the CATALOG, not from the response keys: a field the model
    -- omitted entirely must still produce a row (NOT_EXTRACTED), or it vanishes.
    JOIN {{DB}}.{{SCHEMA}}.FIELD_CATALOG fc ON fc.document_type = r.document_type
    LEFT JOIN vendor v ON v.document_id = r.document_id
)
SELECT
    document_id, document_type, run_id, experiment_id, schema_version, schema_hash,
    field_name, raw_value, score, field_kind,
    CASE field_kind
        WHEN 'AMOUNT'     THEN TO_VARCHAR({{DB}}.{{SCHEMA}}.NORM_AMOUNT(raw_value, number_locale):value::NUMBER(18,2), 'FM999999999990.00')
        WHEN 'DATE'       THEN {{DB}}.{{SCHEMA}}.NORM_DATE(raw_value, date_locale):value::STRING
        WHEN 'DOC_NUMBER' THEN {{DB}}.{{SCHEMA}}.NORM_DOC_NUMBER(raw_value)
        WHEN 'TAX_ID'     THEN {{DB}}.{{SCHEMA}}.NORM_TAX_ID(raw_value)
        WHEN 'PARTY'      THEN {{DB}}.{{SCHEMA}}.NORM_PARTY_NAME(raw_value)
        WHEN 'CURRENCY'   THEN {{DB}}.{{SCHEMA}}.NORM_CURRENCY(raw_value):value::STRING
        WHEN 'INTEGER'    THEN TO_VARCHAR(TRY_TO_NUMBER(REGEXP_SUBSTR(raw_value, '[0-9]+')))
        WHEN 'YESNO'      THEN CASE WHEN UPPER(raw_value) IN ('YES','Y','TRUE') THEN 'YES'
                                    WHEN UPPER(raw_value) IN ('NO','N','FALSE') THEN 'NO' END
        ELSE UPPER(raw_value)
    END AS normalized_value,
    CASE
        WHEN raw_value IS NULL THEN 'NULL'
        WHEN field_kind = 'AMOUNT'   THEN {{DB}}.{{SCHEMA}}.NORM_AMOUNT(raw_value, number_locale):status::STRING
        WHEN field_kind = 'DATE'     THEN {{DB}}.{{SCHEMA}}.NORM_DATE(raw_value, date_locale):status::STRING
        WHEN field_kind = 'CURRENCY' THEN {{DB}}.{{SCHEMA}}.NORM_CURRENCY(raw_value):status::STRING
        WHEN normalized_value IS NULL THEN 'UNPARSEABLE'
        ELSE 'OK'
    END AS normalize_status,
    extract_error, vendor_id, CURRENT_TIMESTAMP()
FROM fields;
```

Two details that matter:

- The response is indexed with `response:response[fc.field_name]` — bracket access by a column value.
  Driving from `FIELD_CATALOG` means every expected field gets a row even if the model omitted the key;
  driving from `OBJECT_KEYS(response)` silently drops omitted fields, which is exactly the
  `NOT_EXTRACTED` case evaluation needs to count.
- `normalized_value` uses `TEXT` (uppercased) for free-text fields; evaluation compares those with
  the same expression on the key side.

## Flatten line items

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.EXTRACTED_LINE_ITEMS (
    document_id      VARCHAR,
    run_id           VARCHAR,
    line_no          INT,
    description      VARCHAR,
    quantity_raw     VARCHAR,
    unit_price_raw   VARCHAR,
    line_amount_raw  VARCHAR,
    line_amount      NUMBER(18,2),
    table_score      FLOAT,           -- ONE score for the whole table (documented); not per row
    columns_aligned  BOOLEAN          -- all column arrays the same length
);

INSERT INTO {{DB}}.{{SCHEMA}}.EXTRACTED_LINE_ITEMS
SELECT
    r.document_id, r.run_id,
    d.index + 1,
    d.value::STRING,
    r.response:response:line_items:quantity[d.index]::STRING,
    r.response:response:line_items:unit_price[d.index]::STRING,
    r.response:response:line_items:line_amount[d.index]::STRING,
    {{DB}}.{{SCHEMA}}.NORM_AMOUNT(r.response:response:line_items:line_amount[d.index]::STRING, v.number_locale):value::NUMBER(18,2),
    r.response:scoring:scores:line_items:score::FLOAT,
    ARRAY_SIZE(r.response:response:line_items:description) = ARRAY_SIZE(r.response:response:line_items:line_amount)
      AND ARRAY_SIZE(r.response:response:line_items:description) = ARRAY_SIZE(r.response:response:line_items:quantity)
FROM {{DB}}.{{SCHEMA}}.EXTRACT_RAW r
LEFT JOIN (SELECT DISTINCT document_id, vendor_id_hint FROM {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS WHERE run_id = :run_id) f
       USING (document_id)
LEFT JOIN {{VENDOR_MASTER}} v ON v.vendor_id = f.vendor_id_hint,
LATERAL FLATTEN(input => r.response:response:line_items:description) d
WHERE r.run_id = :run_id AND r.document_type = 'invoice';
```

`columns_aligned = FALSE` means a wrapped description split into two rows or a column was missed;
those invoices cannot pass the line arithmetic rule and go to exceptions with that reason, rather than
having rows zipped together wrongly.

## Verification at the gate

```sql
-- 1. Errors by type. Each documented message has a specific fix (DIAGNOSING section 2).
SELECT document_type, COALESCE(response:error::STRING, 'OK') AS error, COUNT(*) AS docs
FROM {{DB}}.{{SCHEMA}}.EXTRACT_RAW WHERE run_id = :run_id
GROUP BY 1, 2 ORDER BY 1, docs DESC;

-- 2. Scores present wherever a value is present. Must be zero.
SELECT COUNT(*) AS value_without_score
FROM {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS
WHERE run_id = :run_id AND raw_value IS NOT NULL AND score IS NULL;

-- 3. Per field: fill rate, score distribution, normalization outcomes.
SELECT document_type, field_name,
       COUNT(*)                                            AS docs,
       ROUND(100.0 * COUNT(raw_value) / COUNT(*), 1)       AS pct_filled,
       ROUND(MEDIAN(score), 3)                             AS median_score,
       ROUND(PERCENTILE_CONT(0.1) WITHIN GROUP (ORDER BY score), 3) AS p10_score,
       COUNT_IF(normalize_status = 'AMBIGUOUS')            AS ambiguous,
       COUNT_IF(normalize_status IN ('UNPARSEABLE', 'LOCALE_CONFLICT')) AS normalize_failed
FROM {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS
WHERE run_id = :run_id
GROUP BY 1, 2 ORDER BY 1, 2;

-- 4. Placeholder strings actually returned for absent fields -- check the
--    real distribution once so NULLIF_PLACEHOLDER covers what this account sees.
SELECT r.response:response:po_number::STRING AS raw_po, COUNT(*) AS docs
FROM {{DB}}.{{SCHEMA}}.EXTRACT_RAW r
WHERE r.run_id = :run_id AND r.document_type = 'invoice'
  AND (r.response:response:po_number IS NULL OR LENGTH(r.response:response:po_number::STRING) < 4)
GROUP BY 1 ORDER BY docs DESC;

-- 5. Line tables: alignment and coverage.
SELECT COUNT(DISTINCT document_id) AS invoices_with_lines,
       COUNT_IF(NOT columns_aligned) AS misaligned_rows
FROM {{DB}}.{{SCHEMA}}.EXTRACTED_LINE_ITEMS WHERE run_id = :run_id;
```

Read check 3 carefully. A field whose median score is high but whose `normalize_failed` count is high
is a normalization problem; a field with low fill and low scores is an extraction problem (rewrite the
description, then bump `schema_version`).

Then set `phases.extract: done` and record the tables and UDFs in `created_objects`.

## Normalizer test cases

Run after creating the UDFs. Every row's `ok` must be `TRUE`. These are the same cases used to
develop the functions.

```sql
SELECT raw, loc, expected,
       {{DB}}.{{SCHEMA}}.NORM_AMOUNT(raw, loc):value::NUMBER(18,2)::VARCHAR AS got,
       {{DB}}.{{SCHEMA}}.NORM_AMOUNT(raw, loc):status::STRING               AS status,
       EQUAL_NULL(got, expected) AS ok
FROM (SELECT * FROM VALUES
    ('$1,234.56',     NULL,            '1234.56'),
    ('1.234,56 EUR',  'COMMA_DECIMAL', '1234.56'),
    ('(1,200.00)',    NULL,            '-1200.00'),
    ('1.234',         NULL,            NULL),        -- AMBIGUOUS
    ('1.234',         'COMMA_DECIMAL', '1234.00'),
    ('1.234',         'DOT_DECIMAL',   '1.23'),      -- 1.234 to 2 dp; status RESOLVED_BY_LOCALE
    ('45.10-',        NULL,            '-45.10'),
    ('None',          NULL,            NULL),
    ('-312,00',       'COMMA_DECIMAL', '-312.00')
) t(raw, loc, expected);

SELECT raw, loc, expected,
       {{DB}}.{{SCHEMA}}.NORM_DATE(raw, loc):value::STRING   AS got,
       {{DB}}.{{SCHEMA}}.NORM_DATE(raw, loc):status::STRING  AS status,
       EQUAL_NULL(got, expected) AS ok
FROM (SELECT * FROM VALUES
    ('2026-03-04',    NULL,  '2026-03-04'),
    ('03/04/2026',    NULL,  NULL),                  -- AMBIGUOUS
    ('03/04/2026',    'MDY', '2026-03-04'),
    ('03.04.2026',    'DMY', '2026-04-03'),
    ('13/04/2026',    'MDY', NULL),                  -- LOCALE_CONFLICT
    ('March 4, 2026', NULL,  '2026-03-04'),
    ('N/A',           NULL,  NULL)
) t(raw, loc, expected);

SELECT raw, expected, {{DB}}.{{SCHEMA}}.NORM_DOC_NUMBER(raw) AS got, EQUAL_NULL(got, expected) AS ok
FROM (SELECT * FROM VALUES
    ('INV-010000', '10000'), ('0010000', '10000'), ('#10003', '10003'),
    ('Invoice No. 42', '42'), ('NOVA-12', 'NOVA12'), ('0045001001', '45001001')
) t(raw, expected);
```
