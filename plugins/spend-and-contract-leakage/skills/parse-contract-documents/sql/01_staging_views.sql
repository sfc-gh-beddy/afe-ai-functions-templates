-- =====================================================================
-- Phase 2a. Staging views: map source columns onto the canonical names
-- every later phase uses. No AI functions. No data is copied.
--
-- SUBSTITUTE BEFORE RUNNING (values from spend-leakage-project.yml):
--   {{DB}} {{SCHEMA}}            pipeline database and schema
--   {{SRC_CONTRACTS}}            contracts.source_table (fully qualified)
--   {{SRC_VENDORS}}              spend.vendors_table
--   {{SRC_POS}}                  spend.po_table
--   {{SRC_INVOICE_LINES}}        spend.invoice_lines_table
--
-- For the sandbox, the SRC_* tables are the SYNTH_* tables, whose columns
-- already carry the canonical names, so every mapping below is identity.
-- For a customer, replace each right-hand column with the mapped column
-- from the project file. Do not add columns the source does not have;
-- leave them as typed NULLs so downstream logic sees "absent", not "guessed".
-- =====================================================================

USE DATABASE {{DB}};
USE SCHEMA {{SCHEMA}};

CREATE OR REPLACE VIEW STG_CONTRACT_DOCUMENTS AS
SELECT
    document_id::VARCHAR                AS document_id,
    clm_vendor_id::VARCHAR              AS clm_vendor_id,
    clm_title::VARCHAR                  AS clm_title,
    file_path::VARCHAR                  AS file_path,       -- stage-relative
    uploaded_at::TIMESTAMP_NTZ          AS uploaded_at,
    page_count::INT                     AS page_count,
    document_text::VARCHAR              AS document_text,
    -- Content hash drives parse caching. For file-only sources, replace with
    -- the directory table's MD5 joined on relative_path.
    MD5(COALESCE(document_text, file_path)) AS content_md5
FROM {{SRC_CONTRACTS}};

CREATE OR REPLACE VIEW STG_VENDORS AS
SELECT vendor_id::VARCHAR        AS vendor_id,
       vendor_name::VARCHAR      AS vendor_name,
       default_currency::VARCHAR AS default_currency
FROM {{SRC_VENDORS}};

CREATE OR REPLACE VIEW STG_PURCHASE_ORDERS AS
SELECT po_id::VARCHAR              AS po_id,
       vendor_id::VARCHAR          AS vendor_id,
       po_date::DATE               AS po_date,
       contract_reference::VARCHAR AS contract_reference,   -- free text; a hint, never a key
       sku::VARCHAR                AS sku,
       quantity::NUMBER(18,4)      AS quantity,
       unit_price::NUMBER(18,4)    AS unit_price,
       currency::VARCHAR           AS currency,
       gl_account::VARCHAR         AS gl_account,
       capex_flag::BOOLEAN         AS capex_flag
FROM {{SRC_POS}};

CREATE OR REPLACE VIEW STG_INVOICE_LINES AS
SELECT invoice_line_id::VARCHAR           AS invoice_line_id,
       invoice_id::VARCHAR                AS invoice_id,
       vendor_id::VARCHAR                 AS vendor_id,
       vendor_name_on_invoice::VARCHAR    AS vendor_name_on_invoice,
       po_id::VARCHAR                     AS po_id,
       invoice_date::DATE                 AS invoice_date,
       -- The date that selects the effective rate (best practices rule 5).
       -- If the source has no service date, map invoice_date here AND record
       -- the choice in the project file.
       service_period_start::DATE         AS service_period_start,
       service_period_end::DATE           AS service_period_end,
       NULLIF(TRIM(sku), '')::VARCHAR     AS sku,
       line_description::VARCHAR          AS line_description,
       quantity::NUMBER(18,4)             AS quantity,
       UPPER(TRIM(unit_of_measure))::VARCHAR AS unit_of_measure,
       unit_price::NUMBER(18,4)           AS unit_price,
       UPPER(TRIM(currency))::VARCHAR     AS currency,
       line_amount::NUMBER(18,2)          AS line_amount,
       gl_account::VARCHAR                AS gl_account,
       -- Replace with the GL rule from spend.capex_gl_rule if no flag column exists.
       capex_flag::BOOLEAN                AS capex_flag
FROM {{SRC_INVOICE_LINES}};

-- Party-name normalization used for vendor linking (best practices rule 10).
-- Uppercase, drop dots and commas so "G.m.b.H." becomes GMBH, turn every
-- other non-alphanumeric run into one space, then strip legal-form suffix
-- words. Applied twice to catch stacked suffixes such as "CO INC".
CREATE OR REPLACE FUNCTION NORMALIZE_PARTY_NAME(n VARCHAR)
RETURNS VARCHAR
AS
$$
    TRIM(REGEXP_REPLACE(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          ' ' || REGEXP_REPLACE(REGEXP_REPLACE(UPPER(COALESCE(n, '')), '[.,]', ''), '[^A-Z0-9]+', ' ') || ' ',
          ' (LLC|INC|INCORPORATED|CORP|CORPORATION|CO|COMPANY|LTD|LIMITED|GMBH|AG|SA|SAS|BV|NV|PLC|LLP|LP|SRL|SPA|PTY) ', ' '),
        ' (LLC|INC|INCORPORATED|CORP|CORPORATION|CO|COMPANY|LTD|LIMITED|GMBH|AG|SA|SAS|BV|NV|PLC|LLP|LP|SRL|SPA|PTY) ', ' '),
      ' +', ' '))
$$;

-- Verification:
--   SELECT NORMALIZE_PARTY_NAME('PROSEWARE CONSULTING G.m.b.H.')  -> PROSEWARE CONSULTING
--   SELECT NORMALIZE_PARTY_NAME('Proseware Consulting GmbH')      -> PROSEWARE CONSULTING
--   SELECT NORMALIZE_PARTY_NAME('Fabrikam Cloud Software, Inc.')  -> FABRIKAM CLOUD SOFTWARE
SELECT COUNT(*) AS documents FROM STG_CONTRACT_DOCUMENTS;   -- sandbox: 10
SELECT COUNT(*) AS invoice_lines FROM STG_INVOICE_LINES;    -- sandbox: 120
