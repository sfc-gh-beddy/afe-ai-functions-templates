-- =====================================================================
-- Phase 4. Reconcile invoice lines to contract terms. Pure SQL apart from
-- AI_SIMILARITY, used only to choose a rate line for SKU-less invoice
-- lines that deterministic matching could not resolve (rules 1, 11).
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}} {{SCHEMA}} {{RUN_ID}} {{EXPERIMENT_ID}} {{PROMPT_VERSION}} {{QUERY_TAG_PREFIX}}
--   {{PROMPT_HASH}}        the extract phase's hash for this experiment
--   {{PARAM_HASH}}         sha256 of this file after substitution
--   {{AS_OF_DATE}}         reconcile.as_of_date            (sandbox 2026-09-30)
--   {{PRICE_TOL_ABS}}      reconcile.price_tolerance_abs   (default 0.05)
--   {{PRICE_TOL_REL_PCT}}  reconcile.price_tolerance_rel_pct (default 0.5)
--   {{HORIZON_DAYS}}       reconcile.renewal_horizon_days  (default 90)
--   {{EXPOSURE_MONTHS}}    reconcile.exposure_window_months (default 12)
--   {{SKU_SIM_MIN}}        reconcile.sku_similarity_min    (default 0.80)
--   {{SKU_SIM_MARGIN}}     reconcile.sku_similarity_margin (default 0.03)
--
-- Reads:  STG_INVOICE_LINES, STG_PURCHASE_ORDERS, CONTRACT_REGISTRY,
--         CONTRACT_HEADER_TERMS, CONTRACT_CLAUSE_RULES, CONTRACT_TERM_PERIODS,
--         CONTRACT_EFFECTIVE_RATES
-- Writes: INVOICE_CONTRACT_MATCH, INVOICE_ALLOWED_PRICE (rebuilt),
--         LEAKAGE_FINDINGS, RECONCILE_EXCEPTIONS (accumulate by run_id)
--
-- CURRENT_DATE() appears nowhere in business logic (rule 14).
-- The escalator convention implemented here is ALLOWED_PRICE (rule 15).
-- =====================================================================

USE DATABASE {{DB}};
USE SCHEMA {{SCHEMA}};
ALTER SESSION SET QUERY_TAG = '{{QUERY_TAG_PREFIX}}:reconcile:{{RUN_ID}}';

-- ---------------------------------------------------------------------
-- 0. Family terms, one row per family, with the evidence each term carries.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _R_FAMILY AS
WITH t AS (
    SELECT * FROM CONTRACT_HEADER_TERMS WHERE experiment_id = '{{EXPERIMENT_ID}}'
),
piv AS (
    SELECT contract_family_id,
           MAX(IFF(term_name = 'agreement_effective_date' AND status = 'EXTRACTED', normalized_value, NULL))::DATE AS eff_date,
           MAX(IFF(term_name = 'annual_escalator_cap_pct' AND status = 'EXTRACTED', normalized_value, NULL))::NUMBER(9,4) AS escalator_pct,
           MAX(IFF(term_name = 'renewal_uplift_cap_pct'   AND status = 'EXTRACTED', normalized_value, NULL))::NUMBER(9,4) AS uplift_cap_pct,
           MAX(IFF(term_name = 'audit_window_months'      AND status = 'EXTRACTED', normalized_value, NULL))::INT         AS audit_window_months,
           MAX(IFF(term_name = 'contract_currency'        AND status = 'EXTRACTED', normalized_value, NULL))              AS contract_currency,
           MAX(IFF(term_name = 'annual_escalator_cap_pct', status, NULL)) AS escalator_status,
           MAX(IFF(term_name = 'renewal_uplift_cap_pct',   status, NULL)) AS uplift_cap_status,
           OBJECT_AGG(term_name, OBJECT_CONSTRUCT(
               'term', term_name, 'value', normalized_value, 'status', status,
               'document_id', document_id, 'page_index', page_index,
               'clause_ref', clause_ref, 'quote', evidence_quote)::VARIANT) AS term_evidence
    FROM t GROUP BY 1
),
rules AS (
    SELECT c.contract_family_id,
           c.response:tier_application::VARCHAR         AS tier_application,
           c.response:tier_application_quote::VARCHAR   AS tier_application_quote,
           c.response:tier_accumulation_period::VARCHAR AS tier_accumulation_period,
           c.response:escalator_basis::VARCHAR          AS escalator_basis,
           c.response:escalator_quote::VARCHAR          AS escalator_quote
    FROM CONTRACT_CLAUSE_RULES c
    WHERE c.experiment_id = '{{EXPERIMENT_ID}}' AND c.family_role = 'GOVERNING' AND c.response_status = 'OK'
)
SELECT g.contract_family_id, g.vendor_id, g.agreement_number, g.document_id AS governing_document_id,
       p.eff_date, p.escalator_pct, p.uplift_cap_pct, p.audit_window_months, p.contract_currency,
       p.escalator_status, p.uplift_cap_status, p.term_evidence,
       r.tier_application, r.tier_application_quote, r.tier_accumulation_period,
       r.escalator_basis, r.escalator_quote
FROM CONTRACT_REGISTRY g
LEFT JOIN piv   p ON p.contract_family_id = g.contract_family_id
LEFT JOIN rules r ON r.contract_family_id = g.contract_family_id
WHERE g.family_role = 'GOVERNING' AND g.vendor_id IS NOT NULL;

-- ---------------------------------------------------------------------
-- 1. Coverage: exactly one status per invoice line (rule 8).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _R_LINES AS
SELECT il.*, po.contract_reference,
       UPPER(REGEXP_REPLACE(COALESCE(po.contract_reference, ''), '\\s+', '')) AS po_ref_norm
FROM STG_INVOICE_LINES il
LEFT JOIN STG_PURCHASE_ORDERS po ON po.po_id = il.po_id
WHERE il.service_period_start <= '{{AS_OF_DATE}}'::DATE;

CREATE OR REPLACE TEMPORARY TABLE _R_COVER AS
WITH cand AS (
    SELECT l.invoice_line_id, f.contract_family_id, f.agreement_number,
           p.period_no, p.period_kind, p.period_start, p.period_end,
           (l.service_period_start BETWEEN p.period_start AND p.period_end) AS covers,
           CONTAINS(l.po_ref_norm, UPPER(REGEXP_REPLACE(f.agreement_number, '\\s+', ''))) AS po_ref_hit
    FROM _R_LINES l
    JOIN _R_FAMILY f ON f.vendor_id = l.vendor_id
    LEFT JOIN CONTRACT_TERM_PERIODS p ON p.contract_family_id = f.contract_family_id
),
per_line AS (
    SELECT l.invoice_line_id, l.service_period_start,
           COUNT(DISTINCT c.contract_family_id)                                   AS n_families,
           COUNT(DISTINCT IFF(c.covers, c.contract_family_id, NULL))              AS n_covering,
           COUNT(DISTINCT IFF(c.covers AND c.po_ref_hit, c.contract_family_id, NULL)) AS n_covering_po,
           COUNT_IF(c.period_no IS NOT NULL)                                      AS n_periods,
           MIN(c.period_start) AS first_start, MAX(c.period_end) AS last_end
    FROM _R_LINES l
    LEFT JOIN cand c ON c.invoice_line_id = l.invoice_line_id
    GROUP BY 1, 2
),
chosen AS (
    -- The covering family: the only one, or the only one the PO references.
    SELECT c.invoice_line_id, c.contract_family_id, c.period_no, c.period_kind, c.period_start, c.period_end,
           IFF(pl.n_covering = 1, 'SINGLE_ACTIVE_FAMILY', 'PO_REFERENCE') AS family_match_method
    FROM cand c JOIN per_line pl ON pl.invoice_line_id = c.invoice_line_id
    WHERE c.covers AND (pl.n_covering = 1 OR (pl.n_covering > 1 AND pl.n_covering_po = 1 AND c.po_ref_hit))
),
lapsed AS (
    -- For lines no period covers: the family whose coverage ended most
    -- recently before the service date.
    SELECT c.invoice_line_id, c.contract_family_id, MAX(c.period_end) AS family_end
    FROM cand c JOIN _R_LINES l ON l.invoice_line_id = c.invoice_line_id
    WHERE c.period_end < l.service_period_start
    GROUP BY 1, 2
    QUALIFY ROW_NUMBER() OVER (PARTITION BY c.invoice_line_id ORDER BY MAX(c.period_end) DESC) = 1
)
SELECT pl.invoice_line_id,
       CASE
         WHEN pl.n_families = 0                    THEN 'NO_CONTRACT'
         WHEN pl.n_periods = 0                     THEN 'TERMS_UNAVAILABLE'
         WHEN ch.contract_family_id IS NOT NULL    THEN 'IN_TERM'
         WHEN pl.n_covering > 1                    THEN 'AMBIGUOUS_FAMILY'
         WHEN pl.service_period_start < pl.first_start THEN 'PRE_TERM'
         ELSE 'EXPIRED'
       END AS coverage_status,
       COALESCE(ch.contract_family_id, la.contract_family_id) AS contract_family_id,
       ch.family_match_method, ch.period_no, ch.period_kind, ch.period_start, ch.period_end,
       la.family_end AS lapsed_family_end
FROM per_line pl
LEFT JOIN chosen ch ON ch.invoice_line_id = pl.invoice_line_id
LEFT JOIN lapsed la ON la.invoice_line_id = pl.invoice_line_id;

-- ---------------------------------------------------------------------
-- 2. SKU resolution for IN_TERM lines: exact SKU, then the longest rate
--    description whose words all occur in the line description, then
--    AI_SIMILARITY above a threshold with a margin (rule 11). Matching is
--    always within the chosen family's rates.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _R_FAMILY_SKUS AS
SELECT DISTINCT contract_family_id, sku, description, unit_of_measure, currency,
       SPLIT(TRIM(REGEXP_REPLACE(UPPER(COALESCE(description, '')), '[^A-Z0-9]+', ' ')), ' ') AS desc_tokens
FROM CONTRACT_EFFECTIVE_RATES
QUALIFY ROW_NUMBER() OVER (PARTITION BY contract_family_id, sku ORDER BY effective_from) = 1;

CREATE OR REPLACE TEMPORARY TABLE _R_SKU AS
WITH inl AS (
    SELECT l.invoice_line_id, c.contract_family_id, l.sku, l.line_description,
           SPLIT(TRIM(REGEXP_REPLACE(UPPER(COALESCE(l.line_description, '')), '[^A-Z0-9]+', ' ')), ' ') AS line_tokens
    FROM _R_LINES l JOIN _R_COVER c ON c.invoice_line_id = l.invoice_line_id
    WHERE c.coverage_status = 'IN_TERM'
),
exact AS (
    SELECT i.invoice_line_id, s.sku
    FROM inl i JOIN _R_FAMILY_SKUS s
      ON s.contract_family_id = i.contract_family_id AND UPPER(s.sku) = UPPER(i.sku)
),
contained AS (
    SELECT i.invoice_line_id, s.sku, ARRAY_SIZE(s.desc_tokens) AS n_tokens,
           RANK() OVER (PARTITION BY i.invoice_line_id ORDER BY ARRAY_SIZE(s.desc_tokens) DESC) AS rk,
           COUNT(*) OVER (PARTITION BY i.invoice_line_id, ARRAY_SIZE(s.desc_tokens)) AS ties
    FROM inl i JOIN _R_FAMILY_SKUS s ON s.contract_family_id = i.contract_family_id
    WHERE i.sku IS NULL
      AND ARRAY_SIZE(s.desc_tokens) > 0 AND s.desc_tokens[0]::VARCHAR <> ''
      AND ARRAY_SIZE(ARRAY_EXCEPT(s.desc_tokens, i.line_tokens)) = 0
),
contained_best AS (
    SELECT invoice_line_id, sku FROM contained WHERE rk = 1 AND ties = 1
),
sim_candidates AS (
    SELECT i.invoice_line_id, s.sku,
           AI_SIMILARITY(i.line_description, s.description) AS sim
    FROM inl i JOIN _R_FAMILY_SKUS s ON s.contract_family_id = i.contract_family_id
    WHERE i.sku IS NULL AND i.line_description IS NOT NULL AND s.description IS NOT NULL
      AND i.invoice_line_id NOT IN (SELECT invoice_line_id FROM contained_best)
),
sim_ranked AS (
    SELECT invoice_line_id, sku, sim,
           ROW_NUMBER() OVER (PARTITION BY invoice_line_id ORDER BY sim DESC) AS rn,
           LEAD(sim) OVER (PARTITION BY invoice_line_id ORDER BY sim DESC) AS next_sim
    FROM sim_candidates
)
SELECT i.invoice_line_id,
       COALESCE(e.sku, cb.sku, IFF(sr.sim >= {{SKU_SIM_MIN}} AND sr.sim - COALESCE(sr.next_sim, 0) >= {{SKU_SIM_MARGIN}}, sr.sku, NULL)) AS resolved_sku,
       CASE WHEN e.sku IS NOT NULL THEN 'EXACT_SKU'
            WHEN cb.sku IS NOT NULL THEN 'DESCRIPTION_CONTAINED'
            WHEN sr.sim >= {{SKU_SIM_MIN}} AND sr.sim - COALESCE(sr.next_sim, 0) >= {{SKU_SIM_MARGIN}} THEN 'DESCRIPTION_SIMILARITY'
            WHEN sr.sim >= {{SKU_SIM_MIN}} THEN 'AMBIGUOUS_SKU'
            ELSE 'NO_SKU_MATCH' END AS sku_match_method,
       sr.sim AS sku_similarity, sr.next_sim AS sku_similarity_runner_up
FROM inl i
LEFT JOIN exact e           ON e.invoice_line_id = i.invoice_line_id
LEFT JOIN contained_best cb ON cb.invoice_line_id = i.invoice_line_id
LEFT JOIN sim_ranked sr     ON sr.invoice_line_id = i.invoice_line_id AND sr.rn = 1;

CREATE OR REPLACE TABLE INVOICE_CONTRACT_MATCH AS
SELECT l.invoice_line_id, l.invoice_id, l.vendor_id, l.po_id, l.invoice_date,
       l.service_period_start, l.sku AS invoice_sku, l.line_description,
       l.quantity, l.unit_of_measure, l.unit_price, l.currency, l.line_amount,
       l.gl_account, l.capex_flag,
       c.coverage_status, c.contract_family_id, c.family_match_method,
       c.period_no, c.period_kind, c.period_start, c.period_end, c.lapsed_family_end,
       s.resolved_sku, s.sku_match_method, s.sku_similarity, s.sku_similarity_runner_up,
       fs.unit_of_measure AS rate_unit_of_measure, fs.currency AS rate_currency,
       CASE
         WHEN c.coverage_status <> 'IN_TERM'                    THEN 'NOT_APPLICABLE'
         WHEN s.resolved_sku IS NULL                            THEN COALESCE(s.sku_match_method, 'NO_SKU_MATCH')
         WHEN fs.currency IS DISTINCT FROM l.currency           THEN 'CURRENCY_MISMATCH'
         WHEN fs.unit_of_measure IS DISTINCT FROM l.unit_of_measure THEN 'UOM_MISMATCH'
         ELSE 'READY'
       END AS price_check_status,
       '{{RUN_ID}}' AS run_id, '{{EXPERIMENT_ID}}' AS experiment_id
FROM _R_LINES l
JOIN _R_COVER c ON c.invoice_line_id = l.invoice_line_id
LEFT JOIN _R_SKU s ON s.invoice_line_id = l.invoice_line_id
LEFT JOIN _R_FAMILY_SKUS fs ON fs.contract_family_id = c.contract_family_id AND fs.sku = s.resolved_sku;

-- ---------------------------------------------------------------------
-- 3. Allowed price per READY line.
--    TIERED       cumulative, incremental tiers (rule 7)
--    FIXED        stated rate for the service date
--    ESCALATED    stated rate x (1 + escalator)^anniversaries (rule 15)
--    RENEWAL_CAP  preceding term's rate x (1 + cap)^renewals (rule 15)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE INVOICE_ALLOWED_PRICE AS
WITH ready AS (
    SELECT m.*, f.eff_date, f.escalator_pct, f.uplift_cap_pct, f.tier_application,
           f.tier_accumulation_period, f.escalator_basis
    FROM INVOICE_CONTRACT_MATCH m
    JOIN _R_FAMILY f ON f.contract_family_id = m.contract_family_id
    WHERE m.price_check_status = 'READY'
),
tiered_skus AS (
    SELECT DISTINCT contract_family_id, sku FROM CONTRACT_EFFECTIVE_RATES WHERE tier_min_qty IS NOT NULL
),
-- 3a. Tiered lines: cumulative quantity within the accumulation period.
tiered AS (
    SELECT r.*,
           CASE r.tier_accumulation_period
             WHEN 'CALENDAR_YEAR' THEN YEAR(r.service_period_start)
             ELSE FLOOR(MONTHS_BETWEEN(r.service_period_start, r.eff_date) / 12)   -- CONTRACT_YEAR
           END AS accumulation_bucket,
           SUM(r.quantity) OVER (
               PARTITION BY r.contract_family_id, r.resolved_sku,
                            CASE r.tier_accumulation_period WHEN 'CALENDAR_YEAR' THEN YEAR(r.service_period_start)
                                 ELSE FLOOR(MONTHS_BETWEEN(r.service_period_start, r.eff_date) / 12) END
               ORDER BY r.service_period_start, r.invoice_line_id
               ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cum_qty_after
    FROM ready r
    JOIN tiered_skus t ON t.contract_family_id = r.contract_family_id AND t.sku = r.resolved_sku
    WHERE r.tier_application = 'INCREMENTAL'
      AND r.tier_accumulation_period IN ('CONTRACT_YEAR', 'CALENDAR_YEAR')
),
tiered_priced AS (
    SELECT t.invoice_line_id,
           t.cum_qty_after - t.quantity AS cum_qty_before, t.cum_qty_after,
           SUM(GREATEST(0, LEAST(t.cum_qty_after, COALESCE(e.tier_upper_exclusive, 999999999999999))
                          - GREATEST(t.cum_qty_after - t.quantity, e.tier_min_qty)) * e.unit_price) AS allowed_amount,
           ARRAY_AGG(OBJECT_CONSTRUCT('tier_min', e.tier_min_qty, 'tier_upper_exclusive', e.tier_upper_exclusive,
                                      'tier_price', e.unit_price,
                                      'units', GREATEST(0, LEAST(t.cum_qty_after, COALESCE(e.tier_upper_exclusive, 999999999999999))
                                                          - GREATEST(t.cum_qty_after - t.quantity, e.tier_min_qty)),
                                      'source_document_id', e.source_document_id, 'quote', e.evidence_quote))
               WITHIN GROUP (ORDER BY e.tier_min_qty) AS tier_breakdown
    FROM tiered t
    JOIN CONTRACT_EFFECTIVE_RATES e
      ON e.contract_family_id = t.contract_family_id AND e.sku = t.resolved_sku
     AND e.tier_min_qty IS NOT NULL
     AND t.service_period_start BETWEEN e.effective_from AND e.effective_to
    GROUP BY 1, 2, 3
),
-- 3b. Fixed-rate lines: the stated rate covering the service date.
fixed_rate AS (
    SELECT r.invoice_line_id, e.unit_price AS stated_price, e.effective_from, e.source_document_id,
           e.evidence_quote, e.rate_line_id
    FROM ready r
    JOIN CONTRACT_EFFECTIVE_RATES e
      ON e.contract_family_id = r.contract_family_id AND e.sku = r.resolved_sku
     AND e.tier_min_qty IS NULL
     AND r.service_period_start BETWEEN e.effective_from AND e.effective_to
),
-- 3c. Renewal-term lines with no stated rate: the last stated rate, capped.
last_rate AS (
    SELECT contract_family_id, sku, unit_price, effective_to, source_document_id, evidence_quote, rate_line_id
    FROM CONTRACT_EFFECTIVE_RATES
    WHERE tier_min_qty IS NULL
    QUALIFY ROW_NUMBER() OVER (PARTITION BY contract_family_id, sku ORDER BY effective_to DESC) = 1
)
SELECT r.invoice_line_id, r.contract_family_id, r.resolved_sku, r.service_period_start,
       r.quantity, r.unit_price AS billed_unit_price, r.line_amount, r.currency,
       CASE
         WHEN tp.invoice_line_id IS NOT NULL                                        THEN 'TIERED'
         WHEN fr.invoice_line_id IS NOT NULL AND r.escalator_pct > 0
              AND FLOOR(MONTHS_BETWEEN(r.service_period_start, r.eff_date) / 12)
                - FLOOR(MONTHS_BETWEEN(fr.effective_from, r.eff_date) / 12) > 0     THEN 'ESCALATED'
         WHEN fr.invoice_line_id IS NOT NULL                                        THEN 'FIXED'
         WHEN r.period_kind = 'RENEWAL' AND lr.sku IS NOT NULL AND r.uplift_cap_pct IS NOT NULL THEN 'RENEWAL_CAP'
         WHEN r.period_kind = 'RENEWAL' AND lr.sku IS NOT NULL                      THEN 'UNPRICED_RENEWAL'
         WHEN ts.sku IS NOT NULL                                                    THEN 'TIER_RULE_NOT_APPLIED'
         ELSE 'NO_RATE_FOR_DATE'
       END AS pricing_basis,
       tp.cum_qty_before, tp.cum_qty_after, tp.tier_breakdown,
       -- Allowed unit price (blended for tiered lines).
       CASE
         WHEN tp.invoice_line_id IS NOT NULL THEN ROUND(tp.allowed_amount / NULLIF(r.quantity, 0), 6)
         WHEN fr.invoice_line_id IS NOT NULL AND r.escalator_pct > 0 THEN
              ROUND(fr.stated_price * POWER(1 + r.escalator_pct / 100,
                    GREATEST(0, FLOOR(MONTHS_BETWEEN(r.service_period_start, r.eff_date) / 12)
                              - FLOOR(MONTHS_BETWEEN(fr.effective_from, r.eff_date) / 12))), 2)
         WHEN fr.invoice_line_id IS NOT NULL THEN fr.stated_price
         WHEN r.period_kind = 'RENEWAL' AND lr.sku IS NOT NULL AND r.uplift_cap_pct IS NOT NULL THEN
              ROUND(lr.unit_price * POWER(1 + r.uplift_cap_pct / 100, r.period_no), 2)
       END AS allowed_unit_price,
       CASE
         WHEN tp.invoice_line_id IS NOT NULL THEN ROUND(tp.allowed_amount, 2)
       END AS allowed_amount_tiered,
       COALESCE(fr.stated_price, lr.unit_price) AS stated_unit_price,
       COALESCE(fr.source_document_id, lr.source_document_id) AS rate_source_document_id,
       COALESCE(fr.evidence_quote, lr.evidence_quote)         AS rate_evidence_quote,
       r.escalator_pct, r.uplift_cap_pct, r.period_no, r.period_kind,
       '{{RUN_ID}}' AS run_id, '{{EXPERIMENT_ID}}' AS experiment_id
FROM ready r
LEFT JOIN tiered_priced tp ON tp.invoice_line_id = r.invoice_line_id
LEFT JOIN fixed_rate fr    ON fr.invoice_line_id = r.invoice_line_id AND tp.invoice_line_id IS NULL
LEFT JOIN last_rate lr     ON lr.contract_family_id = r.contract_family_id AND lr.sku = r.resolved_sku
                          AND fr.invoice_line_id IS NULL AND tp.invoice_line_id IS NULL
LEFT JOIN tiered_skus ts   ON ts.contract_family_id = r.contract_family_id AND ts.sku = r.resolved_sku;

-- ---------------------------------------------------------------------
-- 4. Findings. Line-grain price and coverage findings, then contract-grain
--    renewal findings. One finding per line per type (rule 9); review
--    decisions on the same finding_id carry forward from earlier runs.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS LEAKAGE_FINDINGS (
    run_id VARCHAR, experiment_id VARCHAR, prompt_version VARCHAR, prompt_hash VARCHAR, param_hash VARCHAR,
    as_of_date DATE,
    finding_id VARCHAR, finding_type VARCHAR, impact_kind VARCHAR,
    impact_amount NUMBER(18,2), impact_currency VARCHAR,
    vendor_id VARCHAR, contract_family_id VARCHAR,
    invoice_line_id VARCHAR, invoice_id VARCHAR, invoice_date DATE, service_period_start DATE,
    line_amount NUMBER(18,2), quantity NUMBER(18,4),
    billed_unit_price NUMBER(18,4), allowed_unit_price NUMBER(18,6),
    pricing_basis VARCHAR, tolerance_per_unit NUMBER(18,6),
    capex_flag BOOLEAN, lever VARCHAR,
    term_period_end DATE, notice_deadline DATE, days_to_deadline INT, notice_convention VARCHAR,
    audit_window_months INT, within_audit_window BOOLEAN,
    arithmetic VARCHAR, evidence VARIANT, evidence_term_statuses ARRAY,
    review_status VARCHAR, reviewed_by VARCHAR, reviewed_at TIMESTAMP_NTZ,
    created_at TIMESTAMP_NTZ
);

DELETE FROM LEAKAGE_FINDINGS WHERE run_id = '{{RUN_ID}}';

INSERT INTO LEAKAGE_FINDINGS
WITH price AS (
    SELECT a.*, m.vendor_id, m.invoice_id, m.invoice_date, m.capex_flag,
           f.audit_window_months, f.term_evidence, f.tier_application_quote, f.escalator_quote,
           LEAST({{PRICE_TOL_ABS}}, {{PRICE_TOL_REL_PCT}} / 100 * a.allowed_unit_price) AS tol,
           CASE a.pricing_basis
             WHEN 'TIERED' THEN ROUND(a.quantity * a.billed_unit_price - a.allowed_amount_tiered, 2)
             ELSE ROUND(a.quantity * (a.billed_unit_price - a.allowed_unit_price), 2)
           END AS overcharge
    FROM INVOICE_ALLOWED_PRICE a
    JOIN INVOICE_CONTRACT_MATCH m ON m.invoice_line_id = a.invoice_line_id
    JOIN _R_FAMILY f ON f.contract_family_id = a.contract_family_id
    WHERE a.pricing_basis IN ('TIERED', 'FIXED', 'ESCALATED', 'RENEWAL_CAP')
),
price_findings AS (
    SELECT
        CASE pricing_basis WHEN 'TIERED' THEN 'MISSED_VOLUME_DISCOUNT'
                           WHEN 'RENEWAL_CAP' THEN 'UPLIFT_OVER_CAP'
                           ELSE 'RATE_VARIANCE' END AS finding_type,
        'RECOVERABLE_OVERCHARGE' AS impact_kind,
        LEAST(overcharge, line_amount) AS impact_amount, currency AS impact_currency,
        vendor_id, contract_family_id, invoice_line_id, invoice_id, invoice_date, service_period_start,
        line_amount, quantity, billed_unit_price, allowed_unit_price, pricing_basis, tol,
        capex_flag, NULL::DATE AS term_period_end, NULL::DATE AS notice_deadline, NULL::INT AS days_to_deadline,
        NULL AS notice_convention, audit_window_months,
        CASE
          WHEN pricing_basis = 'TIERED' THEN
            'Billed ' || quantity || ' x ' || billed_unit_price || ' = ' || ROUND(quantity * billed_unit_price, 2)
            || '; allowed under incremental tiers (cumulative ' || cum_qty_before || ' to ' || cum_qty_after || ') = '
            || allowed_amount_tiered || '; difference ' || overcharge || ' ' || currency
          WHEN pricing_basis = 'ESCALATED' THEN
            'Billed ' || billed_unit_price || ' vs ceiling ' || allowed_unit_price || ' (stated ' || stated_unit_price
            || ' escalated at up to ' || escalator_pct || '% per anniversary); ' || quantity || ' x '
            || (billed_unit_price - allowed_unit_price) || ' = ' || overcharge || ' ' || currency
          WHEN pricing_basis = 'RENEWAL_CAP' THEN
            'Billed ' || billed_unit_price || ' in renewal term ' || period_no || ' vs cap ' || allowed_unit_price
            || ' (' || stated_unit_price || ' x (1 + ' || uplift_cap_pct || '%)^' || period_no || '); '
            || quantity || ' x ' || (billed_unit_price - allowed_unit_price) || ' = ' || overcharge || ' ' || currency
          ELSE
            'Billed ' || billed_unit_price || ' vs contracted ' || allowed_unit_price || '; '
            || quantity || ' x ' || (billed_unit_price - allowed_unit_price) || ' = ' || overcharge || ' ' || currency
        END AS arithmetic,
        ARRAY_CONSTRUCT_COMPACT(
            OBJECT_CONSTRUCT('term', 'rate', 'document_id', rate_source_document_id, 'quote', rate_evidence_quote, 'status', 'EXTRACTED'),
            IFF(pricing_basis = 'TIERED', OBJECT_CONSTRUCT('term', 'tier_application', 'quote', tier_application_quote, 'status', 'EXTRACTED', 'tiers', tier_breakdown), NULL),
            IFF(pricing_basis = 'ESCALATED', term_evidence:annual_escalator_cap_pct, NULL),
            IFF(pricing_basis = 'RENEWAL_CAP', term_evidence:renewal_uplift_cap_pct, NULL),
            IFF(pricing_basis = 'RENEWAL_CAP', term_evidence:auto_renewal, NULL)
        ) AS evidence
    FROM price
    WHERE (pricing_basis = 'TIERED'
           AND (quantity * billed_unit_price - allowed_amount_tiered) / NULLIF(quantity, 0)
               > LEAST({{PRICE_TOL_ABS}}, {{PRICE_TOL_REL_PCT}} / 100 * allowed_amount_tiered / NULLIF(quantity, 0)))
       OR (pricing_basis <> 'TIERED' AND billed_unit_price - allowed_unit_price > tol)
),
coverage_findings AS (
    SELECT IFF(m.coverage_status = 'NO_CONTRACT', 'OFF_CONTRACT', 'EXPIRED_CONTRACT_SPEND') AS finding_type,
           'SPEND_UNDER_MANAGEMENT' AS impact_kind,
           m.line_amount AS impact_amount, m.currency AS impact_currency,
           m.vendor_id, m.contract_family_id, m.invoice_line_id, m.invoice_id, m.invoice_date, m.service_period_start,
           m.line_amount, m.quantity, m.unit_price, NULL::NUMBER(18,6), NULL AS pricing_basis, NULL::NUMBER(18,6) AS tol,
           m.capex_flag, m.lapsed_family_end, NULL::DATE, NULL::INT, NULL, NULL::INT,
           IFF(m.coverage_status = 'NO_CONTRACT',
               'No commercial contract is registered for vendor ' || m.vendor_id || '; full line amount is unmanaged spend',
               'Service date ' || m.service_period_start || ' is after the last term period of ' || m.contract_family_id
               || ', which ended ' || m.lapsed_family_end || ' with no renewal; full line amount is unmanaged spend') AS arithmetic,
           IFF(m.coverage_status = 'NO_CONTRACT',
               ARRAY_CONSTRUCT(OBJECT_CONSTRUCT('term', 'contract_registry', 'status', 'EXTRACTED',
                   'quote', 'No GOVERNING document linked to vendor ' || m.vendor_id || ' in CONTRACT_REGISTRY')),
               ARRAY_CONSTRUCT_COMPACT(f.term_evidence:initial_term_end_date, f.term_evidence:auto_renewal)) AS evidence
    FROM INVOICE_CONTRACT_MATCH m
    LEFT JOIN _R_FAMILY f ON f.contract_family_id = m.contract_family_id
    WHERE m.coverage_status IN ('NO_CONTRACT', 'EXPIRED')
),
exposure AS (
    SELECT contract_family_id, SUM(line_amount) AS t12m_spend
    FROM INVOICE_CONTRACT_MATCH
    WHERE coverage_status = 'IN_TERM'
      AND service_period_start >  DATEADD(month, -{{EXPOSURE_MONTHS}}, '{{AS_OF_DATE}}'::DATE)
      AND service_period_start <= '{{AS_OF_DATE}}'::DATE
    GROUP BY 1
),
renewal_findings AS (
    SELECT IFF(p.notice_deadline < '{{AS_OF_DATE}}'::DATE, 'AUTO_RENEWAL_NOTICE_MISSED', 'AUTO_RENEWAL_NOTICE_UPCOMING') AS finding_type,
           'COMMITMENT_EXPOSURE' AS impact_kind,
           COALESCE(x.t12m_spend, 0) AS impact_amount, p.contract_currency AS impact_currency,
           f.vendor_id, p.contract_family_id, NULL AS invoice_line_id, NULL AS invoice_id, NULL::DATE, NULL::DATE,
           NULL::NUMBER(18,2), NULL::NUMBER(18,4), NULL::NUMBER(18,4), NULL::NUMBER(18,6), NULL, NULL::NUMBER(18,6),
           NULL::BOOLEAN, p.period_end, p.notice_deadline,
           DATEDIFF(day, '{{AS_OF_DATE}}'::DATE, p.notice_deadline), p.notice_convention, f.audit_window_months,
           'Current term ' || p.period_start || ' to ' || p.period_end || ' (period ' || p.period_no || ', ' || p.period_kind
           || ') auto-renews for ' || p.renewal_months || ' months unless notice is given ' || p.notice_days
           || ' days before the end: deadline ' || p.notice_deadline || ', '
           || ABS(DATEDIFF(day, '{{AS_OF_DATE}}'::DATE, p.notice_deadline)) || ' days '
           || IFF(p.notice_deadline < '{{AS_OF_DATE}}'::DATE, 'ago', 'from now') || ' as of {{AS_OF_DATE}}. Exposure is trailing '
           || {{EXPOSURE_MONTHS}} || '-month spend of ' || COALESCE(x.t12m_spend, 0) || ' ' || p.contract_currency AS arithmetic,
           ARRAY_CONSTRUCT_COMPACT(f.term_evidence:auto_renewal, f.term_evidence:renewal_term_months,
                                   f.term_evidence:non_renewal_notice_days, f.term_evidence:initial_term_end_date) AS evidence
    FROM CONTRACT_TERM_PERIODS p
    JOIN _R_FAMILY f ON f.contract_family_id = p.contract_family_id
    LEFT JOIN exposure x ON x.contract_family_id = p.contract_family_id
    WHERE p.is_current_period
      AND p.auto_renewal = 'TRUE'
      AND p.notice_deadline IS NOT NULL
      AND (p.notice_deadline < '{{AS_OF_DATE}}'::DATE
           OR p.notice_deadline <= DATEADD(day, {{HORIZON_DAYS}}, '{{AS_OF_DATE}}'::DATE))
),
all_findings AS (
    SELECT * FROM price_findings
    UNION ALL SELECT * FROM coverage_findings
    UNION ALL SELECT * FROM renewal_findings
),
prior_review AS (
    SELECT finding_id, review_status, reviewed_by, reviewed_at
    FROM LEAKAGE_FINDINGS
    WHERE review_status <> 'NEW'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY finding_id ORDER BY reviewed_at DESC NULLS LAST) = 1
),
final AS (
    SELECT a.*,
           SHA2(a.finding_type || '|' || COALESCE(a.contract_family_id, '-') || '|'
                || COALESCE(a.invoice_line_id, TO_VARCHAR(a.term_period_end), '-')) AS finding_id,
           ARRAY_DISTINCT(TRANSFORM(a.evidence, e -> e:status)) AS evidence_term_statuses
    FROM all_findings a
)
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{PROMPT_VERSION}}', '{{PROMPT_HASH}}', '{{PARAM_HASH}}',
       '{{AS_OF_DATE}}'::DATE,
       f.finding_id, f.finding_type, f.impact_kind, f.impact_amount, f.impact_currency,
       f.vendor_id, f.contract_family_id, f.invoice_line_id, f.invoice_id, f.invoice_date, f.service_period_start,
       f.line_amount, f.quantity, f.billed_unit_price, f.allowed_unit_price, f.pricing_basis, f.tol,
       f.capex_flag, IFF(f.capex_flag, 'CAPEX', 'OPEX'),
       f.term_period_end, f.notice_deadline, f.days_to_deadline, f.notice_convention,
       f.audit_window_months,
       IFF(f.audit_window_months IS NULL OR f.invoice_date IS NULL, NULL,
           f.invoice_date >= DATEADD(month, -f.audit_window_months, '{{AS_OF_DATE}}'::DATE)),
       f.arithmetic, f.evidence, f.evidence_term_statuses,
       COALESCE(pr.review_status, 'NEW'), pr.reviewed_by, pr.reviewed_at,
       CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM final f
LEFT JOIN prior_review pr ON pr.finding_id = f.finding_id
-- Rule 2: a finding resting on any term that is not EXTRACTED or NOT_STATED
-- is not emitted; the line goes to exceptions instead.
WHERE NOT ARRAY_CONTAINS('UNVERIFIED'::VARIANT, f.evidence_term_statuses)
  AND NOT ARRAY_CONTAINS('FAILED'::VARIANT, f.evidence_term_statuses);

-- ---------------------------------------------------------------------
-- 5. Exceptions: everything reconciliation refused to decide.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS RECONCILE_EXCEPTIONS (
    run_id VARCHAR, experiment_id VARCHAR, as_of_date DATE,
    exception_type VARCHAR, vendor_id VARCHAR, contract_family_id VARCHAR,
    invoice_line_id VARCHAR, amount NUMBER(18,2), currency VARCHAR, detail VARCHAR,
    created_at TIMESTAMP_NTZ
);

DELETE FROM RECONCILE_EXCEPTIONS WHERE run_id = '{{RUN_ID}}';

INSERT INTO RECONCILE_EXCEPTIONS
SELECT '{{RUN_ID}}', '{{EXPERIMENT_ID}}', '{{AS_OF_DATE}}'::DATE, x.exception_type, x.vendor_id,
       x.contract_family_id, x.invoice_line_id, x.amount, x.currency, x.detail, CURRENT_TIMESTAMP()::TIMESTAMP_NTZ
FROM (
    SELECT m.coverage_status AS exception_type, m.vendor_id, m.contract_family_id, m.invoice_line_id,
           m.line_amount AS amount, m.currency,
           'Coverage could not be decided: ' || m.coverage_status AS detail
    FROM INVOICE_CONTRACT_MATCH m
    WHERE m.coverage_status IN ('AMBIGUOUS_FAMILY', 'PRE_TERM', 'TERMS_UNAVAILABLE')
    UNION ALL
    SELECT m.price_check_status, m.vendor_id, m.contract_family_id, m.invoice_line_id, m.line_amount, m.currency,
           'Price not compared: ' || m.price_check_status
           || COALESCE(' (invoice ' || m.currency || ' / ' || m.unit_of_measure || ' vs rate '
                       || m.rate_currency || ' / ' || m.rate_unit_of_measure || ')', '')
           || COALESCE(' best similarity ' || ROUND(m.sku_similarity, 3) || ', runner-up ' || ROUND(m.sku_similarity_runner_up, 3), '')
    FROM INVOICE_CONTRACT_MATCH m
    WHERE m.coverage_status = 'IN_TERM' AND m.price_check_status <> 'READY'
    UNION ALL
    SELECT a.pricing_basis, m.vendor_id, a.contract_family_id, a.invoice_line_id, a.line_amount, a.currency,
           CASE a.pricing_basis
             WHEN 'UNPRICED_RENEWAL'      THEN 'Renewal-term price with no stated rate and no renewal cap; increase is not leakage by itself'
             WHEN 'TIER_RULE_NOT_APPLIED' THEN 'Tiered item but the tier clause is not INCREMENTAL with a CONTRACT_YEAR or CALENDAR_YEAR accumulation; not priced'
             ELSE 'No stated rate covers the service date' END
    FROM INVOICE_ALLOWED_PRICE a
    JOIN INVOICE_CONTRACT_MATCH m ON m.invoice_line_id = a.invoice_line_id
    WHERE a.pricing_basis IN ('UNPRICED_RENEWAL', 'TIER_RULE_NOT_APPLIED', 'NO_RATE_FOR_DATE')
    UNION ALL
    -- Line-grain overcharge capped at the line amount is a unit or currency
    -- error, not leakage (rule 6). Report it.
    SELECT 'OVERCHARGE_EXCEEDS_LINE', vendor_id, contract_family_id, invoice_line_id, line_amount, impact_currency,
           'Computed overcharge exceeded the line amount and was capped; check unit of measure: ' || arithmetic
    FROM LEAKAGE_FINDINGS
    WHERE run_id = '{{RUN_ID}}' AND impact_kind = 'RECOVERABLE_OVERCHARGE' AND impact_amount >= line_amount
    UNION ALL
    -- Auto-renewing families with no notice period: no deadline can be computed.
    SELECT 'NOTICE_PERIOD_NOT_STATED', f.vendor_id, p.contract_family_id, NULL, NULL, p.contract_currency,
           'Auto-renewing contract with no extractable non-renewal notice period'
    FROM CONTRACT_TERM_PERIODS p JOIN _R_FAMILY f ON f.contract_family_id = p.contract_family_id
    WHERE p.is_current_period AND p.auto_renewal = 'TRUE' AND p.notice_days IS NULL
) x;

ALTER SESSION UNSET QUERY_TAG;

-- =====================================================================
-- Verification. Show these at the gate.
-- =====================================================================

-- V1. Spend coverage, per currency. Quote this next to any finding total.
SELECT currency, coverage_status, price_check_status,
       COUNT(*) AS lines, SUM(line_amount) AS amount,
       ROUND(100 * RATIO_TO_REPORT(SUM(line_amount)) OVER (PARTITION BY currency), 1) AS pct_of_currency_spend
FROM INVOICE_CONTRACT_MATCH GROUP BY 1, 2, 3 ORDER BY 1, 5 DESC;

-- V2. Findings by type, kind and currency. Never add rows together.
SELECT finding_type, impact_kind, impact_currency, lever, COUNT(*) AS findings, SUM(impact_amount) AS total
FROM LEAKAGE_FINDINGS WHERE run_id = '{{RUN_ID}}'
GROUP BY 1, 2, 3, 4 ORDER BY 2, 3, 1;
-- Sandbox expectation:
--   RATE_VARIANCE            RECOVERABLE_OVERCHARGE USD OPEX  12   16,800.00
--   RATE_VARIANCE            RECOVERABLE_OVERCHARGE USD CAPEX  1    7,500.00
--   MISSED_VOLUME_DISCOUNT   RECOVERABLE_OVERCHARGE USD OPEX   7    7,800.00
--   UPLIFT_OVER_CAP          RECOVERABLE_OVERCHARGE USD OPEX  11    8,800.00
--   RATE_VARIANCE            RECOVERABLE_OVERCHARGE EUR OPEX   1    1,500.00
--   OFF_CONTRACT             SPEND_UNDER_MANAGEMENT USD OPEX   6   71,000.00
--   EXPIRED_CONTRACT_SPEND   SPEND_UNDER_MANAGEMENT USD OPEX   6   62,400.00
--   AUTO_RENEWAL_NOTICE_MISSED   COMMITMENT_EXPOSURE USD       1  109,200.00
--   AUTO_RENEWAL_NOTICE_UPCOMING COMMITMENT_EXPOSURE USD       2  294,750.00

-- V3. Findings without evidence, or resting on unusable terms. Must be zero.
SELECT finding_id FROM LEAKAGE_FINDINGS
WHERE run_id = '{{RUN_ID}}'
  AND (evidence IS NULL OR ARRAY_SIZE(evidence) = 0
       OR ARRAY_CONTAINS('UNVERIFIED'::VARIANT, evidence_term_statuses));

-- V4. One finding per line per type (rule 9). Must be zero.
SELECT invoice_line_id, COUNT(*) FROM LEAKAGE_FINDINGS
WHERE run_id = '{{RUN_ID}}' AND invoice_line_id IS NOT NULL
GROUP BY 1 HAVING COUNT(*) > 1;

-- V5. Exceptions by type. Each is spend the pipeline refused to judge.
SELECT exception_type, currency, COUNT(*) AS n, SUM(amount) AS amount
FROM RECONCILE_EXCEPTIONS WHERE run_id = '{{RUN_ID}}'
GROUP BY 1, 2 ORDER BY 4 DESC NULLS LAST;
-- Sandbox: zero rows.

-- V6. The tier crossing, line by line.
SELECT invoice_line_id, quantity, cum_qty_before, cum_qty_after, billed_unit_price,
       allowed_amount_tiered, ROUND(quantity * billed_unit_price - allowed_amount_tiered, 2) AS overcharge
FROM INVOICE_ALLOWED_PRICE WHERE pricing_basis = 'TIERED' ORDER BY service_period_start;
-- Sandbox: 2026-03 cumulative 80,000 -> 120,000, overcharge 600.00;
-- 2026-01 and 2026-02 overcharge 0.00.
