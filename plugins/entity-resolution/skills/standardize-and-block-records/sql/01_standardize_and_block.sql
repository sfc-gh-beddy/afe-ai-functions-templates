-- =====================================================================
-- Phase 2: standardize source records and generate candidate pairs.
-- No AI calls. Substitute {{SCHEMA}} and {{MAX_BLOCK_SIZE}}.
--
-- Section 1 (ER_SOURCE_STAGING) is written for the sandbox tables. For real
-- data, generate it from the `sources` block of er-project.yml: one SELECT
-- per source, mapping each configured column and leaving unmapped ones NULL,
-- applying each source's `filter`. Never select columns listed in
-- `excluded_from_ai` — they are not needed anywhere in this pipeline.
-- =====================================================================

USE SCHEMA {{SCHEMA}};

-- ---------------------------------------------------------------------
-- 0. Token normalization map. Data, not nested REPLACE calls (rule 3).
--    domain: PARTY | ADDRESS | PRODUCT
--    token_class: LEGAL_SUFFIX | ABBREVIATION | STOPWORD
--    Extend this table from the customer's own top tokens (see SKILL.md).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ER_TOKEN_MAP (
    domain      VARCHAR,
    token       VARCHAR,
    canonical   VARCHAR,
    token_class VARCHAR
);

INSERT INTO ER_TOKEN_MAP (domain, token, canonical, token_class) VALUES
  ('PARTY','INC','INC','LEGAL_SUFFIX'), ('PARTY','INCORPORATED','INC','LEGAL_SUFFIX'),
  ('PARTY','LLC','LLC','LEGAL_SUFFIX'), ('PARTY','CORP','CORP','LEGAL_SUFFIX'),
  ('PARTY','CORPORATION','CORP','LEGAL_SUFFIX'), ('PARTY','CO','CO','LEGAL_SUFFIX'),
  ('PARTY','COMPANY','CO','LEGAL_SUFFIX'), ('PARTY','LTD','LTD','LEGAL_SUFFIX'),
  ('PARTY','LIMITED','LTD','LEGAL_SUFFIX'), ('PARTY','PLC','PLC','LEGAL_SUFFIX'),
  ('PARTY','GMBH','GMBH','LEGAL_SUFFIX'), ('PARTY','LLP','LLP','LEGAL_SUFFIX'),
  ('PARTY','LP','LP','LEGAL_SUFFIX'),
  ('PARTY','THE','THE','STOPWORD'), ('PARTY','AND','AND','STOPWORD'), ('PARTY','OF','OF','STOPWORD'),
  ('PARTY','MFG','MANUFACTURING','ABBREVIATION'), ('PARTY','SVCS','SERVICES','ABBREVIATION'),
  ('PARTY','SVC','SERVICES','ABBREVIATION'), ('PARTY','DIST','DISTRIBUTION','ABBREVIATION'),
  ('PARTY','TECH','TECHNOLOGIES','ABBREVIATION'), ('PARTY','ENG','ENGINEERING','ABBREVIATION'),
  ('PARTY','INDS','INDUSTRIES','ABBREVIATION'), ('PARTY','INTL','INTERNATIONAL','ABBREVIATION'),
  ('PARTY','PKG','PACKAGING','ABBREVIATION'), ('PARTY','ELEC','ELECTRIC','ABBREVIATION'),
  ('PARTY','GRP','GROUP','ABBREVIATION'), ('PARTY','ASSOC','ASSOCIATES','ABBREVIATION'),
  ('ADDRESS','ST','STREET','ABBREVIATION'), ('ADDRESS','AVE','AVENUE','ABBREVIATION'),
  ('ADDRESS','RD','ROAD','ABBREVIATION'), ('ADDRESS','BLVD','BOULEVARD','ABBREVIATION'),
  ('ADDRESS','DR','DRIVE','ABBREVIATION'), ('ADDRESS','LN','LANE','ABBREVIATION'),
  ('ADDRESS','PKWY','PARKWAY','ABBREVIATION'), ('ADDRESS','STE','SUITE','ABBREVIATION'),
  ('ADDRESS','N','NORTH','ABBREVIATION'), ('ADDRESS','S','SOUTH','ABBREVIATION'),
  ('ADDRESS','E','EAST','ABBREVIATION'), ('ADDRESS','W','WEST','ABBREVIATION'),
  ('PRODUCT','SS','STAINLESS STEEL','ABBREVIATION'), ('PRODUCT','HD','HEAVY DUTY','ABBREVIATION'),
  ('PRODUCT','BLK','BLACK','ABBREVIATION'), ('PRODUCT','WHT','WHITE','ABBREVIATION'),
  ('PRODUCT','CNTR','CONTAINER','ABBREVIATION'), ('PRODUCT','CONC','CONCENTRATE','ABBREVIATION'),
  ('PRODUCT','PK','PACK','ABBREVIATION');

-- Public and free-mail domains. A shared free-mail domain is not evidence.
CREATE OR REPLACE TABLE ER_FREE_EMAIL_DOMAINS (domain VARCHAR);
INSERT INTO ER_FREE_EMAIL_DOMAINS VALUES
  ('freemail.example'), ('gmail.com'), ('yahoo.com'), ('outlook.com'), ('hotmail.com'),
  ('aol.com'), ('icloud.com'), ('proton.me'), ('protonmail.com'), ('live.com'), ('msn.com');

-- ---------------------------------------------------------------------
-- 1. Source staging: one row per in-scope source record, mapped columns.
--    record_uid = source_system || ':' || source_record_id (rule 4).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ER_SOURCE_STAGING AS
WITH ecom AS (
    SELECT *, SPLIT(address, ', ') AS parts FROM SYNTH_ECOM_ACCOUNTS
),
p2p AS (
    SELECT *,
           SPLIT_PART(hq_address, ', ', 1) AS street_part,
           SPLIT_PART(hq_address, ', ', 2) AS locality_part
    FROM SYNTH_P2P_SUPPLIERS
)
SELECT 'CUSTOMER' AS entity_type, 'CRM' AS source_system, TRIM(account_id::VARCHAR) AS source_record_id,
       2 AS trust_rank, last_modified_at::TIMESTAMP_NTZ AS updated_at,
       account_name AS name_raw, billing_street AS address_raw, billing_city AS city_raw,
       billing_state AS region_raw, billing_postal_code AS postal_raw, billing_country AS country_raw,
       phone AS phone_raw, NULL::VARCHAR AS email_raw, website AS website_raw, NULL::VARCHAR AS tax_id_raw,
       NULL::VARCHAR AS brand_raw, NULL::VARCHAR AS mpn_raw, NULL::VARCHAR AS gtin_raw, NULL::VARCHAR AS size_raw
FROM SYNTH_CRM_ACCOUNTS
WHERE account_status = 'ACTIVE'
UNION ALL
SELECT 'CUSTOMER', 'BILLING', TRIM(cust_no::VARCHAR), 1, updated_ts::TIMESTAMP_NTZ,
       customer_name, TRIM(addr_line1 || COALESCE(' ' || addr_line2, '')), city, state_prov, zip, country_code,
       phone_number, contact_email, NULL, tax_registration,
       NULL, NULL, NULL, NULL
FROM SYNTH_BILLING_CUSTOMERS
UNION ALL
SELECT 'CUSTOMER', 'ECOM', TRIM(org_uuid::VARCHAR), 3, created_at::TIMESTAMP_NTZ,
       company,
       parts[0]::STRING,
       parts[1]::STRING,
       SPLIT_PART(parts[2]::STRING, ' ', 1),
       NULLIF(TRIM(SUBSTR(parts[2]::STRING, POSITION(' ' IN parts[2]::STRING || ' '))), ''),
       parts[ARRAY_SIZE(parts) - 1]::STRING,
       NULL, email, NULL, NULL,
       NULL, NULL, NULL, NULL
FROM ecom
UNION ALL
-- The ERP name field is 35 characters; long names overflow into name_2.
-- Blocked vendors are excluded (rule 5).
SELECT 'VENDOR', 'ERP_' || company_code, TRIM(vendor_id::VARCHAR), 1, changed_on::TIMESTAMP_NTZ,
       vendor_name || COALESCE(name_2, ''), street, city, region, postal_code, country,
       telephone, NULL, NULL, tax_number,
       NULL, NULL, NULL, NULL
FROM SYNTH_ERP_VENDORS
WHERE blocked_flag IS NULL
UNION ALL
SELECT 'VENDOR', 'P2P', TRIM(supplier_id::VARCHAR), 2, updated_at::TIMESTAMP_NTZ,
       COALESCE(legal_name, dba_name), street_part,
       REGEXP_SUBSTR(locality_part, '^(.*) ([A-Z]{2,3})( [A-Z0-9]{2,6}(-[0-9]{4})?)?$', 1, 1, 'e', 1),
       REGEXP_SUBSTR(locality_part, '^(.*) ([A-Z]{2,3})( [A-Z0-9]{2,6}(-[0-9]{4})?)?$', 1, 1, 'e', 2),
       TRIM(REGEXP_SUBSTR(locality_part, '^(.*) ([A-Z]{2,3})( [A-Z0-9]{2,6}(-[0-9]{4})?)?$', 1, 1, 'e', 3)),
       country, phone, 'contact@' || email_domain, NULL, tax_id,
       NULL, NULL, NULL, NULL
FROM p2p
UNION ALL
SELECT 'PRODUCT', 'PIM', TRIM(product_code::VARCHAR), 1, updated_at::TIMESTAMP_NTZ,
       product_title, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       brand_name, NULL, gtin, size_text
FROM SYNTH_PIM_PRODUCTS
UNION ALL
SELECT 'PRODUCT', 'ERP_ITEM', TRIM(item_number::VARCHAR), 2, last_change::TIMESTAMP_NTZ,
       item_desc, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, mfr_part_no, gtin, item_desc
FROM SYNTH_ERP_ITEMS
UNION ALL
SELECT 'PRODUCT', 'SUPPLIER_CAT', TRIM(sku::VARCHAR), 3, updated_at::TIMESTAMP_NTZ,
       description, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       manufacturer, mpn, gtin, description
FROM SYNTH_SUPPLIER_CATALOG;

-- ---------------------------------------------------------------------
-- 2. Canonical records. One shared expression per attribute (rule 2).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ER_RECORDS AS
WITH base AS (
    SELECT
        s.*,
        s.source_system || ':' || s.source_record_id AS record_uid,
        -- Upper-case, '&' to AND, collapse dotted L.L.C., strip punctuation, squeeze spaces.
        TRIM(REGEXP_REPLACE(
            REGEXP_REPLACE(
                REGEXP_REPLACE(REPLACE(UPPER(s.name_raw), '&', ' AND '), 'L\\.\\s?L\\.\\s?C\\.?', 'LLC'),
                '[^A-Z0-9 ]', ' '),
            '\\s+', ' ')) AS name_clean,
        TRIM(REGEXP_REPLACE(REGEXP_REPLACE(UPPER(s.address_raw), '[^A-Z0-9 ]', ' '), '\\s+', ' ')) AS address_clean
    FROM ER_SOURCE_STAGING s
),
name_tokens AS (
    SELECT b.record_uid, f.index AS pos, f.value::STRING AS tok,
           IFF(b.entity_type = 'PRODUCT', 'PRODUCT', 'PARTY') AS dom
    FROM base b, LATERAL FLATTEN(input => SPLIT(b.name_clean, ' ')) f
    WHERE f.value::STRING <> ''
),
name_mapped AS (
    SELECT t.record_uid, t.pos,
           COALESCE(m.canonical, t.tok) AS ctok,
           m.token_class
    FROM name_tokens t
    LEFT JOIN ER_TOKEN_MAP m ON m.domain = t.dom AND m.token = t.tok
),
name_agg AS (
    SELECT record_uid,
           LISTAGG(ctok, ' ') WITHIN GROUP (ORDER BY pos) AS name_norm,
           -- LISTAGG skips NULLs, so suffixes and stopwords drop out of name_core.
           LISTAGG(IFF(token_class IN ('LEGAL_SUFFIX','STOPWORD'), NULL, ctok), ' ')
               WITHIN GROUP (ORDER BY pos) AS name_core
    FROM name_mapped
    GROUP BY record_uid
),
addr_tokens AS (
    SELECT b.record_uid, f.index AS pos, f.value::STRING AS tok
    FROM base b, LATERAL FLATTEN(input => SPLIT(b.address_clean, ' ')) f
    WHERE f.value::STRING <> ''
),
addr_agg AS (
    SELECT t.record_uid,
           LISTAGG(COALESCE(m.canonical, t.tok), ' ') WITHIN GROUP (ORDER BY t.pos) AS address_norm
    FROM addr_tokens t
    LEFT JOIN ER_TOKEN_MAP m ON m.domain = 'ADDRESS' AND m.token = t.tok
    GROUP BY t.record_uid
),
shaped AS (
    SELECT
        b.record_uid, b.entity_type, b.source_system, b.source_record_id, b.trust_rank, b.updated_at,
        b.name_raw,
        n.name_norm,
        NULLIF(n.name_core, '')                                            AS name_core,
        SPLIT_PART(NULLIF(n.name_core, ''), ' ', 1)                        AS name_first_token,
        a.address_norm,
        -- Address key without suite / unit designators, for comparison.
        TRIM(REGEXP_REPLACE(a.address_norm, '\\s(SUITE|UNIT|FLOOR|FL|APT)\\s\\S+', ''))   AS address_key,
        NULLIF(TRIM(UPPER(b.city_raw)), '')                                AS city_norm,
        NULLIF(TRIM(UPPER(b.region_raw)), '')                              AS region_norm,
        NULLIF(TRIM(UPPER(b.country_raw)), '')                             AS country_norm,
        CASE WHEN UPPER(TRIM(b.country_raw)) = 'US'
             THEN NULLIF(LEFT(REGEXP_REPLACE(b.postal_raw, '[^0-9]', ''), 5), '')
             ELSE NULLIF(REGEXP_REPLACE(UPPER(b.postal_raw), '[^A-Z0-9]', ''), '') END AS postal_norm,
        -- Digits only, drop a leading country code 1, keep 10.
        RIGHT(REGEXP_REPLACE(b.phone_raw, '[^0-9]', ''), 10)               AS phone_digits,
        NULLIF(LOWER(SPLIT_PART(TRIM(b.email_raw), '@', 2)), '')           AS email_domain_raw,
        NULLIF(LOWER(REGEXP_REPLACE(REGEXP_REPLACE(TRIM(b.website_raw), '^(https?://)?(www\\.)?', ''), '/.*$', '')), '') AS website_domain,
        NULLIF(REGEXP_REPLACE(UPPER(b.tax_id_raw), '[^A-Z0-9]', ''), '')   AS tax_id_clean,
        NULLIF(TRIM(UPPER(b.brand_raw)), '')                               AS brand_norm,
        NULLIF(REGEXP_REPLACE(UPPER(b.mpn_raw), '[^A-Z0-9]', ''), '')      AS mpn_norm,
        NULLIF(LPAD(REGEXP_REPLACE(b.gtin_raw, '[^0-9]', ''), 14, '0'), '00000000000000') AS gtin_norm,
        -- Size in ounces from text like '12 oz', '12OZ', '12-Ounce', '355 ml'.
        CASE
            WHEN REGEXP_LIKE(UPPER(b.size_raw), '.*[0-9]+(\\.[0-9]+)?\\s*-?\\s*(OZ|OUNCE).*')
              THEN TO_DOUBLE(REGEXP_SUBSTR(UPPER(b.size_raw), '([0-9]+(\\.[0-9]+)?)\\s*-?\\s*(OZ|OUNCE)', 1, 1, 'e', 1))
            WHEN REGEXP_LIKE(UPPER(b.size_raw), '.*[0-9]+(\\.[0-9]+)?\\s*ML.*')
              THEN ROUND(TO_DOUBLE(REGEXP_SUBSTR(UPPER(b.size_raw), '([0-9]+(\\.[0-9]+)?)\\s*ML', 1, 1, 'e', 1)) / 29.5735, 1)
        END                                                                AS size_oz
    FROM base b
    LEFT JOIN name_agg n ON n.record_uid = b.record_uid
    LEFT JOIN addr_agg a ON a.record_uid = b.record_uid
),
with_text AS (
SELECT
    s.* EXCLUDE (phone_digits, email_domain_raw, tax_id_clean),
    -- Placeholder exclusion (rule 8): too short, or one repeated digit.
    IFF(LENGTH(s.phone_digits) >= 10 AND LENGTH(REPLACE(s.phone_digits, LEFT(s.phone_digits, 1), '')) > 0,
        s.phone_digits, NULL)                                               AS phone_norm,
    IFF(fe.domain IS NULL, s.email_domain_raw, NULL)                        AS email_domain,
    IFF(LENGTH(s.tax_id_clean) >= 5
        AND NOT REGEXP_LIKE(s.tax_id_clean, '^(SYN)?0+$')
        AND s.tax_id_clean NOT IN ('NA', 'NONE', 'UNKNOWN', 'TBD', 'PENDING'),
        s.tax_id_clean, NULL)                                               AS tax_id_norm,
    -- Embedding text: identity-bearing attributes only, front-loaded, NULL-safe
    -- (rules 1 and 13). Identifiers are compared in SQL, not embedded.
    CASE WHEN s.entity_type = 'PRODUCT' THEN
        ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
            'product: ' || s.name_norm,
            'brand: '   || s.brand_norm,
            'size: '    || TO_VARCHAR(s.size_oz) || ' oz'), ' | ')
    ELSE
        ARRAY_TO_STRING(ARRAY_CONSTRUCT_COMPACT(
            'name: '    || s.name_norm,
            'address: ' || s.address_key,
            'city: '    || s.city_norm,
            'region: '  || s.region_norm,
            'country: ' || s.country_norm), ' | ')
    END                                                                     AS embed_text
FROM shaped s
LEFT JOIN ER_FREE_EMAIL_DOMAINS fe ON fe.domain = s.email_domain_raw
)
SELECT w.*, SHA2(w.embed_text, 256) AS embed_text_hash
FROM with_text w;

-- ---------------------------------------------------------------------
-- 3. Blocking keys. Several independent passes (rule 7). A key is only
--    emitted when its inputs are present; NULL keys never form blocks.
--    SEMANTIC_KNN is added in the score phase, once embeddings exist.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ER_BLOCK_KEYS AS
SELECT record_uid, entity_type, 'NAME_PREFIX_POSTAL' AS block_rule,
       LEFT(name_first_token, 4) || '|' || LEFT(postal_norm, 3) AS block_key
FROM ER_RECORDS
WHERE entity_type <> 'PRODUCT' AND LENGTH(name_first_token) >= 2 AND postal_norm IS NOT NULL
UNION ALL
SELECT record_uid, entity_type, 'NAME_SOUNDEX_CITY',
       SOUNDEX(name_first_token) || '|' || city_norm
FROM ER_RECORDS
WHERE entity_type <> 'PRODUCT' AND name_first_token IS NOT NULL AND city_norm IS NOT NULL
UNION ALL
-- First two core tokens within country: catches records missing postal and city.
SELECT record_uid, entity_type, 'NAME_CORE_2TOK_COUNTRY',
       SPLIT_PART(name_core, ' ', 1) || ' ' || SPLIT_PART(name_core, ' ', 2) || '|' || COALESCE(country_norm, '?')
FROM ER_RECORDS
WHERE entity_type <> 'PRODUCT' AND SPLIT_PART(name_core, ' ', 2) <> ''
UNION ALL
SELECT record_uid, entity_type, 'TAX_ID', tax_id_norm
FROM ER_RECORDS WHERE tax_id_norm IS NOT NULL
UNION ALL
SELECT record_uid, entity_type, 'PHONE', phone_norm
FROM ER_RECORDS WHERE phone_norm IS NOT NULL
UNION ALL
SELECT record_uid, entity_type, 'EMAIL_DOMAIN', email_domain
FROM ER_RECORDS WHERE email_domain IS NOT NULL
UNION ALL
SELECT record_uid, entity_type, 'WEBSITE_DOMAIN', website_domain
FROM ER_RECORDS WHERE website_domain IS NOT NULL
UNION ALL
-- Products: brand (or first description token when brand is not mapped) plus
-- the last description token, which is usually the product noun.
SELECT record_uid, entity_type, 'PRODUCT_BRAND_TYPE',
       COALESCE(brand_norm, SPLIT_PART(name_norm, ' ', 1)) || '|'
         || REGEXP_SUBSTR(name_norm, '(BOTTLE|CONCENTRATE|GLOVES|MUG|GEL|TOWELS|CONTAINER|CLEANER|TIES|GLASSES)')
FROM ER_RECORDS
WHERE entity_type = 'PRODUCT'
  AND REGEXP_SUBSTR(name_norm, '(BOTTLE|CONCENTRATE|GLOVES|MUG|GEL|TOWELS|CONTAINER|CLEANER|TIES|GLASSES)') IS NOT NULL
UNION ALL
SELECT record_uid, entity_type, 'PRODUCT_MPN', mpn_norm
FROM ER_RECORDS WHERE entity_type = 'PRODUCT' AND mpn_norm IS NOT NULL
UNION ALL
SELECT record_uid, entity_type, 'PRODUCT_GTIN', gtin_norm
FROM ER_RECORDS WHERE entity_type = 'PRODUCT' AND gtin_norm IS NOT NULL;

-- The PRODUCT_BRAND_TYPE noun list above is sandbox vocabulary. On real data,
-- replace it with a category column when the source has one, or with the top
-- product nouns found at preflight. Never ship the sandbox list to production.

-- ---------------------------------------------------------------------
-- 4. Block statistics and the cap (rule 8). Capped blocks are logged, never
--    silently dropped.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ER_BLOCK_STATS AS
SELECT entity_type, block_rule, block_key,
       COUNT(*)                                  AS block_size,
       COUNT(*) * (COUNT(*) - 1) / 2             AS potential_pairs,
       COUNT(*) > {{MAX_BLOCK_SIZE}}             AS is_capped
FROM ER_BLOCK_KEYS
GROUP BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- 5. Candidate pairs: canonical order, no self-pairs, same entity type,
--    uncapped blocks only, with the list of rules that produced each pair.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE ER_CANDIDATE_PAIRS AS
WITH k AS (
    SELECT bk.*
    FROM ER_BLOCK_KEYS bk
    JOIN ER_BLOCK_STATS bs
      ON bs.entity_type = bk.entity_type
     AND bs.block_rule  = bk.block_rule
     AND bs.block_key   = bk.block_key
    WHERE NOT bs.is_capped AND bs.block_size > 1
)
SELECT
    SHA2(a.record_uid || '|' || b.record_uid, 256)          AS pair_id,
    a.entity_type,
    a.record_uid                                            AS record_uid_a,
    b.record_uid                                            AS record_uid_b,
    ARRAY_AGG(DISTINCT a.block_rule) WITHIN GROUP (ORDER BY a.block_rule) AS block_rules,
    CURRENT_TIMESTAMP()                                     AS generated_at
FROM k a
JOIN k b
  ON  a.entity_type = b.entity_type
  AND a.block_rule  = b.block_rule
  AND a.block_key   = b.block_key
  AND a.record_uid  < b.record_uid
GROUP BY 1, 2, 3, 4;

-- Pipeline quality log, shared by every phase.
CREATE TABLE IF NOT EXISTS ER_PIPELINE_QUALITY_LOG (
    run_id      VARCHAR,
    phase       VARCHAR,
    check_name  VARCHAR,
    check_value NUMBER,
    detail      VARIANT,
    logged_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
