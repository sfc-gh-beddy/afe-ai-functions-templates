---
name: validate-and-queue-exceptions
description: "Phase 4 of the document-intake build: decide, in SQL, whether each extracted document posts straight through, goes to human review, or is rejected. Applies per-type, per-field confidence thresholds and required-field checks; normalization status checks (ambiguous dates and amounts block); business rules against systems of record (vendor match and active status, remittance bank change detection, tax ID match, PO existence, vendor and amount tolerance, posted-history and in-batch duplicate detection, policy coverage of loss date, counterparty match, TIN match); and arithmetic (line items sum to subtotal, subtotal plus tax equals total, credit-note sign). Writes FIELD_VALIDATION (one row per document x rule), DOCUMENT_DECISION, INTAKE_APPROVED, an actionable EXCEPTIONS_QUEUE with prioritization by amount and due date, and a REVIEW_CORRECTIONS feedback table. Use for validation rules, three-way match, duplicate invoice detection, exception handling, human-in-the-loop review, straight-through processing."
parent_skill: document-intake
---

# Validate, decide, and queue exceptions

This phase is where the value is protected. Extraction produced values and scores; nothing has posted.
Here every document gets exactly one decision — `AUTO_APPROVED`, `EXCEPTION`, or `REJECTED` — made by
SQL rules, and every exception tells a reviewer precisely which field and rule failed.

> The model never decides that a document posts. Scores are inputs. A 0.99 score on a total that does
> not equal its line items is an exception.

## Configuration tables

Thresholds and rule switches are data, loaded from `intake-project.yml`, so tuning is an `UPDATE` and
is auditable.

```sql
CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.FIELD_THRESHOLDS (
    document_type VARCHAR, field_name VARCHAR, min_score FLOAT, required BOOLEAN,
    posts BOOLEAN, threshold_source VARCHAR, set_at TIMESTAMP_LTZ
);

-- Starting values are PLACEHOLDERS (threshold_source = 'PLACEHOLDER'). Phase 5 replaces them
-- from the measured score/correctness curve and sets threshold_source = '<experiment_id>'.
INSERT INTO {{DB}}.{{SCHEMA}}.FIELD_THRESHOLDS
SELECT f.document_type, f.field_name, t.min_score, t.required, t.posts, 'PLACEHOLDER', CURRENT_TIMESTAMP()
FROM {{DB}}.{{SCHEMA}}.FIELD_CATALOG f
JOIN (SELECT * FROM VALUES
    ('invoice','invoice_number',0.90,TRUE,TRUE), ('invoice','invoice_date',0.90,TRUE,TRUE),
    ('invoice','due_date',0.85,FALSE,TRUE),      ('invoice','vendor_name',0.85,TRUE,TRUE),
    ('invoice','vendor_tax_id',0.90,FALSE,FALSE),('invoice','po_number',0.90,FALSE,TRUE),
    ('invoice','currency',0.80,TRUE,TRUE),       ('invoice','subtotal_amount',0.90,FALSE,FALSE),
    ('invoice','tax_amount',0.90,FALSE,TRUE),    ('invoice','total_amount',0.95,TRUE,TRUE),
    ('invoice','payment_terms',0.80,FALSE,FALSE),('invoice','remit_account_last4',0.90,FALSE,FALSE),
    ('invoice','bank_details_change_notice',0.00,FALSE,FALSE),
    ('credit_note','credit_note_number',0.90,TRUE,TRUE), ('credit_note','referenced_invoice_number',0.85,FALSE,TRUE),
    ('credit_note','issue_date',0.90,TRUE,TRUE), ('credit_note','vendor_name',0.85,TRUE,TRUE),
    ('credit_note','currency',0.80,TRUE,TRUE),   ('credit_note','total_amount',0.95,TRUE,TRUE),
    ('contract','counterparty_name',0.85,TRUE,TRUE), ('contract','effective_date',0.90,TRUE,TRUE),
    ('contract','initial_term_months',0.85,TRUE,TRUE), ('contract','auto_renewal',0.85,TRUE,TRUE),
    ('contract','notice_period_days',0.85,FALSE,TRUE), ('contract','annual_fee_amount',0.90,FALSE,TRUE),
    ('contract','liability_cap_amount',0.90,FALSE,TRUE), ('contract','governing_law',0.80,FALSE,FALSE),
    ('contract','currency',0.80,FALSE,TRUE),
    ('insurance_claim_form','policy_number',0.95,TRUE,TRUE), ('insurance_claim_form','policyholder_name',0.85,FALSE,FALSE),
    ('insurance_claim_form','loss_date',0.90,TRUE,TRUE), ('insurance_claim_form','loss_type',0.80,FALSE,FALSE),
    ('insurance_claim_form','estimated_loss_amount',0.90,TRUE,TRUE), ('insurance_claim_form','police_report_number',0.85,FALSE,FALSE),
    ('w9_tax_form','legal_name',0.90,TRUE,TRUE), ('w9_tax_form','tin',0.95,TRUE,TRUE),
    ('w9_tax_form','tax_classification',0.80,FALSE,FALSE)
) t(document_type, field_name, min_score, required, posts)
  ON t.document_type = f.document_type AND t.field_name = f.field_name;
```

`bank_details_change_notice` has `min_score` 0: its score is irrelevant; any non-empty value blocks
(rule `VENDOR_BANK_MATCH` below).

```sql
CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.VALIDATION_RULES (
    rule_id VARCHAR, document_type VARCHAR, severity VARCHAR,   -- BLOCKING | WARNING
    enabled BOOLEAN, requires_reference VARCHAR, description VARCHAR
);

INSERT INTO {{DB}}.{{SCHEMA}}.VALIDATION_RULES VALUES
('REQUIRED_FIELD_MISSING', '*',                    'BLOCKING', TRUE, NULL,                'A required field is empty'),
('LOW_SCORE',              '*',                    'BLOCKING', TRUE, NULL,                'A field value scored below its threshold'),
('NORMALIZE_FAILED',       '*',                    'BLOCKING', TRUE, NULL,                'A posting field value is ambiguous, conflicts with locale, or cannot be parsed'),
('VENDOR_MATCH',           'invoice',              'BLOCKING', TRUE, 'vendor_master',     'Vendor resolves to exactly one master record'),
('VENDOR_ACTIVE',          'invoice',              'BLOCKING', TRUE, 'vendor_master',     'Vendor master status is ACTIVE'),
('VENDOR_BANK_MATCH',      'invoice',              'BLOCKING', TRUE, 'vendor_master',     'Remittance account matches master and no bank-change notice'),
('TAX_ID_MATCH',           'invoice',              'WARNING',  TRUE, 'vendor_master',     'Printed tax ID matches vendor master'),
('CURRENCY_RESOLVED',      'invoice',              'BLOCKING', TRUE, NULL,                'Currency is an explicit code, or inferred from vendor or PO'),
('LINES_ALIGNED',          'invoice',              'BLOCKING', TRUE, NULL,                'Line item columns extracted with equal lengths'),
('LINES_SUM_TO_SUBTOTAL',  'invoice',              'BLOCKING', TRUE, NULL,                'Sum of line amounts equals subtotal within tolerance'),
('SUBTOTAL_TAX_TOTAL',     'invoice',              'BLOCKING', TRUE, NULL,                'Subtotal plus tax equals total within tolerance'),
('DATE_PLAUSIBLE',         'invoice',              'BLOCKING', TRUE, NULL,                'Invoice date not in future; due date not before invoice date'),
('PO_EXISTS',              'invoice',              'BLOCKING', TRUE, 'purchase_orders',   'Printed PO exists'),
('PO_VENDOR_MATCH',        'invoice',              'BLOCKING', TRUE, 'purchase_orders',   'PO belongs to the invoice vendor'),
('PO_AMOUNT_TOLERANCE',    'invoice',              'BLOCKING', TRUE, 'purchase_orders',   'Invoice total within tolerance of PO open amount'),
('DUP_VENDOR_INVOICE',     'invoice',              'BLOCKING', TRUE, NULL,                'Same vendor and normalized invoice number not already posted or in this batch'),
('CREDIT_NOTE_SIGN',       'credit_note',          'BLOCKING', TRUE, NULL,                'Credit note total is negative after normalization'),
('VENDOR_MATCH',           'credit_note',          'BLOCKING', TRUE, 'vendor_master',     'Vendor resolves to exactly one master record'),
('POLICY_EXISTS',          'insurance_claim_form', 'BLOCKING', TRUE, 'policies',          'Policy number exists'),
('POLICY_COVERS_LOSS',     'insurance_claim_form', 'BLOCKING', TRUE, 'policies',          'Loss date within policy effective and expiry dates and policy ACTIVE'),
('COUNTERPARTY_MATCH',     'contract',             'BLOCKING', TRUE, 'contracts_register','Counterparty resolves to the register'),
('TERM_PLAUSIBLE',         'contract',             'WARNING',  TRUE, NULL,                'Initial term between 1 and 120 months'),
('TIN_MATCHES_VENDOR',     'w9_tax_form',          'BLOCKING', TRUE, 'vendor_master',     'TIN matches the vendor master record for the legal name');
```

At the start of the phase, **disable rules whose reference data is absent** in `intake-project.yml`
and say which ones. A disabled `VENDOR_BANK_MATCH` must be called out to the business owner in words:
it is the payment-fraud control.

## Step 1 — field-level rules

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.FIELD_VALIDATION (
    document_id   VARCHAR,
    document_type VARCHAR,
    run_id        VARCHAR,
    rule_id       VARCHAR,
    field_name    VARCHAR,          -- NULL for document-level rules
    passed        BOOLEAN,
    severity      VARCHAR,
    detail        OBJECT,           -- extracted value, normalized value, score, threshold, reference value
    validated_at  TIMESTAMP_LTZ
);

INSERT INTO {{DB}}.{{SCHEMA}}.FIELD_VALIDATION
SELECT f.document_id, f.document_type, f.run_id, r.rule_id, f.field_name,
       CASE r.rule_id
           WHEN 'REQUIRED_FIELD_MISSING' THEN NOT (t.required AND f.normalized_value IS NULL)
           -- Fail CLOSED: a value with no score is not a confident value.
           WHEN 'LOW_SCORE'              THEN f.raw_value IS NULL OR COALESCE(f.score, 0) >= t.min_score
           WHEN 'NORMALIZE_FAILED'       THEN NOT (t.posts AND f.normalize_status IN ('AMBIGUOUS', 'LOCALE_CONFLICT', 'UNPARSEABLE'))
       END AS passed,
       r.severity,
       OBJECT_CONSTRUCT_KEEP_NULL(
           'raw_value', f.raw_value, 'normalized_value', f.normalized_value, 'score', f.score,
           'min_score', t.min_score, 'required', t.required, 'normalize_status', f.normalize_status),
       CURRENT_TIMESTAMP()
FROM {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS f
JOIN {{DB}}.{{SCHEMA}}.FIELD_THRESHOLDS t
  ON t.document_type = f.document_type AND t.field_name = f.field_name
CROSS JOIN (SELECT rule_id, severity FROM {{DB}}.{{SCHEMA}}.VALIDATION_RULES
            WHERE document_type = '*' AND enabled) r
WHERE f.run_id = :run_id;
```

Two deliberate asymmetries:

- `LOW_SCORE` only applies when a value exists. An absent optional field (`NOT_PRESENT`) is not
  low-confidence; an absent **required** field is caught by `REQUIRED_FIELD_MISSING`.
- `NORMALIZE_FAILED` only blocks on **posting** fields. An ambiguous `payment_terms` string does not
  stop an invoice; an ambiguous `due_date` does, because it drives payment timing.

Any extraction error (`EXTRACTED_FIELDS.extract_error IS NOT NULL`) becomes a document-level failure
with rule `EXTRACT_ERROR` in step 2.

## Step 2 — document-level rules

Pivot the normalized fields once, so rules read like business logic:

```sql
CREATE OR REPLACE TEMPORARY TABLE DOC_FIELDS AS
SELECT document_id, document_type, run_id,
       MAX(extract_error)                                                  AS extract_error,
       MAX(vendor_id_hint)                                                 AS vendor_id,
       MAX(IFF(field_name = 'invoice_number',  raw_value, NULL))           AS invoice_number_raw,
       MAX(IFF(field_name = 'invoice_number',  normalized_value, NULL))    AS invoice_number_norm,
       MAX(IFF(field_name = 'invoice_date',    normalized_value, NULL))::DATE AS invoice_date,
       MAX(IFF(field_name = 'due_date',        normalized_value, NULL))::DATE AS due_date,
       MAX(IFF(field_name = 'vendor_tax_id',   normalized_value, NULL))    AS vendor_tax_id,
       MAX(IFF(field_name = 'po_number',       normalized_value, NULL))    AS po_number_norm,
       MAX(IFF(field_name = 'currency',        normalized_value, NULL))    AS currency,
       MAX(IFF(field_name = 'currency',        normalize_status, NULL))    AS currency_status,
       MAX(IFF(field_name = 'subtotal_amount', normalized_value, NULL))::NUMBER(18,2) AS subtotal_amount,
       MAX(IFF(field_name = 'tax_amount',      normalized_value, NULL))::NUMBER(18,2) AS tax_amount,
       MAX(IFF(field_name = 'total_amount',    normalized_value, NULL))::NUMBER(18,2) AS total_amount,
       MAX(IFF(field_name = 'remit_account_last4', REGEXP_REPLACE(raw_value, '[^0-9]', ''), NULL)) AS remit_last4,
       MAX(IFF(field_name = 'bank_details_change_notice', raw_value, NULL)) AS bank_change_notice,
       MAX(IFF(field_name = 'policy_number',   normalized_value, NULL))    AS policy_number_norm,
       MAX(IFF(field_name = 'loss_date',       normalized_value, NULL))::DATE AS loss_date,
       MAX(IFF(field_name IN ('counterparty_name', 'legal_name'), normalized_value, NULL)) AS party_norm,
       MAX(IFF(field_name = 'initial_term_months', normalized_value, NULL))::INT AS term_months,
       MAX(IFF(field_name = 'tin',             normalized_value, NULL))    AS tin_norm
FROM {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS
WHERE run_id = :run_id
GROUP BY 1, 2, 3;
```

The rules, as one insert per family so each is readable and individually disable-able. `:amount_tol`
is `tolerances.amount_abs`; `:po_tol_pct` is `tolerances.po_match_pct` (NULL means exact).

```sql
INSERT INTO {{DB}}.{{SCHEMA}}.FIELD_VALIDATION
-- Extraction error: anything AI_EXTRACT reported. Blocking, and specific.
SELECT d.document_id, d.document_type, d.run_id, 'EXTRACT_ERROR', NULL, FALSE, 'BLOCKING',
       OBJECT_CONSTRUCT('error', d.extract_error), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d WHERE d.extract_error IS NOT NULL

UNION ALL
-- Vendor resolution and status.
SELECT d.document_id, d.document_type, d.run_id, 'VENDOR_MATCH', 'vendor_name',
       v.vendor_id IS NOT NULL, 'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('vendor_id', v.vendor_id), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d LEFT JOIN {{VENDOR_MASTER}} v ON v.vendor_id = d.vendor_id
WHERE d.document_type IN ('invoice', 'credit_note')

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'VENDOR_ACTIVE', 'vendor_name',
       v.status = 'ACTIVE', 'BLOCKING',
       OBJECT_CONSTRUCT('vendor_status', v.status), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d JOIN {{VENDOR_MASTER}} v ON v.vendor_id = d.vendor_id
WHERE d.document_type = 'invoice'

UNION ALL
-- The payment-fraud control. Fails when the printed remittance account
-- differs from master, OR the document announces a bank change in words.
-- A missing printed account with no notice passes: the master account is used.
SELECT d.document_id, d.document_type, d.run_id, 'VENDOR_BANK_MATCH', 'remit_account_last4',
       (d.remit_last4 IS NULL OR d.remit_last4 = v.bank_last4) AND d.bank_change_notice IS NULL,
       'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('printed_last4', d.remit_last4, 'master_last4', v.bank_last4,
                                  'change_notice', d.bank_change_notice),
       CURRENT_TIMESTAMP()
FROM DOC_FIELDS d JOIN {{VENDOR_MASTER}} v ON v.vendor_id = d.vendor_id
WHERE d.document_type = 'invoice'

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'TAX_ID_MATCH', 'vendor_tax_id',
       d.vendor_tax_id IS NULL OR d.vendor_tax_id = {{DB}}.{{SCHEMA}}.NORM_TAX_ID(v.tax_id), 'WARNING',
       OBJECT_CONSTRUCT('match', d.vendor_tax_id = {{DB}}.{{SCHEMA}}.NORM_TAX_ID(v.tax_id)), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d JOIN {{VENDOR_MASTER}} v ON v.vendor_id = d.vendor_id
WHERE d.document_type = 'invoice'

UNION ALL
-- Currency: explicit ISO code, or inferred from vendor default. Inference is recorded.
SELECT d.document_id, d.document_type, d.run_id, 'CURRENCY_RESOLVED', 'currency',
       COALESCE(d.currency, v.default_currency) IS NOT NULL, 'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('printed', d.currency, 'status', d.currency_status,
                                  'inferred_from_vendor', IFF(d.currency IS NULL, v.default_currency, NULL)),
       CURRENT_TIMESTAMP()
FROM DOC_FIELDS d LEFT JOIN {{VENDOR_MASTER}} v ON v.vendor_id = d.vendor_id
WHERE d.document_type = 'invoice'

UNION ALL
-- Arithmetic. The per-cell check that an aggregate table score cannot be.
SELECT d.document_id, d.document_type, d.run_id, 'LINES_ALIGNED', 'line_items',
       COALESCE(l.all_aligned, TRUE), 'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('line_rows', l.n, 'table_score', l.table_score), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d
LEFT JOIN (SELECT document_id, COUNT(*) n, BOOLAND_AGG(columns_aligned) all_aligned, MAX(table_score) table_score
           FROM {{DB}}.{{SCHEMA}}.EXTRACTED_LINE_ITEMS WHERE run_id = :run_id GROUP BY 1) l USING (document_id)
WHERE d.document_type = 'invoice'

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'LINES_SUM_TO_SUBTOTAL', 'subtotal_amount',
       -- No line table, or no printed subtotal: rule not applicable (passes); the
       -- subtotal/tax/total rule still checks the header arithmetic.
       l.sum_lines IS NULL OR d.subtotal_amount IS NULL
         OR ABS(l.sum_lines - d.subtotal_amount) <= :amount_tol,
       'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('sum_lines', l.sum_lines, 'subtotal', d.subtotal_amount,
                                  'difference', l.sum_lines - d.subtotal_amount),
       CURRENT_TIMESTAMP()
FROM DOC_FIELDS d
LEFT JOIN (SELECT document_id, SUM(line_amount) sum_lines, COUNT_IF(line_amount IS NULL) null_lines
           FROM {{DB}}.{{SCHEMA}}.EXTRACTED_LINE_ITEMS WHERE run_id = :run_id GROUP BY 1) l USING (document_id)
WHERE d.document_type = 'invoice'

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'SUBTOTAL_TAX_TOTAL', 'total_amount',
       d.subtotal_amount IS NULL OR d.total_amount IS NULL
         OR ABS(d.subtotal_amount + COALESCE(d.tax_amount, 0) - d.total_amount) <= :amount_tol,
       'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('subtotal', d.subtotal_amount, 'tax', d.tax_amount, 'total', d.total_amount),
       CURRENT_TIMESTAMP()
FROM DOC_FIELDS d WHERE d.document_type = 'invoice'

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'DATE_PLAUSIBLE', 'invoice_date',
       (d.invoice_date IS NULL OR d.invoice_date <= DATEADD(DAY, :future_date_days, c.received_at::DATE))
       AND (d.due_date IS NULL OR d.invoice_date IS NULL OR d.due_date >= d.invoice_date),
       'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('invoice_date', d.invoice_date, 'due_date', d.due_date,
                                  'received', c.received_at::DATE),
       CURRENT_TIMESTAMP()
FROM DOC_FIELDS d LEFT JOIN {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION c USING (document_id)
WHERE d.document_type = 'invoice'

UNION ALL
-- PO rules: only when a PO is printed. A non-PO invoice is not an error.
SELECT d.document_id, d.document_type, d.run_id, 'PO_EXISTS', 'po_number',
       p.po_number IS NOT NULL, 'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('po_printed', d.po_number_norm, 'po_found', p.po_number), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d
LEFT JOIN {{PURCHASE_ORDERS}} p ON {{DB}}.{{SCHEMA}}.NORM_DOC_NUMBER(p.po_number) = d.po_number_norm
WHERE d.document_type = 'invoice' AND d.po_number_norm IS NOT NULL

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'PO_VENDOR_MATCH', 'po_number',
       p.vendor_id = d.vendor_id, 'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('po_vendor', p.vendor_id, 'invoice_vendor', d.vendor_id), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d
JOIN {{PURCHASE_ORDERS}} p ON {{DB}}.{{SCHEMA}}.NORM_DOC_NUMBER(p.po_number) = d.po_number_norm
WHERE d.document_type = 'invoice'

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'PO_AMOUNT_TOLERANCE', 'total_amount',
       d.total_amount IS NULL
         OR d.total_amount <= p.open_amount * (1 + COALESCE(:po_tol_pct, 0)) + :amount_tol,
       'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('invoice_total', d.total_amount, 'po_open_amount', p.open_amount,
                                  'tolerance_pct', :po_tol_pct),
       CURRENT_TIMESTAMP()
FROM DOC_FIELDS d
JOIN {{PURCHASE_ORDERS}} p ON {{DB}}.{{SCHEMA}}.NORM_DOC_NUMBER(p.po_number) = d.po_number_norm
WHERE d.document_type = 'invoice'

UNION ALL
-- Duplicates: vendor-scoped, normalized number, against posted history AND
-- earlier documents (this batch and previously approved). Scoped to vendor so
-- two vendors' invoice 1001 do not collide (best-practices rule 18). Wrapped
-- in a subquery so its QUALIFY cannot attach to the wrong UNION branch.
SELECT * FROM (
    SELECT d.document_id, d.document_type, d.run_id, 'DUP_VENDOR_INVOICE' AS rule_id, 'invoice_number' AS field_name,
           h.invoice_number IS NULL AND prior.earlier_document IS NULL AS passed, 'BLOCKING' AS severity,
           OBJECT_CONSTRUCT_KEEP_NULL('normalized_number', d.invoice_number_norm,
                                      'posted_match', h.invoice_number, 'posted_at', h.posted_at,
                                      'earlier_document', prior.earlier_document) AS detail,
           CURRENT_TIMESTAMP() AS validated_at
    FROM DOC_FIELDS d
    JOIN {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION ca ON ca.document_id = d.document_id
    LEFT JOIN {{POSTED_INVOICES}} h
           ON h.vendor_id = d.vendor_id
          AND {{DB}}.{{SCHEMA}}.NORM_DOC_NUMBER(h.invoice_number) = d.invoice_number_norm
    LEFT JOIN (
        SELECT a.document_id, MIN_BY(b.document_id, b.received_at) AS earlier_document
        FROM DOC_FIELDS a
        JOIN {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION fa ON fa.document_id = a.document_id
        JOIN (
            SELECT df.document_id, df.vendor_id, df.invoice_number_norm, cb.received_at
            FROM DOC_FIELDS df JOIN {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION cb USING (document_id)
            WHERE df.document_type = 'invoice'
            UNION ALL
            SELECT ap.document_id, ap.vendor_id, ap.invoice_number_norm, ap.received_at
            FROM {{DB}}.{{SCHEMA}}.INTAKE_APPROVED ap
        ) b
          ON  b.vendor_id = a.vendor_id
          AND b.invoice_number_norm = a.invoice_number_norm
          AND b.document_id <> a.document_id
          AND (b.received_at < fa.received_at
               OR (b.received_at = fa.received_at AND b.document_id < a.document_id))
        WHERE a.document_type = 'invoice'
        GROUP BY a.document_id
    ) prior ON prior.document_id = d.document_id
    WHERE d.document_type = 'invoice' AND d.invoice_number_norm IS NOT NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY d.document_id ORDER BY h.posted_at NULLS LAST) = 1
)

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'CREDIT_NOTE_SIGN', 'total_amount',
       d.total_amount IS NULL OR d.total_amount < 0, 'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('total', d.total_amount), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d WHERE d.document_type = 'credit_note'

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'POLICY_EXISTS', 'policy_number',
       p.policy_number IS NOT NULL, 'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('policy_found', p.policy_number), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d
LEFT JOIN {{POLICIES}} p ON {{DB}}.{{SCHEMA}}.NORM_DOC_NUMBER(p.policy_number) = d.policy_number_norm
WHERE d.document_type = 'insurance_claim_form'

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'POLICY_COVERS_LOSS', 'loss_date',
       p.status = 'ACTIVE' AND d.loss_date BETWEEN p.effective_date AND p.expiry_date, 'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('loss_date', d.loss_date, 'effective', p.effective_date,
                                  'expiry', p.expiry_date, 'policy_status', p.status),
       CURRENT_TIMESTAMP()
FROM DOC_FIELDS d
JOIN {{POLICIES}} p ON {{DB}}.{{SCHEMA}}.NORM_DOC_NUMBER(p.policy_number) = d.policy_number_norm
WHERE d.document_type = 'insurance_claim_form'

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'COUNTERPARTY_MATCH', 'counterparty_name',
       c.counterparty_id IS NOT NULL, 'BLOCKING',
       OBJECT_CONSTRUCT_KEEP_NULL('counterparty_id', c.counterparty_id), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d
LEFT JOIN {{COUNTERPARTIES}} c ON {{DB}}.{{SCHEMA}}.NORM_PARTY_NAME(c.legal_name) = d.party_norm
WHERE d.document_type = 'contract'

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'TERM_PLAUSIBLE', 'initial_term_months',
       d.term_months BETWEEN 1 AND 120, 'WARNING',
       OBJECT_CONSTRUCT_KEEP_NULL('term_months', d.term_months), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d WHERE d.document_type = 'contract'

UNION ALL
SELECT d.document_id, d.document_type, d.run_id, 'TIN_MATCHES_VENDOR', 'tin',
       v.vendor_id IS NOT NULL, 'BLOCKING',
       -- Never put the TIN itself into detail; record only whether it matched.
       OBJECT_CONSTRUCT_KEEP_NULL('matched_vendor', v.vendor_id), CURRENT_TIMESTAMP()
FROM DOC_FIELDS d
LEFT JOIN {{VENDOR_MASTER}} v
       ON {{DB}}.{{SCHEMA}}.NORM_TAX_ID(v.tax_id) = d.tin_norm
      AND {{DB}}.{{SCHEMA}}.NORM_PARTY_NAME(v.vendor_name) = d.party_norm
WHERE d.document_type = 'w9_tax_form';
```

Filter the union by `VALIDATION_RULES.enabled` (join on `rule_id` and `document_type`) when building
for a customer whose reference data is partial. Substitute `{{VENDOR_MASTER}}`, `{{PURCHASE_ORDERS}}`,
`{{POSTED_INVOICES}}`, `{{POLICIES}}`, `{{COUNTERPARTIES}}` from `reference.*` in the state file — the
sandbox names are `SYN_VENDOR_MASTER`, `SYN_PURCHASE_ORDERS`, `SYN_POSTED_INVOICES`, `SYN_POLICIES`,
`SYN_COUNTERPARTIES`.

Classification exceptions (`route = 'EXCEPTION'` in Phase 2: `MULTI_DOCUMENT`, `PARSE_ERROR`,
`FILE_TOO_LARGE`, ...) enter as document-level failures with the route reason as `rule_id`, so every
document has a decision even if it never reached extraction.

## Step 3 — decide

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION (
    document_id      VARCHAR,
    document_type    VARCHAR,
    run_id           VARCHAR,
    experiment_id    VARCHAR,
    schema_hash      VARCHAR,
    thresholds_version VARCHAR,
    decision         VARCHAR,       -- AUTO_APPROVED | EXCEPTION | REJECTED
    blocking_failures ARRAY,        -- rule_ids
    warnings         ARRAY,
    decided_at       TIMESTAMP_LTZ
);

MERGE INTO {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION t
USING (
    SELECT c.document_id,
           c.document_type,
           :run_id AS run_id,
           :experiment_id AS experiment_id,
           MAX(r.schema_hash) AS schema_hash,
           :thresholds_version AS thresholds_version,
           CASE
               WHEN c.route = 'REJECT' THEN 'REJECTED'
               WHEN c.route = 'EXCEPTION' THEN 'EXCEPTION'
               -- Extracted but no validation rows at all is a pipeline defect, not an approval.
               WHEN COUNT(v.rule_id) = 0 THEN 'EXCEPTION'
               WHEN COUNT_IF(NOT v.passed AND v.severity = 'BLOCKING') > 0 THEN 'EXCEPTION'
               WHEN COUNT_IF(v.passed IS NULL AND v.severity = 'BLOCKING') > 0 THEN 'EXCEPTION'  -- unknown = fail
               ELSE 'AUTO_APPROVED'
           END AS decision,
           ARRAY_AGG(DISTINCT IFF(NOT COALESCE(v.passed, FALSE) AND v.severity = 'BLOCKING', v.rule_id, NULL))
             AS blocking_failures,
           ARRAY_AGG(DISTINCT IFF(NOT COALESCE(v.passed, FALSE) AND v.severity = 'WARNING', v.rule_id, NULL))
             AS warnings
    FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION c
    LEFT JOIN {{DB}}.{{SCHEMA}}.EXTRACT_RAW r
           ON r.document_id = c.document_id AND r.run_id = :run_id
    LEFT JOIN {{DB}}.{{SCHEMA}}.FIELD_VALIDATION v
           ON v.document_id = c.document_id AND v.run_id = :run_id
    WHERE c.run_id = :run_id OR r.run_id = :run_id
    GROUP BY c.document_id, c.document_type, c.route
) s
ON t.document_id = s.document_id AND t.run_id = s.run_id
WHEN MATCHED THEN UPDATE SET decision = s.decision, blocking_failures = s.blocking_failures,
                             warnings = s.warnings, decided_at = CURRENT_TIMESTAMP()
WHEN NOT MATCHED THEN INSERT
    (document_id, document_type, run_id, experiment_id, schema_hash, thresholds_version,
     decision, blocking_failures, warnings, decided_at)
VALUES (s.document_id, s.document_type, s.run_id, s.experiment_id, s.schema_hash, s.thresholds_version,
        s.decision, s.blocking_failures, s.warnings, CURRENT_TIMESTAMP());
```

Note `passed IS NULL` counts as a failure. A rule whose inputs were NULL in a way the expression did not
anticipate must never fall through to approval.

## Step 4 — post approved documents

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.INTAKE_APPROVED (
    document_id         VARCHAR,
    document_type       VARCHAR,
    run_id              VARCHAR,
    schema_hash         VARCHAR,
    vendor_id           VARCHAR,
    invoice_number_norm VARCHAR,
    received_at         TIMESTAMP_TZ,
    fields              OBJECT,        -- field_name -> normalized_value, posting fields only
    total_amount        NUMBER(18,2),
    currency            VARCHAR,
    currency_inferred   BOOLEAN,
    due_date            DATE,
    approved_at         TIMESTAMP_LTZ
);

INSERT INTO {{DB}}.{{SCHEMA}}.INTAKE_APPROVED
SELECT d.document_id, d.document_type, d.run_id, d.schema_hash,
       df.vendor_id, df.invoice_number_norm, c.received_at,
       OBJECT_AGG(ef.field_name, ef.normalized_value::VARIANT) AS fields,
       df.total_amount,
       COALESCE(df.currency, v.default_currency), df.currency IS NULL,
       df.due_date,
       CURRENT_TIMESTAMP()
FROM {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION d
JOIN DOC_FIELDS df ON df.document_id = d.document_id
JOIN {{DB}}.{{SCHEMA}}.EXTRACTED_FIELDS ef ON ef.document_id = d.document_id AND ef.run_id = d.run_id
JOIN {{DB}}.{{SCHEMA}}.FIELD_THRESHOLDS t ON t.document_type = ef.document_type AND t.field_name = ef.field_name AND t.posts
LEFT JOIN {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION c ON c.document_id = d.document_id
LEFT JOIN {{VENDOR_MASTER}} v ON v.vendor_id = df.vendor_id
WHERE d.run_id = :run_id
  AND d.decision = 'AUTO_APPROVED'            -- the ONLY path into this table
  AND ef.normalized_value IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM {{DB}}.{{SCHEMA}}.INTAKE_APPROVED a WHERE a.document_id = d.document_id)
GROUP BY d.document_id, d.document_type, d.run_id, d.schema_hash, df.vendor_id, df.invoice_number_norm,
         c.received_at, df.total_amount, df.currency, v.default_currency, df.due_date;
```

Downstream systems read from this table (or a view over it). This plugin never writes into an ERP,
claims, or CLM system. The `NOT EXISTS` makes a re-run idempotent: a document posts once.

## Step 5 — the exceptions queue

One row per document, listing every failure with what a reviewer needs to fix it, and prioritized by
money and time — the working-capital lever. An invoice with a 2/10 discount whose window closes in
three days goes above a larger invoice due in forty.

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.EXCEPTIONS_QUEUE (
    exception_id     VARCHAR DEFAULT UUID_STRING(),
    document_id      VARCHAR,
    document_type    VARCHAR,
    relative_path    VARCHAR,
    run_id           VARCHAR,
    stage            VARCHAR,       -- CLASSIFY | EXTRACT | VALIDATE
    reasons          ARRAY,         -- [{rule_id, field_name, raw_value, normalized_value, score, min_score, reference}]
    reason_count     INT,
    primary_reason   VARCHAR,
    total_amount     NUMBER(18,2),
    due_date         DATE,
    days_to_due      INT,
    priority         INT,           -- 1 = highest
    status           VARCHAR DEFAULT 'OPEN',   -- OPEN | IN_REVIEW | RESOLVED | REJECTED
    assigned_to      VARCHAR,
    resolution       VARCHAR,
    resolved_at      TIMESTAMP_LTZ,
    created_at       TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

INSERT INTO {{DB}}.{{SCHEMA}}.EXCEPTIONS_QUEUE
    (document_id, document_type, relative_path, run_id, stage, reasons, reason_count, primary_reason,
     total_amount, due_date, days_to_due, priority)
SELECT d.document_id, d.document_type, c.relative_path, d.run_id,
       IFF(c.route = 'EXCEPTION', 'CLASSIFY', IFF(df.extract_error IS NOT NULL, 'EXTRACT', 'VALIDATE')),
       ARRAY_AGG(OBJECT_CONSTRUCT_KEEP_NULL(
           'rule_id', COALESCE(v.rule_id, c.route_reason), 'field_name', v.field_name,
           'detail', v.detail)) WITHIN GROUP (ORDER BY v.rule_id),
       GREATEST(COUNT(v.rule_id), 1),
       -- The rule a reviewer should look at first: fraud and duplicates before scores.
       COALESCE(MIN_BY(v.rule_id, DECODE(v.rule_id,
                    'VENDOR_BANK_MATCH', 1, 'DUP_VENDOR_INVOICE', 2, 'POLICY_COVERS_LOSS', 3,
                    'LINES_SUM_TO_SUBTOTAL', 4, 'SUBTOTAL_TAX_TOTAL', 4, 'PO_AMOUNT_TOLERANCE', 5,
                    'VENDOR_MATCH', 6, 'NORMALIZE_FAILED', 7, 'REQUIRED_FIELD_MISSING', 8, 'LOW_SCORE', 9, 10)),
                c.route_reason),
       df.total_amount, df.due_date,
       DATEDIFF(DAY, CURRENT_DATE(), df.due_date),
       CASE
           WHEN BOOLOR_AGG(v.rule_id IN ('VENDOR_BANK_MATCH', 'DUP_VENDOR_INVOICE')) THEN 1
           WHEN DATEDIFF(DAY, CURRENT_DATE(), df.due_date) <= 5                    THEN 2
           WHEN df.total_amount >= :high_value_threshold                           THEN 3
           ELSE 4
       END
FROM {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION d
JOIN {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION c ON c.document_id = d.document_id
LEFT JOIN DOC_FIELDS df ON df.document_id = d.document_id
LEFT JOIN {{DB}}.{{SCHEMA}}.FIELD_VALIDATION v
       ON v.document_id = d.document_id AND v.run_id = d.run_id
      AND (NOT v.passed OR v.passed IS NULL) AND v.severity = 'BLOCKING'
WHERE d.run_id = :run_id AND d.decision = 'EXCEPTION'
  AND NOT EXISTS (SELECT 1 FROM {{DB}}.{{SCHEMA}}.EXCEPTIONS_QUEUE q
                  WHERE q.document_id = d.document_id AND q.run_id = d.run_id)
GROUP BY d.document_id, d.document_type, c.relative_path, d.run_id, c.route, c.route_reason,
         df.extract_error, df.total_amount, df.due_date;
```

`:high_value_threshold` is a customer policy value (ask; never assume). Priority 2 uses the due date as
a proxy for discount and late-fee windows; if `payment_terms` carries a discount (`2/10 NET 30`),
compute the discount deadline from the invoice date and use that instead — the discount window closes
long before the due date.

Rejected documents (`REJECTED`) are not reviewer work, but they are listed in a daily rejected-documents
view so an out-of-scope classification error is noticed rather than silently dropping an invoice.

### Reviewer feedback becomes labeled data

```sql
CREATE TABLE IF NOT EXISTS {{DB}}.{{SCHEMA}}.REVIEW_CORRECTIONS (
    exception_id      VARCHAR,
    document_id       VARCHAR,
    field_name        VARCHAR,
    extracted_value   VARCHAR,
    corrected_value   VARCHAR,        -- canonical form, as a reviewer keyed it
    extracted_score   FLOAT,
    reviewer          VARCHAR,
    corrected_at      TIMESTAMP_LTZ
);
```

This plugin defines the table and does not build the review UI. When a reviewer application (or a
Streamlit app, or the downstream system's own exception screen) writes corrections here, every
correction is a labeled field. `evaluate-intake-accuracy` uses them to re-fit thresholds on real
documents — which, unlike the sandbox, is the accuracy that matters. Note the bias: corrections only
exist for exceptions, so they say nothing about errors in auto-approved documents. A periodic sample
audit of auto-approved documents is still required.

## Verification at the gate

```sql
-- 1. Decision distribution.
SELECT document_type, decision, COUNT(*) AS docs,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY document_type), 1) AS pct_of_type
FROM {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION WHERE run_id = :run_id
GROUP BY 1, 2 ORDER BY 1, 2;

-- 2. Every document has exactly one decision this run.
SELECT
    (SELECT COUNT(DISTINCT document_id) FROM {{DB}}.{{SCHEMA}}.DOC_CLASSIFICATION WHERE run_id = :run_id) AS classified,
    (SELECT COUNT(*) FROM {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION WHERE run_id = :run_id)                     AS decided,
    (SELECT COUNT(*) FROM {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION WHERE run_id = :run_id AND decision IS NULL) AS null_decisions;

-- 3. Nothing approved without an AUTO_APPROVED decision. Must be zero.
SELECT COUNT(*) AS approved_without_decision
FROM {{DB}}.{{SCHEMA}}.INTAKE_APPROVED a
LEFT JOIN {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION d ON d.document_id = a.document_id AND d.run_id = a.run_id
WHERE d.decision IS DISTINCT FROM 'AUTO_APPROVED';

-- 4. No approved document failed the bank-change control. Must be zero.
SELECT COUNT(*) AS bank_change_approved
FROM {{DB}}.{{SCHEMA}}.DOCUMENT_DECISION d
JOIN {{DB}}.{{SCHEMA}}.FIELD_VALIDATION v ON v.document_id = d.document_id AND v.run_id = d.run_id
WHERE d.decision = 'AUTO_APPROVED' AND v.rule_id = 'VENDOR_BANK_MATCH' AND NOT v.passed;

-- 5. Every exception is actionable: at least one reason. Must be zero.
SELECT COUNT(*) AS exceptions_without_reason
FROM {{DB}}.{{SCHEMA}}.EXCEPTIONS_QUEUE
WHERE run_id = :run_id AND (reason_count = 0 OR primary_reason IS NULL);

-- 6. What is driving exceptions. One rule dominating means a join-key or
--    threshold problem (DIAGNOSING sections 5 and 6), not a bad corpus.
SELECT primary_reason, COUNT(*) AS docs, SUM(total_amount) AS amount_in_queue
FROM {{DB}}.{{SCHEMA}}.EXCEPTIONS_QUEUE WHERE run_id = :run_id
GROUP BY 1 ORDER BY docs DESC;
```

On the sandbox, also check every hard case landed with its expected decision **and** reason (the query
is in `evaluate-intake-accuracy`). H01 in `AUTO_APPROVED` is a stop-the-build defect.

Set `phases.validate: done` and record created objects.
