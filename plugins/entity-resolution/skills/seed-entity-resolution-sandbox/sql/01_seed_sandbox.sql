-- =====================================================================
-- Synthetic multi-system master data with planted duplicates and a
-- labeled answer key, for entity resolution development and accuracy
-- measurement.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}               target database
--   {{SCHEMA}}           schema for synthetic source tables (pipeline reads these)
--   {{EVAL_SCHEMA}}      schema for ground truth (quarantined; pipeline never reads)
--   {{PARTY_ENTITIES}}   number of true organizations, e.g. 1500 (max 7200)
--   {{PRODUCT_BASES}}    number of base products, e.g. 150 (each gets 3 size variants)
--
-- Everything is fabricated. Organization names are combinations of invented
-- words; cities are invented; phone numbers use the 555 exchange; web and
-- email domains use the reserved .example TLD; tax ids carry an SYN- prefix
-- and GTINs a 99 prefix so no value can be mistaken for a real identifier.
--
-- Determinism: all variation is driven by ABS(HASH(...)) of stable inputs,
-- not RANDOM(), so the corpus is reproducible across runs and accounts.
--
-- LEAKAGE GUARD: source record ids are derived from a salted hash of
-- (entity, copy, system), never from the true entity id in readable form.
-- Nothing in a source table reveals which records share an entity.
-- =====================================================================

USE DATABASE {{DB}};
CREATE SCHEMA IF NOT EXISTS {{SCHEMA}};
CREATE SCHEMA IF NOT EXISTS {{EVAL_SCHEMA}};

-- ---------------------------------------------------------------------
-- 0. Word pools and fictional geography.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_GEO (
    geo_idx      INT,
    city         VARCHAR,
    region       VARCHAR,
    postal_base  VARCHAR,
    area_code    VARCHAR,
    country      VARCHAR
);

INSERT INTO {{EVAL_SCHEMA}}.SYNTH_GEO VALUES
 ( 0,'Port Ellery'   ,'NY','114','212','US'), ( 1,'Marston'       ,'NJ','076','201','US'),
 ( 2,'Kelby Falls'   ,'PA','190','215','US'), ( 3,'Ashgrove'      ,'OH','441','216','US'),
 ( 4,'Dunmere'       ,'IL','606','312','US'), ( 5,'Corran Bay'    ,'WA','981','206','US'),
 ( 6,'Halvern'       ,'TX','752','214','US'), ( 7,'Westbrook Hill','GA','303','404','US'),
 ( 8,'Tarrow'        ,'MN','554','612','US'), ( 9,'Selby Cross'   ,'CO','802','303','US'),
 (10,'Ravensmoor'    ,'AZ','850','602','US'), (11,'Linfield'      ,'NC','282','704','US'),
 (12,'Ostley'        ,'MA','021','617','US'), (13,'Brackenridge'  ,'MO','631','314','US'),
 (14,'Glenhollow'    ,'OR','972','503','US'), (15,'Fennick'       ,'TN','372','615','US'),
 (16,'Whitcombe'     ,'MI','482','313','US'), (17,'Calder Point'  ,'FL','331','305','US'),
 (18,'Norwell Green' ,'CA','941','415','US'), (19,'Stavely'       ,'CA','900','213','US'),
 (20,'Maplethorpe'   ,'ON','M5V','416','CA'), (21,'Cresthaven'    ,'BC','V6B','604','CA'),
 (22,'Ambleside Vale','QC','H2Y','514','CA'), (23,'Thornwick'     ,'ENG','EC1','020','GB'),
 (24,'Bellmoor'      ,'ENG','M1' ,'016','GB');

-- ---------------------------------------------------------------------
-- 1. True organizations (ground truth). Quarantined in EVAL_SCHEMA.
--
--    entity_role values and what they test:
--      STANDARD        ordinary entity; duplicates vary in easy and medium ways
--      SIBLING         shares name stem, city and web domain with another
--                      true entity, but is a different legal entity with a
--                      different tax id. Hard negative.
--      FRANCHISE       same trading name as another entity in a different
--                      city with different phone and tax id. Hard negative.
--      MOVED           a later copy has a new address and a changed industry
--                      word; tax id is identical. Hard positive.
--      ACRONYM         a copy uses initials as the name; phone and domain
--                      identical. Hard positive.
--      BOTH_TYPES      appears as customer and as vendor. Same organization;
--                      only linked when scope.cross_type_party is true.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_TRUE_ENTITIES AS
WITH pools AS (
    SELECT
        ARRAY_CONSTRUCT('Alder','Brindle','Cobalt','Dunmore','Elmstead','Fernhill','Granby',
                        'Harlow','Ironvale','Juniper','Kestrel','Larchmont','Marlowe','Northam',
                        'Orchard','Pinecrest','Quarrystone','Redfern','Stonebridge','Thistle',
                        'Umberfield','Vantage','Westmarch','Yarrow','Zephyrine','Ashcombe',
                        'Bramley','Copperline','Driftwood','Evergate') AS w1,
        ARRAY_CONSTRUCT('Valley','Ridge','Harbor','Summit','River','Prairie','Coastal',
                        'Lakeside','Meadow','Highland','Granite','Cedar','Beacon','Crescent',
                        'Falcon','Sterling','Oakmont','Silverline','Bluewater','Northgate') AS w2,
        ARRAY_CONSTRUCT('Manufacturing','Logistics','Services','Supply','Industries',
                        'Technologies','Foods','Engineering','Distribution','Consulting',
                        'Packaging','Electric') AS ind,
        ARRAY_CONSTRUCT('Inc','LLC','Corp','Co','Ltd','Incorporated','Corporation','Company') AS sfx,
        ARRAY_CONSTRUCT('Main','Commerce','Industrial','Harbor','Market','Station','Mill',
                        'Foundry','Quarry','Canal','Bridge','Depot','Granary','Wharf','Kiln') AS street,
        ARRAY_CONSTRUCT('Street','Avenue','Road','Boulevard','Drive','Lane','Parkway','Way') AS stype
),
base AS (
    SELECT SEQ4() AS i
    FROM TABLE(GENERATOR(ROWCOUNT => {{PARTY_ENTITIES}}))
),
named AS (
    SELECT
        b.i,
        p.w1[MOD(b.i, 30)]::STRING                              AS w1,
        p.w2[MOD(FLOOR(b.i / 30), 20)]::STRING                  AS w2,
        p.ind[MOD(FLOOR(b.i / 600), 12)]::STRING                AS ind,
        p.sfx[MOD(ABS(HASH(b.i, 'sfx')), 8)]::STRING            AS sfx,
        p.street[MOD(ABS(HASH(b.i, 'st')), 15)]::STRING         AS street,
        p.stype[MOD(ABS(HASH(b.i, 'sty')), 8)]::STRING          AS stype,
        -- Entities whose (w1, w2) stem repeats (i and i+600, i+1200) are given the
        -- same city when the stem index is small, creating same-city siblings.
        CASE WHEN MOD(b.i, 600) < 40
             THEN MOD(ABS(HASH(MOD(b.i, 600), 'geo')), 25)
             ELSE MOD(ABS(HASH(b.i, 'geo')), 25) END            AS geo_idx,
        CASE
            WHEN MOD(b.i, 600) < 40 AND b.i >= 600 THEN 'SIBLING'
            WHEN MOD(b.i, 50) = 7                  THEN 'MOVED'
            WHEN MOD(b.i, 50) = 13                 THEN 'ACRONYM'
            WHEN MOD(b.i, 40) = 0                  THEN 'BOTH_TYPES'
            ELSE 'STANDARD' END                                 AS entity_role,
        MOD(ABS(HASH(b.i, 'type')), 10)                         AS type_draw
    FROM base b CROSS JOIN pools p
)
SELECT
    'TE-P-' || LPAD(i, 6, '0')                                   AS true_entity_id,
    i                                                            AS seq,
    CASE WHEN entity_role = 'BOTH_TYPES' THEN 'BOTH'
         WHEN type_draw < 6 THEN 'CUSTOMER' ELSE 'VENDOR' END    AS party_type,
    entity_role,
    w1, w2, ind, sfx,
    w1 || ' ' || w2 || ' ' || ind                                AS core_name,
    w1 || ' ' || w2 || ' ' || ind || ' ' || sfx                  AS legal_name,
    (100 + MOD(ABS(HASH(i, 'no')), 9800))::STRING || ' ' || street || ' ' || stype AS address_line,
    street, stype,
    g.city, g.region, g.country,
    g.postal_base || CASE WHEN g.country = 'US'
                          THEN LPAD(MOD(ABS(HASH(i, 'zip')), 100), 2, '0') ELSE '' END AS postal,
    g.area_code,
    -- Unique per entity. 555 exchange; fictional.
    g.area_code || '555' || LPAD(MOD(i, 10000), 4, '0')          AS phone_digits,
    -- Siblings share the stem's domain on purpose (corporate group domain).
    LOWER(w1 || w2) || CASE WHEN entity_role = 'SIBLING' OR MOD(i, 600) < 40
                            THEN '' ELSE LOWER(LEFT(ind, 3)) END || '.example' AS web_domain,
    'SYN-' || LPAD(1000000 + i, 7, '0')                          AS tax_id
FROM named n
JOIN {{EVAL_SCHEMA}}.SYNTH_GEO g ON g.geo_idx = n.geo_idx;

-- Franchise hard negatives: separate true entities with the same trading name
-- as an existing STANDARD entity, in a different city, different phone and
-- tax id, own domain. Roughly 1 in 75 standard entities gets one.
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_TRUE_ENTITIES
SELECT
    'TE-P-F' || LPAD(t.seq, 5, '0'),
    100000 + t.seq,
    t.party_type,
    'FRANCHISE',
    t.w1, t.w2, t.ind, t.sfx,
    t.core_name,
    t.legal_name,
    (100 + MOD(ABS(HASH(t.seq, 'fno')), 9800))::STRING || ' ' || t.street || ' ' || t.stype,
    t.street, t.stype,
    g.city, g.region, g.country,
    g.postal_base || CASE WHEN g.country = 'US'
                          THEN LPAD(MOD(ABS(HASH(t.seq, 'fzip')), 100), 2, '0') ELSE '' END,
    g.area_code,
    g.area_code || '555' || LPAD(MOD(t.seq + 5000, 10000), 4, '0'),
    LOWER(t.w1 || t.w2 || REPLACE(g.city, ' ', '')) || '.example',
    'SYN-' || LPAD(5000000 + t.seq, 7, '0')
FROM {{EVAL_SCHEMA}}.SYNTH_TRUE_ENTITIES t
JOIN {{EVAL_SCHEMA}}.SYNTH_GEO g
  ON g.geo_idx = MOD(ABS(HASH(t.seq, 'fgeo')), 25)
WHERE t.entity_role = 'STANDARD'
  AND MOD(t.seq, 75) = 3
  AND g.city <> t.city;

-- ---------------------------------------------------------------------
-- 2. Copies. Each true entity yields one or more source records. A copy is
--    assigned a source system and a variation recipe.
--
--    recipe  difficulty  variation
--      0     EASY        verbatim, upper-cased
--      1     EASY        legal suffix spelled differently
--      2     MEDIUM      abbreviations (Mfg, Svcs, Intl, Dist, Tech, Eng), '&'
--      3     MEDIUM      one-character typo in the name
--      4     EASY        suffix dropped, trailing punctuation, 'The ' prefix
--      5     MEDIUM      address abbreviations + suite, ZIP+4, phone reformatted
--      6     MEDIUM      phone and tax id missing, lower-case name
--      7     HARD        typo plus abbreviation plus postal missing
--    MOVED entities: copies >= 2 get recipe 90 (new address, industry -> Group)
--    ACRONYM entities: copy 2 gets recipe 91 (initials name)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_COPIES AS
WITH counts AS (
    SELECT
        t.*,
        CASE
            WHEN entity_role IN ('MOVED','ACRONYM','BOTH_TYPES') THEN 2 + MOD(ABS(HASH(seq,'n')), 2)
            ELSE CASE
                WHEN MOD(ABS(HASH(seq, 'n')), 20) < 9  THEN 1
                WHEN MOD(ABS(HASH(seq, 'n')), 20) < 15 THEN 2
                WHEN MOD(ABS(HASH(seq, 'n')), 20) < 18 THEN 3
                ELSE 4 + MOD(ABS(HASH(seq, 'n2')), 2) END
        END AS n_copies
    FROM {{EVAL_SCHEMA}}.SYNTH_TRUE_ENTITIES t
),
copy_slots AS (
    SELECT c.*, s.copy_no
    FROM counts c
    JOIN (SELECT SEQ4() + 1 AS copy_no FROM TABLE(GENERATOR(ROWCOUNT => 5))) s
      ON s.copy_no <= c.n_copies
)
SELECT
    cs.*,
    -- For BOTH_TYPES, odd copies are customers and even copies vendors.
    CASE WHEN party_type = 'BOTH'
         THEN IFF(MOD(copy_no, 2) = 1, 'CUSTOMER', 'VENDOR')
         ELSE party_type END                                          AS copy_entity_type,
    CASE
        WHEN entity_role = 'MOVED'   AND copy_no >= 2 THEN 90
        WHEN entity_role = 'ACRONYM' AND copy_no = 2  THEN 91
        WHEN copy_no = 1 THEN 0
        ELSE MOD(ABS(HASH(seq, copy_no, 'recipe')), 8)
    END                                                               AS recipe,
    MOD(ABS(HASH(seq, copy_no, 'sys')), 3)                            AS sys_draw
FROM copy_slots cs;

-- Varied attribute values per copy, computed once and shared by all source
-- table loaders below.
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_COPY_VALUES AS
WITH v AS (
    SELECT
        c.*,
        CASE copy_entity_type
            WHEN 'CUSTOMER' THEN ARRAY_CONSTRUCT('CRM','BILLING','ECOM')[sys_draw]::STRING
            ELSE ARRAY_CONSTRUCT('ERP_1000','ERP_2000','P2P')[sys_draw]::STRING
        END AS source_system,
        -- Alternate suffix spellings for recipe 1.
        DECODE(sfx, 'Inc','Incorporated', 'Incorporated','Inc.', 'LLC','L.L.C.',
                    'Corp','Corporation', 'Corporation','Corp.', 'Co','Company',
                    'Company','Co.', 'Ltd','Limited', sfx)                           AS alt_sfx,
        -- Abbreviated industry for recipes 2 and 7.
        DECODE(ind, 'Manufacturing','Mfg', 'Services','Svcs', 'Distribution','Dist',
                    'Technologies','Tech', 'Engineering','Eng', 'Industries','Inds',
                    'Logistics','Logistics & Freight', 'Consulting','Consulting Grp',
                    'Packaging','Pkg', 'Electric','Elec', ind)                       AS abbr_ind,
        3 + MOD(ABS(HASH(seq, copy_no, 'typo')), GREATEST(LENGTH(core_name) - 5, 1)) AS typo_pos,
        ARRAY_CONSTRUCT('a','e','i','o','r','n','t','l')[MOD(ABS(HASH(seq, copy_no, 'tc')), 8)]::STRING AS typo_char
    FROM {{EVAL_SCHEMA}}.SYNTH_COPIES c
),
moved_geo AS (
    SELECT v.true_entity_id, v.copy_no, g.*
    FROM v
    JOIN {{EVAL_SCHEMA}}.SYNTH_GEO g ON g.geo_idx = MOD(ABS(HASH(v.seq, 'move')), 25)
)
SELECT
    v.true_entity_id,
    v.copy_no,
    v.entity_role,
    v.copy_entity_type                                                 AS entity_type,
    v.source_system,
    v.recipe,
    CASE
        WHEN v.recipe IN (0,1,4) THEN 'EASY'
        WHEN v.recipe IN (2,3,5,6) THEN 'MEDIUM'
        ELSE 'HARD' END                                                AS difficulty,
    -- Leakage-safe source id: salted hash, no readable link to the entity.
    UPPER(SUBSTR(SHA2(v.true_entity_id || '|' || v.copy_no || '|' || v.source_system
                      || '|seed-salt-7f3a', 256), 1, 12))              AS source_record_id,
    -- Name
    CASE v.recipe
        WHEN 0  THEN UPPER(v.legal_name)
        WHEN 1  THEN v.core_name || ' ' || v.alt_sfx
        WHEN 2  THEN REPLACE(v.w1 || ' ' || v.w2 || ' ' || v.abbr_ind, ' and ', ' & ') || ' ' || v.sfx
        WHEN 3  THEN INSERT(v.core_name, v.typo_pos, 1, v.typo_char) || ' ' || v.sfx
        WHEN 4  THEN 'The ' || v.core_name || ','
        WHEN 5  THEN v.legal_name
        WHEN 6  THEN LOWER(v.legal_name)
        WHEN 7  THEN INSERT(v.w1 || ' ' || v.w2, LEAST(v.typo_pos, LENGTH(v.w1 || ' ' || v.w2) - 1), 1, v.typo_char) || ' ' || v.abbr_ind
        WHEN 90 THEN v.w1 || ' ' || v.w2 || ' Group ' || v.sfx
        WHEN 91 THEN LEFT(v.w1,1) || LEFT(v.w2,1) || LEFT(v.ind,1) || ' ' || v.sfx
    END                                                                AS name_value,
    -- Address
    CASE
        WHEN v.recipe = 90 THEN (200 + MOD(ABS(HASH(v.seq, 'mno')), 9000))::STRING
                                || ' ' || v.street || ' ' || v.stype
        WHEN v.recipe = 5  THEN REPLACE(REPLACE(REPLACE(REPLACE(v.address_line,
                                 'Street','St'), 'Avenue','Ave'), 'Boulevard','Blvd'), 'Road','Rd')
                                || ' Ste ' || (100 + MOD(ABS(HASH(v.seq,'ste')), 400))::STRING
        ELSE v.address_line
    END                                                                AS address_value,
    IFF(v.recipe = 90, m.city,    v.city)                              AS city_value,
    IFF(v.recipe = 90, m.region,  v.region)                            AS region_value,
    IFF(v.recipe = 90, m.country, v.country)                           AS country_value,
    CASE
        WHEN v.recipe = 7  THEN NULL
        WHEN v.recipe = 90 THEN m.postal_base || IFF(m.country = 'US', '07', '')
        WHEN v.recipe = 5 AND v.country = 'US'
             THEN v.postal || '-' || LPAD(MOD(ABS(HASH(v.seq,'p4')), 10000), 4, '0')
        ELSE v.postal
    END                                                                AS postal_value,
    -- Phone in one of several formats; missing for recipe 6.
    CASE
        WHEN v.recipe = 6 THEN NULL
        WHEN v.recipe = 90 THEN m.area_code || '555' || LPAD(MOD(v.seq + 2500, 10000), 4, '0')
        ELSE CASE MOD(ABS(HASH(v.seq, v.copy_no, 'pf')), 4)
            WHEN 0 THEN '(' || LEFT(v.phone_digits,3) || ') ' || SUBSTR(v.phone_digits,4,3) || '-' || RIGHT(v.phone_digits,4)
            WHEN 1 THEN LEFT(v.phone_digits,3) || '.' || SUBSTR(v.phone_digits,4,3) || '.' || RIGHT(v.phone_digits,4)
            WHEN 2 THEN '+1 ' || LEFT(v.phone_digits,3) || ' ' || SUBSTR(v.phone_digits,4,3) || ' ' || RIGHT(v.phone_digits,4)
            ELSE v.phone_digits END
    END                                                                AS phone_value,
    v.web_domain,
    -- Contact email: a role mailbox at the entity domain, or a free-mail address
    -- (which must not be used as a blocking key).
    CASE WHEN MOD(ABS(HASH(v.seq, v.copy_no, 'em')), 5) = 0
         THEN LOWER(v.w1) || '.' || LOWER(v.w2) || '@freemail.example'
         ELSE ARRAY_CONSTRUCT('ap','billing','info','orders','accounts')
                  [MOD(ABS(HASH(v.seq, v.copy_no, 'mb')), 5)]::STRING || '@' || v.web_domain
    END                                                                AS email_value,
    -- Tax id: vendor systems usually hold it, customer systems rarely.
    -- Recipe 6 drops it. MOVED and ACRONYM keep it on every vendor copy.
    CASE
        WHEN v.recipe = 6 THEN NULL
        WHEN v.copy_entity_type = 'VENDOR' AND (v.entity_role IN ('MOVED','ACRONYM')
             OR MOD(ABS(HASH(v.seq, v.copy_no, 'tx')), 10) < 8) THEN v.tax_id
        WHEN v.copy_entity_type = 'CUSTOMER' AND (v.entity_role = 'MOVED'
             OR MOD(ABS(HASH(v.seq, v.copy_no, 'tx')), 10) < 3) THEN v.tax_id
        ELSE NULL
    END                                                                AS tax_id_value,
    -- Updated timestamp: later copies tend to be more recent.
    DATEADD('day', -1 * MOD(ABS(HASH(v.seq, v.copy_no, 'ts')), 900) + v.copy_no * 30,
            '2026-06-30'::TIMESTAMP_NTZ)                               AS updated_at_value
FROM v
LEFT JOIN moved_geo m ON m.true_entity_id = v.true_entity_id AND m.copy_no = v.copy_no;

-- ---------------------------------------------------------------------
-- 3. Source tables. Each system has its own column layout so the column
--    mapping step at preflight is exercised for real.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_CRM_ACCOUNTS AS
SELECT source_record_id      AS account_id,
       name_value            AS account_name,
       address_value         AS billing_street,
       city_value            AS billing_city,
       region_value          AS billing_state,
       postal_value          AS billing_postal_code,
       country_value         AS billing_country,
       phone_value           AS phone,
       'www.' || web_domain  AS website,
       updated_at_value      AS last_modified_at,
       'ACTIVE'              AS account_status
FROM {{EVAL_SCHEMA}}.SYNTH_COPY_VALUES
WHERE source_system = 'CRM';

CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_BILLING_CUSTOMERS AS
SELECT source_record_id      AS cust_no,
       UPPER(name_value)     AS customer_name,        -- billing system upper-cases
       address_value         AS addr_line1,
       NULL::VARCHAR         AS addr_line2,
       city_value            AS city,
       region_value          AS state_prov,
       postal_value          AS zip,
       country_value         AS country_code,
       email_value           AS contact_email,
       phone_value           AS phone_number,
       tax_id_value          AS tax_registration,
       updated_at_value      AS updated_ts
FROM {{EVAL_SCHEMA}}.SYNTH_COPY_VALUES
WHERE source_system = 'BILLING';

-- Single-line address, as e-commerce sign-up forms commonly store it.
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_ECOM_ACCOUNTS AS
SELECT LOWER(source_record_id) AS org_uuid,
       name_value              AS company,
       address_value || ', ' || city_value || ', ' || region_value
         || COALESCE(' ' || postal_value, '') || ', ' || country_value AS address,
       email_value             AS email,
       updated_at_value        AS created_at
FROM {{EVAL_SCHEMA}}.SYNTH_COPY_VALUES
WHERE source_system = 'ECOM';

-- Two ERP company codes in one vendor table, as a multi-plant ERP holds them.
-- bank_account_last4 is present to exercise the excluded_from_ai control; it is
-- fabricated and must never reach a prompt or embedding.
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_ERP_VENDORS AS
SELECT source_record_id                         AS vendor_id,
       REPLACE(source_system, 'ERP_', '')       AS company_code,
       UPPER(LEFT(name_value, 35))              AS vendor_name,   -- 35-char ERP name field
       NULLIF(UPPER(SUBSTR(name_value, 36)), '') AS name_2,
       address_value                            AS street,
       city_value                               AS city,
       region_value                             AS region,
       postal_value                             AS postal_code,
       country_value                            AS country,
       phone_value                              AS telephone,
       tax_id_value                             AS tax_number,
       LPAD(MOD(ABS(HASH(source_record_id, 'bank')), 10000), 4, '0') AS bank_account_last4,
       ARRAY_CONSTRUCT('N30','N45','N60')[MOD(ABS(HASH(source_record_id,'pt')),3)]::STRING AS payment_terms,
       updated_at_value                         AS changed_on,
       IFF(MOD(ABS(HASH(source_record_id, 'blk')), 40) = 0, 'X', NULL) AS blocked_flag
FROM {{EVAL_SCHEMA}}.SYNTH_COPY_VALUES
WHERE source_system IN ('ERP_1000', 'ERP_2000');

CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_P2P_SUPPLIERS AS
SELECT source_record_id                         AS supplier_id,
       name_value                               AS legal_name,
       NULL::VARCHAR                            AS dba_name,
       address_value || ', ' || city_value || ' ' || region_value
         || COALESCE(' ' || postal_value, '')   AS hq_address,
       country_value                            AS country,
       SPLIT_PART(email_value, '@', 2)          AS email_domain,
       phone_value                              AS phone,
       tax_id_value                             AS tax_id,
       updated_at_value                         AS updated_at
FROM {{EVAL_SCHEMA}}.SYNTH_COPY_VALUES
WHERE source_system = 'P2P';

-- ---------------------------------------------------------------------
-- 4. Products. Each base product has three size variants; each variant is a
--    distinct true product (a size variant is a different SKU). Hard
--    negatives are therefore built in: same brand, line and type, different
--    size.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_TRUE_PRODUCTS AS
WITH pools AS (
    SELECT
        ARRAY_CONSTRUCT('Kestrel','Bramwell','Orrin','Tavish','Lumen Ridge','Calloway',
                        'Northfold','Pellam','Quillon','Sorrel','Vexley','Wyndham') AS brand,
        ARRAY_CONSTRUCT('Pro','Classic','Industrial','Eco','Heavy Duty','Select') AS line,
        ARRAY_CONSTRUCT('Stainless Steel Water Bottle','Degreaser Concentrate',
                        'Nitrile Gloves','Thermal Travel Mug','Hand Sanitizer Gel',
                        'Shop Towels','Food Storage Container','Glass Cleaner',
                        'Cable Ties','Safety Glasses') AS ptype,
        ARRAY_CONSTRUCT('Black','White','Blue','Clear','Graphite') AS color
),
base AS (SELECT SEQ4() AS b FROM TABLE(GENERATOR(ROWCOUNT => {{PRODUCT_BASES}}))),
sized AS (
    SELECT base.b, s.size_idx
    FROM base
    CROSS JOIN (SELECT SEQ4() AS size_idx FROM TABLE(GENERATOR(ROWCOUNT => 3))) s
)
SELECT
    'TE-R-' || LPAD(sz.b, 5, '0') || '-' || sz.size_idx              AS true_entity_id,
    sz.b                                                             AS base_seq,
    sz.size_idx,
    IFF(sz.size_idx = 0, 'STANDARD', 'SIZE_VARIANT')                 AS entity_role,
    p.brand[MOD(sz.b, 12)]::STRING                                   AS brand,
    p.line[MOD(FLOOR(sz.b / 12), 6)]::STRING                         AS line,
    p.ptype[MOD(FLOOR(sz.b / 72), 10)]::STRING                       AS ptype,
    p.color[MOD(ABS(HASH(sz.b, 'col')), 5)]::STRING                  AS color,
    ARRAY_CONSTRUCT(12, 16, 32)[sz.size_idx]::INT                    AS size_value,
    'OZ'                                                             AS size_unit,
    UPPER(LEFT(REPLACE(p.brand[MOD(sz.b, 12)]::STRING, ' ', ''), 3))
        || '-' || LPAD(sz.b, 4, '0') || '-' || ARRAY_CONSTRUCT('12','16','32')[sz.size_idx]::STRING AS mpn,
    -- Synthetic 14-digit identifier with a 99 prefix. Not a valid GTIN.
    '0099' || LPAD(sz.b, 6, '0') || LPAD(sz.size_idx, 2, '0') || '00' AS gtin
FROM sized sz CROSS JOIN pools p;

CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_PRODUCT_COPIES AS
WITH slots AS (
    SELECT t.*, s.copy_no,
           1 + MOD(ABS(HASH(t.true_entity_id, 'pn')), 3) AS n_copies
    FROM {{EVAL_SCHEMA}}.SYNTH_TRUE_PRODUCTS t
    CROSS JOIN (SELECT SEQ4() + 1 AS copy_no FROM TABLE(GENERATOR(ROWCOUNT => 3))) s
)
SELECT
    sl.*,
    ARRAY_CONSTRUCT('PIM','ERP_ITEM','SUPPLIER_CAT')[MOD(copy_no - 1 + MOD(ABS(HASH(true_entity_id,'ps')),3), 3)]::STRING AS source_system,
    UPPER(SUBSTR(SHA2(true_entity_id || '|' || copy_no || '|prod-salt-91c2', 256), 1, 10)) AS source_record_id,
    CASE
        WHEN copy_no = 1 THEN 'EASY'
        WHEN MOD(ABS(HASH(true_entity_id, copy_no, 'pd')), 3) = 0 THEN 'HARD'
        ELSE 'MEDIUM' END AS difficulty
FROM slots sl
WHERE copy_no <= n_copies;

CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_PIM_PRODUCTS AS
SELECT source_record_id AS product_code,
       brand || ' ' || line || ' ' || ptype || ', ' || size_value || ' oz, ' || color AS product_title,
       brand            AS brand_name,
       gtin,
       size_value || ' oz' AS size_text,
       color,
       SPLIT_PART(ptype, ' ', -1) AS category,
       DATEADD('day', -MOD(ABS(HASH(source_record_id,'pu')), 400), '2026-06-30'::TIMESTAMP_NTZ) AS updated_at
FROM {{EVAL_SCHEMA}}.SYNTH_PRODUCT_COPIES
WHERE source_system = 'PIM';

-- ERP item descriptions: upper-case, abbreviated, size packed into the text.
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_ERP_ITEMS AS
SELECT source_record_id AS item_number,
       UPPER(LEFT(
         REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
           brand || ' ' || ptype || ' ' || line || ' ' || size_value || 'OZ ' || color,
           'Stainless Steel', 'SS'), 'Heavy Duty', 'HD'), 'Black', 'BLK'),
           'Container', 'CNTR'), 'Concentrate', 'CONC'), 40)) AS item_desc,
       'EA'             AS uom,
       IFF(difficulty = 'HARD', REPLACE(mpn, '-', ''), mpn) AS mfr_part_no,
       NULL::VARCHAR    AS gtin,
       DATEADD('day', -MOD(ABS(HASH(source_record_id,'eu')), 400), '2026-06-30'::TIMESTAMP_NTZ) AS last_change
FROM {{EVAL_SCHEMA}}.SYNTH_PRODUCT_COPIES
WHERE source_system = 'ERP_ITEM';

-- Supplier catalog: metric size on harder copies, so 12 oz must match ~355 ml.
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_SUPPLIER_CATALOG AS
SELECT source_record_id AS sku,
       line || ' ' || ptype || ' - ' || color || ' - '
         || IFF(difficulty = 'HARD',
                ROUND(size_value * 29.5735)::STRING || ' ml',
                size_value::STRING || '-Ounce') AS description,
       brand            AS manufacturer,
       LOWER(mpn)       AS mpn,
       IFF(MOD(ABS(HASH(source_record_id,'cg')), 2) = 0, gtin, NULL) AS gtin,
       '1'              AS pack_size,
       DATEADD('day', -MOD(ABS(HASH(source_record_id,'cu')), 400), '2026-06-30'::TIMESTAMP_NTZ) AS updated_at
FROM {{EVAL_SCHEMA}}.SYNTH_PRODUCT_COPIES
WHERE source_system = 'SUPPLIER_CAT';

-- ---------------------------------------------------------------------
-- 5. The answer key. One row per source record. record_uid is built exactly
--    as the standardize phase builds it: SOURCE_SYSTEM || ':' || source id.
--    ECOM ids are lower-cased in the source table, so the key matches that.
--    Never joined by the pipeline.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY AS
SELECT
    source_system || ':' || IFF(source_system = 'ECOM', LOWER(source_record_id), source_record_id) AS record_uid,
    entity_type,
    true_entity_id,
    entity_role                     AS case_role,
    difficulty,
    recipe,
    -- party_entity_id links customer and vendor copies of BOTH_TYPES entities
    -- for the optional cross-type evaluation.
    true_entity_id                  AS party_entity_id
FROM {{EVAL_SCHEMA}}.SYNTH_COPY_VALUES
UNION ALL
SELECT
    source_system || ':' || source_record_id,
    'PRODUCT',
    true_entity_id,
    entity_role,
    difficulty,
    NULL,
    true_entity_id
FROM {{EVAL_SCHEMA}}.SYNTH_PRODUCT_COPIES;

-- For entity-type-scoped evaluation, BOTH_TYPES copies resolve within type:
-- their customer copies form one entity and their vendor copies another.
-- The within-type id is true_entity_id || ':' || entity_type.
CREATE OR REPLACE VIEW {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY_WITHIN_TYPE AS
SELECT record_uid, entity_type,
       true_entity_id || ':' || entity_type AS true_entity_id,
       case_role, difficulty, recipe
FROM {{EVAL_SCHEMA}}.SYNTH_ER_ANSWER_KEY;
