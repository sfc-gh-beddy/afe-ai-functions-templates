-- =====================================================================
-- Synthetic B2B customer base with planted churn signals, usage, ARR,
-- renewal outcomes, and a quarantined answer key -- for churn-signals
-- pipeline development, reason-classification accuracy, and churn-model
-- evaluation (AUC / lift) with a deliberate label-leakage trap.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}            target database
--   {{SCHEMA}}        sandbox schema (plays the role of the customer's data)
--   {{EVAL_SCHEMA}}   separate schema for the answer key (quarantine)
--   {{N_ACCOUNTS}}    number of accounts, e.g. 600
--   {{ANCHOR_DATE}}   "today" for the sandbox, e.g. 2026-06-30
--   {{HORIZON_DAYS}}  prediction horizon in days, e.g. 90
--
-- DETERMINISM: every random choice is a hash of (account_id, salt), not
-- RANDOM(), so the same parameters regenerate the same corpus and two
-- experiments run on "the sandbox" are run on the same data.
--
-- All identifiers are prefixed SYN- and every account name ends in
-- "(Synthetic)". All companies, competitors, people and products are
-- fabricated.
--
-- WHAT IS LEGITIMATE vs QUARANTINED
--   {{SCHEMA}}.SYN_RENEWAL_OUTCOMES   legitimate training labels: every
--       customer has renewal history in CRM/billing. The model trains on it.
--   {{EVAL_SCHEMA}}.*                 the answer key for text extraction
--       and latent cohorts. Nothing in the pipeline may read it; only the
--       accuracy harness does.
--
-- PLANTED LEAKAGE TRAPS (the harness checks the pipeline avoided them)
--   1. SYN_ACCOUNTS.CRM_STATUS / CRM_CANCEL_REASON reflect the outcome.
--   2. Non-renewal notices, offboarding tickets and exit surveys are dated
--      AFTER the prediction cutoff (renewal_date - HORIZON_DAYS). They are
--      valid input for churn-REASON analytics and invalid as MODEL features.
--   3. Usage drops to zero after a churned renewal date.
-- =====================================================================

USE DATABASE {{DB}};
CREATE SCHEMA IF NOT EXISTS {{SCHEMA}};
CREATE SCHEMA IF NOT EXISTS {{EVAL_SCHEMA}};
USE SCHEMA {{DB}}.{{SCHEMA}};

-- ---------------------------------------------------------------------
-- 0. Reason taxonomy. Configuration, not ground truth: the extraction
--    prompt is built from it and the harness normalises both sides
--    through it. Labels follow AI_CLASSIFY guidance: plain English, no
--    abbreviations, mutually exclusive, with distinguishing descriptions.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYN_REASON_TAXONOMY (
    reason_code  VARCHAR,
    label        VARCHAR,
    description  VARCHAR,
    sort_order   INT
);

INSERT INTO SYN_REASON_TAXONOMY VALUES
 ('PRICE_VALUE',     'price or value concerns',
  'Customer says the product costs too much, questions return on investment, or pushes back on a price increase.', 1),
 ('PRODUCT_GAP',     'missing product capability',
  'Customer needs a feature or integration the product does not have and says it blocks their use case.', 2),
 ('RELIABILITY',     'reliability or performance problems',
  'Outages, errors, data sync failures, or slowness that disrupt the customer''s work.', 3),
 ('SUPPORT',         'poor support experience',
  'Slow, unhelpful or repeated support interactions; customer feels ignored or escalates about support itself.', 4),
 ('ADOPTION',        'low adoption or onboarding difficulty',
  'Users are not using the product, onboarding stalled, or the team finds it too hard to use.', 5),
 ('COMPETITOR',      'evaluating a competitor',
  'Customer is actively evaluating, piloting or moving to another vendor. Not a past evaluation they decided against.', 6),
 ('BUSINESS_CHANGE', 'budget cuts or business change',
  'Budget cuts, layoffs, acquisition, reorganisation or a change in company strategy that removes the need or funding.', 7),
 ('CHAMPION_LOSS',   'loss of internal champion',
  'The internal sponsor or main administrator has left or changed role and nobody has taken ownership.', 8),
 ('NONE',            'no retention risk',
  'Routine request, neutral question, praise, or a concern that was resolved with no indication the customer may leave.', 99);

-- ---------------------------------------------------------------------
-- 1. Latent account truth. Built first so every downstream table is
--    consistent with it. Lands in the EVAL schema: the pipeline must not
--    see cohort or reason.
--
--    Cohorts:
--      VOCAL      churner that left text evidence before the cutoff
--      SILENT     churner with no pre-cutoff text signal (usage only) --
--                 text cannot help here, and the harness says so
--      SAVED      retained account that showed real risk signals
--      DISTRACTOR retained account whose text looks risky but is not
--      HEALTHY    retained account, routine traffic only
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYN_ACCOUNT_TRUTH AS
WITH g AS (
    SELECT SEQ4() AS n FROM TABLE(GENERATOR(ROWCOUNT => {{N_ACCOUNTS}}))
),
a AS (
    SELECT 'SYN-ACCT-' || LPAD(n::STRING, 5, '0') AS account_id FROM g
),
h AS (
    SELECT account_id,
           ABS(HASH(account_id, 'seg'))   % 100  AS h_seg,
           ABS(HASH(account_id, 'churn')) % 1000 AS h_churn,
           ABS(HASH(account_id, 'coh'))   % 100  AS h_coh,
           ABS(HASH(account_id, 'r1'))    % 10   AS h_r1,
           ABS(HASH(account_id, 'r2'))    % 8    AS h_r2,
           ABS(HASH(account_id, 'r2p'))   % 100  AS h_r2p,
           ABS(HASH(account_id, 'dec'))   % 100  AS h_dec,
           ABS(HASH(account_id, 'ren'))   % 540  AS h_ren
    FROM a
),
s AS (
    SELECT h.*,
           CASE WHEN h_seg < 50 THEN 'SMB' WHEN h_seg < 85 THEN 'MID_MARKET' ELSE 'ENTERPRISE' END AS segment,
           DATEADD(day, 180 - h_ren, '{{ANCHOR_DATE}}'::DATE) AS renewal_date
    FROM h
),
c AS (
    SELECT s.*,
           -- churn propensity differs by segment (generator parameter, not a benchmark)
           h_churn < CASE segment WHEN 'SMB' THEN 230 WHEN 'MID_MARKET' THEN 160 ELSE 100 END AS is_churner
    FROM s
)
SELECT
    account_id,
    segment,
    renewal_date,
    renewal_date <= '{{ANCHOR_DATE}}'::DATE                    AS outcome_observed,
    is_churner,
    CASE
        WHEN is_churner AND h_coh < 15 THEN 'SILENT'
        WHEN is_churner                THEN 'VOCAL'
        WHEN h_coh < 12                THEN 'SAVED'
        WHEN h_coh < 24                THEN 'DISTRACTOR'
        ELSE                                'HEALTHY'
    END                                                         AS cohort,
    -- PRICE_VALUE and PRODUCT_GAP weighted double so per-reason support is uneven (a generator choice, not a benchmark)
    ARRAY_CONSTRUCT('PRICE_VALUE','PRICE_VALUE','PRODUCT_GAP','PRODUCT_GAP',
                    'RELIABILITY','SUPPORT','ADOPTION','COMPETITOR',
                    'BUSINESS_CHANGE','CHAMPION_LOSS')[h_r1]::STRING AS primary_reason,
    CASE WHEN h_r2p < 35 THEN
        ARRAY_CONSTRUCT('PRICE_VALUE','PRODUCT_GAP','RELIABILITY','SUPPORT',
                        'ADOPTION','COMPETITOR','BUSINESS_CHANGE','CHAMPION_LOSS')[h_r2]::STRING
    END                                                         AS secondary_reason_raw,
    CASE
        WHEN is_churner     THEN h_dec < 70
        WHEN h_coh < 12     THEN h_dec < 40
        ELSE                     h_dec < 10
    END                                                         AS usage_decline
FROM c;

-- A secondary reason equal to the primary is no secondary reason.
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYN_ACCOUNT_TRUTH AS
SELECT account_id, segment, renewal_date, outcome_observed, is_churner, cohort,
       primary_reason,
       IFF(secondary_reason_raw = primary_reason, NULL, secondary_reason_raw) AS secondary_reason,
       usage_decline,
       DATEADD(day, -{{HORIZON_DAYS}}, renewal_date)  AS prediction_cutoff
FROM {{EVAL_SCHEMA}}.SYN_ACCOUNT_TRUTH;

-- ---------------------------------------------------------------------
-- 2. Accounts -- what CRM would hold. CRM_STATUS and CRM_CANCEL_REASON
--    are leakage trap 1: they are written after the outcome. Half the
--    cancel reasons are 'Other' (a generator choice mimicking an unreliable picklist),
--    and the reason text-derived reasons are worth having.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYN_ACCOUNTS AS
SELECT
    t.account_id,
    ARRAY_CONSTRUCT('Alderbrook','Brightwater','Cobalt Ridge','Driftwood','Emberline',
                    'Foxglove','Granite Peak','Harbor Lane','Ironleaf','Juniper Hill',
                    'Kestrel','Lumen Field','Maple Forge','Northgate','Oakmont',
                    'Pinecrest','Quillstone','Redwood Bay','Silverbirch','Tidewater')
        [ABS(HASH(t.account_id, 'n1')) % 20]::STRING || ' ' ||
    ARRAY_CONSTRUCT('Logistics','Health','Foods','Labs','Partners',
                    'Retail','Energy','Financial','Media','Manufacturing')
        [ABS(HASH(t.account_id, 'n2')) % 10]::STRING || ' (Synthetic)'      AS account_name,
    t.segment,
    ARRAY_CONSTRUCT('Retail','Healthcare','Financial Services','Manufacturing',
                    'Software','Logistics','Media','Public Sector')
        [ABS(HASH(t.account_id, 'ind')) % 8]::STRING                           AS industry,
    ARRAY_CONSTRUCT('NA','EMEA','APAC','LATAM')
        [ABS(HASH(t.account_id, 'reg')) % 4]::STRING                           AS region,
    ROUND(CASE t.segment
            WHEN 'SMB'        THEN 5000   + ABS(HASH(t.account_id, 'arr')) % 35000
            WHEN 'MID_MARKET' THEN 40000  + ABS(HASH(t.account_id, 'arr')) % 210000
            ELSE                   250000 + ABS(HASH(t.account_id, 'arr')) % 1250000
          END, -2)::NUMBER(12,2)                                               AS arr_usd,
    CASE t.segment
        WHEN 'SMB'        THEN 10  + ABS(HASH(t.account_id, 'seat')) % 40
        WHEN 'MID_MARKET' THEN 50  + ABS(HASH(t.account_id, 'seat')) % 250
        ELSE                   300 + ABS(HASH(t.account_id, 'seat')) % 2700
    END                                                                       AS seats_purchased,
    DATEADD(year, -1 - ABS(HASH(t.account_id, 'tenure')) % 3, t.renewal_date) AS contract_start_date,
    t.renewal_date,
    ARRAY_CONSTRUCT('R. Ashcombe','T. Bellweather','M. Carrow','J. Delacroix','P. Everly','S. Fenwick')
        [ABS(HASH(t.account_id, 'csm')) % 6]::STRING                           AS csm_name,
    -- LEAKAGE TRAP 1. Current status, written after the outcome.
    IFF(t.is_churner AND t.outcome_observed, 'CHURNED', 'ACTIVE')             AS crm_status,
    IFF(t.is_churner AND t.outcome_observed,
        IFF(ABS(HASH(t.account_id, 'pick')) % 100 < 50, 'Other', INITCAP(REPLACE(t.primary_reason, '_', ' '))),
        NULL)                                                                 AS crm_cancel_reason,
    '{{ANCHOR_DATE}}'::TIMESTAMP_NTZ                                          AS crm_last_modified_at
FROM {{EVAL_SCHEMA}}.SYN_ACCOUNT_TRUTH t;

-- ---------------------------------------------------------------------
-- 3. Renewal outcomes -- legitimate training labels. Only renewals that
--    have happened by the anchor date have an outcome. notice_date is
--    when a churner told us; recorded_at is when the row was written.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYN_RENEWAL_OUTCOMES AS
SELECT
    account_id,
    renewal_date,
    IFF(is_churner, 'CHURNED', 'RENEWED')                                     AS outcome,
    IFF(is_churner, DATEADD(day, -(15 + ABS(HASH(account_id, 'notice')) % 30), renewal_date), NULL) AS notice_date,
    DATEADD(day, 1, renewal_date)::TIMESTAMP_NTZ                              AS recorded_at
FROM {{EVAL_SCHEMA}}.SYN_ACCOUNT_TRUTH
WHERE outcome_observed;

-- ---------------------------------------------------------------------
-- 4. Monthly usage. 18 months back from the anchor.
--    - usage_decline accounts fall to ~45% over the 6 months before
--      renewal. With a 90-day horizon, half the decline is visible before
--      the cutoff -- a real but partial signal.
--    - LEAKAGE TRAP 3: usage is zero from the month a churner's renewal
--      passes. A feature computed over "the last 3 months" without a
--      cutoff reads that as the strongest predictor in the dataset.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYN_USAGE_MONTHLY AS
WITH m AS (
    SELECT SEQ4() AS k FROM TABLE(GENERATOR(ROWCOUNT => 18))
),
grid AS (
    SELECT t.*, a.seats_purchased,
           DATEADD(month, -m.k, DATE_TRUNC(month, '{{ANCHOR_DATE}}'::DATE)) AS usage_month
    FROM {{EVAL_SCHEMA}}.SYN_ACCOUNT_TRUTH t
    JOIN SYN_ACCOUNTS a USING (account_id)
    CROSS JOIN m
),
f AS (
    SELECT grid.*,
           0.50 + (ABS(HASH(account_id, 'util')) % 46) / 100.0                  AS base_util,
           0.90 + (ABS(HASH(account_id, usage_month, 'jit')) % 21) / 100.0      AS jitter,
           DATEDIFF(month, usage_month, DATE_TRUNC(month, renewal_date))       AS months_to_renewal
    FROM grid
)
SELECT
    account_id,
    usage_month,
    seats_purchased,
    CASE
        WHEN is_churner AND outcome_observed AND usage_month >= DATE_TRUNC(month, renewal_date) THEN 0
        ELSE GREATEST(0, ROUND(seats_purchased * LEAST(1.0, base_util * jitter *
                 IFF(usage_decline AND months_to_renewal BETWEEN 0 AND 6,
                     1 - 0.55 * (6 - months_to_renewal) / 6.0, 1))))
    END::INT                                                                AS active_users,
    CASE
        WHEN is_churner AND outcome_observed AND usage_month >= DATE_TRUNC(month, renewal_date) THEN 0
        ELSE ROUND(seats_purchased * base_util * jitter * (8 + ABS(HASH(account_id, usage_month, 'lg')) % 12) *
                 IFF(usage_decline AND months_to_renewal BETWEEN 0 AND 6,
                     1 - 0.60 * (6 - months_to_renewal) / 6.0, 1))
    END::INT                                                                AS logins,
    DATEADD(second, -1, DATEADD(month, 1, usage_month::TIMESTAMP_NTZ))     AS loaded_at
FROM f;

-- ---------------------------------------------------------------------
-- 5. Text templates. kind:
--      SIGNAL        pre-cutoff evidence of a reason
--      POST_OUTCOME  notice / offboarding / exit survey (after cutoff)
--      NOISE         routine traffic, no risk
--      DISTRACTOR    looks risky to a keyword or naive classifier, is not
--    Placeholders: {competitor} {feature} {pct} {person}
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _SYN_TEMPLATES (
    kind VARCHAR, reason_code VARCHAR, template_no INT, subject VARCHAR, body VARCHAR
);

INSERT INTO _SYN_TEMPLATES VALUES
-- PRICE_VALUE
('SIGNAL','PRICE_VALUE',0,'Renewal pricing','The proposed {pct}% uplift at renewal is hard to justify internally. Finance is asking what we actually get for the spend and I do not have a good answer.'),
('SIGNAL','PRICE_VALUE',1,'Cost review','We are reviewing every tool over a certain cost and this one came up. Honestly the value is not clear to leadership given how few teams use the advanced features we pay for.'),
('SIGNAL','PRICE_VALUE',2,'Licensing question','Can we drop to a smaller tier? We are paying for {pct}% more seats than we use and the per-seat price feels steep compared with what we get out of it.'),
('SIGNAL','PRICE_VALUE',3,'Survey response','Product is fine but it is too expensive for what it does. Hard to see the return on investment this year.'),
('SIGNAL','PRICE_VALUE',4,'QBR follow-up','Customer pushed back on price during the QBR. Sponsor said the budget holder considers us overpriced and wants a discount or a cheaper package before renewal.'),
-- PRODUCT_GAP
('SIGNAL','PRODUCT_GAP',0,'Feature request - urgent','We still do not have {feature}. Our security team says this is a hard requirement and we cannot expand rollout without it.'),
('SIGNAL','PRODUCT_GAP',1,'Roadmap question','Is {feature} on the roadmap with a date? Three of our business units are blocked and they are asking whether we picked the wrong platform.'),
('SIGNAL','PRODUCT_GAP',2,'Survey response','Missing {feature} means we run a parallel process in spreadsheets. It does not fit how we work.'),
('SIGNAL','PRODUCT_GAP',3,'Integration gap','The lack of {feature} is forcing manual workarounds every week. If this does not land soon we will need a tool that has it natively.'),
('SIGNAL','PRODUCT_GAP',4,'Call recap','Admin walked through their requirements; {feature} is the gap. They said everything else is good but this is a blocker for the wider deployment.'),
-- RELIABILITY
('SIGNAL','RELIABILITY',0,'Another outage','This is the third outage this month. Our operations team lost most of a morning and I am being asked whether we can depend on this platform.'),
('SIGNAL','RELIABILITY',1,'Sync failures','Data sync has been failing intermittently for two weeks. Reports are wrong and people have stopped trusting the numbers.'),
('SIGNAL','RELIABILITY',2,'Survey response','Too many errors and slow page loads. When it works it is great but it often does not work.'),
('SIGNAL','RELIABILITY',3,'Performance degradation','Dashboards now take over a minute to load. Users are complaining daily and leadership has noticed.'),
('SIGNAL','RELIABILITY',4,'Escalation','Customer escalated repeated timeouts during month-end close. They called it unacceptable and asked for an incident review.'),
-- SUPPORT
('SIGNAL','SUPPORT',0,'Still waiting','I opened this ticket nine days ago and have had no meaningful response. Each reply asks me to repeat information I already sent.'),
('SIGNAL','SUPPORT',1,'Escalating support experience','Support keeps closing our tickets before the issue is fixed. I want to escalate how we are being treated.'),
('SIGNAL','SUPPORT',2,'Survey response','Support is slow and unhelpful. We feel like a low priority customer.'),
('SIGNAL','SUPPORT',3,'Frustrated with support','Every time we contact support we get a different answer. We have lost confidence in getting help when we need it.'),
('SIGNAL','SUPPORT',4,'Call recap','Sponsor spent most of the call on support frustrations: long response times, tickets bounced between teams, no ownership.'),
-- ADOPTION
('SIGNAL','ADOPTION',0,'Low usage','Only a handful of people log in regularly. The rest of the team went back to the old process after training.'),
('SIGNAL','ADOPTION',1,'Onboarding stalled','Onboarding stalled after the kickoff. We never finished setup and nobody has time to own it.'),
('SIGNAL','ADOPTION',2,'Survey response','Too complicated for our team. Most people do not use it.'),
('SIGNAL','ADOPTION',3,'Training request','Users find the interface confusing and adoption is around {pct}% of licensed seats. Is there anything simpler we can do?'),
('SIGNAL','ADOPTION',4,'Call recap','Customer admitted usage is low outside one team; the rest never adopted it. They are questioning whether the rollout was worth it.'),
-- COMPETITOR
('SIGNAL','COMPETITOR',0,'Comparison request','We are running a pilot with {competitor} this quarter. Can you send a feature comparison so we can make a fair decision?'),
('SIGNAL','COMPETITOR',1,'Pricing comparison','{competitor} quoted us substantially less for similar functionality. We are seriously considering switching.'),
('SIGNAL','COMPETITOR',2,'Survey response','We are looking at {competitor}, which seems to do this better.'),
('SIGNAL','COMPETITOR',3,'Data export question','How would we export all of our historical data if we needed to? We are evaluating {competitor} and need to understand migration effort.'),
('SIGNAL','COMPETITOR',4,'Call recap','Champion mentioned procurement has issued an RFP and {competitor} is in the final round. Tone was guarded.'),
-- BUSINESS_CHANGE
('SIGNAL','BUSINESS_CHANGE',0,'Budget freeze','We have a company-wide budget freeze and every renewal is being re-approved from zero. I cannot promise this one survives.'),
('SIGNAL','BUSINESS_CHANGE',1,'Acquisition','We were acquired last month and the parent company standardises on its own tools. I do not know yet what that means for us.'),
('SIGNAL','BUSINESS_CHANGE',2,'Survey response','Our team was cut in half in the reorganisation, so we may not need this anymore.'),
('SIGNAL','BUSINESS_CHANGE',3,'Headcount changes','After the layoffs the team that used this most no longer exists. We need to talk about reducing or ending the subscription.'),
('SIGNAL','BUSINESS_CHANGE',4,'Call recap','Customer is exiting the business line this product supports. Strategy shift announced by their CEO last week.'),
-- CHAMPION_LOSS
('SIGNAL','CHAMPION_LOSS',0,'Admin departure','{person}, who ran our rollout, has left the company. Nobody else here really knows the system and there is no one assigned yet.'),
('SIGNAL','CHAMPION_LOSS',1,'New contact','I have inherited this account after {person} moved to another role. I was not involved in the purchase and do not know why we bought it.'),
('SIGNAL','CHAMPION_LOSS',2,'Survey response','Our main advocate for this tool left and interest has faded since.'),
('SIGNAL','CHAMPION_LOSS',3,'Bounced email','Our sponsor {person} has left. Emails to them bounce and the replacement contact has not responded in weeks.'),
('SIGNAL','CHAMPION_LOSS',4,'Call recap','Executive sponsor {person} departed; remaining users are passive and no one wants to own the renewal.'),
-- POST_OUTCOME: explicit non-renewal, carries the reason. After the cutoff.
('POST_OUTCOME','PRICE_VALUE',0,'Notice of non-renewal','Please treat this as formal notice that we will not renew. The cost no longer fits our budget relative to the value we get.'),
('POST_OUTCOME','PRICE_VALUE',1,'Exit survey','Cancelled because it was too expensive for what we used.'),
('POST_OUTCOME','PRODUCT_GAP',0,'Notice of non-renewal','We will not be renewing. Without {feature} we could not roll out as planned, so we are moving to a platform that has it.'),
('POST_OUTCOME','PRODUCT_GAP',1,'Exit survey','Leaving because the product lacks {feature}, which we needed.'),
('POST_OUTCOME','RELIABILITY',0,'Notice of non-renewal','We have decided not to renew. The outages and sync failures this year made it impossible to rely on.'),
('POST_OUTCOME','RELIABILITY',1,'Exit survey','Cancelled due to repeated downtime and errors.'),
('POST_OUTCOME','SUPPORT',0,'Notice of non-renewal','We will not renew. The support experience has not met our needs and we no longer have confidence in getting help.'),
('POST_OUTCOME','SUPPORT',1,'Exit survey','Leaving because support was slow and unhelpful.'),
('POST_OUTCOME','ADOPTION',0,'Notice of non-renewal','We are ending the subscription at term. The team never adopted it and we cannot justify keeping it.'),
('POST_OUTCOME','ADOPTION',1,'Exit survey','Cancelled because nobody used it.'),
('POST_OUTCOME','COMPETITOR',0,'Notice of non-renewal','We have selected {competitor} and will not renew. Please send instructions for exporting our data.'),
('POST_OUTCOME','COMPETITOR',1,'Exit survey','Switched to {competitor}.'),
('POST_OUTCOME','BUSINESS_CHANGE',0,'Notice of non-renewal','Following the reorganisation we are cancelling all non-essential subscriptions, including this one, at the end of term.'),
('POST_OUTCOME','BUSINESS_CHANGE',1,'Exit survey','Budget was cut, so we cancelled.'),
('POST_OUTCOME','CHAMPION_LOSS',0,'Notice of non-renewal','Since {person} left nobody owns this tool, so we have decided not to renew.'),
('POST_OUTCOME','CHAMPION_LOSS',1,'Exit survey','The person who championed it left and nobody took it over.'),
-- NOISE
('NOISE','NONE',0,'Password reset','How do I reset a user''s password? One of our team members is locked out.'),
('NOISE','NONE',1,'Invoice copy','Could you resend last quarter''s invoice to our accounts payable address?'),
('NOISE','NONE',2,'Survey response','Works well for our team. Easy to use day to day.'),
('NOISE','NONE',3,'Report export','What is the best way to schedule a weekly export of the activity report?'),
('NOISE','NONE',4,'Add users','Please add five more seats for the new hires starting next month.'),
('NOISE','NONE',5,'Call recap','Routine check-in. Customer happy with recent release and asked about the next training webinar.'),
('NOISE','NONE',6,'Feature tip','Small suggestion: it would be nice if the date picker remembered the last range. Not urgent.'),
('NOISE','NONE',7,'Survey response','Great product, the support team was quick to help last time.'),
('NOISE','NONE',8,'API key','Where do I generate a new API key for our integration account?'),
('NOISE','NONE',9,'Call recap','Walked through new dashboard features; customer plans to roll them out to two more teams.'),
-- DISTRACTOR: risky-sounding, no retention risk
('DISTRACTOR','NONE',0,'Competitor evaluation outcome','We looked at {competitor} last quarter as part of a routine review and decided to stay with you. Looking forward to the renewal.'),
('DISTRACTOR','NONE',1,'Bug - resolved','The export bug was really frustrating yesterday, but your team fixed it within the hour. Thanks for the quick turnaround.'),
('DISTRACTOR','NONE',2,'Expansion pricing','What would pricing look like if we added another {pct}% seats for the new division?'),
('DISTRACTOR','NONE',3,'Admin handover','{person} is moving to a new role, and Dana from our team is taking over as admin. She has been a power user for a year and is excited to own it.'),
('DISTRACTOR','NONE',4,'Budget planning','Budgets are tight everywhere this year, but this platform is on our protected list. Please send the renewal quote early.'),
('DISTRACTOR','NONE',5,'Survey response','Price went up a bit but it is still worth every penny.'),
('DISTRACTOR','NONE',6,'Cancel a meeting','Please cancel tomorrow''s training session; we will reschedule next week.'),
('DISTRACTOR','NONE',7,'Data export','We need a CSV export of last year''s data for our annual audit. Nothing has changed with our usage.');

-- ---------------------------------------------------------------------
-- 6. Interaction slots. One row per planned interaction, with the latent
--    label attached. Dates are relative to each account's cutoff so the
--    planted structure survives a change of HORIZON_DAYS.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _SYN_SLOTS AS
WITH k AS (SELECT SEQ4() AS slot FROM TABLE(GENERATOR(ROWCOUNT => 8))),
t AS (
    SELECT *,
           -- last day the account could have produced routine traffic
           IFF(is_churner AND outcome_observed, renewal_date, LEAST(renewal_date, '{{ANCHOR_DATE}}'::DATE)) AS traffic_end
    FROM {{EVAL_SCHEMA}}.SYN_ACCOUNT_TRUTH
)
-- SIGNAL: vocal churners 2-4, saved accounts 1-2. All before the cutoff.
SELECT t.account_id, 'SIGNAL' AS kind, k.slot,
       IFF(MOD(k.slot, 2) = 1 AND t.secondary_reason IS NOT NULL, t.secondary_reason, t.primary_reason) AS reason_code,
       DATEADD(day, -(5 + ABS(HASH(t.account_id, k.slot, 'sd')) % 150), t.prediction_cutoff)        AS created_on
FROM t CROSS JOIN k
WHERE (t.cohort = 'VOCAL' AND k.slot < 2 + ABS(HASH(t.account_id, 'nsig')) % 3)
   OR (t.cohort = 'SAVED' AND k.slot < 1 + ABS(HASH(t.account_id, 'nsig')) % 2)
UNION ALL
-- POST_OUTCOME: every observed churner, 1-2, between notice and renewal + 5.
SELECT t.account_id, 'POST_OUTCOME', k.slot, t.primary_reason,
       DATEADD(day, -(ABS(HASH(t.account_id, k.slot, 'pd')) % 30) + 5, t.renewal_date)
FROM t CROSS JOIN k
WHERE t.is_churner AND t.outcome_observed
  AND k.slot < 1 + ABS(HASH(t.account_id, 'npost')) % 2
UNION ALL
-- NOISE: every account, 3-6, spread over the 16 months before traffic_end.
SELECT t.account_id, 'NOISE', k.slot, 'NONE',
       DATEADD(day, -(ABS(HASH(t.account_id, k.slot, 'nd')) % 480), t.traffic_end)
FROM t CROSS JOIN k
WHERE k.slot < 3 + ABS(HASH(t.account_id, 'nnoise')) % 4
UNION ALL
-- DISTRACTOR: distractor cohort 1-2; 10% of healthy accounts get one.
SELECT t.account_id, 'DISTRACTOR', k.slot, 'NONE',
       DATEADD(day, -(10 + ABS(HASH(t.account_id, k.slot, 'dd')) % 300), LEAST(t.prediction_cutoff, t.traffic_end))
FROM t CROSS JOIN k
WHERE (t.cohort = 'DISTRACTOR' AND k.slot < 1 + ABS(HASH(t.account_id, 'ndis')) % 2)
   OR (t.cohort = 'HEALTHY' AND k.slot = 0 AND ABS(HASH(t.account_id, 'hdis')) % 100 < 10);

-- ---------------------------------------------------------------------
-- 7. Render interactions and the answer key together, from one CTE, so
--    they cannot drift apart.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE _SYN_RENDERED AS
WITH n AS (
    SELECT kind, reason_code, COUNT(*) AS n_templates
    FROM _SYN_TEMPLATES GROUP BY 1, 2
),
picked AS (
    SELECT s.*,
           ABS(HASH(s.account_id, s.kind, s.slot, 'tpl')) % n.n_templates AS template_no,
           ARRAY_CONSTRUCT('TICKET','SURVEY','EMAIL','CALL_NOTE')
               [ABS(HASH(s.account_id, s.kind, s.slot, 'ch')) % 4]::STRING AS channel
    FROM _SYN_SLOTS s
    JOIN n ON n.kind = s.kind AND n.reason_code = s.reason_code
)
SELECT
    p.account_id, p.kind, p.slot, p.reason_code, p.channel,
    -- created_at never later than the anchor: nothing from the future
    DATEADD(second, 28800 + ABS(HASH(p.account_id, p.kind, p.slot, 'tm')) % 36000,
            LEAST(p.created_on, '{{ANCHOR_DATE}}'::DATE)::TIMESTAMP_NTZ)              AS created_at,
    tp.subject,
    REPLACE(REPLACE(REPLACE(REPLACE(tp.body,
        '{competitor}', ARRAY_CONSTRUCT('Northwind Analytics','Bluefin Suite','Quarry Systems','Lattice Works')
                            [ABS(HASH(p.account_id, 'comp')) % 4]::STRING),
        '{feature}',    ARRAY_CONSTRUCT('SSO provisioning','audit logging','a CRM sync','custom dashboards','an EU data residency option')
                            [ABS(HASH(p.account_id, 'feat')) % 5]::STRING),
        '{pct}',        (10 + ABS(HASH(p.account_id, p.slot, 'pct')) % 30)::STRING),
        '{person}',     ARRAY_CONSTRUCT('Morgan Ellery','Casey Holloway','Jordan Pryce','Riley Ashdown')
                            [ABS(HASH(p.account_id, 'person')) % 4]::STRING) AS core_text
FROM picked p
JOIN _SYN_TEMPLATES tp
  ON tp.kind = p.kind AND tp.reason_code = p.reason_code AND tp.template_no = p.template_no;

CREATE OR REPLACE TABLE SYN_INTERACTIONS AS
SELECT
    'SYN-INT-' || LPAD(ROW_NUMBER() OVER (ORDER BY account_id, created_at, kind, slot)::STRING, 7, '0') AS interaction_id,
    account_id,
    channel,
    created_at,
    CASE channel WHEN 'CALL_NOTE' THEN 'CSM' WHEN 'SURVEY' THEN 'RESPONDENT' ELSE 'CUSTOMER' END     AS author_role,
    CASE channel WHEN 'SURVEY' THEN 'Survey response' ELSE subject END                             AS subject,
    CASE channel
        WHEN 'EMAIL'     THEN 'Hi team,' || CHR(10) || CHR(10) || core_text || CHR(10) || CHR(10) || 'Regards'
        WHEN 'CALL_NOTE' THEN 'CSM notes ' || TO_CHAR(created_at, 'YYYY-MM-DD') || ': ' || core_text
        WHEN 'TICKET'    THEN core_text || CHR(10) || CHR(10) || 'Submitted via support portal.'
        ELSE                  core_text
    END                                                                                            AS body,
    -- carried only to build the answer key below; dropped from the table
    kind  AS _kind,
    reason_code AS _reason_code
FROM _SYN_RENDERED;

-- Answer key: one row per interaction.
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYN_INTERACTION_LABELS AS
SELECT
    i.interaction_id,
    i.account_id,
    i._kind                                                         AS case_type,
    IFF(i._reason_code = 'NONE', ARRAY_CONSTRUCT(), ARRAY_CONSTRUCT(i._reason_code)) AS true_reasons,
    i._reason_code <> 'NONE'                                        AS has_retention_risk,
    i.created_at >= t.prediction_cutoff                             AS is_after_cutoff
FROM SYN_INTERACTIONS i
JOIN {{EVAL_SCHEMA}}.SYN_ACCOUNT_TRUTH t USING (account_id);

ALTER TABLE SYN_INTERACTIONS DROP COLUMN _kind;
ALTER TABLE SYN_INTERACTIONS DROP COLUMN _reason_code;

-- ---------------------------------------------------------------------
-- 8. Generation manifest -- the parameters that produced this corpus,
--    so an accuracy number can always be traced to its data.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYN_MANIFEST AS
SELECT
    {{N_ACCOUNTS}}                  AS n_accounts,
    '{{ANCHOR_DATE}}'::DATE         AS anchor_date,
    {{HORIZON_DAYS}}                AS horizon_days,
    (SELECT COUNT(*) FROM SYN_INTERACTIONS)  AS n_interactions,
    CURRENT_TIMESTAMP()             AS generated_at,
    'deterministic hash-seeded generator v1' AS generator_version;

DROP TABLE IF EXISTS _SYN_TEMPLATES;
DROP TABLE IF EXISTS _SYN_SLOTS;
DROP TABLE IF EXISTS _SYN_RENDERED;
