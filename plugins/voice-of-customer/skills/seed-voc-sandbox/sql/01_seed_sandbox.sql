-- =====================================================================
-- Synthetic voice-of-customer corpus with ground truth, for topic
-- classification, aspect-level sentiment, emerging-theme detection and
-- theme summarization development and accuracy measurement.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}              target database
--   {{SCHEMA}}          schema for sandbox source data (pipeline reads this)
--   {{EVAL_SCHEMA}}     separate schema for labels (QUARANTINE; pipeline never reads)
--   {{BACKGROUND_ROWS}} background feedback rows, e.g. 3000
--   {{END_DATE}}        last day of the 16-week window, e.g. '2026-06-28'
--                       (a fixed literal, not CURRENT_DATE, so reruns are comparable)
--
-- Design:
--   * Background feedback is COMPOSED from single-topic fragments whose
--     labels are known, so every generated row carries exact topic and
--     aspect-sentiment labels without hand-labeling thousands of rows.
--   * Hard cases (sarcasm, negation, comparatives, mixed aspects, off-topic,
--     spam, non-English, over-length, syndicated duplicates) are hand-authored
--     with explicit labels.
--   * Two emerging themes are planted with a known start week, SKU and region,
--     and both fall OUTSIDE taxonomy v1 at L2, so drift handling is testable.
--   * The fragment table and the generation plan carry labels, so they live in
--     {{EVAL_SCHEMA}} with the answer key. Only SYNTH_FEEDBACK, SYNTH_PRODUCTS,
--     SYNTH_REGIONS and SYNTH_SKU_WEEKLY land in {{SCHEMA}}.
--
-- All identifiers carry a SYN- prefix. All handles, products and regions are
-- fabricated. Nothing here is modeled on a real company.
-- =====================================================================

USE DATABASE {{DB}};
CREATE SCHEMA IF NOT EXISTS {{SCHEMA}};
CREATE SCHEMA IF NOT EXISTS {{EVAL_SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Reference dimensions (pipeline-visible)
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_PRODUCTS (
    sku           VARCHAR,
    product_name  VARCHAR,
    product_line  VARCHAR,
    list_price    NUMBER(10,2),
    launch_date   DATE
);

INSERT INTO {{SCHEMA}}.SYNTH_PRODUCTS VALUES
    ('SYN-SKU-HP-100', 'Synthwave Over-Ear Headphones Classic', 'AUDIO',   129.00, DATEADD(MONTH, -30, '{{END_DATE}}'::DATE)),
    ('SYN-SKU-HP-200', 'Synthwave Over-Ear Headphones Fold',    'AUDIO',   179.00, DATEADD(MONTH,  -5, '{{END_DATE}}'::DATE)),
    ('SYN-SKU-EB-300', 'Synthwave Wireless Earbuds',            'AUDIO',    99.00, DATEADD(MONTH, -18, '{{END_DATE}}'::DATE)),
    ('SYN-SKU-BL-100', 'Kitchenry Countertop Blender',          'KITCHEN',  89.00, DATEADD(MONTH, -40, '{{END_DATE}}'::DATE)),
    ('SYN-SKU-BL-200', 'Kitchenry Pro Blender',                 'KITCHEN', 149.00, DATEADD(MONTH, -12, '{{END_DATE}}'::DATE)),
    ('SYN-SKU-KT-100', 'Kitchenry Electric Kettle',             'KITCHEN',  49.00, DATEADD(MONTH, -24, '{{END_DATE}}'::DATE)),
    ('SYN-SKU-JK-100', 'Trailform Rain Jacket',                 'APPAREL', 119.00, DATEADD(MONTH, -20, '{{END_DATE}}'::DATE)),
    ('SYN-SKU-JK-200', 'Trailform Insulated Jacket',            'APPAREL', 199.00, DATEADD(MONTH,  -9, '{{END_DATE}}'::DATE)),
    ('SYN-SKU-FL-100', 'Trailform Fleece Pullover',             'APPAREL',  69.00, DATEADD(MONTH, -36, '{{END_DATE}}'::DATE));

CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_REGIONS (
    region_code  VARCHAR,
    region_name  VARCHAR
);

INSERT INTO {{SCHEMA}}.SYNTH_REGIONS VALUES
    ('SYN-NAE', 'North America East'),
    ('SYN-NAW', 'North America West'),
    ('SYN-EU',  'Continental Europe'),
    ('SYN-UK',  'United Kingdom'),
    ('SYN-APAC','Asia Pacific');

-- ---------------------------------------------------------------------
-- 2. Labeled fragments (QUARANTINED: carries labels)
--    One fragment = one topic, one aspect, one sentiment. Composed rows
--    inherit the union of their fragments' labels.
--    product_line NULL means the fragment fits any line.
--    topic_l2_v2 differs from topic_l2_v1 where taxonomy v2 renamed or
--    split a node; the evaluation harness scores against whichever
--    taxonomy version the run used.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_FRAGMENTS (
    fragment_id     INT,
    topic_l1        VARCHAR,
    topic_l2_v1     VARCHAR,
    topic_l2_v2     VARCHAR,
    aspect          VARCHAR,     -- matches an AI_SENTIMENT aspect name, <= 30 chars
    sentiment       VARCHAR,     -- positive | negative | neutral
    product_line    VARCHAR,
    emerging_theme  VARCHAR,     -- NULL for background fragments
    fragment_text   VARCHAR
);

INSERT INTO {{EVAL_SCHEMA}}.SYNTH_FRAGMENTS VALUES
 -- Product Quality
 (101,'Product Quality','Durability','Durability','Product Quality','negative',NULL,NULL,'It stopped working properly after about three weeks of normal use.'),
 (102,'Product Quality','Durability','Durability','Product Quality','positive',NULL,NULL,'Two years in and it still works like the day I bought it.'),
 (103,'Product Quality','Performance','Performance','Product Quality','positive','AUDIO',NULL,'The sound is clear and the bass is rich without being muddy.'),
 (104,'Product Quality','Performance','Performance','Product Quality','negative','AUDIO',NULL,'The noise cancelling barely blocks anything on my commute.'),
 (105,'Product Quality','Performance','Performance','Product Quality','positive','KITCHEN',NULL,'It crushes ice in seconds and the smoothies come out perfectly smooth.'),
 (106,'Product Quality','Performance','Performance','Product Quality','negative','KITCHEN',NULL,'The motor struggles with anything thicker than juice.'),
 (107,'Product Quality','Materials and Build','Materials and Build','Product Quality','positive','APPAREL',NULL,'The fabric feels substantial and the seams are cleanly stitched.'),
 (108,'Product Quality','Materials and Build','Materials and Build','Product Quality','negative',NULL,NULL,'The plastic feels cheap and creaks when you handle it.'),
 (109,'Product Quality','Defective on Arrival','Defective on Arrival','Product Quality','negative',NULL,NULL,'Mine arrived dead and would not power on at all.'),
 (110,'Product Quality','Performance','Performance','Product Quality','positive','APPAREL',NULL,'It kept me completely dry through a full day of steady rain.'),
 (111,'Product Quality','Performance','Performance','Product Quality','negative','APPAREL',NULL,'The so-called waterproof shell soaked through within an hour.'),
 -- Fit and Sizing (apparel only)
 (201,'Fit and Sizing','Runs Small','Runs Small','Fit and Sizing','negative','APPAREL',NULL,'I ordered my usual size and it was tight across the shoulders, size up.'),
 (202,'Fit and Sizing','Runs Large','Runs Large','Fit and Sizing','negative','APPAREL',NULL,'The sleeves are far too long and the whole thing fits like a tent.'),
 (203,'Fit and Sizing','True to Size','True to Size','Fit and Sizing','positive','APPAREL',NULL,'Fits exactly as the size chart says, no surprises.'),
 -- Price and Value
 (301,'Price and Value','Too Expensive','Too Expensive','Price and Value','negative',NULL,NULL,'Honestly it is overpriced for what you get.'),
 (302,'Price and Value','Good Value','Good Value','Price and Value','positive',NULL,NULL,'For the price this is a steal compared to the big brands.'),
 (303,'Price and Value','Promotions and Discounts','Promotions and Discounts','Price and Value','positive',NULL,NULL,'I grabbed it during the seasonal sale and the discount made it an easy decision.'),
 (304,'Price and Value','Promotions and Discounts','Promotions and Discounts','Price and Value','negative',NULL,NULL,'The promo code from the email would not apply at checkout.'),
 -- Shipping and Delivery
 (401,'Shipping and Delivery','Delivery Speed','Delivery Time','Shipping and Delivery','positive',NULL,NULL,'It showed up two days earlier than promised.'),
 (402,'Shipping and Delivery','Delivery Speed','Delivery Time','Shipping and Delivery','negative',NULL,NULL,'Delivery took almost three weeks with no explanation.'),
 (403,'Shipping and Delivery','Damaged in Transit','Damaged in Transit','Shipping and Delivery','negative',NULL,NULL,'The box was crushed and the item inside was cracked from shipping.'),
 (404,'Shipping and Delivery','Tracking','Tracking','Shipping and Delivery','negative',NULL,NULL,'The tracking number never updated after the first day.'),
 -- Customer Service
 (501,'Customer Service','Agent Helpfulness','Agent Helpfulness','Customer Service','positive',NULL,NULL,'The support agent sorted everything out in one chat and was genuinely kind.'),
 (502,'Customer Service','Agent Helpfulness','Agent Helpfulness','Customer Service','negative',NULL,NULL,'Support kept sending me the same scripted answer that did not address my problem.'),
 (503,'Customer Service','Response Time','Response Time','Customer Service','negative',NULL,NULL,'I waited five days for anyone to reply to my support ticket.'),
 (504,'Customer Service','Response Time','Response Time','Customer Service','positive',NULL,NULL,'Customer service answered my email within the hour.'),
 -- Returns and Refunds
 (601,'Returns and Refunds','Return Process','Return Process','Returns and Refunds','positive',NULL,NULL,'Returning it was painless, the prepaid label was in the box.'),
 (602,'Returns and Refunds','Return Process','Return Process','Returns and Refunds','negative',NULL,NULL,'The return portal kept erroring out and I had to print the label at a shop.'),
 (603,'Returns and Refunds','Refund Delay','Refund Delay','Returns and Refunds','negative',NULL,NULL,'They received my return a month ago and I still have not been refunded.'),
 -- Packaging
 (701,'Packaging','Excess Packaging','Excess Packaging','Packaging','negative',NULL,NULL,'Way too much plastic wrap and foam for such a small item.'),
 (702,'Packaging','Packaging Quality','Packaging Quality','Packaging','positive',NULL,NULL,'Nicely packaged in recyclable cardboard, it would make a good gift.'),
 -- Website and App
 (801,'Website and App','Checkout','Checkout','Website and App','negative',NULL,NULL,'The app crashed twice while I was trying to pay.'),
 (802,'Website and App','Checkout','Checkout','Website and App','positive',NULL,NULL,'Checkout on the website took less than a minute.'),
 (803,'Website and App','Product Information Accuracy','Product Information Accuracy','Website and App','negative',NULL,NULL,'The product page listed a feature that this model does not actually have.'),
 -- Emerging theme 1: hinge breakage on SYN-SKU-HP-200, SYN-EU, from week 6.
 -- Not a v1 L2 node: v1 truth is Durability; v2 adds Hinge Breakage.
 (901,'Product Quality','Durability','Hinge Breakage','Product Quality','negative','AUDIO','HINGE','The folding hinge on the left earcup snapped after a couple of weeks.'),
 (902,'Product Quality','Durability','Hinge Breakage','Product Quality','negative','AUDIO','HINGE','There is a crack forming right where the headband folds, and it is getting worse.'),
 (903,'Product Quality','Durability','Hinge Breakage','Product Quality','negative','AUDIO','HINGE','The fold mechanism feels loose now and one side flops around.'),
 -- Emerging theme 2: subscription fee backlash, social channel, all regions, from week 10.
 -- Not a v1 L2 node: v1 truth is Too Expensive; v2 adds Subscription Fees.
 (911,'Price and Value','Too Expensive','Subscription Fees','Price and Value','negative',NULL,'SUBSCRIPTION','Now they want a monthly subscription just to use the companion app features I already paid for.'),
 (912,'Price and Value','Too Expensive','Subscription Fees','Price and Value','negative',NULL,'SUBSCRIPTION','Putting the warranty extension behind a paid membership is a terrible move.'),
 (913,'Price and Value','Too Expensive','Subscription Fees','Price and Value','negative',NULL,'SUBSCRIPTION','Cancelled. Not paying a recurring fee on top of the product price.');

-- ---------------------------------------------------------------------
-- 3. Generation plan (QUARANTINED). Materialized once so RANDOM() is
--    evaluated exactly once per row: a view or CTE would re-roll on every
--    reference and the text would stop matching its labels.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_FEEDBACK_PLAN AS
WITH base AS (
    SELECT
        'SYN-FB-' || LPAD(SEQ4(), 7, '0')                         AS feedback_id,
        ARRAY_CONSTRUCT('REVIEW','REVIEW','REVIEW','SURVEY','SURVEY','SOCIAL')
            [UNIFORM(0, 5, RANDOM())]::STRING                      AS source_channel,
        ARRAY_CONSTRUCT('SYN-SKU-HP-100','SYN-SKU-HP-200','SYN-SKU-EB-300',
                        'SYN-SKU-BL-100','SYN-SKU-BL-200','SYN-SKU-KT-100',
                        'SYN-SKU-JK-100','SYN-SKU-JK-200','SYN-SKU-FL-100')
            [UNIFORM(0, 8, RANDOM())]::STRING                      AS sku,
        ARRAY_CONSTRUCT('SYN-NAE','SYN-NAW','SYN-EU','SYN-UK','SYN-APAC')
            [UNIFORM(0, 4, RANDOM())]::STRING                      AS region_code,
        DATEADD(DAY, -UNIFORM(0, 111, RANDOM()), '{{END_DATE}}'::DATE) AS created_date,
        UNIFORM(1, 3, RANDOM())                                    AS n_fragments,
        'BACKGROUND'                                               AS case_role,
        RANDOM()                                                   AS seed_a
    FROM TABLE(GENERATOR(ROWCOUNT => {{BACKGROUND_ROWS}}))
),
pool AS (
    -- Background fragments eligible for each product line, densely numbered
    -- per line so a uniform draw always lands on an eligible fragment.
    SELECT p.product_line, f.fragment_id,
           ROW_NUMBER() OVER (PARTITION BY p.product_line ORDER BY f.fragment_id) AS rn,
           COUNT(*)     OVER (PARTITION BY p.product_line)                        AS cnt
    FROM (SELECT DISTINCT product_line FROM {{SCHEMA}}.SYNTH_PRODUCTS) p
    JOIN {{EVAL_SCHEMA}}.SYNTH_FRAGMENTS f
      ON (f.product_line IS NULL OR f.product_line = p.product_line)
     AND f.emerging_theme IS NULL
),
slots AS (
    SELECT b.*, pr.product_line, s.slot,
           UNIFORM(1, 1000000, RANDOM()) AS draw
    FROM base b
    JOIN {{SCHEMA}}.SYNTH_PRODUCTS pr ON pr.sku = b.sku
    JOIN (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS slot FROM TABLE(GENERATOR(ROWCOUNT => 3))) s
      ON s.slot <= b.n_fragments
)
SELECT s.feedback_id, s.source_channel, s.sku, s.region_code, s.created_date,
       s.case_role, s.slot, po.fragment_id
FROM slots s
JOIN (SELECT DISTINCT product_line, cnt FROM pool) c ON c.product_line = s.product_line
JOIN pool po
  ON po.product_line = s.product_line
 AND po.rn = MOD(s.draw, c.cnt) + 1
-- Drop a repeated fragment inside one row; keeps text natural, labels unchanged.
QUALIFY ROW_NUMBER() OVER (PARTITION BY s.feedback_id, po.fragment_id ORDER BY s.slot) = 1;

-- Emerging theme 1: hinge breakage. Week index skews late (sqrt of uniform)
-- so volume visibly accelerates, which is what a trend detector must catch.
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_FEEDBACK_PLAN
WITH e AS (
    SELECT 'SYN-FB-E1-' || LPAD(SEQ4(), 5, '0') AS feedback_id,
           ARRAY_CONSTRUCT('REVIEW','REVIEW','SURVEY','SOCIAL')[UNIFORM(0,3,RANDOM())]::STRING AS source_channel,
           6 + FLOOR(SQRT(UNIFORM(0, 120, RANDOM())))::INT AS week_idx,   -- weeks 6..16
           UNIFORM(0, 6, RANDOM()) AS dow,
           901 + UNIFORM(0, 2, RANDOM()) AS fragment_id
    FROM TABLE(GENERATOR(ROWCOUNT => 160))
)
SELECT feedback_id, source_channel, 'SYN-SKU-HP-200', 'SYN-EU',
       LEAST(DATEADD(DAY, (week_idx - 1) * 7 + dow, DATEADD(DAY, -111, '{{END_DATE}}'::DATE)), '{{END_DATE}}'::DATE),
       'EMERGING', 1, fragment_id
FROM e;

-- Emerging theme 2: subscription backlash, social only, every SKU and region, weeks 10..16.
INSERT INTO {{EVAL_SCHEMA}}.SYNTH_FEEDBACK_PLAN
WITH e AS (
    SELECT 'SYN-FB-E2-' || LPAD(SEQ4(), 5, '0') AS feedback_id,
           10 + FLOOR(SQRT(UNIFORM(0, 48, RANDOM())))::INT AS week_idx,    -- weeks 10..16
           UNIFORM(0, 6, RANDOM()) AS dow,
           ARRAY_CONSTRUCT('SYN-SKU-HP-100','SYN-SKU-HP-200','SYN-SKU-EB-300',
                           'SYN-SKU-BL-200','SYN-SKU-JK-200')[UNIFORM(0,4,RANDOM())]::STRING AS sku,
           ARRAY_CONSTRUCT('SYN-NAE','SYN-NAW','SYN-EU','SYN-UK','SYN-APAC')[UNIFORM(0,4,RANDOM())]::STRING AS region_code,
           911 + UNIFORM(0, 2, RANDOM()) AS fragment_id
    FROM TABLE(GENERATOR(ROWCOUNT => 140))
)
SELECT feedback_id, 'SOCIAL', sku, region_code,
       LEAST(DATEADD(DAY, (week_idx - 1) * 7 + dow, DATEADD(DAY, -111, '{{END_DATE}}'::DATE)), '{{END_DATE}}'::DATE),
       'EMERGING', 1, fragment_id
FROM e;

-- ---------------------------------------------------------------------
-- 4. Composed feedback (pipeline-visible). Channel wrappers make social
--    and survey text look like their channel, without adding topics.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_FEEDBACK (
    feedback_id      VARCHAR,
    source_channel   VARCHAR,      -- REVIEW | SURVEY | SOCIAL
    source_system    VARCHAR,      -- where it was collected
    sku              VARCHAR,      -- NULL when the source does not carry one
    region_code      VARCHAR,
    language_code    VARCHAR,      -- as reported by the source; may be NULL or wrong
    author_handle    VARCHAR,
    star_rating      INT,          -- reviews only
    nps_score        INT,          -- surveys only
    created_at       TIMESTAMP_NTZ,
    feedback_text    VARCHAR
);

INSERT INTO {{SCHEMA}}.SYNTH_FEEDBACK
WITH txt AS (
    SELECT p.feedback_id,
           ANY_VALUE(p.source_channel) AS source_channel,
           ANY_VALUE(p.sku)            AS sku,
           ANY_VALUE(p.region_code)    AS region_code,
           ANY_VALUE(p.created_date)   AS created_date,
           LISTAGG(f.fragment_text, ' ') WITHIN GROUP (ORDER BY p.slot) AS body,
           COUNT_IF(f.sentiment = 'positive') AS pos,
           COUNT_IF(f.sentiment = 'negative') AS neg
    FROM {{EVAL_SCHEMA}}.SYNTH_FEEDBACK_PLAN p
    JOIN {{EVAL_SCHEMA}}.SYNTH_FRAGMENTS f ON f.fragment_id = p.fragment_id
    GROUP BY p.feedback_id
)
SELECT
    txt.feedback_id,
    txt.source_channel,
    CASE txt.source_channel WHEN 'REVIEW' THEN 'SYN-RETAIL-SITE'
                            WHEN 'SURVEY' THEN 'SYN-POST-PURCHASE-SURVEY'
                            ELSE 'SYN-SOCIAL-LISTENING' END,
    -- Social listening often cannot resolve a SKU. Leave ~40% of social rows
    -- unresolved so the entity-linking step is exercised rather than assumed.
    CASE WHEN txt.source_channel = 'SOCIAL' AND MOD(ABS(HASH(txt.feedback_id)), 10) < 4
         THEN NULL ELSE txt.sku END,
    txt.region_code,
    'en',
    'syn_user_' || LPAD(MOD(ABS(HASH(txt.feedback_id)), 100000)::STRING, 5, '0'),
    -- Star rating and NPS are derived from fragment polarity so they are
    -- plausible, but the answer key never uses them as sentiment truth.
    CASE WHEN txt.source_channel = 'REVIEW' THEN
         CASE WHEN txt.neg = 0 THEN 4 + MOD(ABS(HASH(txt.feedback_id)), 2)
              WHEN txt.pos = 0 THEN 1 + MOD(ABS(HASH(txt.feedback_id)), 2)
              ELSE 3 END END,
    CASE WHEN txt.source_channel = 'SURVEY' THEN
         CASE WHEN txt.neg = 0 THEN 9 + MOD(ABS(HASH(txt.feedback_id)), 2)
              WHEN txt.pos = 0 THEN MOD(ABS(HASH(txt.feedback_id)), 6)
              ELSE 7 END END,
    DATEADD(MINUTE, MOD(ABS(HASH(txt.feedback_id)), 1440), txt.created_date::TIMESTAMP_NTZ),
    CASE WHEN txt.source_channel = 'SOCIAL'
         THEN '@synthbrand ' || txt.body || ' #' || LOWER(pr.product_line)
         ELSE txt.body END
FROM txt
JOIN {{SCHEMA}}.SYNTH_PRODUCTS pr ON pr.sku = txt.sku;

-- ---------------------------------------------------------------------
-- 5. Hand-authored hard cases (pipeline-visible text).
--    Each one exists to catch a specific failure; the case_role in the
--    quarantined row labels says which. Keep apostrophes doubled.
-- ---------------------------------------------------------------------
INSERT INTO {{SCHEMA}}.SYNTH_FEEDBACK
    (feedback_id, source_channel, source_system, sku, region_code, language_code,
     author_handle, star_rating, nps_score, created_at, feedback_text)
VALUES
 ('SYN-FB-H001','REVIEW','SYN-RETAIL-SITE','SYN-SKU-BL-100','SYN-NAE','en','syn_hard_001',1,NULL,DATEADD(DAY,-80,'{{END_DATE}}'::DATE),
  'Oh great, another blender that sounds like a jet engine and barely blends a banana. Exactly what I wanted for my birthday.'),
 ('SYN-FB-H002','SOCIAL','SYN-SOCIAL-LISTENING',NULL,'SYN-NAW','en','syn_hard_002',NULL,NULL,DATEADD(DAY,-75,'{{END_DATE}}'::DATE),
  '@synthbrand Love waiting three weeks for a package that was promised in two days. Truly world class logistics.'),
 ('SYN-FB-H003','REVIEW','SYN-RETAIL-SITE','SYN-SKU-HP-100','SYN-UK','en','syn_hard_003',5,NULL,DATEADD(DAY,-70,'{{END_DATE}}'::DATE),
  'Not bad at all for the price, and I was not expecting them to sound this good.'),
 ('SYN-FB-H004','SURVEY','SYN-POST-PURCHASE-SURVEY','SYN-SKU-EB-300','SYN-EU','en','syn_hard_004',NULL,3,DATEADD(DAY,-66,'{{END_DATE}}'::DATE),
  'I would not say the support team was unhelpful, they just never actually fixed anything.'),
 ('SYN-FB-H005','REVIEW','SYN-RETAIL-SITE','SYN-SKU-HP-200','SYN-NAE','en','syn_hard_005',2,NULL,DATEADD(DAY,-90,'{{END_DATE}}'::DATE),
  'The Classic sounded far better than this Fold version, which feels like a downgrade in every way that matters to my ears.'),
 ('SYN-FB-H006','REVIEW','SYN-RETAIL-SITE','SYN-SKU-JK-200','SYN-APAC','en','syn_hard_006',5,NULL,DATEADD(DAY,-60,'{{END_DATE}}'::DATE),
  'Much warmer than the jacket I had from another brand, and about half the weight.'),
 ('SYN-FB-H007','REVIEW','SYN-RETAIL-SITE','SYN-SKU-JK-100','SYN-UK','en','syn_hard_007',3,NULL,DATEADD(DAY,-55,'{{END_DATE}}'::DATE),
  'Beautifully made jacket and the fit is perfect, but it took a month to arrive.'),
 ('SYN-FB-H008','REVIEW','SYN-RETAIL-SITE','SYN-SKU-BL-200','SYN-NAW','en','syn_hard_008',3,NULL,DATEADD(DAY,-50,'{{END_DATE}}'::DATE),
  'The blender is seriously powerful, but the lid cracked on the second use.'),
 ('SYN-FB-H009','SOCIAL','SYN-SOCIAL-LISTENING',NULL,'SYN-NAE','en','syn_hard_009',NULL,NULL,DATEADD(DAY,-45,'{{END_DATE}}'::DATE),
  '@synthbrand Does anyone know if the downtown store is open on public holidays?'),
 ('SYN-FB-H010','SOCIAL','SYN-SOCIAL-LISTENING',NULL,'SYN-APAC','en','syn_spam_a',NULL,NULL,DATEADD(DAY,-40,'{{END_DATE}}'::DATE),
  '@synthbrand Earn 500 a day from home, no experience needed, click the link in my bio!!!'),
 ('SYN-FB-H011','SOCIAL','SYN-SOCIAL-LISTENING',NULL,'SYN-APAC','en','syn_spam_b',NULL,NULL,DATEADD(DAY,-40,'{{END_DATE}}'::DATE),
  '@synthbrand Earn 500 a day from home, no experience needed, click the link in my bio!!!'),
 ('SYN-FB-H012','SOCIAL','SYN-SOCIAL-LISTENING',NULL,'SYN-APAC','en','syn_spam_c',NULL,NULL,DATEADD(DAY,-39,'{{END_DATE}}'::DATE),
  '@synthbrand Earn 500 a day from home, no experience needed, click the link in my bio!!!'),
 ('SYN-FB-H013','REVIEW','SYN-RETAIL-SITE','SYN-SKU-KT-100','SYN-EU','es','syn_hard_013',1,NULL,DATEADD(DAY,-35,'{{END_DATE}}'::DATE),
  'El envio tardo casi un mes y nadie respondio a mis correos.'),
 ('SYN-FB-H014','REVIEW','SYN-RETAIL-SITE','SYN-SKU-HP-100','SYN-EU',NULL,'syn_hard_014',5,NULL,DATEADD(DAY,-33,'{{END_DATE}}'::DATE),
  'Tres bon rapport qualite-prix, le son est excellent.'),
 ('SYN-FB-H015','REVIEW','SYN-RETAIL-SITE','SYN-SKU-JK-100','SYN-EU','en','syn_hard_015',2,NULL,DATEADD(DAY,-30,'{{END_DATE}}'::DATE),
  'Die Jacke ist viel zu klein ausgefallen, bitte eine Nummer groesser bestellen.'),
 ('SYN-FB-H016','SURVEY','SYN-POST-PURCHASE-SURVEY','SYN-SKU-BL-200','SYN-NAE','en','syn_hard_016',NULL,1,DATEADD(DAY,-28,'{{END_DATE}}'::DATE),
  REPEAT('I am writing in detail because the return experience was the worst part of this purchase. The return portal rejected my order number repeatedly, the chat bot looped me back to the start, and when I finally shipped the blender back it took weeks for anyone to acknowledge it. The refund has still not arrived and every email gets a different answer. ', 40)),
 ('SYN-FB-H017A','REVIEW','SYN-RETAIL-SITE','SYN-SKU-KT-100','SYN-UK','en','syn_hard_017',3,NULL,DATEADD(DAY,-25,'{{END_DATE}}'::DATE),
  'The kettle boils really fast but the lid hinge started wobbling after a month.'),
 ('SYN-FB-H017B','REVIEW','SYN-PARTNER-RETAILER-A','SYN-SKU-KT-100','SYN-UK','en','syn_hard_017',3,NULL,DATEADD(DAY,-24,'{{END_DATE}}'::DATE),
  'The kettle boils really fast but the lid hinge started wobbling after a month.'),
 ('SYN-FB-H017C','REVIEW','SYN-PARTNER-RETAILER-B','SYN-SKU-KT-100','SYN-UK','en','syn_hard_017',3,NULL,DATEADD(DAY,-24,'{{END_DATE}}'::DATE),
  'The kettle boils really fast but the lid hinge started wobbling after a month.'),
 ('SYN-FB-H018A','REVIEW','SYN-RETAIL-SITE','SYN-SKU-FL-100','SYN-NAE','en','syn_hard_018a',5,NULL,DATEADD(DAY,-22,'{{END_DATE}}'::DATE),
  'Great product, fast shipping.'),
 ('SYN-FB-H018B','REVIEW','SYN-RETAIL-SITE','SYN-SKU-EB-300','SYN-NAW','en','syn_hard_018b',5,NULL,DATEADD(DAY,-21,'{{END_DATE}}'::DATE),
  'Great product, fast shipping.'),
 ('SYN-FB-H018C','REVIEW','SYN-RETAIL-SITE','SYN-SKU-BL-100','SYN-APAC','en','syn_hard_018c',5,NULL,DATEADD(DAY,-20,'{{END_DATE}}'::DATE),
  'Great product, fast shipping.'),
 ('SYN-FB-H019','REVIEW','SYN-RETAIL-SITE','SYN-SKU-EB-300','SYN-NAW','en','syn_hard_019',5,NULL,DATEADD(DAY,-18,'{{END_DATE}}'::DATE),
  'Five stars because the delivery driver was lovely, but the earbuds disconnect from my phone constantly.'),
 ('SYN-FB-H020','SOCIAL','SYN-SOCIAL-LISTENING',NULL,'SYN-UK','en','syn_hard_020',NULL,NULL,DATEADD(DAY,-16,'{{END_DATE}}'::DATE),
  '@synthbrand The Synthwave Fold headphones sound incredible, best I have owned. #audio'),
 ('SYN-FB-H021','SOCIAL','SYN-SOCIAL-LISTENING',NULL,'SYN-NAE','en','syn_hard_021',NULL,NULL,DATEADD(DAY,-15,'{{END_DATE}}'::DATE),
  '@synthbrand Kitchenry pro blender is loud as anything but it pulverizes everything I throw at it.'),
 ('SYN-FB-H022','REVIEW','SYN-RETAIL-SITE','SYN-SKU-FL-100','SYN-APAC','en','syn_hard_022',2,NULL,DATEADD(DAY,-14,'{{END_DATE}}'::DATE),
  'Cheap, and it feels cheap.'),
 ('SYN-FB-H023','SOCIAL','SYN-SOCIAL-LISTENING',NULL,'SYN-EU','en','syn_hard_023',NULL,NULL,DATEADD(DAY,-12,'{{END_DATE}}'::DATE),
  '@synthbrand Is the Fold model compatible with airline audio adapters?'),
 ('SYN-FB-H024','SURVEY','SYN-POST-PURCHASE-SURVEY','SYN-SKU-JK-100','SYN-NAW','en','syn_hard_024',NULL,9,DATEADD(DAY,-10,'{{END_DATE}}'::DATE),
  'The zipper broke after a few weeks, but support sent a replacement within two days, so I am happy overall.'),
 ('SYN-FB-H025','REVIEW','SYN-RETAIL-SITE','SYN-SKU-HP-100','SYN-NAE','en','syn_hard_025',2,NULL,DATEADD(DAY,-9,'{{END_DATE}}'::DATE),
  'Sending these back, the earcups are too small and press on my ears after twenty minutes.'),
 ('SYN-FB-H026','REVIEW','SYN-RETAIL-SITE','SYN-SKU-BL-100','SYN-UK','en','syn_hard_026',1,NULL,DATEADD(DAY,-8,'{{END_DATE}}'::DATE),
  'Returning it tomorrow. The motor smells like burning plastic every time I run it.'),
 ('SYN-FB-H027','SURVEY','SYN-POST-PURCHASE-SURVEY','SYN-SKU-JK-200','SYN-EU','en','syn_hard_027',NULL,4,DATEADD(DAY,-7,'{{END_DATE}}'::DATE),
  'I am thinking about returning it, but the return window rules on the website are confusing.'),
 ('SYN-FB-H028','REVIEW','SYN-RETAIL-SITE','SYN-SKU-KT-100','SYN-NAW','en','syn_hard_028',3,NULL,DATEADD(DAY,-6,'{{END_DATE}}'::DATE),
  'It is a kettle. It boils water.'),
 ('SYN-FB-H029','REVIEW','SYN-RETAIL-SITE','SYN-SKU-HP-200','SYN-NAE','en','syn_hard_029',2,NULL,DATEADD(DAY,-104,'{{END_DATE}}'::DATE),
  'The folding hinge on the left earcup snapped after a couple of weeks.'),
 ('SYN-FB-H030','SOCIAL','SYN-SOCIAL-LISTENING',NULL,'SYN-NAW','en','syn_hard_030',NULL,NULL,DATEADD(DAY,-4,'{{END_DATE}}'::DATE),
  '@synthbrand WORST CHECKOUT EVER, the app froze three times before my card went through :(');

-- ---------------------------------------------------------------------
-- 6. Hard-case labels (QUARANTINED).
--    topic_l2_* NULL means the case is labeled at L1 only ("Great product"
--    has no defensible L2); the harness scores L2 only where it is set.
--    One row per topic+aspect claim; a row with topic_l1 NULL is a
--    non-feedback item with no topic.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_HARD_LABELS (
    feedback_id  VARCHAR,
    topic_l1     VARCHAR,
    topic_l2_v1  VARCHAR,
    topic_l2_v2  VARCHAR,
    aspect       VARCHAR,
    sentiment    VARCHAR
);

INSERT INTO {{EVAL_SCHEMA}}.SYNTH_HARD_LABELS VALUES
 ('SYN-FB-H001','Product Quality','Performance','Performance','Product Quality','negative'),
 ('SYN-FB-H002','Shipping and Delivery','Delivery Speed','Delivery Time','Shipping and Delivery','negative'),
 ('SYN-FB-H003','Price and Value','Good Value','Good Value','Price and Value','positive'),
 ('SYN-FB-H003','Product Quality','Performance','Performance','Product Quality','positive'),
 ('SYN-FB-H004','Customer Service','Agent Helpfulness','Agent Helpfulness','Customer Service','negative'),
 ('SYN-FB-H005','Product Quality','Performance','Performance','Product Quality','negative'),
 ('SYN-FB-H006','Product Quality','Performance','Performance','Product Quality','positive'),
 ('SYN-FB-H007','Product Quality','Materials and Build','Materials and Build','Product Quality','positive'),
 ('SYN-FB-H007','Fit and Sizing','True to Size','True to Size','Fit and Sizing','positive'),
 ('SYN-FB-H007','Shipping and Delivery','Delivery Speed','Delivery Time','Shipping and Delivery','negative'),
 ('SYN-FB-H008','Product Quality','Performance','Performance','Product Quality','positive'),
 ('SYN-FB-H008','Product Quality','Durability','Durability','Product Quality','negative'),
 ('SYN-FB-H009',NULL,NULL,NULL,NULL,NULL),
 ('SYN-FB-H010',NULL,NULL,NULL,NULL,NULL),
 ('SYN-FB-H011',NULL,NULL,NULL,NULL,NULL),
 ('SYN-FB-H012',NULL,NULL,NULL,NULL,NULL),
 ('SYN-FB-H013','Shipping and Delivery','Delivery Speed','Delivery Time','Shipping and Delivery','negative'),
 ('SYN-FB-H013','Customer Service','Response Time','Response Time','Customer Service','negative'),
 ('SYN-FB-H014','Price and Value','Good Value','Good Value','Price and Value','positive'),
 ('SYN-FB-H014','Product Quality','Performance','Performance','Product Quality','positive'),
 ('SYN-FB-H015','Fit and Sizing','Runs Small','Runs Small','Fit and Sizing','negative'),
 ('SYN-FB-H016','Returns and Refunds','Return Process','Return Process','Returns and Refunds','negative'),
 ('SYN-FB-H016','Returns and Refunds','Refund Delay','Refund Delay','Returns and Refunds','negative'),
 ('SYN-FB-H016','Customer Service','Agent Helpfulness','Agent Helpfulness','Customer Service','negative'),
 ('SYN-FB-H017A','Product Quality','Performance','Performance','Product Quality','positive'),
 ('SYN-FB-H017A','Product Quality','Durability','Durability','Product Quality','negative'),
 ('SYN-FB-H017B','Product Quality','Performance','Performance','Product Quality','positive'),
 ('SYN-FB-H017B','Product Quality','Durability','Durability','Product Quality','negative'),
 ('SYN-FB-H017C','Product Quality','Performance','Performance','Product Quality','positive'),
 ('SYN-FB-H017C','Product Quality','Durability','Durability','Product Quality','negative'),
 ('SYN-FB-H018A','Product Quality',NULL,NULL,'Product Quality','positive'),
 ('SYN-FB-H018A','Shipping and Delivery','Delivery Speed','Delivery Time','Shipping and Delivery','positive'),
 ('SYN-FB-H018B','Product Quality',NULL,NULL,'Product Quality','positive'),
 ('SYN-FB-H018B','Shipping and Delivery','Delivery Speed','Delivery Time','Shipping and Delivery','positive'),
 ('SYN-FB-H018C','Product Quality',NULL,NULL,'Product Quality','positive'),
 ('SYN-FB-H018C','Shipping and Delivery','Delivery Speed','Delivery Time','Shipping and Delivery','positive'),
 ('SYN-FB-H019','Product Quality','Performance','Performance','Product Quality','negative'),
 ('SYN-FB-H019','Shipping and Delivery',NULL,NULL,'Shipping and Delivery','positive'),
 ('SYN-FB-H020','Product Quality','Performance','Performance','Product Quality','positive'),
 ('SYN-FB-H021','Product Quality','Performance','Performance','Product Quality','negative'),
 ('SYN-FB-H021','Product Quality','Performance','Performance','Product Quality','positive'),
 ('SYN-FB-H022','Price and Value','Good Value','Good Value','Price and Value','positive'),
 ('SYN-FB-H022','Product Quality','Materials and Build','Materials and Build','Product Quality','negative'),
 ('SYN-FB-H023',NULL,NULL,NULL,NULL,NULL),
 ('SYN-FB-H024','Product Quality','Durability','Durability','Product Quality','negative'),
 ('SYN-FB-H024','Customer Service','Response Time','Response Time','Customer Service','positive'),
 ('SYN-FB-H025','Product Quality','Materials and Build','Materials and Build','Product Quality','negative'),
 ('SYN-FB-H026','Product Quality','Performance','Performance','Product Quality','negative'),
 ('SYN-FB-H027','Returns and Refunds','Return Process','Return Process','Returns and Refunds','negative'),
 ('SYN-FB-H027','Website and App','Product Information Accuracy','Product Information Accuracy','Website and App','negative'),
 ('SYN-FB-H028','Product Quality','Performance','Performance','Product Quality','neutral'),
 ('SYN-FB-H029','Product Quality','Durability','Hinge Breakage','Product Quality','negative'),
 ('SYN-FB-H030','Website and App','Checkout','Checkout','Website and App','negative');

CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_HARD_ROW_LABELS (
    feedback_id             VARCHAR,
    case_role               VARCHAR,
    is_feedback             BOOLEAN,   -- FALSE for spam, off-topic, pre-sales questions
    canonical_feedback_id   VARCHAR,   -- differs from feedback_id for syndicated duplicates
    expected_sku            VARCHAR,   -- truth for entity linking when the source SKU is NULL
    expected_language       VARCHAR,   -- truth, regardless of what the source reported
    expected_return_intent  BOOLEAN,
    expected_overall        VARCHAR,
    expected_over_window    BOOLEAN    -- exceeds the AI_SENTIMENT 2,048-token window
);

INSERT INTO {{EVAL_SCHEMA}}.SYNTH_HARD_ROW_LABELS VALUES
 ('SYN-FB-H001','SARCASM',TRUE,'SYN-FB-H001','SYN-SKU-BL-100','en',FALSE,'negative',FALSE),
 ('SYN-FB-H002','SARCASM',TRUE,'SYN-FB-H002',NULL,'en',FALSE,'negative',FALSE),
 ('SYN-FB-H003','NEGATION',TRUE,'SYN-FB-H003','SYN-SKU-HP-100','en',FALSE,'positive',FALSE),
 ('SYN-FB-H004','NEGATION',TRUE,'SYN-FB-H004','SYN-SKU-EB-300','en',FALSE,'negative',FALSE),
 ('SYN-FB-H005','COMPARATIVE',TRUE,'SYN-FB-H005','SYN-SKU-HP-200','en',FALSE,'negative',FALSE),
 ('SYN-FB-H006','COMPARATIVE',TRUE,'SYN-FB-H006','SYN-SKU-JK-200','en',FALSE,'positive',FALSE),
 ('SYN-FB-H007','MIXED_ASPECTS',TRUE,'SYN-FB-H007','SYN-SKU-JK-100','en',FALSE,'mixed',FALSE),
 ('SYN-FB-H008','MIXED_WITHIN_ASPECT',TRUE,'SYN-FB-H008','SYN-SKU-BL-200','en',FALSE,'mixed',FALSE),
 ('SYN-FB-H009','OFF_TOPIC',FALSE,'SYN-FB-H009',NULL,'en',FALSE,'neutral',FALSE),
 ('SYN-FB-H010','SPAM',FALSE,'SYN-FB-H010',NULL,'en',FALSE,NULL,FALSE),
 ('SYN-FB-H011','SPAM',FALSE,'SYN-FB-H011',NULL,'en',FALSE,NULL,FALSE),
 ('SYN-FB-H012','SPAM',FALSE,'SYN-FB-H012',NULL,'en',FALSE,NULL,FALSE),
 ('SYN-FB-H013','NON_ENGLISH',TRUE,'SYN-FB-H013','SYN-SKU-KT-100','es',FALSE,'negative',FALSE),
 ('SYN-FB-H014','NON_ENGLISH_UNREPORTED',TRUE,'SYN-FB-H014','SYN-SKU-HP-100','fr',FALSE,'positive',FALSE),
 ('SYN-FB-H015','NON_ENGLISH_MISREPORTED',TRUE,'SYN-FB-H015','SYN-SKU-JK-100','de',FALSE,'negative',FALSE),
 ('SYN-FB-H016','OVER_WINDOW',TRUE,'SYN-FB-H016','SYN-SKU-BL-200','en',TRUE,'negative',TRUE),
 ('SYN-FB-H017A','SYNDICATED_CANONICAL',TRUE,'SYN-FB-H017A','SYN-SKU-KT-100','en',FALSE,'mixed',FALSE),
 ('SYN-FB-H017B','SYNDICATED_DUPLICATE',TRUE,'SYN-FB-H017A','SYN-SKU-KT-100','en',FALSE,'mixed',FALSE),
 ('SYN-FB-H017C','SYNDICATED_DUPLICATE',TRUE,'SYN-FB-H017A','SYN-SKU-KT-100','en',FALSE,'mixed',FALSE),
 ('SYN-FB-H018A','TEMPLATE_COLLISION',TRUE,'SYN-FB-H018A','SYN-SKU-FL-100','en',FALSE,'positive',FALSE),
 ('SYN-FB-H018B','TEMPLATE_COLLISION',TRUE,'SYN-FB-H018B','SYN-SKU-EB-300','en',FALSE,'positive',FALSE),
 ('SYN-FB-H018C','TEMPLATE_COLLISION',TRUE,'SYN-FB-H018C','SYN-SKU-BL-100','en',FALSE,'positive',FALSE),
 ('SYN-FB-H019','RATING_TEXT_MISMATCH',TRUE,'SYN-FB-H019','SYN-SKU-EB-300','en',FALSE,'mixed',FALSE),
 ('SYN-FB-H020','SKU_FROM_TEXT',TRUE,'SYN-FB-H020','SYN-SKU-HP-200','en',FALSE,'positive',FALSE),
 ('SYN-FB-H021','SKU_FROM_TEXT',TRUE,'SYN-FB-H021','SYN-SKU-BL-200','en',FALSE,'mixed',FALSE),
 ('SYN-FB-H022','ASPECT_AMBIGUITY',TRUE,'SYN-FB-H022','SYN-SKU-FL-100','en',FALSE,'negative',FALSE),
 ('SYN-FB-H023','PRESALES_QUESTION',FALSE,'SYN-FB-H023','SYN-SKU-HP-200','en',FALSE,'neutral',FALSE),
 ('SYN-FB-H024','RECOVERY',TRUE,'SYN-FB-H024','SYN-SKU-JK-100','en',FALSE,'positive',FALSE),
 ('SYN-FB-H025','RETURN_INTENT',TRUE,'SYN-FB-H025','SYN-SKU-HP-100','en',TRUE,'negative',FALSE),
 ('SYN-FB-H026','RETURN_INTENT',TRUE,'SYN-FB-H026','SYN-SKU-BL-100','en',TRUE,'negative',FALSE),
 ('SYN-FB-H027','RETURN_INTENT_CONTEMPLATED',TRUE,'SYN-FB-H027','SYN-SKU-JK-200','en',TRUE,'negative',FALSE),
 ('SYN-FB-H028','NEUTRAL',TRUE,'SYN-FB-H028','SYN-SKU-KT-100','en',FALSE,'neutral',FALSE),
 ('SYN-FB-H029','EMERGING_PRECURSOR',TRUE,'SYN-FB-H029','SYN-SKU-HP-200','en',FALSE,'negative',FALSE),
 ('SYN-FB-H030','SHOUTING',TRUE,'SYN-FB-H030',NULL,'en',FALSE,'negative',FALSE);

-- ---------------------------------------------------------------------
-- 7. Answer key (QUARANTINED). One topic table keyed by taxonomy version,
--    so a run on v1 and a run on v2 are each scored against the truth for
--    the taxonomy they actually used.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_LABEL_TOPICS AS
SELECT DISTINCT p.feedback_id, v.taxonomy_version, f.topic_l1,
       IFF(v.taxonomy_version = 'v1', f.topic_l2_v1, f.topic_l2_v2) AS topic_l2
FROM {{EVAL_SCHEMA}}.SYNTH_FEEDBACK_PLAN p
JOIN {{EVAL_SCHEMA}}.SYNTH_FRAGMENTS f ON f.fragment_id = p.fragment_id
CROSS JOIN (SELECT column1 AS taxonomy_version FROM VALUES ('v1'), ('v2')) v
UNION
SELECT DISTINCT h.feedback_id, v.taxonomy_version, h.topic_l1,
       IFF(v.taxonomy_version = 'v1', h.topic_l2_v1, h.topic_l2_v2)
FROM {{EVAL_SCHEMA}}.SYNTH_HARD_LABELS h
CROSS JOIN (SELECT column1 AS taxonomy_version FROM VALUES ('v1'), ('v2')) v
WHERE h.topic_l1 IS NOT NULL;

-- Aspect truth: positive + negative on one aspect in one row is 'mixed',
-- which is exactly what AI_SENTIMENT returns for that case.
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_LABEL_ASPECTS AS
WITH claims AS (
    SELECT p.feedback_id, f.aspect, f.sentiment
    FROM {{EVAL_SCHEMA}}.SYNTH_FEEDBACK_PLAN p
    JOIN {{EVAL_SCHEMA}}.SYNTH_FRAGMENTS f ON f.fragment_id = p.fragment_id
    UNION ALL
    SELECT feedback_id, aspect, sentiment
    FROM {{EVAL_SCHEMA}}.SYNTH_HARD_LABELS
    WHERE aspect IS NOT NULL
)
SELECT feedback_id, aspect,
       CASE WHEN COUNT_IF(sentiment = 'positive') > 0 AND COUNT_IF(sentiment = 'negative') > 0 THEN 'mixed'
            WHEN COUNT_IF(sentiment = 'positive') > 0 THEN 'positive'
            WHEN COUNT_IF(sentiment = 'negative') > 0 THEN 'negative'
            ELSE 'neutral' END AS expected_sentiment
FROM claims
GROUP BY 1, 2;

-- Row-level truth for every feedback row, background and hard.
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_LABEL_ROWS AS
WITH bg AS (
    SELECT p.feedback_id,
           ANY_VALUE(p.case_role) AS case_role,
           ANY_VALUE(p.sku)       AS expected_sku,
           COUNT_IF(f.sentiment = 'positive') AS pos,
           COUNT_IF(f.sentiment = 'negative') AS neg,
           MAX(f.emerging_theme)  AS emerging_theme
    FROM {{EVAL_SCHEMA}}.SYNTH_FEEDBACK_PLAN p
    JOIN {{EVAL_SCHEMA}}.SYNTH_FRAGMENTS f ON f.fragment_id = p.fragment_id
    GROUP BY 1
)
SELECT feedback_id, case_role, TRUE AS is_feedback, feedback_id AS canonical_feedback_id,
       expected_sku, 'en' AS expected_language,
       NULL::BOOLEAN AS expected_return_intent,      -- background rows are not labeled for return intent
       CASE WHEN pos > 0 AND neg > 0 THEN 'mixed' WHEN neg > 0 THEN 'negative' ELSE 'positive' END AS expected_overall,
       FALSE AS expected_over_window,
       emerging_theme
FROM bg
UNION ALL
SELECT feedback_id, case_role, is_feedback, canonical_feedback_id, expected_sku, expected_language,
       expected_return_intent, expected_overall, expected_over_window,
       IFF(feedback_id = 'SYN-FB-H029', 'HINGE', NULL)
FROM {{EVAL_SCHEMA}}.SYNTH_HARD_ROW_LABELS;

-- Emerging-theme truth: what a detector should surface, where, and from when.
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_LABEL_EMERGING (
    theme_key           VARCHAR,
    description         VARCHAR,
    topic_l1            VARCHAR,
    v2_topic_l2         VARCHAR,
    sku                 VARCHAR,   -- NULL means not SKU-specific
    region_code         VARCHAR,   -- NULL means not region-specific
    source_channel      VARCHAR,   -- NULL means all channels
    onset_week_start    DATE,      -- first week a detector could reasonably fire
    window_start        DATE
);

INSERT INTO {{EVAL_SCHEMA}}.SYNTH_LABEL_EMERGING VALUES
 ('HINGE', 'Folding hinge cracking or snapping on the Fold headphones', 'Product Quality', 'Hinge Breakage',
  'SYN-SKU-HP-200', 'SYN-EU', NULL,
  DATE_TRUNC('WEEK', DATEADD(DAY, 35, DATEADD(DAY, -111, '{{END_DATE}}'::DATE))),
  DATEADD(DAY, -111, '{{END_DATE}}'::DATE)),
 ('SUBSCRIPTION', 'Backlash against a new recurring subscription or membership fee', 'Price and Value', 'Subscription Fees',
  NULL, NULL, 'SOCIAL',
  DATE_TRUNC('WEEK', DATEADD(DAY, 63, DATEADD(DAY, -111, '{{END_DATE}}'::DATE))),
  DATEADD(DAY, -111, '{{END_DATE}}'::DATE));

-- ---------------------------------------------------------------------
-- 8. Weekly operational outcomes per SKU and region (pipeline-visible).
--    SYNTHETIC, for demonstrating the theme-to-outcome join only. These are
--    not benchmarks and must never appear in a value readout as if they
--    were a customer's numbers. Returns on SYN-SKU-HP-200 in SYN-EU rise
--    from week 6 so the join has something to find.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{SCHEMA}}.SYNTH_SKU_WEEKLY AS
WITH weeks AS (
    SELECT n + 1 AS week_idx,
           DATE_TRUNC('WEEK', DATEADD(DAY, n * 7, DATEADD(DAY, -111, '{{END_DATE}}'::DATE))) AS week_start
    -- ROW_NUMBER, not two SEQ4() calls: SEQ4 is not guaranteed gap-free.
    FROM (SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS n
          FROM TABLE(GENERATOR(ROWCOUNT => 16)))
)
SELECT p.sku, r.region_code, w.week_start,
       UNIFORM(150, 400, RANDOM()) AS units_sold,
       0 AS units_returned,
       0 AS support_contacts,
       w.week_idx
FROM {{SCHEMA}}.SYNTH_PRODUCTS p
CROSS JOIN {{SCHEMA}}.SYNTH_REGIONS r
CROSS JOIN weeks w;

UPDATE {{SCHEMA}}.SYNTH_SKU_WEEKLY
SET units_returned = ROUND(units_sold * (0.04 + UNIFORM(0, 30, RANDOM()) / 1000.0
                     + IFF(sku = 'SYN-SKU-HP-200' AND region_code = 'SYN-EU' AND week_idx >= 6,
                           (week_idx - 5) * 0.012, 0))),
    support_contacts = ROUND(units_sold * (0.06 + UNIFORM(0, 30, RANDOM()) / 1000.0));

ALTER TABLE {{SCHEMA}}.SYNTH_SKU_WEEKLY DROP COLUMN week_idx;
