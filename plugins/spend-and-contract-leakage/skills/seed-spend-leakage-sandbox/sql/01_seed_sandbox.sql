-- =====================================================================
-- Synthetic contract, PO and invoice corpus with planted leakage and a
-- labeled answer key, for spend-and-contract-leakage development and
-- accuracy measurement.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}            target database
--   {{SCHEMA}}        target schema for sandbox data
--   {{EVAL_SCHEMA}}   separate schema for the answer keys (quarantine)
--
-- The corpus is anchored to a fixed as-of date of 2026-09-30. Every
-- renewal-deadline expectation in the answer key is computed against
-- that date. If you change it, the renewal findings in
-- SYNTH_LEAKAGE_KEY must be recomputed (see 02_verify_seed.sql).
--
-- All identifiers are prefixed SYN- and every company name is a
-- fabricated sample name. The buyer is "Synthetic Holdings Corp."
-- Nothing here resembles a real counterparty, price list or contract.
--
-- The answer keys land in {{EVAL_SCHEMA}}, NOT {{SCHEMA}}. Nothing in
-- the pipeline may read them. Only evaluate-leakage-accuracy reads them.
-- =====================================================================

USE DATABASE {{DB}};
CREATE SCHEMA IF NOT EXISTS {{SCHEMA}};
CREATE SCHEMA IF NOT EXISTS {{EVAL_SCHEMA}};
USE SCHEMA {{DB}}.{{SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Vendor master (ERP side). vendor_name is the ERP spelling, which
--    deliberately differs from the contract spelling for SYN-V008 so
--    contract-to-vendor linking has to do real normalisation.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_VENDORS (
    vendor_id        VARCHAR(20),
    vendor_name      VARCHAR,
    spend_category   VARCHAR,
    country_code     VARCHAR(2),
    default_currency VARCHAR(3)
);

INSERT INTO SYNTH_VENDORS VALUES
    ('SYN-V001', 'Northwind Facility Services LLC', 'Facilities',          'US', 'USD'),
    ('SYN-V002', 'Contoso Industrial Supply Inc',   'MRO',                 'US', 'USD'),
    ('SYN-V003', 'Fabrikam Cloud Software Inc',     'Software',            'US', 'USD'),
    ('SYN-V004', 'Litware Lab Equipment Co',        'Capital Equipment',   'US', 'USD'),
    ('SYN-V005', 'Adventure Logistics Partners',    'Freight',             'US', 'USD'),
    ('SYN-V006', 'Tailspin Temporary Staffing',     'Contingent Labor',    'US', 'USD'),
    ('SYN-V007', 'Wide World Telecom Services',     'Telecom',             'US', 'USD'),
    ('SYN-V008', 'Proseware Consulting GmbH',       'Professional Services','DE', 'EUR');

-- ---------------------------------------------------------------------
-- 2. Contract documents (CLM side). document_text is what a text-native
--    CLM export looks like. file_path is populated so the rendered
--    corpus (build-contract-test-corpus) can replace text with real
--    files. clm_vendor_id is NULL on two rows on purpose: real CLM
--    exports are missing the counterparty link often enough that the
--    pipeline must be able to link from extracted party names.
--
--    Document mix:
--      7 commercial agreements (one per contracted vendor)
--      1 amendment that changes a rate mid-term     (precedence trap)
--      1 mutual NDA with no commercial terms         (classification trap)
--      1 byte-identical duplicate of an agreement    (double-count trap)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_CONTRACT_DOCUMENTS (
    document_id     VARCHAR(40),
    clm_vendor_id   VARCHAR(20),
    clm_title       VARCHAR,
    file_path       VARCHAR,
    file_format     VARCHAR(10),
    page_count      INT,
    uploaded_at     TIMESTAMP_NTZ,
    document_text   VARCHAR
);

INSERT INTO SYNTH_CONTRACT_DOCUMENTS
SELECT 'SYN-DOC-C001', 'SYN-V001', 'Northwind MSA', 'contracts/SYN-DOC-C001.pdf', 'PDF', 3,
       '2025-01-03 09:12:00'::TIMESTAMP_NTZ,
$$MASTER SERVICES AGREEMENT
Agreement No. SYN-MSA-1001

This Master Services Agreement (the "Agreement") is entered into as of January 1, 2025 (the "Effective Date") by and between Synthetic Holdings Corp. ("Customer") and Northwind Facility Services LLC ("Supplier").

1. TERM
1.1 Initial Term. The initial term of this Agreement begins on the Effective Date and ends on December 31, 2026 (the "Initial Term").
1.2 Renewal. Upon expiration of the Initial Term, this Agreement shall renew automatically for successive renewal terms of twelve (12) months each (each a "Renewal Term") unless either party delivers written notice of non-renewal to the other party at least sixty (60) days before the end of the then-current term.

2. SERVICES
2.1 Supplier shall provide the janitorial and facility cleaning services described in each Statement of Work at the Customer sites listed therein.

3. PRICING
3.1 Rates. Supplier shall invoice Services at the rates set out in Schedule A. Rates are stated in United States dollars.
3.2 Price Changes. Rates in Schedule A are fixed for the Initial Term and may be changed only by a written amendment signed by both parties.
3.3 No Other Charges. No fuel, materials, or administrative surcharges apply unless expressly listed in Schedule A.

4. INVOICING AND PAYMENT
4.1 Supplier shall invoice monthly in arrears. Undisputed amounts are payable within forty-five (45) days of receipt of a correct invoice.
4.2 Customer may audit Supplier invoices for twenty-four (24) months after payment and Supplier shall refund any overcharge identified.

5. TERMINATION
5.1 Termination for Convenience. Customer may terminate this Agreement or any Statement of Work for convenience upon ninety (90) days prior written notice to Supplier.
5.2 Termination for Cause. Either party may terminate for material breach not cured within thirty (30) days of written notice.

6. GENERAL
6.1 Governing Law. This Agreement is governed by the laws of the State of Delaware.

SCHEDULE A - RATE CARD (USD)
| Service Code | Description                  | Unit | Rate   |
| JAN-STD      | Standard janitorial service  | Hour | $42.00 |
| JAN-DEEP     | Deep clean service           | Hour | $55.00 |
$$
UNION ALL
SELECT 'SYN-DOC-C001-A1', 'SYN-V001', 'Northwind MSA Amendment 1', 'contracts/SYN-DOC-C001-A1.pdf', 'PDF', 1,
       '2025-12-15 14:40:00'::TIMESTAMP_NTZ,
$$AMENDMENT NO. 1 TO MASTER SERVICES AGREEMENT NO. SYN-MSA-1001

This Amendment No. 1 (the "Amendment") is made between Synthetic Holdings Corp. ("Customer") and Northwind Facility Services LLC ("Supplier") and is effective as of January 1, 2026 (the "Amendment Effective Date").

1. Schedule A of the Agreement is amended as follows: the Rate for Service Code JAN-STD (Standard janitorial service) is replaced with $44.00 per Hour.
2. The Rate for Service Code JAN-DEEP is unchanged.
3. Except as expressly modified by this Amendment, all terms of the Agreement remain in full force and effect. In the event of conflict between this Amendment and the Agreement, this Amendment controls.
$$
UNION ALL
SELECT 'SYN-DOC-C001-DUP', NULL, 'scan_0042', 'contracts/scans/scan_0042.pdf', 'PDF', 3,
       '2025-03-20 11:05:00'::TIMESTAMP_NTZ,
       NULL   -- populated below as an exact copy of SYN-DOC-C001
UNION ALL
SELECT 'SYN-DOC-C002', 'SYN-V002', 'Contoso Supply Agreement 2026', 'contracts/SYN-DOC-C002.pdf', 'PDF', 2,
       '2025-12-20 10:00:00'::TIMESTAMP_NTZ,
$$SUPPLY AGREEMENT
Agreement No. SYN-SUP-2001

This Supply Agreement is made effective January 1, 2026 (the "Effective Date") between Synthetic Holdings Corp. ("Buyer") and Contoso Industrial Supply Inc ("Seller").

1. TERM. This Agreement commences on the Effective Date and expires on December 31, 2026 (the "Contract Year"). Any renewal requires a written agreement signed by both parties. This Agreement does not renew automatically.

2. PRODUCTS AND PRICING
2.1 Seller shall supply the products listed below at the following prices (USD).
| Item Code | Description                    | Unit | Price per Unit |
| GLOVE-NIT | Nitrile disposable glove, box  | Each | see Section 2.2 |
| TAPE-DUCT | Duct tape, 48mm roll           | Each | $3.10 |

2.2 Volume Pricing for GLOVE-NIT. Pricing for Item GLOVE-NIT is based on cumulative quantity purchased during the Contract Year:
| Tier | Cumulative Units (Contract Year) | Price per Unit |
| 1    | 0 to 99,999                      | $0.18 |
| 2    | 100,000 to 499,999               | $0.15 |
| 3    | 500,000 and above                | $0.12 |

2.3 Application of Tiers. Volume tiers apply incrementally: a tier price applies only to units purchased after the cumulative Contract Year quantity reaches that tier's threshold. Tier prices are not applied retroactively to units purchased before the threshold was reached.
2.4 Seller is responsible for tracking cumulative quantity and shall invoice at the applicable tier price.

3. PAYMENT. Payment is due net thirty (30) days from the invoice date.

4. GOVERNING LAW. Ohio.
$$
UNION ALL
SELECT 'SYN-DOC-C003', 'SYN-V003', 'Fabrikam Order Form', 'contracts/SYN-DOC-C003.pdf', 'PDF', 2,
       '2024-10-28 16:22:00'::TIMESTAMP_NTZ,
$$ORDER FORM
Order Form No. SYN-OF-3001, issued under the Fabrikam Cloud Subscription Terms

Customer: Synthetic Holdings Corp.
Provider: Fabrikam Cloud Software Inc

Subscription: Fabrikam Platform Subscription (Item SUB-PLATFORM), Enterprise tier, up to 500 named users.
Subscription Start Date: November 1, 2024
Subscription End Date: October 31, 2025
Fees: $8,000.00 per month, billed monthly in advance, in USD.
Payment Terms: Net 30 days.

Renewal. This subscription will automatically renew for successive twelve (12) month renewal terms unless either party gives the other written notice of non-renewal at least ninety (90) days prior to the end of the then-current term.

Renewal Pricing. Fees for any renewal term will not increase by more than five percent (5%) over the fees in effect for the immediately preceding term.

Termination. Fees are non-cancellable and non-refundable for the then-current term except as provided in the Subscription Terms.
$$
UNION ALL
SELECT 'SYN-DOC-C004', 'SYN-V004', 'Litware Equipment Purchase Agreement', 'contracts/SYN-DOC-C004.pdf', 'PDF', 2,
       '2026-01-25 13:30:00'::TIMESTAMP_NTZ,
$$EQUIPMENT PURCHASE AGREEMENT
Agreement No. SYN-EPA-4001

This Equipment Purchase Agreement is entered into effective February 1, 2026 between Synthetic Holdings Corp. ("Purchaser") and Litware Lab Equipment Co ("Vendor").

1. TERM. This Agreement is effective from February 1, 2026 through January 31, 2027. It does not renew automatically.

2. EQUIPMENT AND PRICE. Vendor shall sell the following equipment to Purchaser at the prices below, which are firm for all purchase orders placed during the term:
| Model  | Description                              | Unit | Unit Price  |
| LX-500 | Benchtop centrifuge, 24-place rotor      | Each | $18,500.00  |
| LX-SVC | Annual preventive maintenance, per unit  | Each | $1,200.00   |

3. DELIVERY AND ACCEPTANCE. Title passes on acceptance. Purchaser has thirty (30) days to inspect and accept.

4. PAYMENT. Net sixty (60) days after acceptance.

5. WARRANTY. Twelve (12) months parts and labor from acceptance.
$$
UNION ALL
SELECT 'SYN-DOC-C006', 'SYN-V006', 'Tailspin Staffing Agreement', 'contracts/SYN-DOC-C006.pdf', 'PDF', 2,
       '2024-06-25 08:45:00'::TIMESTAMP_NTZ,
$$TEMPORARY STAFFING SERVICES AGREEMENT
Agreement No. SYN-STF-6001

Between Synthetic Holdings Corp. ("Client") and Tailspin Temporary Staffing ("Agency"). Effective Date: July 1, 2024.

1. TERM. This Agreement begins on the Effective Date and ends on June 30, 2025. This Agreement expires at the end of the term and does not renew automatically. Any extension must be in writing.

2. BILL RATES (USD).
| Position                     | Code      | Bill Rate per Hour |
| General warehouse associate  | WH-ASSOC  | $65.00             |
Overtime is billed at 1.5 times the applicable bill rate only when pre-approved in writing by Client.

3. TERMINATION. Either party may terminate this Agreement for convenience on thirty (30) days written notice.

4. PAYMENT. Net 30.
$$
UNION ALL
SELECT 'SYN-DOC-C007', 'SYN-V007', 'Wide World Managed WAN', 'contracts/SYN-DOC-C007.pdf', 'PDF', 3,
       '2024-12-18 12:00:00'::TIMESTAMP_NTZ,
$$MANAGED NETWORK SERVICES AGREEMENT
Agreement No. SYN-TEL-7001

This Agreement between Synthetic Holdings Corp. ("Customer") and Wide World Telecom Services ("Provider") is effective January 1, 2025 (the "Effective Date").

1. TERM AND RENEWAL
1.1 The initial term is twenty-four (24) months from the Effective Date, ending December 31, 2026.
1.2 Thereafter this Agreement renews automatically for successive one (1) year terms unless either party gives written notice of non-renewal no later than sixty (60) days before the expiration of the then-current term.

2. FEES
2.1 Monthly Service Fee: Managed WAN service (SKU WAN-MGD), $5,000.00 per month, USD.
2.2 Annual Adjustment: On each anniversary of the Effective Date, Provider may increase the Monthly Service Fee by up to three percent (3%) of the fee then in effect.

3. EARLY TERMINATION. If Customer terminates this Agreement before the end of the then-current term other than for Provider's uncured breach, Customer shall pay an early termination fee equal to fifty percent (50%) of the Monthly Service Fees remaining for the then-current term.

4. PAYMENT. Net thirty (30) days.
$$
UNION ALL
SELECT 'SYN-DOC-C008', NULL, 'SOW Proseware 2026', 'contracts/SYN-DOC-C008.pdf', 'PDF', 2,
       '2026-02-20 15:10:00'::TIMESTAMP_NTZ,
$$STATEMENT OF WORK
SOW No. SYN-SOW-8001

Client: Synthetic Holdings Corp.
Contractor: PROSEWARE CONSULTING G.m.b.H., Berlin

Period of Performance: March 1, 2026 through December 31, 2026. This SOW ends on the last day of the Period of Performance and does not renew.

Fees. All fees are stated and invoiced in Euro (EUR).
| Role               | Code         | Unit | Rate         |
| Senior Consultant  | SENIOR-CONS  | Day  | EUR 1,450.00 |
| Consultant         | CONS         | Day  | EUR 1,050.00 |

Travel and expenses are not billable unless pre-approved in writing.

Payment. Invoices are payable within thirty (30) days.
$$
UNION ALL
SELECT 'SYN-DOC-N008', 'SYN-V008', 'Mutual NDA Proseware', 'contracts/SYN-DOC-N008.pdf', 'PDF', 2,
       '2026-01-10 09:00:00'::TIMESTAMP_NTZ,
$$MUTUAL NON-DISCLOSURE AGREEMENT

This Mutual Non-Disclosure Agreement is entered into as of January 10, 2026 between Synthetic Holdings Corp. and Proseware Consulting GmbH.

1. Purpose. The parties wish to evaluate a potential consulting engagement and may disclose Confidential Information to each other.
2. Obligations. Each party shall protect the other's Confidential Information with at least reasonable care.
3. Term. This Agreement remains in effect for two (2) years from the date above and renews automatically for successive one (1) year periods unless terminated by either party on thirty (30) days notice. Confidentiality obligations survive for three (3) years.
4. No fees are payable under this Agreement.
$$;

-- The duplicate is an exact copy of the master agreement: a re-scanned
-- file that the CLM ingested again under a new id.
UPDATE SYNTH_CONTRACT_DOCUMENTS
SET document_text = (SELECT document_text FROM SYNTH_CONTRACT_DOCUMENTS WHERE document_id = 'SYN-DOC-C001')
WHERE document_id = 'SYN-DOC-C001-DUP';

-- ---------------------------------------------------------------------
-- 3. Purchase orders (ERP side). One line per PO for simplicity.
--    contract_reference is free text, as it is in most ERPs; it is
--    populated on some POs and blank on others.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_PURCHASE_ORDERS (
    po_id               VARCHAR(20),
    vendor_id           VARCHAR(20),
    po_date             DATE,
    contract_reference  VARCHAR,
    sku                 VARCHAR(40),
    quantity            NUMBER(18,4),
    unit_price          NUMBER(18,4),
    currency            VARCHAR(3),
    gl_account          VARCHAR(40),
    capex_flag          BOOLEAN
);

INSERT INTO SYNTH_PURCHASE_ORDERS VALUES
    ('SYN-PO-1001', 'SYN-V001', '2025-01-02', 'MSA SYN-MSA-1001', 'JAN-STD',     NULL,  NULL,     'USD', '6100-FACILITIES', FALSE),
    ('SYN-PO-2001', 'SYN-V002', '2026-01-02', 'SYN-SUP-2001',     'GLOVE-NIT',   NULL,  NULL,     'USD', '6200-MRO',        FALSE),
    ('SYN-PO-3001', 'SYN-V003', '2024-10-30', NULL,               'SUB-PLATFORM',NULL,  NULL,     'USD', '6300-SOFTWARE',   FALSE),
    ('SYN-PO-4001', 'SYN-V004', '2026-03-10', 'EPA 4001',         'LX-500',      3,     21000.00, 'USD', '1500-CAPEX-LAB',  TRUE),
    ('SYN-PO-6001', 'SYN-V006', '2024-07-01', 'SYN-STF-6001',     'WH-ASSOC',    NULL,  NULL,     'USD', '6400-LABOR',      FALSE),
    ('SYN-PO-7001', 'SYN-V007', '2025-01-02', 'SYN-TEL-7001',     'WAN-MGD',     NULL,  NULL,     'USD', '6500-TELECOM',    FALSE),
    ('SYN-PO-8001', 'SYN-V008', '2026-02-25', NULL,               NULL,          NULL,  NULL,     'EUR', '6600-CONSULTING', FALSE);

-- ---------------------------------------------------------------------
-- 4. Invoice lines (AP side). Generated per vendor with the planted
--    behaviour written as explicit CASE branches so the plant is
--    readable. invoice_line_id is deterministic so the answer key can
--    reference it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_INVOICE_LINES (
    invoice_line_id         VARCHAR(60),
    invoice_id              VARCHAR(40),
    vendor_id               VARCHAR(20),
    vendor_name_on_invoice  VARCHAR,
    po_id                   VARCHAR(20),
    invoice_date            DATE,
    service_period_start    DATE,
    service_period_end      DATE,
    sku                     VARCHAR(40),
    line_description        VARCHAR,
    quantity                NUMBER(18,4),
    unit_of_measure         VARCHAR(20),
    unit_price              NUMBER(18,4),
    currency                VARCHAR(3),
    line_amount             NUMBER(18,2),
    gl_account              VARCHAR(40),
    capex_flag              BOOLEAN
);

-- 4a. SYN-V001 Northwind, JAN-STD 400 hours/month, Jan 2025 - Sep 2026.
--     PLANT  2025-07..2025-12 billed 46.50 vs contracted 42.00
--     PLANT  2026-04..2026-09 billed 46.50 vs amended 44.00
--     DISTRACTOR 2025-06 billed 42.01 (inside rounding tolerance)
--     DISTRACTOR 2026-01..2026-03 billed 44.00 (correct after amendment;
--                a pipeline that ignores the amendment flags these)
INSERT INTO SYNTH_INVOICE_LINES
WITH m AS (
    SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2025-01-01'::DATE) AS period
    FROM TABLE(GENERATOR(ROWCOUNT => 21))
), p AS (
    SELECT period,
           CASE WHEN period <  '2025-06-01' THEN 42.00
                WHEN period =  '2025-06-01' THEN 42.01
                WHEN period <  '2026-01-01' THEN 46.50
                WHEN period <  '2026-04-01' THEN 44.00
                ELSE 46.50 END AS price
    FROM m
)
SELECT 'SYN-IL-V001-' || TO_CHAR(period, 'YYYY-MM') || '-STD',
       'SYN-INV-V001-' || TO_CHAR(period, 'YYYYMM'),
       'SYN-V001', 'Northwind Facility Services LLC', 'SYN-PO-1001',
       LAST_DAY(period), period, LAST_DAY(period),
       'JAN-STD', 'Standard janitorial service - monthly hours', 400, 'HOUR',
       price, 'USD', ROUND(400 * price, 2), '6100-FACILITIES', FALSE
FROM p;

-- 4b. SYN-V001 Northwind, JAN-DEEP 20 hours/month at the correct rate.
INSERT INTO SYNTH_INVOICE_LINES
WITH m AS (
    SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2025-01-01'::DATE) AS period
    FROM TABLE(GENERATOR(ROWCOUNT => 21))
)
SELECT 'SYN-IL-V001-' || TO_CHAR(period, 'YYYY-MM') || '-DEEP',
       'SYN-INV-V001-' || TO_CHAR(period, 'YYYYMM'),
       'SYN-V001', 'Northwind Facility Services LLC', 'SYN-PO-1001',
       LAST_DAY(period), period, LAST_DAY(period),
       'JAN-DEEP', 'Deep clean service', 20, 'HOUR',
       55.00, 'USD', 1100.00, '6100-FACILITIES', FALSE
FROM m;

-- 4c. SYN-V002 Contoso, GLOVE-NIT 40,000 units/month, Jan - Sep 2026,
--     always billed at tier 1 (0.18).
--     Cumulative crosses 100,000 during March (80,000 -> 120,000).
--     PLANT  2026-03: 20,000 units should have been 0.15  -> 600.00
--     PLANT  2026-04..2026-09: 40,000 units at 0.15       -> 1,200.00 each
--     DISTRACTOR 2026-01, 2026-02: correctly billed at tier 1.
--     Cumulative never reaches 500,000, so tier 3 never applies.
--     A pipeline that applies the tier retroactively over-states March
--     at 120,000 x 0.03 = 3,600; the dollar reconciliation catches it.
INSERT INTO SYNTH_INVOICE_LINES
WITH m AS (
    SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-01-01'::DATE) AS period
    FROM TABLE(GENERATOR(ROWCOUNT => 9))
)
SELECT 'SYN-IL-V002-' || TO_CHAR(period, 'YYYY-MM') || '-GLOVE',
       'SYN-INV-V002-' || TO_CHAR(period, 'YYYYMM'),
       'SYN-V002', 'Contoso Industrial Supply Inc', 'SYN-PO-2001',
       LAST_DAY(period), period, LAST_DAY(period),
       'GLOVE-NIT', 'Nitrile gloves box', 40000, 'EACH',
       0.18, 'USD', 7200.00, '6200-MRO', FALSE
FROM m;

-- 4d. SYN-V003 Fabrikam SaaS, Nov 2024 - Sep 2026.
--     Initial term Nov 2024 - Oct 2025 at 8,000.00 (compliant).
--     Auto-renewed Nov 2025 at 9,200.00 = +15%, cap is 5% (8,400.00).
--     PLANT  2025-11..2026-09: 11 lines, 800.00 over cap each.
INSERT INTO SYNTH_INVOICE_LINES
WITH m AS (
    SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2024-11-01'::DATE) AS period
    FROM TABLE(GENERATOR(ROWCOUNT => 23))
)
SELECT 'SYN-IL-V003-' || TO_CHAR(period, 'YYYY-MM') || '-SUB',
       'SYN-INV-V003-' || TO_CHAR(period, 'YYYYMM'),
       'SYN-V003', 'Fabrikam Cloud Software, Inc.', 'SYN-PO-3001',
       period, period, LAST_DAY(period),
       'SUB-PLATFORM', 'Platform subscription - Enterprise - monthly', 1, 'MONTH',
       IFF(period < '2025-11-01', 8000.00, 9200.00), 'USD',
       IFF(period < '2025-11-01', 8000.00, 9200.00), '6300-SOFTWARE', FALSE
FROM m;

-- 4e. SYN-V004 Litware, CapEx. 3 x LX-500 at 21,000.00 vs 18,500.00.
--     PLANT  one line, 3 x 2,500.00 = 7,500.00, capex_flag TRUE.
INSERT INTO SYNTH_INVOICE_LINES VALUES
    ('SYN-IL-V004-2026-04-LX500', 'SYN-INV-V004-202604', 'SYN-V004', 'Litware Lab Equipment Co',
     'SYN-PO-4001', '2026-04-15', '2026-04-15', '2026-04-15',
     'LX-500', 'Centrifuge LX-500 benchtop 24-place', 3, 'EACH',
     21000.00, 'USD', 63000.00, '1500-CAPEX-LAB', TRUE);

-- 4f. SYN-V005 Adventure Logistics. No contract, no PO.
--     PLANT  6 lines of off-contract spend totalling 71,000.00.
INSERT INTO SYNTH_INVOICE_LINES
SELECT 'SYN-IL-V005-' || TO_CHAR(period, 'YYYY-MM') || '-FRT',
       'SYN-INV-V005-' || TO_CHAR(period, 'YYYYMM'),
       'SYN-V005', 'Adventure Logistics Partners', NULL,
       LAST_DAY(period), period, LAST_DAY(period),
       NULL, 'Freight services - LTL shipments', 1, 'LOT',
       amt, 'USD', amt, '6700-FREIGHT', FALSE
FROM (SELECT column1::DATE AS period, column2::NUMBER(18,2) AS amt FROM VALUES
        ('2026-04-01', 12000.00), ('2026-05-01',  9500.00), ('2026-06-01', 14200.00),
        ('2026-07-01', 11800.00), ('2026-08-01', 13100.00), ('2026-09-01', 10400.00));

-- 4g. SYN-V006 Tailspin. Contract expired 2025-06-30 with no renewal.
--     Jan - Jun 2025 compliant. Jul - Dec 2025 billed after expiry.
--     PLANT  6 lines of expired-contract spend, 10,400.00 each = 62,400.00.
--     The rate (65.00) is unchanged, so this is NOT a rate variance;
--     a pipeline that reports it as one has the wrong finding type.
INSERT INTO SYNTH_INVOICE_LINES
WITH m AS (
    SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2025-01-01'::DATE) AS period
    FROM TABLE(GENERATOR(ROWCOUNT => 12))
)
SELECT 'SYN-IL-V006-' || TO_CHAR(period, 'YYYY-MM') || '-WH',
       'SYN-INV-V006-' || TO_CHAR(period, 'YYYYMM'),
       'SYN-V006', 'Tailspin Temporary Staffing', 'SYN-PO-6001',
       LAST_DAY(period), period, LAST_DAY(period),
       'WH-ASSOC', 'Warehouse associate hours', 160, 'HOUR',
       65.00, 'USD', 10400.00, '6400-LABOR', FALSE
FROM m;

-- 4h. SYN-V007 Wide World Telecom, Jan 2025 - Sep 2026.
--     2025 at 5,000.00; 2026 at 5,150.00 (+3.0%, exactly the permitted
--     anniversary escalator).
--     DISTRACTOR 2026-01..2026-09: compliant; a pipeline that compares
--                to the base fee without the escalator flags all nine.
INSERT INTO SYNTH_INVOICE_LINES
WITH m AS (
    SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2025-01-01'::DATE) AS period
    FROM TABLE(GENERATOR(ROWCOUNT => 21))
)
SELECT 'SYN-IL-V007-' || TO_CHAR(period, 'YYYY-MM') || '-WAN',
       'SYN-INV-V007-' || TO_CHAR(period, 'YYYYMM'),
       'SYN-V007', 'Wide World Telecom Services', 'SYN-PO-7001',
       period, period, LAST_DAY(period),
       'WAN-MGD', 'Managed WAN monthly service fee', 1, 'MONTH',
       IFF(period < '2026-01-01', 5000.00, 5150.00), 'USD',
       IFF(period < '2026-01-01', 5000.00, 5150.00), '6500-TELECOM', FALSE
FROM m;

-- 4i. SYN-V008 Proseware, EUR, Mar - Aug 2026, 10 days/month.
--     No SKU on the invoice; the description must be matched to the
--     contracted role. Invoice vendor name is an uppercase variant.
--     PLANT  2026-07 billed EUR 1,600.00/day vs 1,450.00 -> EUR 1,500.00
--     DISTRACTOR the other five months: compliant, in EUR. A pipeline
--                that compares EUR invoices to a USD-assumed rate, or
--                that fails the vendor-name link, gets these wrong.
INSERT INTO SYNTH_INVOICE_LINES
WITH m AS (
    SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-03-01'::DATE) AS period
    FROM TABLE(GENERATOR(ROWCOUNT => 6))
)
SELECT 'SYN-IL-V008-' || TO_CHAR(period, 'YYYY-MM') || '-SC',
       'SYN-INV-V008-' || TO_CHAR(period, 'YYYYMM'),
       'SYN-V008', 'PROSEWARE CONSULTING', 'SYN-PO-8001',
       LAST_DAY(period), period, LAST_DAY(period),
       NULL, 'Senior consultant - daily rate', 10, 'DAY',
       IFF(period = '2026-07-01', 1600.00, 1450.00), 'EUR',
       IFF(period = '2026-07-01', 16000.00, 14500.00), '6600-CONSULTING', FALSE
FROM m;

-- =====================================================================
-- 5. ANSWER KEYS. Quarantined schema. Never read by the pipeline.
-- =====================================================================
USE SCHEMA {{DB}}.{{EVAL_SCHEMA}};

-- 5a. Header terms per contract family, wide form. 'NOT_STATED' is a
--     real value meaning the contract is silent on the term; it is
--     different from an extraction failure and is scored separately.
--     Dates are ISO strings; percents and day counts are plain numbers.
CREATE OR REPLACE TABLE SYNTH_TERM_KEY_WIDE (
    contract_family_id                     VARCHAR(20),
    governing_document_id                  VARCHAR(40),
    vendor_id                              VARCHAR(20),
    agreement_effective_date               VARCHAR,
    initial_term_end_date                  VARCHAR,
    auto_renewal                           VARCHAR,
    renewal_term_months                    VARCHAR,
    non_renewal_notice_days                VARCHAR,
    renewal_uplift_cap_pct                 VARCHAR,
    annual_escalator_cap_pct               VARCHAR,
    contract_currency                      VARCHAR,
    payment_terms_days                     VARCHAR,
    termination_for_convenience_notice_days VARCHAR,
    early_termination_fee_pct              VARCHAR
);

INSERT INTO SYNTH_TERM_KEY_WIDE VALUES
    ('SYN-MSA-1001','SYN-DOC-C001','SYN-V001','2025-01-01','2026-12-31','TRUE', '12','60','NOT_STATED','NOT_STATED','USD','45','90','NOT_STATED'),
    ('SYN-SUP-2001','SYN-DOC-C002','SYN-V002','2026-01-01','2026-12-31','FALSE','NOT_STATED','NOT_STATED','NOT_STATED','NOT_STATED','USD','30','NOT_STATED','NOT_STATED'),
    ('SYN-OF-3001', 'SYN-DOC-C003','SYN-V003','2024-11-01','2025-10-31','TRUE', '12','90','5','NOT_STATED','USD','30','NOT_STATED','NOT_STATED'),
    ('SYN-EPA-4001','SYN-DOC-C004','SYN-V004','2026-02-01','2027-01-31','FALSE','NOT_STATED','NOT_STATED','NOT_STATED','NOT_STATED','USD','60','NOT_STATED','NOT_STATED'),
    ('SYN-STF-6001','SYN-DOC-C006','SYN-V006','2024-07-01','2025-06-30','FALSE','NOT_STATED','NOT_STATED','NOT_STATED','NOT_STATED','USD','30','30','NOT_STATED'),
    ('SYN-TEL-7001','SYN-DOC-C007','SYN-V007','2025-01-01','2026-12-31','TRUE', '12','60','NOT_STATED','3','USD','30','NOT_STATED','50'),
    ('SYN-SOW-8001','SYN-DOC-C008','SYN-V008','2026-03-01','2026-12-31','FALSE','NOT_STATED','NOT_STATED','NOT_STATED','NOT_STATED','EUR','30','NOT_STATED','NOT_STATED');

-- Long form for scoring: one row per (family, term).
CREATE OR REPLACE VIEW SYNTH_TERM_KEY AS
SELECT contract_family_id, governing_document_id, vendor_id,
       LOWER(term_name) AS term_name, expected_value
FROM SYNTH_TERM_KEY_WIDE
UNPIVOT (expected_value FOR term_name IN (
    agreement_effective_date, initial_term_end_date, auto_renewal,
    renewal_term_months, non_renewal_notice_days, renewal_uplift_cap_pct,
    annual_escalator_cap_pct, contract_currency, payment_terms_days,
    termination_for_convenience_notice_days, early_termination_fee_pct
));

-- 5b. Document classification key. The NDA must classify as
--     non-commercial; the duplicate must be recognised as a duplicate.
CREATE OR REPLACE TABLE SYNTH_DOCUMENT_KEY (
    document_id         VARCHAR(40),
    expected_doc_class  VARCHAR(40),
    contract_family_id  VARCHAR(20),
    is_duplicate_of     VARCHAR(40)
);

INSERT INTO SYNTH_DOCUMENT_KEY VALUES
    ('SYN-DOC-C001',     'MASTER_AGREEMENT',   'SYN-MSA-1001', NULL),
    ('SYN-DOC-C001-A1',  'AMENDMENT',          'SYN-MSA-1001', NULL),
    ('SYN-DOC-C001-DUP', 'MASTER_AGREEMENT',   'SYN-MSA-1001', 'SYN-DOC-C001'),
    ('SYN-DOC-C002',     'MASTER_AGREEMENT',   'SYN-SUP-2001', NULL),
    ('SYN-DOC-C003',     'ORDER_FORM_OR_SOW',  'SYN-OF-3001',  NULL),
    ('SYN-DOC-C004',     'MASTER_AGREEMENT',   'SYN-EPA-4001', NULL),
    ('SYN-DOC-C006',     'MASTER_AGREEMENT',   'SYN-STF-6001', NULL),
    ('SYN-DOC-C007',     'MASTER_AGREEMENT',   'SYN-TEL-7001', NULL),
    ('SYN-DOC-C008',     'ORDER_FORM_OR_SOW',  'SYN-SOW-8001', NULL),
    ('SYN-DOC-N008',     'NON_COMMERCIAL',     NULL,           NULL);

-- 5c. Rate card key, with effective windows. The amendment produces a
--     second JAN-STD row; the tiers produce three GLOVE-NIT rows.
CREATE OR REPLACE TABLE SYNTH_RATE_KEY (
    contract_family_id   VARCHAR(20),
    source_document_id   VARCHAR(40),
    sku                  VARCHAR(40),
    unit_of_measure      VARCHAR(20),
    tier_min_qty         NUMBER(18,4),
    tier_max_qty         NUMBER(18,4),
    unit_price           NUMBER(18,4),
    currency             VARCHAR(3),
    effective_from       DATE,
    effective_to         DATE
);

INSERT INTO SYNTH_RATE_KEY VALUES
    ('SYN-MSA-1001','SYN-DOC-C001',   'JAN-STD',     'HOUR',  NULL,   NULL,   42.00,  'USD','2025-01-01','2025-12-31'),
    ('SYN-MSA-1001','SYN-DOC-C001-A1','JAN-STD',     'HOUR',  NULL,   NULL,   44.00,  'USD','2026-01-01','2026-12-31'),
    ('SYN-MSA-1001','SYN-DOC-C001',   'JAN-DEEP',    'HOUR',  NULL,   NULL,   55.00,  'USD','2025-01-01','2026-12-31'),
    ('SYN-SUP-2001','SYN-DOC-C002',   'GLOVE-NIT',   'EACH',  0,      99999,  0.18,   'USD','2026-01-01','2026-12-31'),
    ('SYN-SUP-2001','SYN-DOC-C002',   'GLOVE-NIT',   'EACH',  100000, 499999, 0.15,   'USD','2026-01-01','2026-12-31'),
    ('SYN-SUP-2001','SYN-DOC-C002',   'GLOVE-NIT',   'EACH',  500000, NULL,   0.12,   'USD','2026-01-01','2026-12-31'),
    ('SYN-SUP-2001','SYN-DOC-C002',   'TAPE-DUCT',   'EACH',  NULL,   NULL,   3.10,   'USD','2026-01-01','2026-12-31'),
    ('SYN-OF-3001', 'SYN-DOC-C003',   'SUB-PLATFORM','MONTH', NULL,   NULL,   8000.00,'USD','2024-11-01','2025-10-31'),
    ('SYN-EPA-4001','SYN-DOC-C004',   'LX-500',      'EACH',  NULL,   NULL,   18500.00,'USD','2026-02-01','2027-01-31'),
    ('SYN-EPA-4001','SYN-DOC-C004',   'LX-SVC',      'EACH',  NULL,   NULL,   1200.00,'USD','2026-02-01','2027-01-31'),
    ('SYN-STF-6001','SYN-DOC-C006',   'WH-ASSOC',    'HOUR',  NULL,   NULL,   65.00,  'USD','2024-07-01','2025-06-30'),
    ('SYN-TEL-7001','SYN-DOC-C007',   'WAN-MGD',     'MONTH', NULL,   NULL,   5000.00,'USD','2025-01-01','2026-12-31'),
    ('SYN-SOW-8001','SYN-DOC-C008',   'SENIOR-CONS', 'DAY',   NULL,   NULL,   1450.00,'EUR','2026-03-01','2026-12-31'),
    ('SYN-SOW-8001','SYN-DOC-C008',   'CONS',        'DAY',   NULL,   NULL,   1050.00,'EUR','2026-03-01','2026-12-31');

-- 5d. Leakage finding key.
--   case_role   PLANTED     a finding the pipeline must raise
--               DISTRACTOR  a line or contract the pipeline must NOT flag
--   impact_kind RECOVERABLE_OVERCHARGE   money billed above contract
--               SPEND_UNDER_MANAGEMENT   spend with no valid contract
--               COMMITMENT_EXPOSURE      value of a renewal at risk
--   The three impact kinds are never summed together.
CREATE OR REPLACE TABLE SYNTH_LEAKAGE_KEY (
    finding_key            VARCHAR(80),
    case_role              VARCHAR(20),
    finding_type           VARCHAR(40),
    vendor_id              VARCHAR(20),
    contract_family_id     VARCHAR(20),
    invoice_line_id        VARCHAR(60),
    expected_impact_amount NUMBER(18,2),
    impact_currency        VARCHAR(3),
    impact_kind            VARCHAR(30),
    plant_note             VARCHAR
);

-- RATE_VARIANCE, Northwind 2025 H2 (6 x 400 x 4.50 = 10,800.00)
INSERT INTO SYNTH_LEAKAGE_KEY
WITH m AS (SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2025-07-01'::DATE) AS period
           FROM TABLE(GENERATOR(ROWCOUNT => 6)))
SELECT 'RV-SYN-IL-V001-' || TO_CHAR(period,'YYYY-MM') || '-STD', 'PLANTED', 'RATE_VARIANCE',
       'SYN-V001', 'SYN-MSA-1001', 'SYN-IL-V001-' || TO_CHAR(period,'YYYY-MM') || '-STD',
       1800.00, 'USD', 'RECOVERABLE_OVERCHARGE', 'Billed 46.50 vs Schedule A 42.00'
FROM m;

-- RATE_VARIANCE, Northwind 2026 Apr-Sep (6 x 400 x 2.50 = 6,000.00)
INSERT INTO SYNTH_LEAKAGE_KEY
WITH m AS (SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-04-01'::DATE) AS period
           FROM TABLE(GENERATOR(ROWCOUNT => 6)))
SELECT 'RV-SYN-IL-V001-' || TO_CHAR(period,'YYYY-MM') || '-STD', 'PLANTED', 'RATE_VARIANCE',
       'SYN-V001', 'SYN-MSA-1001', 'SYN-IL-V001-' || TO_CHAR(period,'YYYY-MM') || '-STD',
       1000.00, 'USD', 'RECOVERABLE_OVERCHARGE', 'Billed 46.50 vs Amendment 1 rate 44.00'
FROM m;

-- MISSED_VOLUME_DISCOUNT, Contoso (600.00 + 6 x 1,200.00 = 7,800.00)
INSERT INTO SYNTH_LEAKAGE_KEY
WITH m AS (SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-03-01'::DATE) AS period
           FROM TABLE(GENERATOR(ROWCOUNT => 7)))
SELECT 'MVD-SYN-IL-V002-' || TO_CHAR(period,'YYYY-MM') || '-GLOVE', 'PLANTED', 'MISSED_VOLUME_DISCOUNT',
       'SYN-V002', 'SYN-SUP-2001', 'SYN-IL-V002-' || TO_CHAR(period,'YYYY-MM') || '-GLOVE',
       IFF(period = '2026-03-01', 600.00, 1200.00), 'USD', 'RECOVERABLE_OVERCHARGE',
       IFF(period = '2026-03-01', '20,000 of 40,000 units past the 100,000 threshold, incremental tier',
                                  'All 40,000 units in tier 2 at 0.15')
FROM m;

-- UPLIFT_OVER_CAP, Fabrikam (11 x 800.00 = 8,800.00)
INSERT INTO SYNTH_LEAKAGE_KEY
WITH m AS (SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2025-11-01'::DATE) AS period
           FROM TABLE(GENERATOR(ROWCOUNT => 11)))
SELECT 'UOC-SYN-IL-V003-' || TO_CHAR(period,'YYYY-MM') || '-SUB', 'PLANTED', 'UPLIFT_OVER_CAP',
       'SYN-V003', 'SYN-OF-3001', 'SYN-IL-V003-' || TO_CHAR(period,'YYYY-MM') || '-SUB',
       800.00, 'USD', 'RECOVERABLE_OVERCHARGE', 'Renewal at 9,200 vs 5% cap of 8,400'
FROM m;

INSERT INTO SYNTH_LEAKAGE_KEY VALUES
    -- CapEx rate variance (3 x 2,500.00)
    ('RV-SYN-IL-V004-2026-04-LX500','PLANTED','RATE_VARIANCE','SYN-V004','SYN-EPA-4001',
     'SYN-IL-V004-2026-04-LX500', 7500.00,'USD','RECOVERABLE_OVERCHARGE','LX-500 at 21,000 vs firm 18,500; CapEx GL'),
    -- EUR rate variance (10 x 150.00)
    ('RV-SYN-IL-V008-2026-07-SC','PLANTED','RATE_VARIANCE','SYN-V008','SYN-SOW-8001',
     'SYN-IL-V008-2026-07-SC', 1500.00,'EUR','RECOVERABLE_OVERCHARGE','Senior consultant at EUR 1,600 vs 1,450'),
    -- Renewal findings: contract grain, exposure = trailing 12 months of
    -- invoiced spend under the family as of 2026-09-30.
    ('ARN-SYN-OF-3001','PLANTED','AUTO_RENEWAL_NOTICE_MISSED','SYN-V003','SYN-OF-3001',
     NULL, 109200.00,'USD','COMMITMENT_EXPOSURE',
     'Current term ends 2026-10-31 after a prior auto-renewal; 90-day notice deadline 2026-08-02 has passed'),
    ('ARU-SYN-MSA-1001','PLANTED','AUTO_RENEWAL_NOTICE_UPCOMING','SYN-V001','SYN-MSA-1001',
     NULL, 233400.00,'USD','COMMITMENT_EXPOSURE',
     'Initial term ends 2026-12-31; 60-day notice deadline 2026-11-01, 32 days after as-of'),
    ('ARU-SYN-TEL-7001','PLANTED','AUTO_RENEWAL_NOTICE_UPCOMING','SYN-V007','SYN-TEL-7001',
     NULL, 61350.00,'USD','COMMITMENT_EXPOSURE',
     'Initial term ends 2026-12-31; 60-day notice deadline 2026-11-01, 32 days after as-of');

-- OFF_CONTRACT, Adventure Logistics (71,000.00)
INSERT INTO SYNTH_LEAKAGE_KEY
SELECT 'OC-' || invoice_line_id, 'PLANTED', 'OFF_CONTRACT', 'SYN-V005', NULL, invoice_line_id,
       line_amount, 'USD', 'SPEND_UNDER_MANAGEMENT', 'No contract on file for vendor; non-PO'
FROM {{DB}}.{{SCHEMA}}.SYNTH_INVOICE_LINES
WHERE vendor_id = 'SYN-V005';

-- EXPIRED_CONTRACT_SPEND, Tailspin (6 x 10,400.00 = 62,400.00)
INSERT INTO SYNTH_LEAKAGE_KEY
WITH m AS (SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2025-07-01'::DATE) AS period
           FROM TABLE(GENERATOR(ROWCOUNT => 6)))
SELECT 'EXP-SYN-IL-V006-' || TO_CHAR(period,'YYYY-MM') || '-WH', 'PLANTED', 'EXPIRED_CONTRACT_SPEND',
       'SYN-V006', 'SYN-STF-6001', 'SYN-IL-V006-' || TO_CHAR(period,'YYYY-MM') || '-WH',
       10400.00, 'USD', 'SPEND_UNDER_MANAGEMENT', 'Billed after 2025-06-30 expiry; rate unchanged'
FROM m;

-- DISTRACTORS. Expected impact 0; any finding raised on these is a
-- false positive. finding_type records the trap being tested.
INSERT INTO SYNTH_LEAKAGE_KEY VALUES
    ('D-SYN-IL-V001-2025-06-STD','DISTRACTOR','RATE_VARIANCE','SYN-V001','SYN-MSA-1001',
     'SYN-IL-V001-2025-06-STD',0,'USD','RECOVERABLE_OVERCHARGE','42.01 vs 42.00: inside rounding tolerance');

INSERT INTO SYNTH_LEAKAGE_KEY
WITH m AS (SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-01-01'::DATE) AS period
           FROM TABLE(GENERATOR(ROWCOUNT => 3)))
SELECT 'D-SYN-IL-V001-' || TO_CHAR(period,'YYYY-MM') || '-STD', 'DISTRACTOR', 'RATE_VARIANCE',
       'SYN-V001', 'SYN-MSA-1001', 'SYN-IL-V001-' || TO_CHAR(period,'YYYY-MM') || '-STD',
       0, 'USD', 'RECOVERABLE_OVERCHARGE', '44.00 is correct under Amendment 1'
FROM m;

INSERT INTO SYNTH_LEAKAGE_KEY
WITH m AS (SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-01-01'::DATE) AS period
           FROM TABLE(GENERATOR(ROWCOUNT => 9)))
SELECT 'D-SYN-IL-V007-' || TO_CHAR(period,'YYYY-MM') || '-WAN', 'DISTRACTOR', 'RATE_VARIANCE',
       'SYN-V007', 'SYN-TEL-7001', 'SYN-IL-V007-' || TO_CHAR(period,'YYYY-MM') || '-WAN',
       0, 'USD', 'RECOVERABLE_OVERCHARGE', '5,150 is the permitted 3% anniversary escalator'
FROM m;

INSERT INTO SYNTH_LEAKAGE_KEY
WITH m AS (SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-03-01'::DATE) AS period
           FROM TABLE(GENERATOR(ROWCOUNT => 6)))
SELECT 'D-SYN-IL-V008-' || TO_CHAR(period,'YYYY-MM') || '-SC', 'DISTRACTOR', 'RATE_VARIANCE',
       'SYN-V008', 'SYN-SOW-8001', 'SYN-IL-V008-' || TO_CHAR(period,'YYYY-MM') || '-SC',
       0, 'EUR', 'RECOVERABLE_OVERCHARGE', 'Compliant EUR billing; vendor name and description variants'
FROM m
WHERE period <> '2026-07-01';

INSERT INTO SYNTH_LEAKAGE_KEY
WITH m AS (SELECT DATEADD(month, ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1, '2026-01-01'::DATE) AS period
           FROM TABLE(GENERATOR(ROWCOUNT => 2)))
SELECT 'D-SYN-IL-V002-' || TO_CHAR(period,'YYYY-MM') || '-GLOVE', 'DISTRACTOR', 'MISSED_VOLUME_DISCOUNT',
       'SYN-V002', 'SYN-SUP-2001', 'SYN-IL-V002-' || TO_CHAR(period,'YYYY-MM') || '-GLOVE',
       0, 'USD', 'RECOVERABLE_OVERCHARGE', 'Cumulative still under 100,000; tier 1 is correct'
FROM m;

-- Contract-level distractors: contracts that must NOT raise a renewal
-- finding. The NDA auto-renews but carries no commercial exposure.
INSERT INTO SYNTH_LEAKAGE_KEY VALUES
    ('D-ARN-SYN-SUP-2001','DISTRACTOR','AUTO_RENEWAL_NOTICE_UPCOMING','SYN-V002','SYN-SUP-2001',NULL,0,'USD','COMMITMENT_EXPOSURE','Does not auto-renew'),
    ('D-ARN-SYN-SOW-8001','DISTRACTOR','AUTO_RENEWAL_NOTICE_UPCOMING','SYN-V008','SYN-SOW-8001',NULL,0,'EUR','COMMITMENT_EXPOSURE','Does not renew'),
    ('D-ARN-SYN-DOC-N008','DISTRACTOR','AUTO_RENEWAL_NOTICE_UPCOMING','SYN-V008',NULL,         NULL,0,'EUR','COMMITMENT_EXPOSURE','NDA auto-renews but is non-commercial');

-- Expected totals, as literals, so the verification script can assert
-- the key was built correctly rather than trusting the generators.
CREATE OR REPLACE TABLE SYNTH_EXPECTED_TOTALS (
    impact_kind     VARCHAR(30),
    impact_currency VARCHAR(3),
    expected_total  NUMBER(18,2),
    expected_count  INT
);

INSERT INTO SYNTH_EXPECTED_TOTALS VALUES
    ('RECOVERABLE_OVERCHARGE','USD', 40900.00, 31),   -- 16,800 + 7,800 + 8,800 + 7,500
    ('RECOVERABLE_OVERCHARGE','EUR',  1500.00,  1),
    ('SPEND_UNDER_MANAGEMENT','USD',133400.00, 12),   -- 71,000 + 62,400
    ('COMMITMENT_EXPOSURE',   'USD',403950.00,  3);   -- 109,200 + 233,400 + 61,350
