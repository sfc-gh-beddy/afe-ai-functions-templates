-- =====================================================================
-- Synthetic document-intake sandbox with a FIELD-LEVEL answer key.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}            target database
--   {{SCHEMA}}        sandbox schema (pipeline reads this)
--   {{EVAL_SCHEMA}}   answer-key schema (ONLY the accuracy harness reads this)
--   {{N_INVOICES}}    generated background invoices, e.g. 300
--   {{SEED}}          integer seed so the corpus is reproducible, e.g. 42
--
-- Design:
--   * Every generated document is RENDERED FROM A TRUTH ROW. The answer key
--     is derived from the same truth row, so it is exact by construction and
--     large enough that one miss does not move a rate by ten points.
--   * Hand-authored HARD CASES cover the failure modes a generator would
--     not produce on its own: payment-redirection, duplicates, ambiguous
--     dates, broken arithmetic, out-of-coverage claims, multi-document files.
--   * Every identifier is prefixed SYN- and every party name is fabricated.
--   * document_text is the text a digital-born PDF would carry. The
--     build-intake-test-corpus skill renders these same rows to real PDFs
--     and scans, so text-path and file-path accuracy can be compared on
--     identical content.
-- =====================================================================

USE DATABASE {{DB}};
CREATE SCHEMA IF NOT EXISTS {{SCHEMA}};
CREATE SCHEMA IF NOT EXISTS {{EVAL_SCHEMA}};
USE SCHEMA {{DB}}.{{SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. REFERENCE DATA (what validation joins to)
-- ---------------------------------------------------------------------

-- Vendor master. number_locale / date_locale record how each vendor prints
-- amounts and dates -- the only safe way to resolve '1.234' and '03/04/2026'.
-- Bank details are stored as last-4 + hash, never the full number.
CREATE OR REPLACE TABLE SYN_VENDOR_MASTER (
    vendor_id        VARCHAR,
    vendor_name      VARCHAR,
    vendor_name_norm VARCHAR,
    tax_id           VARCHAR,      -- stored digits-only; invoices print it with hyphens
    bank_last4       VARCHAR,
    bank_hash        VARCHAR,
    default_currency VARCHAR,
    country          VARCHAR,
    number_locale    VARCHAR,      -- 'DOT_DECIMAL' | 'COMMA_DECIMAL'
    date_locale      VARCHAR,      -- 'MDY' | 'DMY' | 'ISO'
    payment_terms    VARCHAR,
    status           VARCHAR
);

INSERT INTO SYN_VENDOR_MASTER VALUES
('SYN-V001','Alderbrook Office Supply LLC','ALDERBROOK OFFICE SUPPLY','900000101','4411',SHA2('SYN-ACCT-4411'),'USD','US','DOT_DECIMAL','MDY','NET 30','ACTIVE'),
('SYN-V002','Brightwater Facilities Inc','BRIGHTWATER FACILITIES','900000102','5522',SHA2('SYN-ACCT-5522'),'USD','US','DOT_DECIMAL','MDY','NET 45','ACTIVE'),
('SYN-V003','Corvane Logistik GmbH','CORVANE LOGISTIK','900000103','6633',SHA2('SYN-ACCT-6633'),'EUR','DE','COMMA_DECIMAL','DMY','NET 30','ACTIVE'),
('SYN-V004','Duskfield Components Ltd','DUSKFIELD COMPONENTS','900000104','7744',SHA2('SYN-ACCT-7744'),'GBP','GB','DOT_DECIMAL','DMY','NET 60','ACTIVE'),
('SYN-V005','Emberline Software Corp','EMBERLINE SOFTWARE','900000105','8855',SHA2('SYN-ACCT-8855'),'USD','US','DOT_DECIMAL','ISO','2/10 NET 30','ACTIVE'),
('SYN-V006','Fennick Industrial SARL','FENNICK INDUSTRIAL','900000106','9966',SHA2('SYN-ACCT-9966'),'EUR','FR','COMMA_DECIMAL','DMY','NET 30','ACTIVE'),
('SYN-V007','Glenmora Printing Co','GLENMORA PRINTING','900000107','1077',SHA2('SYN-ACCT-1077'),'USD','US','DOT_DECIMAL','MDY','NET 30','ACTIVE'),
('SYN-V008','Hollowell Catering Services','HOLLOWELL CATERING SERVICES','900000108','2188',SHA2('SYN-ACCT-2188'),'USD','US','DOT_DECIMAL','MDY','DUE ON RECEIPT','INACTIVE');

-- Purchase orders. PO master stores leading zeros; invoices often drop them.
CREATE OR REPLACE TABLE SYN_PURCHASE_ORDERS (
    po_number    VARCHAR,          -- '0045001001' style
    vendor_id    VARCHAR,
    po_amount    NUMBER(18,2),
    open_amount  NUMBER(18,2),
    currency     VARCHAR,
    status       VARCHAR
);

INSERT INTO SYN_PURCHASE_ORDERS
SELECT
    '00450' || LPAD(1000 + SEQ4(), 5, '0')                           AS po_number,
    'SYN-V00' || (1 + MOD(SEQ4(), 7))::VARCHAR                       AS vendor_id,
    ROUND(500 + UNIFORM(0, 950000, RANDOM({{SEED}})) / 100.0, 2)     AS po_amount,
    NULL                                                             AS open_amount,
    NULL                                                             AS currency,
    'OPEN'                                                           AS status
FROM TABLE(GENERATOR(ROWCOUNT => {{N_INVOICES}}));

UPDATE SYN_PURCHASE_ORDERS p
SET open_amount = p.po_amount,
    currency    = v.default_currency
FROM SYN_VENDOR_MASTER v
WHERE v.vendor_id = p.vendor_id;

-- Insurance policy register for the claims cases.
CREATE OR REPLACE TABLE SYN_POLICIES (
    policy_number  VARCHAR,
    policyholder   VARCHAR,
    effective_date DATE,
    expiry_date    DATE,
    status         VARCHAR
);

INSERT INTO SYN_POLICIES VALUES
('SYN-POL-700101','Marrow, Ines',     '2026-01-01','2026-12-31','ACTIVE'),
('SYN-POL-700102','Quillon, Bastian', '2025-07-01','2026-06-30','ACTIVE'),
('SYN-POL-700103','Tessaro, Wren',    '2025-01-01','2025-12-31','LAPSED');

-- Counterparty register for contracts.
CREATE OR REPLACE TABLE SYN_COUNTERPARTIES (
    counterparty_id   VARCHAR,
    legal_name        VARCHAR,
    legal_name_norm   VARCHAR
);

INSERT INTO SYN_COUNTERPARTIES VALUES
('SYN-CP01','Emberline Software Corp','EMBERLINE SOFTWARE'),
('SYN-CP02','Brightwater Facilities Inc','BRIGHTWATER FACILITIES');

-- ---------------------------------------------------------------------
-- 2. INVOICE TRUTH -- one row per generated invoice. Everything else
--    (document text, answer key, posted history) derives from this.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{DB}}.{{EVAL_SCHEMA}}.SYN_INVOICE_TRUTH (
    document_id     VARCHAR,
    vendor_id       VARCHAR,
    invoice_number  VARCHAR,
    invoice_date    DATE,
    due_date        DATE,
    po_number       VARCHAR,      -- NULL = invoice genuinely carries no PO
    currency        VARCHAR,
    line1_desc      VARCHAR,
    line1_qty       NUMBER(10,0),
    line1_unit      NUMBER(18,2),
    line2_desc      VARCHAR,
    line2_qty       NUMBER(10,0),
    line2_unit      NUMBER(18,2),
    subtotal_amount NUMBER(18,2),
    tax_rate        NUMBER(6,4),
    tax_amount      NUMBER(18,2),
    total_amount    NUMBER(18,2),
    payment_terms   VARCHAR,
    case_role       VARCHAR       -- GENERATED for these rows
);

INSERT INTO {{DB}}.{{EVAL_SCHEMA}}.SYN_INVOICE_TRUTH
WITH base AS (
    SELECT
        SEQ4()                                                         AS n,
        'SYN-V00' || (1 + MOD(SEQ4(), 7))::VARCHAR                     AS vendor_id,
        DATEADD(DAY, -UNIFORM(5, 120, RANDOM({{SEED}} + 1)), '2026-10-15'::DATE) AS invoice_date,
        UNIFORM(1, 40,   RANDOM({{SEED}} + 2))                         AS q1,
        UNIFORM(500, 40000, RANDOM({{SEED}} + 3)) / 100.0              AS u1,
        UNIFORM(0, 12,   RANDOM({{SEED}} + 4))                         AS q2,
        UNIFORM(500, 90000, RANDOM({{SEED}} + 5)) / 100.0              AS u2,
        UNIFORM(0, 100,  RANDOM({{SEED}} + 6))                         AS po_roll,
        ARRAY_CONSTRUCT('Paper, A4, 80gsm (box)','Toner cartridge, black','Pallet freight',
                        'Annual support subscription','Janitorial service, monthly',
                        'Bearing assembly 40mm','Catering, staff event','Brochure print run')
            [UNIFORM(0, 7, RANDOM({{SEED}} + 7))]::VARCHAR             AS d1,
        ARRAY_CONSTRUCT('Delivery surcharge','Installation labor','Spare parts kit',
                        'Onsite visit','Rush handling fee','Packaging')
            [UNIFORM(0, 5, RANDOM({{SEED}} + 8))]::VARCHAR             AS d2
    FROM TABLE(GENERATOR(ROWCOUNT => {{N_INVOICES}}))
),
priced AS (
    SELECT b.*, v.default_currency, v.payment_terms, v.country,
           ROUND(b.q1 * b.u1, 2) + ROUND(b.q2 * b.u2, 2) AS subtotal,
           CASE v.country WHEN 'DE' THEN 0.19 WHEN 'FR' THEN 0.20 WHEN 'GB' THEN 0.20 ELSE 0.0725 END AS rate
    FROM base b JOIN SYN_VENDOR_MASTER v USING (vendor_id)
)
SELECT
    'SYN-DOC-' || LPAD(n + 1, 6, '0'),
    vendor_id,
    -- Vendor-specific numbering styles, so invoice-number normalization is exercised.
    CASE MOD(n, 4)
        WHEN 0 THEN 'INV-' || LPAD(10000 + n, 6, '0')
        WHEN 1 THEN LPAD(10000 + n, 7, '0')
        WHEN 2 THEN 'A' || (10000 + n)::VARCHAR
        ELSE        '#' || (10000 + n)::VARCHAR
    END,
    invoice_date,
    DATEADD(DAY, CASE payment_terms WHEN 'NET 45' THEN 45 WHEN 'NET 60' THEN 60
                                    WHEN 'DUE ON RECEIPT' THEN 0 ELSE 30 END, invoice_date),
    -- ~70% PO-backed. PO n is generated with the same vendor formula as invoice n
    -- (1 + MOD(n, 7)), so invoice n always references its own vendor's PO and
    -- each PO backs exactly one invoice. Leading zeros are stripped on print.
    IFF(po_roll < 70, '00450' || LPAD(1000 + n, 5, '0'), NULL),
    default_currency,
    d1, q1, u1,
    IFF(q2 = 0, NULL, d2), IFF(q2 = 0, NULL, q2), IFF(q2 = 0, NULL, u2),
    subtotal,
    rate,
    ROUND(subtotal * rate, 2),
    subtotal + ROUND(subtotal * rate, 2),
    payment_terms,
    'GENERATED'
FROM priced;

-- Point the matched POs' amounts at the invoice totals (within tolerance),
-- so PO-amount validation passes on generated rows unless a case says otherwise.
UPDATE SYN_PURCHASE_ORDERS p
SET po_amount = t.total_amount, open_amount = t.total_amount
FROM (
    SELECT po_number, MAX(total_amount) AS total_amount
    FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_INVOICE_TRUTH
    WHERE po_number IS NOT NULL
    GROUP BY 1
) t
WHERE t.po_number = p.po_number;

-- ---------------------------------------------------------------------
-- 3. DOCUMENTS -- text rendered FROM the truth, in each vendor's locale.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYN_DOCUMENTS (
    document_id    VARCHAR,
    file_name      VARCHAR,       -- what the rendered file will be called
    channel        VARCHAR,       -- EMAIL | SCAN | PORTAL | SFTP
    received_at    TIMESTAMP_NTZ,
    page_count     INT,
    document_text  VARCHAR        -- unbounded; never length-constrain document text
);

-- Locale-aware renderers, kept inline so the document text and the answer
-- key cannot drift: the key holds typed truth, the text holds what a vendor
-- in that locale would actually print.
INSERT INTO SYN_DOCUMENTS
WITH t AS (
    SELECT t.*, v.vendor_name, v.tax_id, v.bank_last4, v.number_locale, v.date_locale, v.country
    FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_INVOICE_TRUTH t
    JOIN SYN_VENDOR_MASTER v USING (vendor_id)
    WHERE t.case_role = 'GENERATED'
),
fmt AS (
    SELECT t.*,
        -- amount printer
        IFF(number_locale = 'COMMA_DECIMAL',
            REPLACE(REPLACE(REPLACE(TO_VARCHAR(total_amount,    '999,999,990.00'), ',', '~'), '.', ','), '~', '.'),
            TO_VARCHAR(total_amount, '999,999,990.00'))                               AS p_total,
        IFF(number_locale = 'COMMA_DECIMAL',
            REPLACE(REPLACE(REPLACE(TO_VARCHAR(subtotal_amount, '999,999,990.00'), ',', '~'), '.', ','), '~', '.'),
            TO_VARCHAR(subtotal_amount, '999,999,990.00'))                            AS p_sub,
        IFF(number_locale = 'COMMA_DECIMAL',
            REPLACE(REPLACE(REPLACE(TO_VARCHAR(tax_amount,      '999,999,990.00'), ',', '~'), '.', ','), '~', '.'),
            TO_VARCHAR(tax_amount, '999,999,990.00'))                                 AS p_tax,
        -- date printer
        CASE date_locale WHEN 'MDY' THEN TO_VARCHAR(invoice_date, 'MM/DD/YYYY')
                         WHEN 'DMY' THEN TO_VARCHAR(invoice_date, 'DD.MM.YYYY')
                         ELSE TO_VARCHAR(invoice_date, 'YYYY-MM-DD') END                AS p_date,
        CASE date_locale WHEN 'MDY' THEN TO_VARCHAR(due_date, 'MM/DD/YYYY')
                         WHEN 'DMY' THEN TO_VARCHAR(due_date, 'DD.MM.YYYY')
                         ELSE TO_VARCHAR(due_date, 'YYYY-MM-DD') END                    AS p_due,
        -- tax id printed with hyphens; master stores digits only
        SUBSTR(tax_id, 1, 2) || '-' || SUBSTR(tax_id, 3)                                AS p_tax_id
    FROM t
)
SELECT
    document_id,
    REPLACE(document_id, 'SYN-DOC-', 'inv_') || '.pdf',
    ARRAY_CONSTRUCT('EMAIL','EMAIL','PORTAL','SCAN','SFTP')[UNIFORM(0, 4, RANDOM({{SEED}} + 9))]::VARCHAR,
    DATEADD(HOUR, UNIFORM(2, 72, RANDOM({{SEED}} + 10)), invoice_date::TIMESTAMP_NTZ),
    1,
    'INVOICE\n'
    || vendor_name || '\nTax ID: ' || p_tax_id || '\n\n'
    || 'Invoice No: ' || invoice_number || '\n'
    || 'Invoice Date: ' || p_date || '\n'
    || 'Due Date: ' || p_due || '\n'
    || IFF(po_number IS NOT NULL, 'PO Number: ' || LTRIM(po_number, '0') || '\n', '')
    || 'Terms: ' || payment_terms || '\n'
    || 'Bill To: SYN Demo Buyer Co, Accounts Payable\n\n'
    || 'Description | Qty | Unit Price | Amount\n'
    || line1_desc || ' | ' || line1_qty || ' | ' || TO_VARCHAR(line1_unit, '999990.00') || ' | '
    || TO_VARCHAR(ROUND(line1_qty * line1_unit, 2), '9999990.00') || '\n'
    || IFF(line2_desc IS NOT NULL,
           line2_desc || ' | ' || line2_qty || ' | ' || TO_VARCHAR(line2_unit, '999990.00') || ' | '
           || TO_VARCHAR(ROUND(line2_qty * line2_unit, 2), '9999990.00') || '\n', '')
    || '\nSubtotal: ' || TRIM(p_sub) || '\n'
    || 'Tax (' || TO_VARCHAR(tax_rate * 100, '90.00') || '%): ' || TRIM(p_tax) || '\n'
    || 'TOTAL DUE (' || currency || '): ' || TRIM(p_total) || '\n\n'
    || 'Remit to account ending ' || bank_last4 || '\n'
    || 'Thank you for your business.'
FROM fmt;

-- ---------------------------------------------------------------------
-- 4. HARD CASES -- hand-authored. Each one exists to catch a specific
--    failure mode. Expected decision is recorded in the document key.
-- ---------------------------------------------------------------------
INSERT INTO SYN_DOCUMENTS (document_id, file_name, channel, received_at, page_count, document_text) VALUES
-- H01 Payment redirection: remit account differs from vendor master. MUST be EXCEPTION.
('SYN-DOC-H01','hard_bank_change.pdf','EMAIL','2026-10-01 09:12:00',1,
 'INVOICE\nBrightwater Facilities Inc\nTax ID: 90-0000102\n\nInvoice No: BW-77812\nInvoice Date: 09/28/2026\nDue Date: 11/12/2026\nPO Number: 4501001\nTerms: NET 45\n\nDescription | Qty | Unit Price | Amount\nJanitorial service, monthly | 1 | 4200.00 | 4200.00\n\nSubtotal: 4,200.00\nTax (7.25%): 304.50\nTOTAL DUE (USD): 4,504.50\n\nIMPORTANT: Our banking details have changed. Please remit to account ending 0193 effective immediately.'),
-- H02 Duplicate of an already-posted invoice, printed with a different number style. MUST be EXCEPTION.
('SYN-DOC-H02','hard_duplicate.pdf','PORTAL','2026-10-02 14:03:00',1,
 'INVOICE\nAlderbrook Office Supply LLC\nTax ID: 90-0000101\n\nInvoice No: 0010000\nInvoice Date: 08/14/2026\nDue Date: 09/13/2026\nTerms: NET 30\n\nDescription | Qty | Unit Price | Amount\nPaper, A4, 80gsm (box) | 20 | 38.50 | 770.00\n\nSubtotal: 770.00\nTax (7.25%): 55.83\nTOTAL DUE (USD): 825.83\n\nRemit to account ending 4411\nSECOND NOTICE'),
-- H03 Arithmetic does not close: lines sum to 1,950.00 but subtotal says 1,590.00. MUST be EXCEPTION.
('SYN-DOC-H03','hard_bad_math.pdf','EMAIL','2026-10-03 08:00:00',1,
 'INVOICE\nGlenmora Printing Co\nTax ID: 90-0000107\n\nInvoice No: GP-3310\nInvoice Date: 10/01/2026\nDue Date: 10/31/2026\nTerms: NET 30\n\nDescription | Qty | Unit Price | Amount\nBrochure print run | 1 | 1500.00 | 1500.00\nRush handling fee | 1 | 450.00 | 450.00\n\nSubtotal: 1,590.00\nTax (7.25%): 115.28\nTOTAL DUE (USD): 1,705.28\n\nRemit to account ending 1077'),
-- H04 Ambiguous date, resolvable ONLY via vendor locale (DMY). 03.04.2026 = 3 April.
--     Expected invoice_date 2026-04-03. A pipeline that guesses MDY gets 4 March.
('SYN-DOC-H04','hard_ambiguous_date.pdf','SFTP','2026-04-06 10:00:00',1,
 'RECHNUNG / INVOICE\nCorvane Logistik GmbH\nUSt-IdNr / Tax ID: 90-0000103\n\nRechnungsnr / Invoice No: CL-2026-0412\nDatum / Date: 03.04.2026\nFaellig / Due: 03.05.2026\nTerms: NET 30\n\nBeschreibung | Menge | Preis | Betrag\nPallet freight | 3 | 410,00 | 1.230,00\n\nZwischensumme / Subtotal: 1.230,00\nMwSt 19%: 233,70\nGESAMT / TOTAL (EUR): 1.463,70\n\nRemit to account ending 6633'),
-- H05 Credit note with parenthesized negative. Type must be credit_note, total -312.00.
('SYN-DOC-H05','hard_credit_note.pdf','EMAIL','2026-10-04 11:30:00',1,
 'CREDIT NOTE\nEmberline Software Corp\nTax ID: 90-0000105\n\nCredit Note No: CN-0091\nReferences Invoice: INV-010004\nDate: 2026-10-03\n\nDescription | Amount\nService credit, outage 2026-09-12 | (312.00)\n\nTOTAL CREDIT (USD): (312.00)\n\nThis credit will be applied to your next invoice.'),
-- H06 Unknown vendor -- not in master. MUST be EXCEPTION (VENDOR_MATCH).
('SYN-DOC-H06','hard_unknown_vendor.pdf','EMAIL','2026-10-05 16:45:00',1,
 'INVOICE\nKestrel Ridge Consulting Partners\nTax ID: 90-0000999\n\nInvoice No: KR-1001\nInvoice Date: 10/02/2026\nDue Date: 11/01/2026\nTerms: NET 30\n\nDescription | Qty | Unit Price | Amount\nAdvisory services, September | 1 | 9800.00 | 9800.00\n\nSubtotal: 9,800.00\nTax (0.00%): 0.00\nTOTAL DUE (USD): 9,800.00\n\nRemit to account ending 5050'),
-- H07 PO amount variance beyond tolerance: PO 0045001003 exists; invoice far exceeds it. EXCEPTION.
('SYN-DOC-H07','hard_po_variance.pdf','PORTAL','2026-10-06 09:00:00',1,
 'INVOICE\nDuskfield Components Ltd\nTax ID: 90-0000104\n\nInvoice No: DC/88213\nInvoice Date: 02/10/2026\nDue Date: 01/12/2026\nPO Number: 45001003\nTerms: NET 60\n\nDescription | Qty | Unit Price | Amount\nBearing assembly 40mm | 900 | 41.20 | 37080.00\n\nSubtotal: 37,080.00\nVAT (20%): 7,416.00\nTOTAL DUE (GBP): 44,496.00\n\nRemit to account ending 7744'),
-- H08 Inactive vendor. EXCEPTION (VENDOR_ACTIVE).
('SYN-DOC-H08','hard_inactive_vendor.pdf','EMAIL','2026-10-07 12:00:00',1,
 'INVOICE\nHollowell Catering Services\nTax ID: 90-0000108\n\nInvoice No: HC-551\nInvoice Date: 10/06/2026\nDue Date: 10/06/2026\nTerms: DUE ON RECEIPT\n\nDescription | Qty | Unit Price | Amount\nCatering, staff event | 1 | 1250.00 | 1250.00\n\nSubtotal: 1,250.00\nTax (7.25%): 90.63\nTOTAL DUE (USD): 1,340.63\n\nRemit to account ending 2188'),
-- H09 Clean non-PO invoice. po_number is NOT_PRESENT and must NOT be an error. Expected AUTO_APPROVED.
('SYN-DOC-H09','hard_non_po_clean.pdf','EMAIL','2026-10-08 08:30:00',1,
 'INVOICE\nEmberline Software Corp\nTax ID: 90-0000105\n\nInvoice No: INV-020001\nInvoice Date: 2026-10-07\nDue Date: 2026-11-06\nTerms: 2/10 NET 30\n\nDescription | Qty | Unit Price | Amount\nAnnual support subscription | 1 | 2400.00 | 2400.00\n\nSubtotal: 2,400.00\nTax (7.25%): 174.00\nTOTAL DUE (USD): 2,574.00\n\nRemit to account ending 8855'),
-- H10 Multi-document file: invoice followed by a packing slip. Expected EXCEPTION (MULTI_DOCUMENT).
('SYN-DOC-H10','hard_multi_document.pdf','SCAN','2026-10-09 15:20:00',2,
 'INVOICE\nAlderbrook Office Supply LLC\nTax ID: 90-0000101\n\nInvoice No: INV-030777\nInvoice Date: 10/08/2026\nDue Date: 11/07/2026\nTerms: NET 30\n\nDescription | Qty | Unit Price | Amount\nToner cartridge, black | 6 | 89.00 | 534.00\n\nSubtotal: 534.00\nTax (7.25%): 38.72\nTOTAL DUE (USD): 572.72\n\nRemit to account ending 4411\n\f\nPACKING SLIP\nShip To: SYN Demo Buyer Co, Receiving Dock 2\nOrder Ref: INV-030777\nItems shipped: Toner cartridge, black x 6\nCarrier: SYN Freight, tracking SYN-TRK-00912\nReceived by: ____________'),
-- H11 Contract. Typed contract fields; NOT an invoice despite containing amounts.
('SYN-DOC-H11','contract_msa_emberline.pdf','EMAIL','2026-09-15 10:00:00',4,
 'MASTER SERVICES AGREEMENT\n\nThis Master Services Agreement (the "Agreement") is entered into as of September 1, 2026 (the "Effective Date") by and between SYN Demo Buyer Co ("Customer") and Emberline Software Corp ("Provider").\n\n1. TERM. The initial term is thirty-six (36) months from the Effective Date and renews automatically for successive twelve (12) month periods unless either party gives written notice of non-renewal at least ninety (90) days before the end of the then-current term.\n\n2. FEES. Customer shall pay annual fees of USD 120,000.00, invoiced annually in advance, payable net thirty (30) days.\n\n3. LIMITATION OF LIABILITY. Each party''s aggregate liability shall not exceed USD 250,000.00.\n\n4. TERMINATION FOR CONVENIENCE. Customer may terminate on sixty (60) days written notice.\n\n5. GOVERNING LAW. This Agreement is governed by the laws of the State of Delaware.\n\nSigned for Customer: ______  Signed for Provider: ______'),
-- H12 Insurance claim, valid: loss date within an ACTIVE policy. Expected AUTO_APPROVED.
('SYN-DOC-H12','claim_valid.pdf','PORTAL','2026-10-10 09:40:00',2,
 'PROPERTY LOSS NOTICE - CLAIM FORM\nPolicy Number: SYN-POL-700101\nPolicyholder Name: Ines Marrow\nDate of Loss: 10/04/2026\nTime of Loss: approx. 02:00\nType of Loss: Water damage - burst pipe\nLoss Location: Unit 4, 18 Synthetic Lane\nEstimated Loss Amount (USD): 6,850.00\nPolice/Fire Report Number: N/A\nDescription: Pipe in ceiling burst overnight; kitchen ceiling and flooring damaged.\nClaimant Signature: on file   Date Signed: 10/09/2026'),
-- H13 Insurance claim, loss date outside coverage (policy lapsed 2025-12-31). EXCEPTION (POLICY_COVERS_LOSS).
('SYN-DOC-H13','claim_out_of_coverage.pdf','PORTAL','2026-10-11 13:15:00',2,
 'PROPERTY LOSS NOTICE - CLAIM FORM\nPolicy Number: SYN-POL-700103\nPolicyholder Name: Wren Tessaro\nDate of Loss: 09/20/2026\nType of Loss: Theft - bicycle from garage\nLoss Location: 7 Synthetic Court\nEstimated Loss Amount (USD): 1,900.00\nPolice/Fire Report Number: SYN-PR-55102\nDescription: Garage entered while owner away; bicycle and tools taken.\nClaimant Signature: on file   Date Signed: 09/22/2026'),
-- H14 W-9 style tax form. Typed; TIN must be stored masked downstream.
('SYN-DOC-H14','w9_glenmora.pdf','EMAIL','2026-09-01 08:00:00',1,
 'Form W-9 (SYNTHETIC SAMPLE)\nRequest for Taxpayer Identification Number and Certification\n1 Name: Glenmora Printing Co\n2 Business name: Glenmora Printing Co\n3 Federal tax classification: C Corporation\n5 Address: 22 Synthetic Ave\n6 City, state, ZIP: Exampleton, ZZ 00000\nPart I Taxpayer Identification Number: Employer identification number 90-0000107\nPart II Certification: signed\nDate: 08/29/2026'),
-- H15 Out of scope: a vendor newsletter. Expected REJECTED as other_document.
('SYN-DOC-H15','vendor_newsletter.pdf','EMAIL','2026-10-12 07:00:00',1,
 'BRIGHTWATER FACILITIES - AUTUMN NEWSLETTER\nOur team is growing! This quarter we welcomed six new site supervisors and expanded weekend coverage. Tips for winterizing your building: check seals, service boilers early, and schedule gutter clearing. We value your partnership. No action is required.'),
-- H16 Exact-file duplicate of a generated invoice (same bytes). Expected REJECTED (DUP_FILE_HASH).
--     Text copied at load time below.
('SYN-DOC-H16','inv_000002_resend.pdf','EMAIL','2026-10-13 09:00:00',1, NULL);

UPDATE SYN_DOCUMENTS
SET document_text = (SELECT document_text FROM SYN_DOCUMENTS WHERE document_id = 'SYN-DOC-000002')
WHERE document_id = 'SYN-DOC-H16';

-- Already-posted invoice history. Includes the generated SYN-DOC-000001 (number
-- 'INV-010000') so H02 (printed '0010000') must be caught by NORMALIZED match.
CREATE OR REPLACE TABLE SYN_POSTED_INVOICES (
    vendor_id           VARCHAR,
    invoice_number      VARCHAR,
    invoice_number_norm VARCHAR,
    invoice_date        DATE,
    total_amount        NUMBER(18,2),
    posted_at           TIMESTAMP_NTZ
);

INSERT INTO SYN_POSTED_INVOICES
SELECT vendor_id, invoice_number,
       -- Same normalization the pipeline uses (NORM_DOC_NUMBER in extract-document-fields).
       LTRIM(REGEXP_REPLACE(REGEXP_REPLACE(UPPER(TRIM(invoice_number)),
             '^((INVOICE|INV|NUMBER|NO|NR)([-#:.]|\\s)+)+', ''), '[^A-Z0-9]', ''), '0'),
       invoice_date, total_amount, '2026-08-20 10:00:00'
FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_INVOICE_TRUTH
WHERE document_id = 'SYN-DOC-000001';
-- SYN-DOC-000001 is vendor SYN-V001 (1 + MOD(0, 7)), number 'INV-010000' -> '10000'.
-- H02 prints '0010000' for the same vendor -> '10000'. The business-level duplicate
-- key is (vendor, normalized invoice number); total is reviewer context only, since
-- a resent invoice with late fees added is still the same invoice.

-- ---------------------------------------------------------------------
-- 5. ANSWER KEYS -- in {{EVAL_SCHEMA}}. Never read by the pipeline.
-- ---------------------------------------------------------------------

-- 5a. Document-level key: expected type and expected decision.
CREATE OR REPLACE TABLE {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY (
    document_id        VARCHAR,
    expected_type      VARCHAR,
    expected_decision  VARCHAR,     -- AUTO_APPROVED | EXCEPTION | REJECTED
    expected_reason    VARCHAR,     -- rule_id that should fire, for EXCEPTION / REJECTED
    case_role          VARCHAR,     -- GENERATED | HARD_CASE
    note               VARCHAR,
    corpus_source      VARCHAR      -- NULL for sandbox rows; set by build-intake-test-corpus
);

INSERT INTO {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY
SELECT document_id, 'invoice',
       -- Generated invoices are designed to pass every rule. Vendor V008 is INACTIVE,
       -- but the generator only uses V001-V007, so none hit that rule.
       'AUTO_APPROVED', NULL, 'GENERATED', NULL, NULL
FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_INVOICE_TRUTH
WHERE case_role = 'GENERATED';

-- SYN-DOC-000001 is the already-posted original; the pipeline sees it again
-- as a document, so it is ALSO a duplicate of history. Expected EXCEPTION.
UPDATE {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY
SET expected_decision = 'EXCEPTION', expected_reason = 'DUP_VENDOR_INVOICE',
    note = 'Original of an invoice already in posted history'
WHERE document_id = 'SYN-DOC-000001';

INSERT INTO {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY VALUES
('SYN-DOC-H01','invoice','EXCEPTION','VENDOR_BANK_MATCH','HARD_CASE','Payment redirection signature',NULL),
('SYN-DOC-H02','invoice','EXCEPTION','DUP_VENDOR_INVOICE','HARD_CASE','0010000 normalizes to the posted INV-010000',NULL),
('SYN-DOC-H03','invoice','EXCEPTION','LINES_SUM_TO_SUBTOTAL','HARD_CASE','Lines 1,950.00 vs subtotal 1,590.00',NULL),
('SYN-DOC-H04','invoice','AUTO_APPROVED',NULL,'HARD_CASE','Ambiguous 03.04.2026 resolved by vendor DMY locale to 2026-04-03; if the pipeline lacks locale it must be EXCEPTION, never a guess',NULL),
('SYN-DOC-H05','credit_note','AUTO_APPROVED',NULL,'HARD_CASE','Parenthesized negative total -312.00',NULL),
('SYN-DOC-H06','invoice','EXCEPTION','VENDOR_MATCH','HARD_CASE','Vendor not in master',NULL),
('SYN-DOC-H07','invoice','EXCEPTION','PO_AMOUNT_TOLERANCE','HARD_CASE','Invoice total far above PO amount',NULL),
('SYN-DOC-H08','invoice','EXCEPTION','VENDOR_ACTIVE','HARD_CASE','Vendor status INACTIVE',NULL),
('SYN-DOC-H09','invoice','AUTO_APPROVED',NULL,'HARD_CASE','Non-PO invoice; missing PO is NOT_PRESENT, not an error',NULL),
('SYN-DOC-H10','invoice','EXCEPTION','MULTI_DOCUMENT','HARD_CASE','Invoice plus packing slip in one file',NULL),
('SYN-DOC-H11','contract','AUTO_APPROVED',NULL,'HARD_CASE','Contract fields extracted; counterparty matches register',NULL),
('SYN-DOC-H12','insurance_claim_form','AUTO_APPROVED',NULL,'HARD_CASE','Loss date within active policy',NULL),
('SYN-DOC-H13','insurance_claim_form','EXCEPTION','POLICY_COVERS_LOSS','HARD_CASE','Policy lapsed before loss date',NULL),
('SYN-DOC-H14','w9_tax_form','AUTO_APPROVED',NULL,'HARD_CASE','Tax form; TIN matches vendor master',NULL),
('SYN-DOC-H15','other_document','REJECTED','OUT_OF_SCOPE','HARD_CASE','Newsletter',NULL),
('SYN-DOC-H16','invoice','REJECTED','DUP_FILE_HASH','HARD_CASE','Byte-identical resend of SYN-DOC-000002',NULL);

-- 5b. Field-level key. One row per (document, field). expected_value holds the
--     CANONICAL normalized form: amounts as fixed 2-dp strings, dates ISO,
--     identifiers as printed (the harness applies the shared normalizer to both
--     sides before comparing). status NOT_PRESENT means the field is genuinely
--     absent from the document and a NULL extraction is CORRECT.
--     posts = TRUE marks fields a downstream system consumes; a wrong value in a
--     posting field on an AUTO_APPROVED document is a false STP.
CREATE OR REPLACE TABLE {{DB}}.{{EVAL_SCHEMA}}.SYN_FIELD_ANSWER_KEY (
    document_id     VARCHAR,
    document_type   VARCHAR,
    field_name      VARCHAR,
    expected_value  VARCHAR,
    expected_status VARCHAR,       -- PRESENT | NOT_PRESENT
    posts           BOOLEAN,
    corpus_source   VARCHAR        -- NULL for sandbox rows
);

-- Generated invoices: derived from truth, so exact by construction.
INSERT INTO {{DB}}.{{EVAL_SCHEMA}}.SYN_FIELD_ANSWER_KEY
SELECT t.document_id, 'invoice',
       f.value:f::STRING,
       f.value:v::STRING,                     -- OBJECT_CONSTRUCT drops NULL values, so absent => NULL here
       IFF(f.value:v IS NULL, 'NOT_PRESENT', 'PRESENT'),
       f.value:p::BOOLEAN,
       NULL
FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_INVOICE_TRUTH t
JOIN SYN_VENDOR_MASTER v USING (vendor_id),
LATERAL FLATTEN(input => ARRAY_CONSTRUCT(
    OBJECT_CONSTRUCT('f', 'invoice_number',      'v', t.invoice_number,                                       'p', TRUE),
    OBJECT_CONSTRUCT('f', 'invoice_date',        'v', TO_VARCHAR(t.invoice_date, 'YYYY-MM-DD'),               'p', TRUE),
    OBJECT_CONSTRUCT('f', 'due_date',            'v', TO_VARCHAR(t.due_date, 'YYYY-MM-DD'),                   'p', TRUE),
    OBJECT_CONSTRUCT('f', 'vendor_name',         'v', v.vendor_name,                                          'p', TRUE),
    OBJECT_CONSTRUCT('f', 'vendor_tax_id',       'v', SUBSTR(v.tax_id, 1, 2) || '-' || SUBSTR(v.tax_id, 3),   'p', FALSE),
    OBJECT_CONSTRUCT('f', 'po_number',           'v', LTRIM(t.po_number, '0'),                                'p', TRUE),
    OBJECT_CONSTRUCT('f', 'currency',            'v', t.currency,                                             'p', TRUE),
    OBJECT_CONSTRUCT('f', 'subtotal_amount',     'v', TO_VARCHAR(t.subtotal_amount, 'FM999999990.00'),        'p', FALSE),
    OBJECT_CONSTRUCT('f', 'tax_amount',          'v', TO_VARCHAR(t.tax_amount,      'FM999999990.00'),        'p', TRUE),
    OBJECT_CONSTRUCT('f', 'total_amount',        'v', TO_VARCHAR(t.total_amount,    'FM999999990.00'),        'p', TRUE),
    OBJECT_CONSTRUCT('f', 'payment_terms',       'v', t.payment_terms,                                        'p', FALSE),
    OBJECT_CONSTRUCT('f', 'remit_account_last4', 'v', v.bank_last4,                                           'p', FALSE)
)) f
WHERE t.case_role = 'GENERATED';

-- Hard cases: hand-authored keys.
INSERT INTO {{DB}}.{{EVAL_SCHEMA}}.SYN_FIELD_ANSWER_KEY VALUES
('SYN-DOC-H01','invoice','invoice_number','BW-77812','PRESENT',TRUE,NULL),
('SYN-DOC-H01','invoice','invoice_date','2026-09-28','PRESENT',TRUE,NULL),
('SYN-DOC-H01','invoice','total_amount','4504.50','PRESENT',TRUE,NULL),
('SYN-DOC-H01','invoice','remit_account_last4','0193','PRESENT',FALSE,NULL),
('SYN-DOC-H01','invoice','vendor_name','Brightwater Facilities Inc','PRESENT',TRUE,NULL),
('SYN-DOC-H02','invoice','invoice_number','0010000','PRESENT',TRUE,NULL),
('SYN-DOC-H02','invoice','total_amount','825.83','PRESENT',TRUE,NULL),
('SYN-DOC-H02','invoice','po_number',NULL,'NOT_PRESENT',TRUE,NULL),
('SYN-DOC-H03','invoice','subtotal_amount','1590.00','PRESENT',FALSE,NULL),
('SYN-DOC-H03','invoice','total_amount','1705.28','PRESENT',TRUE,NULL),
('SYN-DOC-H04','invoice','invoice_number','CL-2026-0412','PRESENT',TRUE,NULL),
('SYN-DOC-H04','invoice','invoice_date','2026-04-03','PRESENT',TRUE,NULL),
('SYN-DOC-H04','invoice','due_date','2026-05-03','PRESENT',TRUE,NULL),
('SYN-DOC-H04','invoice','currency','EUR','PRESENT',TRUE,NULL),
('SYN-DOC-H04','invoice','subtotal_amount','1230.00','PRESENT',FALSE,NULL),
('SYN-DOC-H04','invoice','tax_amount','233.70','PRESENT',TRUE,NULL),
('SYN-DOC-H04','invoice','total_amount','1463.70','PRESENT',TRUE,NULL),
('SYN-DOC-H05','credit_note','credit_note_number','CN-0091','PRESENT',TRUE,NULL),
('SYN-DOC-H05','credit_note','referenced_invoice_number','INV-010004','PRESENT',TRUE,NULL),
('SYN-DOC-H05','credit_note','total_amount','-312.00','PRESENT',TRUE,NULL),
('SYN-DOC-H05','credit_note','issue_date','2026-10-03','PRESENT',TRUE,NULL),
('SYN-DOC-H06','invoice','vendor_name','Kestrel Ridge Consulting Partners','PRESENT',TRUE,NULL),
('SYN-DOC-H06','invoice','total_amount','9800.00','PRESENT',TRUE,NULL),
('SYN-DOC-H07','invoice','po_number','45001003','PRESENT',TRUE,NULL),
('SYN-DOC-H07','invoice','invoice_date','2026-10-02','PRESENT',TRUE,NULL),
('SYN-DOC-H07','invoice','due_date','2026-12-01','PRESENT',TRUE,NULL),
('SYN-DOC-H07','invoice','total_amount','44496.00','PRESENT',TRUE,NULL),
('SYN-DOC-H07','invoice','currency','GBP','PRESENT',TRUE,NULL),
('SYN-DOC-H08','invoice','total_amount','1340.63','PRESENT',TRUE,NULL),
('SYN-DOC-H09','invoice','invoice_number','INV-020001','PRESENT',TRUE,NULL),
('SYN-DOC-H09','invoice','invoice_date','2026-10-07','PRESENT',TRUE,NULL),
('SYN-DOC-H09','invoice','due_date','2026-11-06','PRESENT',TRUE,NULL),
('SYN-DOC-H09','invoice','po_number',NULL,'NOT_PRESENT',TRUE,NULL),
('SYN-DOC-H09','invoice','currency','USD','PRESENT',TRUE,NULL),
('SYN-DOC-H09','invoice','total_amount','2574.00','PRESENT',TRUE,NULL),
('SYN-DOC-H09','invoice','payment_terms','2/10 NET 30','PRESENT',FALSE,NULL),
('SYN-DOC-H10','invoice','invoice_number','INV-030777','PRESENT',TRUE,NULL),
('SYN-DOC-H10','invoice','total_amount','572.72','PRESENT',TRUE,NULL),
('SYN-DOC-H11','contract','counterparty_name','Emberline Software Corp','PRESENT',TRUE,NULL),
('SYN-DOC-H11','contract','effective_date','2026-09-01','PRESENT',TRUE,NULL),
('SYN-DOC-H11','contract','initial_term_months','36','PRESENT',TRUE,NULL),
('SYN-DOC-H11','contract','auto_renewal','YES','PRESENT',TRUE,NULL),
('SYN-DOC-H11','contract','notice_period_days','90','PRESENT',TRUE,NULL),
('SYN-DOC-H11','contract','annual_fee_amount','120000.00','PRESENT',TRUE,NULL),
('SYN-DOC-H11','contract','liability_cap_amount','250000.00','PRESENT',TRUE,NULL),
('SYN-DOC-H11','contract','governing_law','Delaware','PRESENT',FALSE,NULL),
('SYN-DOC-H11','contract','currency','USD','PRESENT',TRUE,NULL),
('SYN-DOC-H12','insurance_claim_form','policy_number','SYN-POL-700101','PRESENT',TRUE,NULL),
('SYN-DOC-H12','insurance_claim_form','loss_date','2026-10-04','PRESENT',TRUE,NULL),
('SYN-DOC-H12','insurance_claim_form','loss_type','Water damage - burst pipe','PRESENT',FALSE,NULL),
('SYN-DOC-H12','insurance_claim_form','estimated_loss_amount','6850.00','PRESENT',TRUE,NULL),
('SYN-DOC-H12','insurance_claim_form','police_report_number',NULL,'NOT_PRESENT',FALSE,NULL),
('SYN-DOC-H13','insurance_claim_form','policy_number','SYN-POL-700103','PRESENT',TRUE,NULL),
('SYN-DOC-H13','insurance_claim_form','loss_date','2026-09-20','PRESENT',TRUE,NULL),
('SYN-DOC-H13','insurance_claim_form','estimated_loss_amount','1900.00','PRESENT',TRUE,NULL),
('SYN-DOC-H13','insurance_claim_form','police_report_number','SYN-PR-55102','PRESENT',FALSE,NULL),
('SYN-DOC-H14','w9_tax_form','legal_name','Glenmora Printing Co','PRESENT',TRUE,NULL),
('SYN-DOC-H14','w9_tax_form','tin','90-0000107','PRESENT',TRUE,NULL),
('SYN-DOC-H14','w9_tax_form','tax_classification','C Corporation','PRESENT',FALSE,NULL);

-- ---------------------------------------------------------------------
-- 6. VERIFICATION -- run and show results before marking the phase done.
-- ---------------------------------------------------------------------

-- 6.1 Every document has a doc-level key, and every key has a document.
SELECT 'doc_without_key' AS issue, COUNT(*) FROM SYN_DOCUMENTS d
LEFT JOIN {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY k USING (document_id) WHERE k.document_id IS NULL
UNION ALL
SELECT 'key_without_doc', COUNT(*) FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY k
LEFT JOIN SYN_DOCUMENTS d USING (document_id) WHERE d.document_id IS NULL;
-- Both zero.

-- 6.2 Generated arithmetic closes in the truth (a seed bug here would make
--     correct extractions fail LINES_SUM_TO_SUBTOTAL).
SELECT COUNT(*) AS truth_rows_failing_math
FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_INVOICE_TRUTH
WHERE case_role = 'GENERATED'
  AND ( ABS(ROUND(line1_qty * line1_unit, 2) + COALESCE(ROUND(line2_qty * line2_unit, 2), 0) - subtotal_amount) > 0.005
     OR ABS(subtotal_amount + tax_amount - total_amount) > 0.005 );
-- Zero.

-- 6.3 The rendered text actually contains each PRESENT expected value in its
--     printed form for a sample of fields that print verbatim. Catches a
--     renderer/key drift before it reads as an extraction failure.
SELECT k.field_name, COUNT(*) AS keyed, COUNT_IF(CONTAINS(d.document_text, k.expected_value)) AS found_verbatim
FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_FIELD_ANSWER_KEY k
JOIN SYN_DOCUMENTS d USING (document_id)
WHERE k.expected_status = 'PRESENT'
  AND k.field_name IN ('invoice_number', 'vendor_name', 'vendor_tax_id', 'currency', 'payment_terms', 'po_number')
GROUP BY 1 ORDER BY 1;
-- keyed = found_verbatim for every row.

-- 6.4 Decision mix -- the harness needs all three outcomes.
SELECT case_role, expected_decision, COUNT(*) AS docs
FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_DOC_ANSWER_KEY
GROUP BY 1, 2 ORDER BY 1, 2;

-- 6.5 Locale coverage -- both amount conventions and all three date
--     conventions must be present, or normalization is untested.
SELECT v.number_locale, v.date_locale, COUNT(*) AS invoices
FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_INVOICE_TRUTH t JOIN SYN_VENDOR_MASTER v USING (vendor_id)
GROUP BY 1, 2 ORDER BY 1, 2;

-- 6.6 Ambiguous dates exist in the generated set (day <= 12 under DMY or MDY).
SELECT COUNT(*) AS generated_ambiguous_dates
FROM {{DB}}.{{EVAL_SCHEMA}}.SYN_INVOICE_TRUTH t JOIN SYN_VENDOR_MASTER v USING (vendor_id)
WHERE v.date_locale IN ('MDY', 'DMY') AND DAY(t.invoice_date) <= 12 AND DAY(t.invoice_date) <> MONTH(t.invoice_date);
-- Expect > 0. These must resolve via vendor locale, not guessing.

-- 6.7 Duplicate controls are wired.
SELECT
    (SELECT COUNT(*) FROM SYN_POSTED_INVOICES)                                             AS posted_history_rows,
    (SELECT COUNT(*) FROM SYN_DOCUMENTS a JOIN SYN_DOCUMENTS b
        ON a.document_text = b.document_text AND a.document_id < b.document_id)            AS identical_text_pairs;
-- posted_history_rows >= 1, identical_text_pairs >= 1.
