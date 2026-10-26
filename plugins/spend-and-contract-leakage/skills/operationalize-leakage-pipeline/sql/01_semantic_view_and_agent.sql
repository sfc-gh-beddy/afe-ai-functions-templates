-- =====================================================================
-- Phase 6a. Serving layer: current-run views, semantic view, Cortex Agent.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}} {{SCHEMA}} {{WAREHOUSE}}
--   {{PROD_EXPERIMENT_ID}}   the experiment whose findings are served
--                            (an evaluated one, never an untested prompt)
--   {{AGENT_NAME}}           e.g. SPEND_LEAKAGE_AGENT
--
-- Nothing here reads the eval schema. The semantic view exposes findings,
-- term periods and spend coverage; it never exposes full contract text
-- (rule 24).
-- =====================================================================

USE DATABASE {{DB}};
USE SCHEMA {{SCHEMA}};

-- Latest run of the served experiment. A view, so the agent always reads
-- the newest completed run without anyone repointing it.
CREATE OR REPLACE VIEW V_CURRENT_RUN AS
SELECT run_id, as_of_date
FROM LEAKAGE_FINDINGS
WHERE experiment_id = '{{PROD_EXPERIMENT_ID}}'
QUALIFY ROW_NUMBER() OVER (ORDER BY created_at DESC) = 1;

CREATE OR REPLACE VIEW V_LEAKAGE_FINDINGS_CURRENT AS
SELECT f.finding_id, f.finding_type, f.impact_kind, f.impact_amount, f.impact_currency,
       f.vendor_id, v.vendor_name, f.contract_family_id, f.invoice_line_id, f.invoice_id,
       f.invoice_date, f.service_period_start, f.lever, f.pricing_basis,
       f.billed_unit_price, f.allowed_unit_price, f.quantity,
       f.term_period_end, f.notice_deadline, f.days_to_deadline,
       f.within_audit_window, f.review_status, f.arithmetic,
       -- Evidence flattened to the cited clauses only, for display.
       ARRAY_TO_STRING(TRANSFORM(f.evidence,
           e -> COALESCE(e:document_id::VARCHAR, 'registry') || COALESCE(' p' || e:page_index::VARCHAR, '')
                || COALESCE(' s' || e:clause_ref::VARCHAR, '') || ': "' || COALESCE(e:quote::VARCHAR, '') || '"'), ' | ') AS evidence_text,
       f.as_of_date, f.run_id
FROM LEAKAGE_FINDINGS f
JOIN V_CURRENT_RUN r ON r.run_id = f.run_id
LEFT JOIN STG_VENDORS v ON v.vendor_id = f.vendor_id;

CREATE OR REPLACE VIEW V_SPEND_COVERAGE_CURRENT AS
SELECT m.invoice_line_id, m.vendor_id, m.contract_family_id, m.invoice_date, m.service_period_start,
       m.currency, m.line_amount, m.capex_flag, m.coverage_status, m.price_check_status, m.sku_match_method
FROM INVOICE_CONTRACT_MATCH m
JOIN V_CURRENT_RUN r ON r.run_id = m.run_id;

CREATE OR REPLACE VIEW V_RENEWAL_CALENDAR AS
SELECT p.contract_family_id, reg.vendor_id, p.period_no, p.period_kind, p.period_start, p.period_end,
       p.auto_renewal, p.renewal_months, p.notice_days, p.notice_deadline, p.notice_convention,
       DATEDIFF(day, r.as_of_date, p.notice_deadline) AS days_to_deadline, r.as_of_date
FROM CONTRACT_TERM_PERIODS p
JOIN CONTRACT_REGISTRY reg ON reg.contract_family_id = p.contract_family_id AND reg.family_role = 'GOVERNING'
CROSS JOIN V_CURRENT_RUN r
WHERE p.is_current_period
  AND p.experiment_id = '{{PROD_EXPERIMENT_ID}}';

-- ---------------------------------------------------------------------
-- Semantic view. Metrics are per impact kind; there is deliberately no
-- metric that sums all findings (rule 13), and the generation instruction
-- requires grouping by currency (rule 12).
-- ---------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW SPEND_LEAKAGE_SV
  TABLES (
    findings AS V_LEAKAGE_FINDINGS_CURRENT
      PRIMARY KEY (finding_id)
      WITH SYNONYMS ('leakage', 'overcharges', 'contract compliance findings')
      COMMENT = 'One row per leakage finding in the latest evaluated run. Each finding has one impact kind and one currency.',
    vendors AS STG_VENDORS
      PRIMARY KEY (vendor_id)
      WITH SYNONYMS ('suppliers')
      COMMENT = 'ERP vendor master.',
    coverage AS V_SPEND_COVERAGE_CURRENT
      PRIMARY KEY (invoice_line_id)
      COMMENT = 'Every invoice line in the latest run with its contract coverage and whether its price could be checked.',
    renewals AS V_RENEWAL_CALENDAR
      PRIMARY KEY (contract_family_id)
      WITH SYNONYMS ('renewal calendar', 'notice deadlines')
      COMMENT = 'Current term of every contract family with its renewal and notice deadline as of the run date.'
  )
  RELATIONSHIPS (
    findings_to_vendors AS findings (vendor_id) REFERENCES vendors,
    coverage_to_vendors AS coverage (vendor_id) REFERENCES vendors,
    renewals_to_vendors AS renewals (vendor_id) REFERENCES vendors
  )
  FACTS (
    findings.impact AS findings.impact_amount,
    coverage.spend AS coverage.line_amount
  )
  DIMENSIONS (
    findings.finding_type AS finding_type
      WITH SYNONYMS ('leakage type')
      COMMENT = 'RATE_VARIANCE, MISSED_VOLUME_DISCOUNT, UPLIFT_OVER_CAP, OFF_CONTRACT, EXPIRED_CONTRACT_SPEND, AUTO_RENEWAL_NOTICE_MISSED, AUTO_RENEWAL_NOTICE_UPCOMING',
    findings.impact_kind AS impact_kind
      COMMENT = 'RECOVERABLE_OVERCHARGE, SPEND_UNDER_MANAGEMENT or COMMITMENT_EXPOSURE. Never add amounts across kinds.',
    findings.impact_currency AS impact_currency
      COMMENT = 'ISO currency of the impact amount. Never add amounts across currencies.',
    findings.lever AS lever COMMENT = 'OPEX or CAPEX, from the invoice line CapEx flag.',
    findings.review_status AS review_status,
    findings.contract_family_id AS contract_family_id WITH SYNONYMS ('contract', 'agreement number'),
    findings.service_month AS DATE_TRUNC('month', findings.service_period_start),
    findings.within_audit_window AS within_audit_window
      COMMENT = 'TRUE when the invoice falls inside the contract audit look-back window; NULL when the contract states none.',
    findings.arithmetic AS arithmetic COMMENT = 'How the impact amount was computed.',
    findings.evidence_text AS evidence_text COMMENT = 'Cited contract clauses supporting the finding.',
    vendors.vendor_name AS vendor_name WITH SYNONYMS ('supplier name'),
    coverage.coverage_status AS coverage_status
      COMMENT = 'IN_TERM, NO_CONTRACT, EXPIRED, PRE_TERM, AMBIGUOUS_FAMILY, TERMS_UNAVAILABLE',
    coverage.price_check_status AS price_check_status,
    coverage.currency AS spend_currency,
    renewals.notice_deadline AS notice_deadline,
    renewals.period_end AS term_end,
    renewals.auto_renewal AS auto_renewal
  )
  METRICS (
    findings.recoverable_overcharge AS SUM(IFF(findings.impact_kind = 'RECOVERABLE_OVERCHARGE', findings.impact_amount, 0))
      WITH SYNONYMS ('overcharge', 'recoverable', 'overbilling')
      COMMENT = 'Money billed above contract. Report per currency.',
    findings.spend_under_management AS SUM(IFF(findings.impact_kind = 'SPEND_UNDER_MANAGEMENT', findings.impact_amount, 0))
      WITH SYNONYMS ('off-contract spend', 'maverick spend', 'unmanaged spend')
      COMMENT = 'Spend with no valid contract. Not an overcharge. Report per currency.',
    findings.commitment_exposure AS SUM(IFF(findings.impact_kind = 'COMMITMENT_EXPOSURE', findings.impact_amount, 0))
      WITH SYNONYMS ('renewal exposure', 'auto-renewal exposure')
      COMMENT = 'Trailing spend under contracts whose renewal notice deadline is missed or near. Not money lost.',
    findings.finding_count AS COUNT(findings.finding_id),
    coverage.total_spend AS SUM(coverage.line_amount),
    coverage.price_checked_spend AS SUM(IFF(coverage.price_check_status = 'READY', coverage.line_amount, 0))
      COMMENT = 'Spend whose price was compared to a contract rate.'
  )
  COMMENT = 'Spend and contract leakage: findings with cited clause evidence, spend coverage, and the renewal calendar.'
  AI_SQL_GENERATION 'Always group monetary metrics by impact_currency (or spend_currency for coverage). Never add recoverable_overcharge, spend_under_management and commitment_exposure together; report them as separate figures. When reporting a finding total, also report price_checked_spend over total_spend in the same currency so the reader knows how much spend was checked. Include arithmetic and evidence_text when listing individual findings.';

-- ---------------------------------------------------------------------
-- Cortex Agent over the semantic view.
-- ---------------------------------------------------------------------
CREATE OR REPLACE AGENT {{AGENT_NAME}}
  COMMENT = 'Answers questions about supplier contract leakage, spend coverage and renewal deadlines with cited clause evidence.'
  PROFILE = '{"display_name": "Spend and Contract Leakage"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    budget:
      seconds: 60
      tokens: 16000

  instructions:
    response: >
      Answer from the leakage tool only. State every monetary figure with its currency and its
      impact kind, and never add amounts of different currencies or different impact kinds.
      Recoverable overcharge is money billed above contract; spend under management is spend with
      no valid contract and is not an overcharge; commitment exposure is the size of a renewal at
      risk and is not money lost. When you give a total, also give how much of the spend was
      price-checked. When you discuss a specific finding, show its arithmetic and quote its cited
      clause exactly as provided; do not quote more contract text than the cited clause, and do not
      paraphrase a clause as if quoting it. If a question asks whether a supplier owes money, say the
      finding is a reading of the contract for procurement and legal to confirm. Do not speculate
      about contracts or suppliers that are not in the data.
    orchestration: >
      Use the leakage tool for every question about findings, overcharges, off-contract or expired
      spend, volume discounts, renewal caps, renewal or notice deadlines, and spend coverage.
    sample_questions:
      - question: "What is the recoverable overcharge by supplier, per currency?"
      - question: "Which contracts auto-renew in the next 90 days and what is the exposure?"
      - question: "How much of our spend was checked against a contract price?"
      - question: "Show the evidence for the largest rate variance."

  tools:
    - tool_spec:
        type: "cortex_analyst_text_to_sql"
        name: "leakage"
        description: "Leakage findings with impact kind, currency, arithmetic and cited clause evidence; spend coverage by invoice line; and the current renewal calendar."

  tool_resources:
    leakage:
      semantic_view: "{{DB}}.{{SCHEMA}}.SPEND_LEAKAGE_SV"
      execution_environment:
        type: "warehouse"
        warehouse: "{{WAREHOUSE}}"
  $$;

-- =====================================================================
-- Verification.
-- =====================================================================

-- V1. The semantic view returns the same totals as the findings table.
SELECT * FROM SEMANTIC_VIEW(
    SPEND_LEAKAGE_SV
    DIMENSIONS findings.impact_currency
    METRICS findings.recoverable_overcharge, findings.spend_under_management, findings.commitment_exposure
) ORDER BY impact_currency;

SELECT impact_currency,
       SUM(IFF(impact_kind = 'RECOVERABLE_OVERCHARGE', impact_amount, 0)) AS recoverable_overcharge,
       SUM(IFF(impact_kind = 'SPEND_UNDER_MANAGEMENT', impact_amount, 0)) AS spend_under_management,
       SUM(IFF(impact_kind = 'COMMITMENT_EXPOSURE',    impact_amount, 0)) AS commitment_exposure
FROM V_LEAKAGE_FINDINGS_CURRENT GROUP BY 1 ORDER BY 1;
-- The two results must be identical. Sandbox: USD 40,900.00 / 133,400.00 / 403,950.00;
-- EUR 1,500.00 / 0 / 0.

-- V2. The renewal calendar view has one current period per family.
SELECT contract_family_id, COUNT(*) FROM V_RENEWAL_CALENDAR GROUP BY 1 HAVING COUNT(*) > 1;
-- Expect zero rows.
