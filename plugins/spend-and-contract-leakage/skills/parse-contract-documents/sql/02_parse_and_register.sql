-- =====================================================================
-- Phase 2b. Parse, classify, deduplicate, identify, form families and
-- link vendors.
--
-- AI functions: AI_PARSE_DOCUMENT (files only), AI_CLASSIFY,
--               AI_EXTRACT (document identity, first page only),
--               AI_SIMILARITY (near-duplicate check on candidate pairs only)
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}} {{SCHEMA}} {{RUN_ID}} {{EXPERIMENT_ID}} {{QUERY_TAG_PREFIX}}
--   {{STAGE}}               e.g. @SPEND_LEAKAGE.PIPELINE.CONTRACT_FILES (files only)
--   {{PARSE_SOURCE}}        TEXT | FILE | AUTO
--                           TEXT  use document_text only (sandbox default)
--                           FILE  parse file_path with AI_PARSE_DOCUMENT
--                           AUTO  text when present and longer than 500 chars, else file
--   {{MIN_CHARS_PER_PAGE}}  parse.min_chars_per_page
--   {{NEAR_DUP_SIM}}        parse.near_duplicate_similarity
--   {{BUYER_NAME}}          the customer's own legal name, so it is never
--                           extracted as the counterparty
--                           (sandbox: Synthetic Holdings Corp.)
--   {{VENDOR_JW_MIN}}       reconcile.vendor_name_jw_min
-- =====================================================================

USE DATABASE {{DB}};
USE SCHEMA {{SCHEMA}};
ALTER SESSION SET QUERY_TAG = '{{QUERY_TAG_PREFIX}}:parse:{{RUN_ID}}';

-- ---------------------------------------------------------------------
-- 1. Pages. One row per (document, page). Text-native documents become a
--    single page 0 with parse_source TEXT_NATIVE; files are parsed in
--    LAYOUT mode with page_split so every term can cite its page and so
--    rate-card tables survive as Markdown.
--
--    Caching: documents whose content_md5 is unchanged since a previous
--    run are not reparsed. On the first run the table does not exist yet;
--    create it empty first.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CONTRACT_PAGES (
    document_id   VARCHAR,
    page_index    INT,
    page_text     VARCHAR,
    parse_source  VARCHAR,        -- TEXT_NATIVE | AI_PARSE_DOCUMENT
    parse_mode    VARCHAR,        -- NULL | LAYOUT
    char_count    INT,
    parse_error   VARCHAR,
    content_md5   VARCHAR,
    run_id        VARCHAR,
    parsed_at     TIMESTAMP_NTZ
);

CREATE OR REPLACE TEMPORARY TABLE _DOCS_TO_PARSE AS
SELECT d.*,
       CASE
         WHEN '{{PARSE_SOURCE}}' = 'TEXT' THEN 'TEXT'
         WHEN '{{PARSE_SOURCE}}' = 'FILE' THEN 'FILE'
         WHEN d.document_text IS NOT NULL AND LENGTH(d.document_text) > 500 THEN 'TEXT'
         ELSE 'FILE'
       END AS route
FROM STG_CONTRACT_DOCUMENTS d
WHERE NOT EXISTS (
    SELECT 1 FROM CONTRACT_PAGES p
    WHERE p.document_id = d.document_id AND p.content_md5 = d.content_md5);

-- Remove stale pages for documents whose content changed.
DELETE FROM CONTRACT_PAGES
WHERE document_id IN (SELECT document_id FROM _DOCS_TO_PARSE);

-- 1a. Text-native.
INSERT INTO CONTRACT_PAGES
SELECT document_id, 0, document_text, 'TEXT_NATIVE', NULL,
       LENGTH(document_text),
       IFF(document_text IS NULL OR LENGTH(document_text) < {{MIN_CHARS_PER_PAGE}}, 'TEXT_MISSING_OR_SHORT', NULL),
       content_md5, '{{RUN_ID}}', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM _DOCS_TO_PARSE
WHERE route = 'TEXT';

-- 1b. Files. return_error_details => TRUE keeps the failure reason instead
--     of a bare NULL (best practices rule 23). A document that fails to
--     parse gets one page row with page_index -1 carrying the error, so it
--     is counted rather than silently missing.
INSERT INTO CONTRACT_PAGES
WITH parsed AS (
    SELECT d.document_id, d.content_md5,
           AI_PARSE_DOCUMENT(
               TO_FILE('{{STAGE}}', d.file_path),
               {'mode': 'LAYOUT', 'page_split': TRUE},
               TRUE) AS r
    FROM _DOCS_TO_PARSE d
    WHERE d.route = 'FILE'
)
SELECT p.document_id,
       f.value:index::INT,
       f.value:content::VARCHAR,
       'AI_PARSE_DOCUMENT', 'LAYOUT',
       LENGTH(f.value:content::VARCHAR),
       IFF(LENGTH(f.value:content::VARCHAR) < {{MIN_CHARS_PER_PAGE}}, 'LOW_TEXT_PAGE', NULL),
       p.content_md5, '{{RUN_ID}}', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM parsed p,
     LATERAL FLATTEN(input => p.r:value:pages) f
WHERE p.r:error IS NULL
UNION ALL
SELECT p.document_id, -1, NULL, 'AI_PARSE_DOCUMENT', 'LAYOUT', 0,
       COALESCE(p.r:error::VARCHAR, 'NO_PAGES_RETURNED'),
       p.content_md5, '{{RUN_ID}}', CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM parsed p
WHERE p.r:error IS NOT NULL OR ARRAY_SIZE(p.r:value:pages) = 0;

-- ---------------------------------------------------------------------
-- 2. Document-level text and exact-duplicate detection.
--    norm_text_hash collapses whitespace and case, so a re-exported copy
--    with different line breaks still hashes the same. The earliest
--    upload in each hash group is canonical (best practices rule 3).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _DOC_TEXT AS
WITH full_text AS (
    SELECT document_id,
           LISTAGG(page_text, '\n\n') WITHIN GROUP (ORDER BY page_index) AS full_text,
           GET(ARRAY_AGG(IFF(page_index >= 0, page_text, NULL))
               WITHIN GROUP (ORDER BY page_index), 0)::VARCHAR           AS first_page_text,
           COUNT_IF(page_index >= 0)                                     AS pages_parsed,
           MAX(parse_source)                                             AS parse_source,
           MAX(IFF(page_index = -1, parse_error, NULL))                  AS doc_parse_error,
           COUNT_IF(parse_error = 'LOW_TEXT_PAGE')                       AS low_text_pages
    FROM CONTRACT_PAGES
    GROUP BY document_id
)
SELECT d.document_id, d.clm_vendor_id, d.clm_title, d.file_path, d.uploaded_at,
       COALESCE(d.page_count, t.pages_parsed) AS page_count,
       t.full_text, t.first_page_text, t.parse_source, t.low_text_pages,
       CASE
         WHEN t.doc_parse_error IS NOT NULL                          THEN 'PARSE_FAILED'
         WHEN t.full_text IS NULL OR LENGTH(t.full_text) < {{MIN_CHARS_PER_PAGE}} THEN 'LOW_TEXT'
         ELSE 'OK'
       END AS parse_status,
       t.doc_parse_error,
       MD5(REGEXP_REPLACE(UPPER(t.full_text), '\\s+', ' ')) AS norm_text_hash,
       FIRST_VALUE(d.document_id) OVER (
           PARTITION BY MD5(REGEXP_REPLACE(UPPER(t.full_text), '\\s+', ' '))
           ORDER BY d.uploaded_at, d.document_id) AS hash_canonical_id
FROM STG_CONTRACT_DOCUMENTS d
LEFT JOIN full_text t ON t.document_id = d.document_id;

-- ---------------------------------------------------------------------
-- 3. Classification and identity, on canonical, parsed documents only.
--    AI_CLASSIFY reads the opening of the document, where the title and
--    recitals are. Descriptions are kept under 25 words as the function
--    requires. AI_EXTRACT reads the first page for the agreement number,
--    the agreement it amends or is issued under, the counterparty and the
--    effective date. Every answer must be the literal NOT_STATED when the
--    document does not say, so NULL can be read as FAILED (rule 16).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _DOC_AI AS
SELECT t.document_id,
       AI_CLASSIFY(
           LEFT(t.full_text, 6000),
           [
             {'label': 'MASTER_AGREEMENT',  'description': 'Primary agreement setting terms, pricing or rate schedules between buyer and a supplier, e.g. MSA, supply, purchase or staffing agreement.'},
             {'label': 'AMENDMENT',         'description': 'Document that modifies an existing agreement, such as an amendment, addendum, change order or extension.'},
             {'label': 'ORDER_FORM_OR_SOW', 'description': 'Order form, statement of work or subscription order with its own fees, issued under or alongside terms.'},
             {'label': 'NON_COMMERCIAL',    'description': 'Agreement with no fees or pricing, such as an NDA, confidentiality, data processing or insurance document.'},
             {'label': 'OTHER',             'description': 'Anything else: invoices, letters, quotes, correspondence, unsigned drafts.'}
           ],
           {'task_description': 'Classify a procurement contract document by its role in the supplier relationship.'},
           TRUE) AS cls,
       AI_EXTRACT(
           text => LEFT(COALESCE(t.first_page_text, t.full_text), 8000),
           responseFormat => {
             'agreement_number':        'What is the identifying number of THIS document (agreement, order form, statement of work or amendment number)? Return only the identifier, for example ABC-123. Answer NOT_STATED if none is given.',
             'parent_agreement_number': 'If this document amends, extends, or is issued under another numbered agreement, what is that other agreement number? Return only the identifier. Answer NOT_STATED if no other numbered agreement is referenced.',
             'counterparty_legal_name': 'What is the legal name of the supplier, vendor, provider, seller, agency or contractor party? Exclude {{BUYER_NAME}}, exclude addresses and city names. Answer NOT_STATED if not given.',
             'document_effective_date': 'On what date does this document take effect? Answer as YYYY-MM-DD, or NOT_STATED.'
           }) AS ident
FROM _DOC_TEXT t
WHERE t.parse_status = 'OK'
  AND t.document_id = t.hash_canonical_id;

-- ---------------------------------------------------------------------
-- 4. Registry with identity, vendor link, near-duplicate check and family.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE CONTRACT_REGISTRY AS
WITH base AS (
    SELECT t.*,
           a.cls:value:labels[0]::VARCHAR                                   AS doc_class_raw,
           a.cls:error::VARCHAR                                             AS classify_error,
           a.ident:error::VARCHAR                                           AS identity_error,
           NULLIF(UPPER(REGEXP_REPLACE(a.ident:response:agreement_number::VARCHAR,        '\\s+', '')), 'NOT_STATED') AS agreement_number,
           NULLIF(UPPER(REGEXP_REPLACE(a.ident:response:parent_agreement_number::VARCHAR, '\\s+', '')), 'NOT_STATED') AS parent_agreement_number,
           NULLIF(a.ident:response:counterparty_legal_name::VARCHAR, 'NOT_STATED') AS counterparty_name,
           TRY_TO_DATE(a.ident:response:document_effective_date::VARCHAR, 'YYYY-MM-DD') AS document_effective_date
    FROM _DOC_TEXT t
    LEFT JOIN _DOC_AI a ON a.document_id = t.hash_canonical_id
),
vnorm AS (
    SELECT vendor_id, NORMALIZE_PARTY_NAME(vendor_name) AS n FROM STG_VENDORS
),
name_exact AS (
    SELECT b.document_id, MIN(v.vendor_id) AS vendor_id, COUNT(*) AS candidates
    FROM base b JOIN vnorm v ON v.n = NORMALIZE_PARTY_NAME(b.counterparty_name)
    WHERE b.counterparty_name IS NOT NULL
    GROUP BY 1
),
name_fuzzy AS (
    SELECT b.document_id, IFF(COUNT(*) = 1, MIN(v.vendor_id), NULL) AS vendor_id
    FROM base b JOIN vnorm v
      ON JAROWINKLER_SIMILARITY(v.n, NORMALIZE_PARTY_NAME(b.counterparty_name)) >= {{VENDOR_JW_MIN}}
    WHERE b.counterparty_name IS NOT NULL
    GROUP BY 1
),
vendor_link AS (
    -- Rule 10: CLM id that resolves in the vendor master, then normalized
    -- exact name (unique), then Jaro-Winkler with exactly one candidate.
    SELECT b.document_id,
           v_clm.vendor_id                          AS clm_vendor_resolved,
           IFF(e.candidates = 1, e.vendor_id, NULL) AS name_exact_vendor,
           f.vendor_id                              AS name_fuzzy_vendor
    FROM base b
    LEFT JOIN STG_VENDORS v_clm ON v_clm.vendor_id = b.clm_vendor_id
    LEFT JOIN name_exact e ON e.document_id = b.document_id
    LEFT JOIN name_fuzzy f ON f.document_id = b.document_id
),
linked AS (
    SELECT b.*,
           COALESCE(l.clm_vendor_resolved, l.name_exact_vendor, l.name_fuzzy_vendor) AS vendor_id,
           CASE WHEN l.clm_vendor_resolved IS NOT NULL THEN 'CLM_ID'
                WHEN l.name_exact_vendor   IS NOT NULL THEN 'NAME_NORMALIZED'
                WHEN l.name_fuzzy_vendor   IS NOT NULL THEN 'NAME_FUZZY'
                ELSE 'UNLINKED' END AS vendor_link_method,
           -- Classification is inherited from the canonical copy for exact duplicates.
           CASE WHEN b.parse_status <> 'OK' THEN NULL
                WHEN b.doc_class_raw IS NULL THEN 'CLASSIFY_FAILED'
                ELSE b.doc_class_raw END AS doc_class
    FROM base b
    JOIN vendor_link l ON l.document_id = b.document_id
)
SELECT l.document_id, l.clm_vendor_id, l.clm_title, l.file_path, l.uploaded_at, l.page_count,
       l.parse_source, l.parse_status, l.doc_parse_error, l.low_text_pages,
       l.full_text, l.norm_text_hash,
       l.doc_class, l.classify_error, l.identity_error,
       l.agreement_number, l.parent_agreement_number,
       l.counterparty_name, NORMALIZE_PARTY_NAME(l.counterparty_name) AS counterparty_norm,
       l.document_effective_date,
       l.vendor_id, l.vendor_link_method,
       IFF(l.document_id <> l.hash_canonical_id, l.hash_canonical_id, NULL) AS is_duplicate_of,
       IFF(l.document_id <> l.hash_canonical_id, 'EXACT_HASH', NULL)       AS duplicate_method,
       CAST(NULL AS VARCHAR) AS contract_family_id,
       CAST(NULL AS VARCHAR) AS family_role,
       '{{RUN_ID}}' AS run_id, '{{EXPERIMENT_ID}}' AS experiment_id,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ AS registered_at
FROM linked l;

-- 4a. Near-duplicates: rescans whose OCR text differs slightly. Candidate
--     pairs only: same vendor, same class, same agreement number, both
--     canonical by hash. Similarity alone is never enough (two annual SOWs
--     are near-identical and are not duplicates).
UPDATE CONTRACT_REGISTRY r
SET is_duplicate_of = c.keep_id,
    duplicate_method = 'NEAR_DUPLICATE'
FROM (
    SELECT b.document_id AS drop_id, a.document_id AS keep_id
    FROM CONTRACT_REGISTRY a
    JOIN CONTRACT_REGISTRY b
      ON a.vendor_id = b.vendor_id
     AND a.doc_class = b.doc_class
     AND a.agreement_number = b.agreement_number
     AND (a.uploaded_at < b.uploaded_at
          OR (a.uploaded_at = b.uploaded_at AND a.document_id < b.document_id))
    WHERE a.is_duplicate_of IS NULL AND b.is_duplicate_of IS NULL
      AND a.doc_class IN ('MASTER_AGREEMENT', 'ORDER_FORM_OR_SOW', 'AMENDMENT')
      AND AI_SIMILARITY(LEFT(a.full_text, 6000), LEFT(b.full_text, 6000)) >= {{NEAR_DUP_SIM}}
    QUALIFY ROW_NUMBER() OVER (PARTITION BY b.document_id ORDER BY a.uploaded_at, a.document_id) = 1
) c
WHERE r.document_id = c.drop_id;

-- 4b. Exact duplicates inherit identity from their canonical copy, so the
--     duplicate is visibly the same agreement (and fails rule 3 if it ever
--     governs).
UPDATE CONTRACT_REGISTRY r
SET doc_class = k.doc_class,
    agreement_number = k.agreement_number,
    parent_agreement_number = k.parent_agreement_number,
    counterparty_name = k.counterparty_name,
    counterparty_norm = k.counterparty_norm,
    document_effective_date = k.document_effective_date,
    vendor_id = COALESCE(r.vendor_id, k.vendor_id),
    vendor_link_method = IFF(r.vendor_id IS NULL, 'INHERITED_FROM_CANONICAL', r.vendor_link_method)
FROM CONTRACT_REGISTRY k
WHERE r.duplicate_method = 'EXACT_HASH' AND k.document_id = r.is_duplicate_of;

-- 4c. Families. A governing document is a canonical master agreement or
--     order form/SOW; its family id is its agreement number (or a
--     document-scoped id when none was found). An amendment joins the
--     family of the agreement it names. An amendment naming a number no
--     governing document carries is an ORPHAN_AMENDMENT and drives nothing.
UPDATE CONTRACT_REGISTRY
SET family_role = CASE
        WHEN is_duplicate_of IS NOT NULL                              THEN 'DUPLICATE'
        WHEN parse_status <> 'OK'                                     THEN 'EXCLUDED_PARSE'
        WHEN doc_class IN ('MASTER_AGREEMENT', 'ORDER_FORM_OR_SOW')   THEN 'GOVERNING'
        WHEN doc_class = 'AMENDMENT'                                  THEN 'AMENDMENT'
        ELSE 'EXCLUDED_NON_COMMERCIAL' END,
    contract_family_id = CASE
        WHEN is_duplicate_of IS NULL AND parse_status = 'OK'
         AND doc_class IN ('MASTER_AGREEMENT', 'ORDER_FORM_OR_SOW')
        THEN COALESCE(agreement_number, 'DOC:' || document_id)
        ELSE NULL END;

UPDATE CONTRACT_REGISTRY a
SET contract_family_id = g.contract_family_id
FROM CONTRACT_REGISTRY g
WHERE a.family_role = 'AMENDMENT'
  AND g.family_role = 'GOVERNING'
  AND g.agreement_number = a.parent_agreement_number;

UPDATE CONTRACT_REGISTRY
SET family_role = 'ORPHAN_AMENDMENT'
WHERE family_role = 'AMENDMENT' AND contract_family_id IS NULL;

-- Duplicates point at their canonical copy's family for traceability, but
-- keep family_role = 'DUPLICATE' so no extraction runs on them.
UPDATE CONTRACT_REGISTRY d
SET contract_family_id = k.contract_family_id
FROM CONTRACT_REGISTRY k
WHERE d.family_role = 'DUPLICATE' AND k.document_id = d.is_duplicate_of;

ALTER SESSION UNSET QUERY_TAG;

-- =====================================================================
-- Verification. Show these results at the gate.
-- =====================================================================

-- V1. Documents by parse source, status and class.
SELECT parse_source, parse_status, doc_class, family_role, COUNT(*) AS docs
FROM CONTRACT_REGISTRY GROUP BY 1, 2, 3, 4 ORDER BY 1, 2, 3, 4;
-- Sandbox (text): 7 GOVERNING (5 MASTER_AGREEMENT, 2 ORDER_FORM_OR_SOW),
-- 1 AMENDMENT, 1 DUPLICATE, 1 EXCLUDED_NON_COMMERCIAL. Zero PARSE_FAILED.

-- V2. Parse failures and low-text pages. Investigate every row.
SELECT document_id, page_index, char_count, parse_error
FROM CONTRACT_PAGES WHERE parse_error IS NOT NULL ORDER BY 1, 2;

-- V3. Exactly one governing document per family (rule 3).
SELECT contract_family_id, COUNT_IF(family_role = 'GOVERNING') AS governing
FROM CONTRACT_REGISTRY WHERE contract_family_id IS NOT NULL
GROUP BY 1 HAVING governing <> 1;
-- Expect zero rows.

-- V4. Family, vendor and link method per document.
SELECT document_id, doc_class, family_role, contract_family_id, agreement_number,
       parent_agreement_number, vendor_id, vendor_link_method, is_duplicate_of
FROM CONTRACT_REGISTRY ORDER BY contract_family_id NULLS LAST, document_id;
-- Sandbox: 7 families (SYN-MSA-1001, SYN-SUP-2001, SYN-OF-3001, SYN-EPA-4001,
-- SYN-STF-6001, SYN-TEL-7001, SYN-SOW-8001); SYN-DOC-C001-A1 in SYN-MSA-1001;
-- SYN-DOC-C001-DUP DUPLICATE of SYN-DOC-C001; SYN-DOC-C008 linked to SYN-V008
-- by NAME_NORMALIZED; SYN-DOC-N008 EXCLUDED_NON_COMMERCIAL.

-- V5. Classification or identity failures. Must be zero or explained.
SELECT document_id, classify_error, identity_error
FROM CONTRACT_REGISTRY
WHERE classify_error IS NOT NULL OR identity_error IS NOT NULL OR doc_class = 'CLASSIFY_FAILED';

-- V6. Governing documents with no vendor link. Each one turns all of that
--     supplier's spend into OFF_CONTRACT downstream.
SELECT document_id, counterparty_name, counterparty_norm
FROM CONTRACT_REGISTRY WHERE family_role = 'GOVERNING' AND vendor_id IS NULL;
-- Expect zero rows on the sandbox.
