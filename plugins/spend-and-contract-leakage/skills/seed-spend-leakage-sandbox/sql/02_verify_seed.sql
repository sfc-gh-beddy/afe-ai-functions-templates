-- =====================================================================
-- Verification for the spend-leakage sandbox. Run after
-- 01_seed_sandbox.sql with the same substitutions. Every query states
-- the expected result; any deviation is a seed bug, and a seed bug will
-- read later as a pipeline accuracy failure.
-- =====================================================================

USE DATABASE {{DB}};

-- 1. Row counts per object.
SELECT 'SYNTH_VENDORS' AS obj, COUNT(*) AS n FROM {{SCHEMA}}.SYNTH_VENDORS             -- expect 8
UNION ALL SELECT 'SYNTH_CONTRACT_DOCUMENTS', COUNT(*) FROM {{SCHEMA}}.SYNTH_CONTRACT_DOCUMENTS   -- expect 10
UNION ALL SELECT 'SYNTH_PURCHASE_ORDERS',    COUNT(*) FROM {{SCHEMA}}.SYNTH_PURCHASE_ORDERS      -- expect 7
UNION ALL SELECT 'SYNTH_INVOICE_LINES',      COUNT(*) FROM {{SCHEMA}}.SYNTH_INVOICE_LINES        -- expect 120
UNION ALL SELECT 'SYNTH_TERM_KEY',           COUNT(*) FROM {{EVAL_SCHEMA}}.SYNTH_TERM_KEY        -- expect 77
UNION ALL SELECT 'SYNTH_RATE_KEY',           COUNT(*) FROM {{EVAL_SCHEMA}}.SYNTH_RATE_KEY        -- expect 14
UNION ALL SELECT 'SYNTH_LEAKAGE_KEY',        COUNT(*) FROM {{EVAL_SCHEMA}}.SYNTH_LEAKAGE_KEY;    -- expect 70
-- Invoice lines: V001 42 + V002 9 + V003 23 + V004 1 + V005 6 + V006 12 + V007 21 + V008 6 = 120.
-- Leakage key: 47 planted + 23 distractors = 70.

-- 2. Planted totals match the literal expectations. Any row returned is
--    a generator error in the key.
WITH actual AS (
    SELECT impact_kind, impact_currency,
           SUM(expected_impact_amount) AS total, COUNT(*) AS n
    FROM {{EVAL_SCHEMA}}.SYNTH_LEAKAGE_KEY
    WHERE case_role = 'PLANTED'
    GROUP BY 1, 2
)
SELECT e.impact_kind, e.impact_currency, e.expected_total, a.total, e.expected_count, a.n
FROM {{EVAL_SCHEMA}}.SYNTH_EXPECTED_TOTALS e
FULL OUTER JOIN actual a
  ON a.impact_kind = e.impact_kind AND a.impact_currency = e.impact_currency
WHERE a.total IS DISTINCT FROM e.expected_total
   OR a.n     IS DISTINCT FROM e.expected_count;
-- Expect zero rows.

-- 3. Every line-grain key row resolves to a real invoice line. A key row
--    pointing at a nonexistent line produces a phantom false negative.
SELECT k.finding_key
FROM {{EVAL_SCHEMA}}.SYNTH_LEAKAGE_KEY k
LEFT JOIN {{SCHEMA}}.SYNTH_INVOICE_LINES il ON il.invoice_line_id = k.invoice_line_id
WHERE k.invoice_line_id IS NOT NULL AND il.invoice_line_id IS NULL;
-- Expect zero rows.

-- 4. Recompute recoverable overcharge directly from invoices and the
--    rate key, independently of the generator branches. This is the
--    arithmetic the pipeline must reproduce, done the simple way.
WITH rv AS (
    SELECT il.invoice_line_id,
           il.quantity * (il.unit_price - rk.unit_price) AS overcharge
    FROM {{SCHEMA}}.SYNTH_INVOICE_LINES il
    JOIN {{EVAL_SCHEMA}}.SYNTH_RATE_KEY rk
      ON rk.sku = il.sku
     AND il.service_period_start BETWEEN rk.effective_from AND rk.effective_to
     AND rk.tier_min_qty IS NULL
    WHERE il.unit_price - rk.unit_price > 0.05      -- the 0.05 tolerance used by the reconcile skill
)
SELECT ROUND(SUM(overcharge), 2) AS fixed_rate_overcharge_usd
FROM rv;
-- Expect 25,650.00 = Northwind 16,800 + Litware 7,500 + 1,350.
-- The 1,350 is Wide World 2026 (9 x 150) and is NOT leakage: it is the
-- permitted 3% escalator. This naive query is deliberately the wrong
-- one, and shows exactly the false positive the escalator distractor
-- exists to catch. The answer key's correct figure for fixed-rate
-- variance is 24,300.00.
-- (Fabrikam is an uplift-cap finding, not a rate-card finding, because
--  the rate key only covers the initial term; Proseware has no SKU on
--  the invoice; Contoso is tiered.)

-- 5. The tier crossing happens in March, at the quantity the key assumes.
SELECT TO_CHAR(service_period_start, 'YYYY-MM') AS period,
       quantity,
       SUM(quantity) OVER (ORDER BY service_period_start) AS cumulative_units
FROM {{SCHEMA}}.SYNTH_INVOICE_LINES
WHERE vendor_id = 'SYN-V002'
ORDER BY 1;
-- Expect cumulative 120,000 at 2026-03 and 360,000 at 2026-09.

-- 6. Trailing-12-month exposure per renewal family, as of 2026-09-30.
SELECT il.vendor_id, SUM(il.line_amount) AS t12m_spend
FROM {{SCHEMA}}.SYNTH_INVOICE_LINES il
WHERE il.service_period_start >  DATEADD(month, -12, '2026-09-30'::DATE)
  AND il.service_period_start <= '2026-09-30'::DATE
  AND il.vendor_id IN ('SYN-V001','SYN-V003','SYN-V007')
GROUP BY 1 ORDER BY 1;
-- Expect V001 233,400.00, V003 109,200.00, V007 61,350.00.

-- 7. The duplicate really is a duplicate, and nothing else is.
SELECT MD5(document_text) AS h, ARRAY_AGG(document_id) AS docs
FROM {{SCHEMA}}.SYNTH_CONTRACT_DOCUMENTS
GROUP BY 1 HAVING COUNT(*) > 1;
-- Expect exactly one row: SYN-DOC-C001 and SYN-DOC-C001-DUP.

-- 8. The answer key is not reachable from the sandbox schema.
SELECT table_name
FROM {{DB}}.information_schema.tables
WHERE table_schema = '{{SCHEMA}}'
  AND (table_name ILIKE '%KEY%' OR table_name ILIKE '%EXPECTED%');
-- Expect zero rows.

-- 9. Vendor name on invoices differs from ERP master for exactly V003
--    and V008, so the linking traps are actually present.
SELECT DISTINCT il.vendor_id, il.vendor_name_on_invoice, v.vendor_name
FROM {{SCHEMA}}.SYNTH_INVOICE_LINES il
JOIN {{SCHEMA}}.SYNTH_VENDORS v ON v.vendor_id = il.vendor_id
WHERE il.vendor_name_on_invoice <> v.vendor_name;
-- Expect two rows (SYN-V003, SYN-V008).
