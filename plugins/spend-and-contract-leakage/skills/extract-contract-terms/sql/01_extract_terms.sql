-- =====================================================================
-- Phase 3. Extract commercial terms with cited clause evidence, then
-- derive term periods and effective-dated rates in pure SQL.
--
-- AI functions:
--   AI_EXTRACT  (entity)  header terms, each paired with a verbatim quote
--   AI_EXTRACT  (table)   rate cards and volume-tier tables
--   AI_COMPLETE (schema)  prose pricing (fallback only), and clause
--                         interpretation: tier application, accumulation
--                         period, escalator basis, amendment changes
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}} {{SCHEMA}} {{RUN_ID}} {{EXPERIMENT_ID}} {{PROMPT_VERSION}}
--   {{PROMPT_HASH}}       sha256 of THIS file after substitution, computed
--                         by the agent (shasum -a 256) before running
--   {{MODEL}}             models.clause_interpret
--   {{QUOTE_MIN_CHARS}}   extract.quote_min_chars
--   {{AS_OF_DATE}}        reconcile.as_of_date
--   {{QUERY_TAG_PREFIX}}
--
-- Reads:  CONTRACT_REGISTRY, CONTRACT_PAGES
-- Writes: CONTRACT_HEADER_TERMS, CONTRACT_RATE_LINES, CONTRACT_CLAUSE_RULES
--         (all accumulate by experiment), CONTRACT_TERM_PERIODS and
--         CONTRACT_EFFECTIVE_RATES (rebuilt for this experiment)
-- =====================================================================

USE DATABASE {{DB}};
USE SCHEMA {{SCHEMA}};
ALTER SESSION SET QUERY_TAG = '{{QUERY_TAG_PREFIX}}:extract:{{RUN_ID}}';

-- Documents in scope: canonical commercial documents with a family.
-- Duplicates, NDAs, orphan amendments and parse failures are excluded
-- here, once, so no later statement has to remember to (rules 3, 17).
CREATE OR REPLACE TEMPORARY TABLE _X_DOCS AS
SELECT r.document_id, r.contract_family_id, r.family_role, r.doc_class, r.vendor_id,
       r.full_text, r.document_effective_date,
       REGEXP_REPLACE(UPPER(r.full_text), '\\s+', ' ') AS norm_text
FROM CONTRACT_REGISTRY r
WHERE r.family_role IN ('GOVERNING', 'AMENDMENT')
  AND r.contract_family_id IS NOT NULL
  AND r.parse_status = 'OK';

-- Text helper: normalized page text for page attribution of quotes.
CREATE OR REPLACE TEMPORARY TABLE _X_PAGES AS
SELECT p.document_id, p.page_index, REGEXP_REPLACE(UPPER(p.page_text), '\\s+', ' ') AS norm_page
FROM CONTRACT_PAGES p
JOIN _X_DOCS d ON d.document_id = p.document_id
WHERE p.page_index >= 0;

-- ---------------------------------------------------------------------
-- 1. Header terms. Governing documents only. Every term is asked twice:
--    the value, and the sentence it came from. NOT_STATED is mandatory for
--    absence so that NULL means FAILED (rule 16).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _X_HEADER_RAW AS
SELECT d.document_id, d.contract_family_id,
       AI_EXTRACT(
         text => d.full_text,
         responseFormat => {
           'agreement_effective_date':       'On what date does this agreement, order or statement of work take effect or begin (the effective date, start date or commencement date)? Answer as YYYY-MM-DD, or NOT_STATED.',
           'agreement_effective_date_quote': 'Copy, word for word, the single sentence that states the effective or start date. Answer NOT_STATED if none.',
           'initial_term_end_date':          'On what date does the initial term, subscription term, contract year or period of performance end? Answer as YYYY-MM-DD, or NOT_STATED.',
           'initial_term_end_date_quote':    'Copy, word for word, the single sentence that states when the initial term ends. Answer NOT_STATED if none.',
           'auto_renewal':                   'Does this agreement renew automatically at the end of its term unless a party gives notice? Answer TRUE only if it explicitly renews automatically, FALSE if it explicitly expires, does not renew, or requires a written agreement to renew. Answer NOT_STATED if the document does not address renewal.',
           'auto_renewal_quote':             'Copy, word for word, the single sentence that states whether the agreement renews. Answer NOT_STATED if none.',
           'renewal_term_months':            'If the agreement renews automatically, how many months is each renewal term? Answer with a whole number of months only, or NOT_STATED.',
           'renewal_term_months_quote':      'Copy, word for word, the single sentence that states the length of a renewal term. Answer NOT_STATED if none.',
           'non_renewal_notice_days':        'How many days before the end of the term must notice of non-renewal be given to stop automatic renewal? Answer with a whole number of days only, or NOT_STATED.',
           'non_renewal_notice_days_quote':  'Copy, word for word, the single sentence that states the non-renewal notice period. Answer NOT_STATED if none.',
           'renewal_uplift_cap_pct':         'What is the maximum percentage by which fees or prices may increase for a renewal term over the preceding term? Answer with the number only, without the percent sign, or NOT_STATED.',
           'renewal_uplift_cap_pct_quote':   'Copy, word for word, the single sentence that limits price increases on renewal. Answer NOT_STATED if none.',
           'annual_escalator_cap_pct':       'During the term, what is the maximum percentage by which fees may be increased each year or on each anniversary? Answer with the number only, without the percent sign, or NOT_STATED. Do not answer with a renewal price cap.',
           'annual_escalator_cap_pct_quote': 'Copy, word for word, the single sentence that permits annual or anniversary price increases. Answer NOT_STATED if none.',
           'contract_currency':              'In what currency are the prices or fees stated? Answer with the three-letter ISO currency code, for example USD or EUR, or NOT_STATED.',
           'contract_currency_quote':        'Copy, word for word, the single sentence or table heading that states the currency. Answer NOT_STATED if none.',
           'payment_terms_days':             'Within how many days must invoices be paid (for example net 30)? Answer with a whole number of days only, or NOT_STATED.',
           'payment_terms_days_quote':       'Copy, word for word, the single sentence that states the payment terms. Answer NOT_STATED if none.',
           'termination_for_convenience_notice_days':       'How many days of notice are required to terminate this agreement for convenience, without cause? Answer with a whole number of days only, or NOT_STATED. Do not answer with a cure period for breach.',
           'termination_for_convenience_notice_days_quote': 'Copy, word for word, the single sentence that permits termination for convenience. Answer NOT_STATED if none.',
           'early_termination_fee_pct':       'If the buyer terminates early, what early termination fee applies, expressed as a percentage of remaining fees? Answer with the number only, without the percent sign, or NOT_STATED.',
           'early_termination_fee_pct_quote': 'Copy, word for word, the single sentence that states the early termination fee. Answer NOT_STATED if none.',
           'audit_window_months':             'For how many months after payment may the buyer audit invoices or claim refunds of overcharges? Answer with a whole number of months only, or NOT_STATED.',
           'audit_window_months_quote':       'Copy, word for word, the single sentence that states the audit or refund look-back period. Answer NOT_STATED if none.'
         }) AS resp
FROM _X_DOCS d
WHERE d.family_role = 'GOVERNING';

CREATE TABLE IF NOT EXISTS CONTRACT_HEADER_TERMS (
    run_id VARCHAR, experiment_id VARCHAR, prompt_version VARCHAR, prompt_hash VARCHAR,
    contract_family_id VARCHAR, document_id VARCHAR, term_name VARCHAR,
    raw_value VARCHAR, normalized_value VARCHAR, status VARCHAR,
    evidence_quote VARCHAR, quote_verified BOOLEAN, page_index INT, clause_ref VARCHAR,
    extractor VARCHAR, extract_error VARCHAR, extracted_at TIMESTAMP_NTZ
);

DELETE FROM CONTRACT_HEADER_TERMS WHERE experiment_id = '{{EXPERIMENT_ID}}';

INSERT INTO CONTRACT_HEADER_TERMS
WITH terms (term_name, term_type) AS (
    SELECT * FROM VALUES
      ('agreement_effective_date','DATE'), ('initial_term_end_date','DATE'),
      ('auto_renewal','BOOL'), ('renewal_term_months','NUM'),
      ('non_renewal_notice_days','NUM'), ('renewal_uplift_cap_pct','NUM'),
      ('annual_escalator_cap_pct','NUM'), ('contract_currency','CCY'),
      ('payment_terms_days','NUM'), ('termination_for_convenience_notice_days','NUM'),
      ('early_termination_fee_pct','NUM'), ('audit_window_months','NUM')
),
long AS (
    SELECT h.document_id, h.contract_family_id, t.term_name, t.term_type,
           h.resp:error::VARCHAR                                   AS extract_error,
           NULLIF(TRIM(GET(h.resp:response, t.term_name)::VARCHAR), '')            AS raw_value,
           NULLIF(TRIM(GET(h.resp:response, t.term_name || '_quote')::VARCHAR), '') AS raw_quote
    FROM _X_HEADER_RAW h CROSS JOIN terms t
),
norm AS (
    SELECT l.*,
           CASE
             WHEN UPPER(l.raw_value) = 'NOT_STATED' THEN 'NOT_STATED'
             WHEN l.term_type = 'DATE' THEN TO_VARCHAR(TRY_TO_DATE(l.raw_value, 'YYYY-MM-DD'), 'YYYY-MM-DD')
             WHEN l.term_type = 'BOOL' THEN IFF(UPPER(l.raw_value) IN ('TRUE','FALSE'), UPPER(l.raw_value), NULL)
             WHEN l.term_type = 'CCY'  THEN IFF(REGEXP_LIKE(UPPER(l.raw_value), '^[A-Z]{3}$'), UPPER(l.raw_value), NULL)
             WHEN l.term_type = 'NUM'  THEN RTRIM(RTRIM(TO_VARCHAR(
                     TRY_TO_DECIMAL(REGEXP_REPLACE(l.raw_value, '[%\\s]', ''), 18, 4)), '0'), '.')
           END AS normalized_value,
           IFF(UPPER(l.raw_quote) = 'NOT_STATED', NULL, l.raw_quote) AS evidence_quote
    FROM long l
),
page_hit AS (
    SELECT n.document_id, n.term_name, MIN(p.page_index) AS page_index
    FROM norm n
    JOIN _X_PAGES p
      ON p.document_id = n.document_id
     AND CONTAINS(p.norm_page, REGEXP_REPLACE(UPPER(n.evidence_quote), '\\s+', ' '))
    WHERE n.evidence_quote IS NOT NULL
    GROUP BY 1, 2
),
verified AS (
    SELECT n.*,
           COALESCE(n.evidence_quote IS NOT NULL
             AND LENGTH(n.evidence_quote) >= {{QUOTE_MIN_CHARS}}
             AND CONTAINS(d.norm_text, REGEXP_REPLACE(UPPER(n.evidence_quote), '\\s+', ' ')), FALSE) AS quote_verified,
           ph.page_index,
           -- Best-effort clause reference: a section number such as 1.2 or 4.
           -- at the start of the quoted sentence. NULL when the quote does not
           -- begin a numbered clause; never guessed.
           REGEXP_SUBSTR(n.evidence_quote, '^\\s*([0-9]+(\\.[0-9]+)*)[. ]', 1, 1, 'e', 1) AS clause_ref
    FROM norm n
    JOIN _X_DOCS d ON d.document_id = n.document_id
    LEFT JOIN page_hit ph ON ph.document_id = n.document_id AND ph.term_name = n.term_name
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{PROMPT_VERSION}}', '{{PROMPT_HASH}}',
       contract_family_id, document_id, term_name, raw_value, normalized_value,
       CASE
         WHEN extract_error IS NOT NULL OR raw_value IS NULL THEN 'FAILED'
         WHEN normalized_value = 'NOT_STATED'                THEN 'NOT_STATED'
         WHEN normalized_value IS NULL                       THEN 'FAILED'
         WHEN NOT quote_verified                             THEN 'UNVERIFIED'
         ELSE 'EXTRACTED'
       END,
       evidence_quote, quote_verified, page_index, clause_ref,
       'AI_EXTRACT', extract_error, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM verified;

-- ---------------------------------------------------------------------
-- 2. Rate lines from tables. AI_EXTRACT table extraction reads rate cards
--    and volume-tier tables as column arrays. Table rows carry no quote,
--    so evidence is located in SQL: the source line that contains both the
--    item code (or description) and the price. A row whose line cannot be
--    found is UNVERIFIED and cannot price anything (rule 2).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _X_TABLES_RAW AS
SELECT d.document_id, d.contract_family_id, d.family_role,
       AI_EXTRACT(
         text => d.full_text,
         responseFormat => {'schema': {'type': 'object', 'properties': {
           'rate_card': {
             'description': 'Table of priced items, services, roles or SKUs with their unit price, rate or fee. Exclude volume tier tables.',
             'type': 'object',
             'column_ordering': ['item_code', 'description', 'unit', 'price'],
             'properties': {
               'item_code':   {'description': 'Item code, SKU, service code, model or role code', 'type': 'array'},
               'description': {'description': 'Item, service or role description', 'type': 'array'},
               'unit':        {'description': 'Unit of measure such as Hour, Day, Each, Month. If the unit appears only in the price column heading, such as Rate per Hour, use that unit.', 'type': 'array'},
               'price':       {'description': 'Unit price, rate or fee exactly as written, including any currency symbol', 'type': 'array'}
             }},
           'volume_tiers': {
             'description': 'Volume, quantity or tier pricing table where the unit price depends on cumulative quantity purchased',
             'type': 'object',
             'column_ordering': ['item_code', 'tier_min_quantity', 'tier_max_quantity', 'tier_price'],
             'properties': {
               'item_code':         {'description': 'Item code the tier table applies to, from the table heading or the sentence introducing it', 'type': 'array'},
               'tier_min_quantity': {'description': 'Lowest quantity in the tier, as written', 'type': 'array'},
               'tier_max_quantity': {'description': 'Highest quantity in the tier as written, or the words used for an open-ended top tier', 'type': 'array'},
               'tier_price':        {'description': 'Unit price for the tier, exactly as written', 'type': 'array'}
             }}
         }}}) AS resp
FROM _X_DOCS d
WHERE d.family_role = 'GOVERNING';

-- Source lines, for locating table-row evidence.
CREATE OR REPLACE TEMPORARY TABLE _X_LINES AS
SELECT d.document_id, s.index AS line_no, s.value::VARCHAR AS line_text,
       REPLACE(UPPER(s.value::VARCHAR), ',', '') AS line_cmp
FROM _X_DOCS d,
     LATERAL SPLIT_TO_TABLE(d.full_text, '\n') s
WHERE LENGTH(TRIM(s.value)) > 0;

CREATE TABLE IF NOT EXISTS CONTRACT_RATE_LINES (
    run_id VARCHAR, experiment_id VARCHAR, prompt_version VARCHAR, prompt_hash VARCHAR,
    contract_family_id VARCHAR, document_id VARCHAR, source_kind VARCHAR,   -- RATE_CARD | VOLUME_TIER | PROSE | AMENDMENT
    sku VARCHAR, description VARCHAR, raw_unit VARCHAR, unit_of_measure VARCHAR,
    raw_price VARCHAR, unit_price NUMBER(18,4), currency VARCHAR,
    tier_min_qty NUMBER(18,4), tier_max_qty NUMBER(18,4),
    status VARCHAR, evidence_quote VARCHAR, quote_verified BOOLEAN,
    extractor VARCHAR, extract_error VARCHAR, extracted_at TIMESTAMP_NTZ
);

DELETE FROM CONTRACT_RATE_LINES WHERE experiment_id = '{{EXPERIMENT_ID}}';

-- Shared normalizers, inlined as CTEs per statement:
--   unit:  HOUR | DAY | EACH | MONTH | YEAR | other uppercased
--   price: remove currency tokens, separators and spaces; must then be a
--          plain decimal, otherwise NON_NUMERIC ("see Section 2.2" must
--          not become a price of 2.2)
INSERT INTO CONTRACT_RATE_LINES
WITH card AS (
    SELECT t.document_id, t.contract_family_id, t.resp:error::VARCHAR AS extract_error,
           f.index AS i,
           NULLIF(TRIM(f.value::VARCHAR), '') AS sku,
           NULLIF(TRIM(t.resp:response:rate_card:description[f.index]::VARCHAR), '') AS description,
           NULLIF(TRIM(t.resp:response:rate_card:unit[f.index]::VARCHAR), '')        AS raw_unit,
           NULLIF(TRIM(t.resp:response:rate_card:price[f.index]::VARCHAR), '')       AS raw_price
    FROM _X_TABLES_RAW t,
         LATERAL FLATTEN(input => t.resp:response:rate_card:item_code) f
),
tiers AS (
    SELECT t.document_id, t.contract_family_id, t.resp:error::VARCHAR AS extract_error,
           f.index AS i,
           NULLIF(TRIM(f.value::VARCHAR), '') AS sku,
           t.resp:response:volume_tiers:tier_min_quantity[f.index]::VARCHAR AS raw_min,
           t.resp:response:volume_tiers:tier_max_quantity[f.index]::VARCHAR AS raw_max,
           t.resp:response:volume_tiers:tier_price[f.index]::VARCHAR        AS raw_price
    FROM _X_TABLES_RAW t,
         LATERAL FLATTEN(input => t.resp:response:volume_tiers:item_code) f
),
hdr_ccy AS (
    SELECT contract_family_id, normalized_value AS ccy
    FROM CONTRACT_HEADER_TERMS
    WHERE experiment_id = '{{EXPERIMENT_ID}}' AND term_name = 'contract_currency' AND status = 'EXTRACTED'
),
rows_all AS (
    SELECT document_id, contract_family_id, 'RATE_CARD' AS source_kind, sku, description, raw_unit, raw_price,
           NULL AS raw_min, NULL AS raw_max, extract_error
    FROM card
    UNION ALL
    SELECT tr.document_id, tr.contract_family_id, 'VOLUME_TIER', tr.sku,
           c.description, c.raw_unit, tr.raw_price, tr.raw_min, tr.raw_max, tr.extract_error
    FROM tiers tr
    LEFT JOIN card c ON c.document_id = tr.document_id AND UPPER(c.sku) = UPPER(tr.sku)
),
normed AS (
    SELECT r.*,
           REGEXP_REPLACE(UPPER(COALESCE(r.raw_price, '')),
               '(USD|EUR|GBP|CHF|CAD|AUD|JPY|US|PER|EACH|HOUR|HR|DAY|MONTH|UNIT|\\$|€|£|,|\\s)', '') AS price_clean,
           CASE
             WHEN UPPER(r.raw_unit) IN ('HOUR','HOURS','HR','HRS','PER HOUR','HOURLY')  THEN 'HOUR'
             WHEN UPPER(r.raw_unit) IN ('DAY','DAYS','PER DAY','DAILY')                 THEN 'DAY'
             WHEN UPPER(r.raw_unit) IN ('EACH','EA','UNIT','UNITS','PER UNIT','PIECE')  THEN 'EACH'
             WHEN UPPER(r.raw_unit) IN ('MONTH','MONTHS','MONTHLY','PER MONTH','MO')    THEN 'MONTH'
             WHEN UPPER(r.raw_unit) IN ('YEAR','YEARS','ANNUAL','ANNUALLY','PER YEAR')  THEN 'YEAR'
             ELSE NULLIF(UPPER(TRIM(r.raw_unit)), '')
           END AS unit_of_measure,
           CASE
             WHEN REGEXP_LIKE(UPPER(r.raw_price), '.*(EUR|€).*') THEN 'EUR'
             WHEN REGEXP_LIKE(UPPER(r.raw_price), '.*(GBP|£).*') THEN 'GBP'
             WHEN REGEXP_LIKE(UPPER(r.raw_price), '.*(USD|\\$).*') THEN 'USD'
             ELSE NULL
           END AS price_ccy,
           TRY_TO_DECIMAL(REPLACE(r.raw_min, ',', ''), 18, 4) AS tier_min_qty,
           TRY_TO_DECIMAL(REPLACE(r.raw_max, ',', ''), 18, 4) AS tier_max_qty
    FROM rows_all r
),
priced AS (
    SELECT n.*,
           ROW_NUMBER() OVER (ORDER BY n.document_id, n.source_kind, n.sku, n.raw_min) AS row_key,
           IFF(REGEXP_LIKE(n.price_clean, '^[0-9]+(\\.[0-9]+)?$'), TRY_TO_DECIMAL(n.price_clean, 18, 4), NULL) AS unit_price
    FROM normed n
),
evidence_hits AS (
    -- Source lines containing the price digits and the item code (or the
    -- tier minimum, or the description). Commas are removed on both sides so
    -- 18,500.00 matches 18500.00. The first such line is the evidence.
    SELECT p.row_key, MIN_BY(l.line_text, l.line_no) AS evidence_line
    FROM priced p
    JOIN _X_LINES l
      ON l.document_id = p.document_id
     AND CONTAINS(l.line_cmp, p.price_clean)
     AND (   (p.sku IS NOT NULL AND CONTAINS(l.line_cmp, UPPER(p.sku)))
          OR (p.source_kind = 'VOLUME_TIER' AND p.tier_min_qty IS NOT NULL
              AND CONTAINS(l.line_cmp, TO_VARCHAR(p.tier_min_qty::INT)))
          OR (p.description IS NOT NULL AND CONTAINS(l.line_cmp, UPPER(p.description))))
    WHERE p.unit_price IS NOT NULL
    GROUP BY 1
),
tier_skus AS (
    SELECT DISTINCT document_id, UPPER(sku) AS sku FROM tiers WHERE sku IS NOT NULL
),
evidence AS (
    SELECT p.*, eh.evidence_line, ts.sku IS NOT NULL AS sku_has_tiers
    FROM priced p
    LEFT JOIN evidence_hits eh ON eh.row_key = p.row_key
    LEFT JOIN tier_skus ts ON ts.document_id = p.document_id AND ts.sku = UPPER(p.sku)
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{PROMPT_VERSION}}', '{{PROMPT_HASH}}',
       e.contract_family_id, e.document_id, e.source_kind,
       UPPER(e.sku), e.description, e.raw_unit, e.unit_of_measure,
       e.raw_price, e.unit_price, COALESCE(e.price_ccy, h.ccy),
       IFF(e.source_kind = 'VOLUME_TIER', e.tier_min_qty, NULL),
       IFF(e.source_kind = 'VOLUME_TIER', e.tier_max_qty, NULL),
       CASE
         WHEN e.extract_error IS NOT NULL                                   THEN 'FAILED'
         WHEN e.unit_price IS NULL AND e.source_kind = 'RATE_CARD' AND e.sku_has_tiers THEN 'SUPERSEDED_BY_TIERS'
         WHEN e.unit_price IS NULL                                          THEN 'NON_NUMERIC'
         WHEN e.sku IS NULL AND e.description IS NULL                       THEN 'FAILED'
         WHEN e.evidence_line IS NULL                                       THEN 'UNVERIFIED'
         WHEN COALESCE(e.price_ccy, h.ccy) IS NULL                          THEN 'NO_CURRENCY'
         ELSE 'EXTRACTED'
       END,
       TRIM(e.evidence_line), e.evidence_line IS NOT NULL,
       'AI_EXTRACT_TABLE', e.extract_error, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM evidence e
LEFT JOIN hdr_ccy h ON h.contract_family_id = e.contract_family_id;

-- ---------------------------------------------------------------------
-- 3. Prose pricing fallback. Only for governing documents that produced no
--    EXTRACTED rate line from tables (prices written as sentences, as in
--    "Fees: $8,000.00 per month"). AI_COMPLETE with a JSON schema, sent the
--    pricing window only, never the whole contract (rule 22).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _X_WINDOWS AS
WITH flagged AS (
    SELECT l.document_id, l.line_no, l.line_text,
           REGEXP_LIKE(UPPER(l.line_text),
             '.*(PRICE|PRICING|FEE|RATE|TIER|VOLUME|CUMULATIVE|INCREASE|ADJUST|ESCALAT|UPLIFT|RENEW|AMEND|REPLACE|SUPERSEDE|RETROACTIV|SCHEDULE|\\$|EUR|USD|PER MONTH|PER HOUR|PER UNIT).*') AS hit
    FROM _X_LINES l
),
win AS (
    SELECT f.*,
           hit OR LAG(hit) OVER (PARTITION BY document_id ORDER BY line_no)
               OR LEAD(hit) OVER (PARTITION BY document_id ORDER BY line_no) AS keep
    FROM flagged f
)
SELECT document_id,
       LISTAGG(line_text, '\n') WITHIN GROUP (ORDER BY line_no) AS window_text
FROM win WHERE keep
GROUP BY document_id;

INSERT INTO CONTRACT_RATE_LINES
WITH need AS (
    SELECT d.document_id, d.contract_family_id, w.window_text, d.norm_text
    FROM _X_DOCS d
    JOIN _X_WINDOWS w ON w.document_id = d.document_id
    WHERE d.family_role = 'GOVERNING'
      AND NOT EXISTS (SELECT 1 FROM CONTRACT_RATE_LINES r
                      WHERE r.experiment_id = '{{EXPERIMENT_ID}}'
                        AND r.document_id = d.document_id AND r.status = 'EXTRACTED')
),
resp AS (
    SELECT n.*,
           TRY_PARSE_JSON(TO_VARCHAR(AI_COMPLETE(
             model => '{{MODEL}}',
             prompt => 'You are abstracting the pricing of a supplier contract. From the contract excerpt below, list every priced item, service, subscription or role stated in sentences. For each, give the item code or SKU if stated, a short description, the unit of measure (Hour, Day, Each, Month or Year), the unit price as a number without symbols or separators, the three-letter currency code, and evidence_quote: one sentence copied word for word from the excerpt that contains the price. Do not compute or infer prices. If no price is stated, return an empty list. Respond in JSON.\n\nCONTRACT EXCERPT:\n' || n.window_text,
             model_parameters => {'temperature': 0, 'max_tokens': 2048},
             response_format => {'type': 'json', 'schema': {
               'type': 'object', 'additionalProperties': false, 'required': ['rate_lines'],
               'properties': {'rate_lines': {'type': 'array', 'items': {
                 'type': 'object', 'additionalProperties': false,
                 'required': ['item_code', 'description', 'unit', 'unit_price', 'currency', 'evidence_quote'],
                 'properties': {
                   'item_code': {'type': 'string'}, 'description': {'type': 'string'},
                   'unit': {'type': 'string'}, 'unit_price': {'type': 'string'},
                   'currency': {'type': 'string'}, 'evidence_quote': {'type': 'string'}}}}}}}
           ))) AS j
    FROM need n
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{PROMPT_VERSION}}', '{{PROMPT_HASH}}',
       r.contract_family_id, r.document_id, 'PROSE',
       NULLIF(UPPER(TRIM(f.value:item_code::VARCHAR)), ''), f.value:description::VARCHAR,
       f.value:unit::VARCHAR,
       CASE UPPER(f.value:unit::VARCHAR) WHEN 'HOUR' THEN 'HOUR' WHEN 'DAY' THEN 'DAY' WHEN 'EACH' THEN 'EACH'
                                         WHEN 'MONTH' THEN 'MONTH' WHEN 'YEAR' THEN 'YEAR'
                                         ELSE NULLIF(UPPER(TRIM(f.value:unit::VARCHAR)), '') END,
       f.value:unit_price::VARCHAR,
       TRY_TO_DECIMAL(REPLACE(f.value:unit_price::VARCHAR, ',', ''), 18, 4),
       NULLIF(UPPER(TRIM(f.value:currency::VARCHAR)), ''),
       NULL, NULL,
       CASE
         WHEN r.j IS NULL THEN 'FAILED'
         WHEN TRY_TO_DECIMAL(REPLACE(f.value:unit_price::VARCHAR, ',', ''), 18, 4) IS NULL THEN 'NON_NUMERIC'
         WHEN LENGTH(f.value:evidence_quote::VARCHAR) < {{QUOTE_MIN_CHARS}}
           OR NOT CONTAINS(r.norm_text, REGEXP_REPLACE(UPPER(f.value:evidence_quote::VARCHAR), '\\s+', ' '))
           -- The quote must also contain the price it is evidence for, written
           -- with two decimals or as a whole number.
           OR NOT (CONTAINS(REPLACE(f.value:evidence_quote::VARCHAR, ',', ''),
                            TO_VARCHAR(TRY_TO_DECIMAL(REPLACE(f.value:unit_price::VARCHAR, ',', ''), 18, 2), 'FM9999999999990.00'))
                OR CONTAINS(REPLACE(f.value:evidence_quote::VARCHAR, ',', '') || ' ',
                            TO_VARCHAR(TRY_TO_DECIMAL(REPLACE(f.value:unit_price::VARCHAR, ',', ''), 18, 0)) || ' '))
           THEN 'UNVERIFIED'
         ELSE 'EXTRACTED'
       END,
       f.value:evidence_quote::VARCHAR,
       CONTAINS(r.norm_text, REGEXP_REPLACE(UPPER(f.value:evidence_quote::VARCHAR), '\\s+', ' ')),
       'AI_COMPLETE', IFF(r.j IS NULL, 'NULL_OR_UNPARSEABLE_RESPONSE', NULL), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM resp r,
     LATERAL FLATTEN(input => r.j:rate_lines, OUTER => TRUE) f;

-- ---------------------------------------------------------------------
-- 4. Clause interpretation. Governing documents and amendments. These are
--    the clauses that single-value extraction cannot answer: how tiers
--    apply, what accumulates, how escalators are measured, and exactly what
--    an amendment changes and from when.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS CONTRACT_CLAUSE_RULES (
    run_id VARCHAR, experiment_id VARCHAR, prompt_version VARCHAR, prompt_hash VARCHAR,
    contract_family_id VARCHAR, document_id VARCHAR, family_role VARCHAR,
    response VARIANT, response_status VARCHAR, extracted_at TIMESTAMP_NTZ
);

DELETE FROM CONTRACT_CLAUSE_RULES WHERE experiment_id = '{{EXPERIMENT_ID}}';

INSERT INTO CONTRACT_CLAUSE_RULES
WITH src AS (
    SELECT d.document_id, d.contract_family_id, d.family_role,
           IFF(d.family_role = 'AMENDMENT', d.full_text, w.window_text) AS clause_text
    FROM _X_DOCS d
    LEFT JOIN _X_WINDOWS w ON w.document_id = d.document_id
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{PROMPT_VERSION}}', '{{PROMPT_HASH}}',
       s.contract_family_id, s.document_id, s.family_role, j,
       IFF(j IS NULL, 'FAILED', 'OK'), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM (
    SELECT s.*,
           TRY_PARSE_JSON(TO_VARCHAR(AI_COMPLETE(
             model => '{{MODEL}}',
             prompt => 'You are a contract analyst reading an excerpt of a supplier contract or an amendment. Answer only from the text. Use NOT_STATED whenever the text does not say. Every *_quote field and every evidence_quote must be copied word for word from the excerpt, or NOT_STATED.\n'
                    || '1. tier_application: if volume or tier pricing exists, does a tier price apply only to units purchased after the threshold is reached (INCREMENTAL), or to all units once the threshold is reached (RETROACTIVE)? NOT_STATED if no tiers or the text does not say.\n'
                    || '2. tier_accumulation_period: over what period is quantity counted toward tiers: CONTRACT_YEAR, CALENDAR_YEAR, PER_ORDER, PER_INVOICE, or NOT_STATED.\n'
                    || '3. escalator_basis: if annual price increases are permitted during the term, are they measured from each anniversary of the effective date (ANNIVERSARY_OF_EFFECTIVE_DATE) or each calendar year (CALENDAR_YEAR)? NOT_STATED otherwise.\n'
                    || '4. If this document is an amendment: amendment_effective_date as YYYY-MM-DD, amended_term_end_date as YYYY-MM-DD if the amendment changes when the term ends, and amendment_changes: one entry per price the amendment addresses, with item_code, change_kind (REPLACED, UNCHANGED, ADDED or REMOVED), new_unit_price as a number without symbols (NOT_STATED for UNCHANGED or REMOVED), unit, currency code, effective_date as YYYY-MM-DD or NOT_STATED, and evidence_quote. For a document that is not an amendment, return NOT_STATED and an empty list.\n'
                    || 'Respond in JSON.\n\nEXCERPT:\n' || s.clause_text,
             model_parameters => {'temperature': 0, 'max_tokens': 2048},
             response_format => {'type': 'json', 'schema': {
               'type': 'object', 'additionalProperties': false,
               'required': ['tier_application', 'tier_application_quote', 'tier_accumulation_period', 'tier_accumulation_quote',
                            'escalator_basis', 'escalator_quote', 'amendment_effective_date', 'amended_term_end_date',
                            'amended_term_end_quote', 'amendment_changes'],
               'properties': {
                 'tier_application':          {'type': 'string', 'enum': ['INCREMENTAL', 'RETROACTIVE', 'NOT_STATED']},
                 'tier_application_quote':    {'type': 'string'},
                 'tier_accumulation_period':  {'type': 'string', 'enum': ['CONTRACT_YEAR', 'CALENDAR_YEAR', 'PER_ORDER', 'PER_INVOICE', 'NOT_STATED']},
                 'tier_accumulation_quote':   {'type': 'string'},
                 'escalator_basis':           {'type': 'string', 'enum': ['ANNIVERSARY_OF_EFFECTIVE_DATE', 'CALENDAR_YEAR', 'NOT_STATED']},
                 'escalator_quote':           {'type': 'string'},
                 'amendment_effective_date':  {'type': 'string'},
                 'amended_term_end_date':     {'type': 'string'},
                 'amended_term_end_quote':    {'type': 'string'},
                 'amendment_changes': {'type': 'array', 'items': {
                   'type': 'object', 'additionalProperties': false,
                   'required': ['item_code', 'change_kind', 'new_unit_price', 'unit', 'currency', 'effective_date', 'evidence_quote'],
                   'properties': {
                     'item_code': {'type': 'string'},
                     'change_kind': {'type': 'string', 'enum': ['REPLACED', 'UNCHANGED', 'ADDED', 'REMOVED']},
                     'new_unit_price': {'type': 'string'}, 'unit': {'type': 'string'},
                     'currency': {'type': 'string'}, 'effective_date': {'type': 'string'},
                     'evidence_quote': {'type': 'string'}}}}}}}
           ))) AS j
    FROM src s
) s;

-- 4a. Amendment price changes become rate lines, verified like any other.
INSERT INTO CONTRACT_RATE_LINES
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{PROMPT_VERSION}}', '{{PROMPT_HASH}}',
       c.contract_family_id, c.document_id, 'AMENDMENT',
       UPPER(TRIM(f.value:item_code::VARCHAR)), f.value:change_kind::VARCHAR,
       f.value:unit::VARCHAR,
       CASE UPPER(f.value:unit::VARCHAR) WHEN 'HOUR' THEN 'HOUR' WHEN 'DAY' THEN 'DAY' WHEN 'EACH' THEN 'EACH'
                                         WHEN 'MONTH' THEN 'MONTH' WHEN 'YEAR' THEN 'YEAR'
                                         ELSE NULLIF(UPPER(TRIM(f.value:unit::VARCHAR)), '') END,
       f.value:new_unit_price::VARCHAR,
       TRY_TO_DECIMAL(REPLACE(f.value:new_unit_price::VARCHAR, ',', ''), 18, 4),
       NULLIF(NULLIF(UPPER(TRIM(f.value:currency::VARCHAR)), ''), 'NOT_STATED'),
       NULL, NULL,
       CASE
         WHEN f.value:change_kind::VARCHAR <> 'REPLACED' AND f.value:change_kind::VARCHAR <> 'ADDED' THEN 'NO_PRICE_CHANGE'
         WHEN TRY_TO_DECIMAL(REPLACE(f.value:new_unit_price::VARCHAR, ',', ''), 18, 4) IS NULL THEN 'NON_NUMERIC'
         WHEN LENGTH(f.value:evidence_quote::VARCHAR) < {{QUOTE_MIN_CHARS}}
           OR NOT CONTAINS(d.norm_text, REGEXP_REPLACE(UPPER(f.value:evidence_quote::VARCHAR), '\\s+', ' '))
           THEN 'UNVERIFIED'
         ELSE 'EXTRACTED'
       END,
       f.value:evidence_quote::VARCHAR,
       CONTAINS(d.norm_text, REGEXP_REPLACE(UPPER(f.value:evidence_quote::VARCHAR), '\\s+', ' ')),
       'AI_COMPLETE', NULL, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM CONTRACT_CLAUSE_RULES c
JOIN _X_DOCS d ON d.document_id = c.document_id,
     LATERAL FLATTEN(input => c.response:amendment_changes) f
WHERE c.experiment_id = '{{EXPERIMENT_ID}}' AND c.family_role = 'AMENDMENT' AND c.response_status = 'OK';

-- ---------------------------------------------------------------------
-- 5. Term periods (pure SQL). Initial term from header terms, extended by
--    a verified amendment term end, then rolled forward while the contract
--    auto-renews until a period starts after the as-of date (rule 14).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE CONTRACT_TERM_PERIODS AS
WITH h AS (
    SELECT contract_family_id,
           MAX(IFF(term_name = 'agreement_effective_date' AND status = 'EXTRACTED', normalized_value, NULL))::DATE AS eff_date,
           MAX(IFF(term_name = 'initial_term_end_date'    AND status = 'EXTRACTED', normalized_value, NULL))::DATE AS init_end,
           MAX(IFF(term_name = 'auto_renewal'             AND status = 'EXTRACTED', normalized_value, NULL))     AS auto_renewal,
           MAX(IFF(term_name = 'renewal_term_months'      AND status = 'EXTRACTED', normalized_value, NULL))::INT  AS renewal_months,
           MAX(IFF(term_name = 'non_renewal_notice_days'  AND status = 'EXTRACTED', normalized_value, NULL))::INT  AS notice_days,
           MAX(IFF(term_name = 'contract_currency'        AND status = 'EXTRACTED', normalized_value, NULL))       AS contract_currency
    FROM CONTRACT_HEADER_TERMS
    WHERE experiment_id = '{{EXPERIMENT_ID}}'
    GROUP BY 1
),
amend_end AS (
    -- Latest verified amended term end per family. The quote must verify.
    SELECT c.contract_family_id,
           MAX(TRY_TO_DATE(c.response:amended_term_end_date::VARCHAR, 'YYYY-MM-DD')) AS amended_end
    FROM CONTRACT_CLAUSE_RULES c
    JOIN _X_DOCS d ON d.document_id = c.document_id
    WHERE c.experiment_id = '{{EXPERIMENT_ID}}' AND c.family_role = 'AMENDMENT'
      AND TRY_TO_DATE(c.response:amended_term_end_date::VARCHAR, 'YYYY-MM-DD') IS NOT NULL
      AND CONTAINS(d.norm_text, REGEXP_REPLACE(UPPER(c.response:amended_term_end_quote::VARCHAR), '\\s+', ' '))
    GROUP BY 1
),
base AS (
    SELECT h.*, COALESCE(a.amended_end, h.init_end) AS initial_end_effective
    FROM h LEFT JOIN amend_end a ON a.contract_family_id = h.contract_family_id
    WHERE h.eff_date IS NOT NULL AND h.init_end IS NOT NULL
),
n AS (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS k FROM TABLE(GENERATOR(ROWCOUNT => 60))),
periods AS (
    SELECT b.contract_family_id, n.k AS period_no,
           IFF(n.k = 0, 'INITIAL', 'RENEWAL') AS period_kind,
           IFF(n.k = 0, b.eff_date,
               DATEADD(month, b.renewal_months * (n.k - 1), DATEADD(day, 1, b.initial_end_effective))) AS period_start,
           IFF(n.k = 0, b.initial_end_effective,
               DATEADD(day, -1, DATEADD(month, b.renewal_months * n.k, DATEADD(day, 1, b.initial_end_effective)))) AS period_end,
           b.auto_renewal, b.renewal_months, b.notice_days, b.contract_currency
    FROM base b JOIN n
      ON n.k = 0 OR (b.auto_renewal = 'TRUE' AND b.renewal_months > 0)
)
SELECT p.*,
       IFF(p.notice_days IS NOT NULL AND p.auto_renewal = 'TRUE',
           DATEADD(day, -p.notice_days, p.period_end), NULL) AS notice_deadline,
       '{{AS_OF_DATE}}'::DATE BETWEEN p.period_start AND p.period_end AS is_current_period,
       'CALENDAR_DAYS_BEFORE_PERIOD_END' AS notice_convention,
       '{{RUN_ID}}' AS run_id, '{{EXPERIMENT_ID}}' AS experiment_id
FROM periods p
WHERE p.period_no = 0 OR p.period_start <= '{{AS_OF_DATE}}'::DATE;

-- ---------------------------------------------------------------------
-- 6. Effective rates (pure SQL, rule 4). Base rates span the initial term;
--    amendment rates start on their effective date and close the window of
--    the rate they replace. Only EXTRACTED lines participate.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE CONTRACT_EFFECTIVE_RATES AS
WITH init AS (
    SELECT contract_family_id, MIN(period_start) AS term_start,
           MAX(IFF(period_no = 0, period_end, NULL)) AS initial_end
    FROM CONTRACT_TERM_PERIODS GROUP BY 1
),
amend_eff AS (
    SELECT c.document_id, TRY_TO_DATE(c.response:amendment_effective_date::VARCHAR, 'YYYY-MM-DD') AS amend_date
    FROM CONTRACT_CLAUSE_RULES c
    WHERE c.experiment_id = '{{EXPERIMENT_ID}}' AND c.family_role = 'AMENDMENT'
),
stated AS (
    SELECT r.contract_family_id, r.document_id AS source_document_id, r.source_kind,
           r.sku, r.description, r.unit_of_measure, r.tier_min_qty, r.tier_max_qty,
           r.unit_price, r.currency, r.evidence_quote,
           CASE WHEN r.source_kind = 'AMENDMENT'
                THEN COALESCE(ae.amend_date, reg.document_effective_date)
                ELSE i.term_start END AS effective_from,
           i.initial_end AS term_end,
           IFF(r.source_kind = 'AMENDMENT', 1, 0) AS is_amendment
    FROM CONTRACT_RATE_LINES r
    JOIN init i ON i.contract_family_id = r.contract_family_id
    LEFT JOIN amend_eff ae ON ae.document_id = r.document_id
    LEFT JOIN CONTRACT_REGISTRY reg ON reg.document_id = r.document_id
    WHERE r.experiment_id = '{{EXPERIMENT_ID}}' AND r.status = 'EXTRACTED'
),
-- An amendment that replaces a SKU's price inherits the base row's unit,
-- description and currency when it does not restate them.
filled AS (
    SELECT s.contract_family_id, s.source_document_id, s.source_kind, s.sku,
           COALESCE(b.description, s.description) AS description,
           COALESCE(s.unit_of_measure, b.unit_of_measure) AS unit_of_measure,
           s.tier_min_qty, s.tier_max_qty, s.unit_price,
           COALESCE(s.currency, b.currency) AS currency,
           s.evidence_quote, s.effective_from, s.term_end, s.is_amendment
    FROM stated s
    LEFT JOIN stated b
      ON s.is_amendment = 1 AND b.is_amendment = 0
     AND b.contract_family_id = s.contract_family_id AND b.sku = s.sku AND b.tier_min_qty IS NULL
),
ranked AS (
    SELECT f.*,
           ROW_NUMBER() OVER (PARTITION BY contract_family_id, sku, COALESCE(tier_min_qty, -1)
                              ORDER BY effective_from, is_amendment, source_document_id) AS precedence_rank,
           LEAD(effective_from) OVER (PARTITION BY contract_family_id, sku, COALESCE(tier_min_qty, -1)
                                      ORDER BY effective_from, is_amendment, source_document_id) AS next_from
    FROM filled f
)
SELECT SHA2(contract_family_id || '|' || source_document_id || '|' || COALESCE(sku, description) || '|'
            || COALESCE(TO_VARCHAR(tier_min_qty), '-') || '|' || TO_VARCHAR(effective_from)) AS rate_line_id,
       contract_family_id, source_document_id, source_kind, sku, description, unit_of_measure,
       tier_min_qty, tier_max_qty,
       -- Half-open upper bound for tier arithmetic: the next tier's minimum (rule 7).
       LEAD(tier_min_qty) OVER (PARTITION BY contract_family_id, sku, effective_from ORDER BY tier_min_qty) AS tier_upper_exclusive,
       unit_price, currency, effective_from,
       LEAST(term_end, COALESCE(DATEADD(day, -1, next_from), term_end)) AS effective_to,
       precedence_rank, evidence_quote,
       '{{RUN_ID}}' AS run_id, '{{EXPERIMENT_ID}}' AS experiment_id
FROM ranked;

ALTER SESSION UNSET QUERY_TAG;

-- =====================================================================
-- Verification. Show these at the gate.
-- =====================================================================

-- V1. Header term status per term. FAILED and UNVERIFIED must be explained.
SELECT term_name,
       COUNT_IF(status = 'EXTRACTED') AS extracted, COUNT_IF(status = 'NOT_STATED') AS not_stated,
       COUNT_IF(status = 'FAILED') AS failed, COUNT_IF(status = 'UNVERIFIED') AS unverified
FROM CONTRACT_HEADER_TERMS WHERE experiment_id = '{{EXPERIMENT_ID}}'
GROUP BY 1 ORDER BY 1;
-- Sandbox: 7 families x 12 terms = 84 rows; FAILED and UNVERIFIED zero.

-- V2. Rate lines by source and status.
SELECT source_kind, status, COUNT(*) FROM CONTRACT_RATE_LINES
WHERE experiment_id = '{{EXPERIMENT_ID}}' GROUP BY 1, 2 ORDER BY 1, 2;
-- Sandbox: GLOVE-NIT rate-card row is SUPERSEDED_BY_TIERS; JAN-DEEP
-- amendment entry is NO_PRICE_CHANGE.

-- V3. Effective rates. Compare to the sandbox's 14 expected rows by eye
--     here; Phase 5 scores them.
SELECT contract_family_id, sku, unit_of_measure, tier_min_qty, tier_upper_exclusive,
       unit_price, currency, effective_from, effective_to, source_document_id
FROM CONTRACT_EFFECTIVE_RATES ORDER BY 1, 2, 4, 8;

-- V4. Overlapping windows (must be zero, rule 4).
SELECT a.rate_line_id, b.rate_line_id
FROM CONTRACT_EFFECTIVE_RATES a JOIN CONTRACT_EFFECTIVE_RATES b
  ON a.contract_family_id = b.contract_family_id AND a.sku = b.sku
 AND a.tier_min_qty IS NOT DISTINCT FROM b.tier_min_qty
 AND a.rate_line_id < b.rate_line_id
 AND a.effective_from <= b.effective_to AND b.effective_from <= a.effective_to;

-- V5. Families with no term period (must be zero for commercial families).
SELECT r.contract_family_id FROM CONTRACT_REGISTRY r
WHERE r.family_role = 'GOVERNING'
  AND NOT EXISTS (SELECT 1 FROM CONTRACT_TERM_PERIODS p WHERE p.contract_family_id = r.contract_family_id);

-- V6. Term periods, with the current period and deadline.
SELECT contract_family_id, period_no, period_kind, period_start, period_end,
       auto_renewal, notice_days, notice_deadline, is_current_period
FROM CONTRACT_TERM_PERIODS ORDER BY 1, 2;
-- Sandbox: SYN-OF-3001 has period 1, 2025-11-01..2026-10-31, current,
-- deadline 2026-08-02. SYN-MSA-1001 and SYN-TEL-7001 current period 0,
-- deadline 2026-11-01.

-- V7. Clause interpretation failures.
SELECT document_id, response_status FROM CONTRACT_CLAUSE_RULES
WHERE experiment_id = '{{EXPERIMENT_ID}}' AND response_status <> 'OK';
