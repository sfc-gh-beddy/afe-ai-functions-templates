-- =====================================================================
-- Shared normalizers for document intake.
--
-- ONE implementation, used by validation AND by the accuracy harness on
-- BOTH sides of every comparison (best-practices rules 7, 8, 20). Never
-- write a second normalizer for one field; fix this file instead.
--
-- Every function returns an OBJECT {value, status} so a failed or
-- ambiguous normalization is visible as data rather than an unexplained
-- NULL. status values:
--   OK                  normalized cleanly
--   NULL                input was empty or a placeholder ('None','N/A',...)
--   AMBIGUOUS           more than one valid reading and no locale to decide
--   RESOLVED_BY_LOCALE  ambiguous, decided by the vendor's recorded locale
--   LOCALE_CONFLICT     only parses in the convention OPPOSITE the locale
--   UNPARSEABLE         not a value of this kind at all
--
-- SUBSTITUTE: {{DB}}, {{SCHEMA}}
-- The logic below was tested against literal cases (see extract-document-
-- fields/SKILL.md, "Normalizer test cases"). Re-run those tests after any edit.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Placeholder strings -> NULL. Applied before every other normalizer.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION {{DB}}.{{SCHEMA}}.NULLIF_PLACEHOLDER(s VARCHAR)
RETURNS VARCHAR
AS
$$
    IFF(s IS NULL
        OR TRIM(s) = ''
        OR UPPER(TRIM(s)) IN ('NONE', 'NULL', 'N/A', 'NA', 'N.A.', '-', '--', 'NOT FOUND',
                              'NOT PROVIDED', 'NOT AVAILABLE', 'UNKNOWN', 'NIL'),
        NULL, TRIM(s))
$$;

-- ---------------------------------------------------------------------
-- Amounts. number_locale: 'DOT_DECIMAL' | 'COMMA_DECIMAL' | NULL.
--   * last '.' or ',' followed by exactly 1-2 digits is the decimal separator
--   * (x), leading '-', trailing '-' are negative
--   * '1.234' / '1,234' (1-3 digits, separator, exactly 3 digits) is
--     AMBIGUOUS without a locale -- never guessed
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION {{DB}}.{{SCHEMA}}.NORM_AMOUNT(raw VARCHAR, number_locale VARCHAR)
RETURNS OBJECT
AS
$$
    SELECT OBJECT_CONSTRUCT_KEEP_NULL(
        'value',
        CASE
            WHEN s IS NULL OR digits = '' THEN NULL
            WHEN REGEXP_LIKE(digits, '^[0-9]{1,3}[.,][0-9]{3}$') AND number_locale IS NULL THEN NULL
            WHEN REGEXP_LIKE(digits, '^[0-9]{1,3}[.,][0-9]{3}$') AND number_locale = 'COMMA_DECIMAL' AND CONTAINS(digits, ',')
                 THEN TRY_TO_DECIMAL(REPLACE(digits, ',', '.'), 18, 4)
            WHEN REGEXP_LIKE(digits, '^[0-9]{1,3}[.,][0-9]{3}$') AND number_locale = 'DOT_DECIMAL' AND CONTAINS(digits, '.')
                 THEN TRY_TO_DECIMAL(digits, 18, 4)
            WHEN REGEXP_LIKE(digits, '^[0-9]{1,3}[.,][0-9]{3}$')
                 THEN TRY_TO_DECIMAL(REGEXP_REPLACE(digits, '[.,]', ''), 18, 4)
            WHEN REGEXP_LIKE(digits, '.*[.,][0-9]{1,2}$')
                 THEN TRY_TO_DECIMAL(
                          REGEXP_REPLACE(LEFT(digits, LENGTH(digits) - LENGTH(REGEXP_SUBSTR(digits, '[.,][0-9]{1,2}$'))), '[.,]', '')
                          || '.' || REGEXP_SUBSTR(digits, '[.,]([0-9]{1,2})$', 1, 1, 'e'), 18, 4)
            ELSE TRY_TO_DECIMAL(REGEXP_REPLACE(digits, '[.,]', ''), 18, 4)
        END * IFF(neg, -1, 1),
        'status',
        CASE
            WHEN s IS NULL OR digits = '' THEN IFF(s IS NULL, 'NULL', 'UNPARSEABLE')
            WHEN REGEXP_LIKE(digits, '^[0-9]{1,3}[.,][0-9]{3}$') AND number_locale IS NULL THEN 'AMBIGUOUS'
            WHEN REGEXP_LIKE(digits, '^[0-9]{1,3}[.,][0-9]{3}$') THEN 'RESOLVED_BY_LOCALE'
            ELSE 'OK'
        END)
    FROM (
        SELECT {{DB}}.{{SCHEMA}}.NULLIF_PLACEHOLDER(raw) AS s,
               REGEXP_REPLACE(s, '[^0-9.,]', '')         AS digits,
               (REGEXP_LIKE(s, '^\\(.*\\)$')
                OR REGEXP_LIKE(s, '^[^0-9]*-.*')
                OR REGEXP_LIKE(s, '.*[0-9]\\s*-$'))       AS neg
    )
$$;

-- ---------------------------------------------------------------------
-- Dates. date_locale: 'MDY' | 'DMY' | 'ISO' | NULL.
--   Unambiguous formats first (ISO, month names). For numeric slash/dot/dash
--   dates, parse both ways; if both succeed and differ, the locale decides,
--   and without a locale the value is AMBIGUOUS (never guessed).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION {{DB}}.{{SCHEMA}}.NORM_DATE(raw VARCHAR, date_locale VARCHAR)
RETURNS OBJECT
AS
$$
    SELECT OBJECT_CONSTRUCT_KEEP_NULL(
        'value',
        CASE
            WHEN s IS NULL THEN NULL
            WHEN unamb IS NOT NULL THEN unamb
            WHEN mdy IS NOT NULL AND dmy IS NOT NULL AND mdy <> dmy
                 THEN CASE date_locale WHEN 'MDY' THEN mdy WHEN 'DMY' THEN dmy END
            WHEN mdy IS NOT NULL AND date_locale = 'DMY' THEN NULL     -- conflict: do not accept
            WHEN dmy IS NOT NULL AND date_locale = 'MDY' THEN NULL
            ELSE COALESCE(mdy, dmy)
        END::VARCHAR,
        'status',
        CASE
            WHEN s IS NULL THEN 'NULL'
            WHEN unamb IS NOT NULL THEN 'OK'
            WHEN mdy IS NOT NULL AND dmy IS NOT NULL AND mdy <> dmy
                 THEN IFF(date_locale IN ('MDY', 'DMY'), 'RESOLVED_BY_LOCALE', 'AMBIGUOUS')
            WHEN mdy IS NOT NULL AND date_locale = 'DMY' THEN 'LOCALE_CONFLICT'
            WHEN dmy IS NOT NULL AND date_locale = 'MDY' THEN 'LOCALE_CONFLICT'
            WHEN COALESCE(mdy, dmy) IS NULL THEN 'UNPARSEABLE'
            ELSE 'OK'
        END)
    FROM (
        SELECT s,
               COALESCE(TRY_TO_DATE(s, 'YYYY-MM-DD'), TRY_TO_DATE(s, 'YYYY/MM/DD'),
                        TRY_TO_DATE(s, 'MMMM DD, YYYY'), TRY_TO_DATE(s, 'MON DD, YYYY'),
                        TRY_TO_DATE(s, 'DD MON YYYY'),   TRY_TO_DATE(s, 'DD MMMM YYYY')) AS unamb,
               TRY_TO_DATE(REPLACE(REPLACE(s, '.', '/'), '-', '/'), 'MM/DD/YYYY')       AS mdy,
               TRY_TO_DATE(REPLACE(REPLACE(s, '.', '/'), '-', '/'), 'DD/MM/YYYY')       AS dmy
        FROM (SELECT {{DB}}.{{SCHEMA}}.NULLIF_PLACEHOLDER(raw) AS s)
    )
$$;

-- ---------------------------------------------------------------------
-- Document numbers (invoice, PO, credit note, policy). Strips repeated
-- label prefixes that require a separator (so 'NOVA-12' keeps 'NOVA'),
-- all non-alphanumerics, and leading zeros. Used for MATCHING only --
-- the posted value keeps the printed form.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION {{DB}}.{{SCHEMA}}.NORM_DOC_NUMBER(raw VARCHAR)
RETURNS VARCHAR
AS
$$
    LTRIM(
        REGEXP_REPLACE(
            REGEXP_REPLACE(UPPER({{DB}}.{{SCHEMA}}.NULLIF_PLACEHOLDER(raw)),
                           '^((INVOICE|INV|NUMBER|NO|NR|PO|P\\.O\\.)([-#:.]|\\s)+)+', ''),
            '[^A-Z0-9]', ''),
        '0')
$$;

-- ---------------------------------------------------------------------
-- Tax IDs: digits only (masters usually store digits; documents print
-- hyphens). Never log the result.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION {{DB}}.{{SCHEMA}}.NORM_TAX_ID(raw VARCHAR)
RETURNS VARCHAR
AS
$$
    NULLIF(REGEXP_REPLACE({{DB}}.{{SCHEMA}}.NULLIF_PLACEHOLDER(raw), '[^0-9A-Za-z]', ''), '')
$$;

-- ---------------------------------------------------------------------
-- Party names for matching: uppercase, punctuation stripped, common legal
-- suffixes removed, whitespace collapsed. 'Corvane Logistik GmbH' and
-- 'CORVANE LOGISTIK' must compare equal.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION {{DB}}.{{SCHEMA}}.NORM_PARTY_NAME(raw VARCHAR)
RETURNS VARCHAR
AS
$$
    TRIM(REGEXP_REPLACE(
        REGEXP_REPLACE(
            REGEXP_REPLACE(UPPER({{DB}}.{{SCHEMA}}.NULLIF_PLACEHOLDER(raw)), '[^A-Z0-9 ]', ' '),
            '\\b(INC|INCORPORATED|LLC|LTD|LIMITED|CORP|CORPORATION|CO|COMPANY|GMBH|AG|SARL|SAS|SA|BV|NV|PLC|LLP|LP)\\b', ' '),
        '\\s+', ' '))
$$;

-- ---------------------------------------------------------------------
-- Currency: ISO code when present; a bare symbol is NOT resolved here
-- (best-practices rule 9) -- validation falls back to vendor/PO currency
-- and records that it inferred it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION {{DB}}.{{SCHEMA}}.NORM_CURRENCY(raw VARCHAR)
RETURNS OBJECT
AS
$$
    SELECT OBJECT_CONSTRUCT_KEEP_NULL(
        'value',  REGEXP_SUBSTR(UPPER(s), '\\b(USD|EUR|GBP|CAD|AUD|CHF|JPY|SEK|NOK|DKK|PLN|MXN|BRL|INR|SGD|NZD|ZAR)\\b'),
        'status', CASE
                    WHEN s IS NULL THEN 'NULL'
                    WHEN REGEXP_SUBSTR(UPPER(s), '\\b(USD|EUR|GBP|CAD|AUD|CHF|JPY|SEK|NOK|DKK|PLN|MXN|BRL|INR|SGD|NZD|ZAR)\\b') IS NOT NULL THEN 'OK'
                    WHEN REGEXP_LIKE(s, '.*[$€£¥].*') THEN 'SYMBOL_ONLY'
                    ELSE 'UNPARSEABLE'
                  END)
    FROM (SELECT {{DB}}.{{SCHEMA}}.NULLIF_PLACEHOLDER(raw) AS s)
$$;
