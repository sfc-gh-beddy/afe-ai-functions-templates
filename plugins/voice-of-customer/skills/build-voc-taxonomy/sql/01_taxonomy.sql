-- =====================================================================
-- Versioned VoC taxonomy, label descriptions, few-shot examples, and the
-- version-to-version mapping that makes drift measurable.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}               target database
--   {{TAXONOMY_SCHEMA}}  schema for taxonomy objects (pipeline reads this)
--
-- Sandbox note: v1 and v2 below match the synthetic corpus. For a customer
-- build, replace the INSERTs with the customer's taxonomy (see SKILL.md,
-- "Bootstrapping from the customer's own data") and keep the structure.
--
-- Constraints honoured here, all from the AI_CLASSIFY reference:
--   * label descriptions <= 25 words
--   * task_description  <= 50 words
--   * keep each category list well under ~20 labels (accuracy degrades
--     beyond that), which is why classification is two-level
--   * labels are plain English, no abbreviations or codes
-- And from AI_SENTIMENT: aspect names <= 30 characters, <= 10 per call.
-- =====================================================================

USE DATABASE {{DB}};
CREATE SCHEMA IF NOT EXISTS {{TAXONOMY_SCHEMA}};
USE SCHEMA {{DB}}.{{TAXONOMY_SCHEMA}};

-- One row per L2 node per version. L1 attributes repeat per row; this keeps
-- the table flat and the version boundary explicit.
CREATE OR REPLACE TABLE VOC_TAXONOMY (
    taxonomy_version   VARCHAR      NOT NULL,
    topic_l1           VARCHAR      NOT NULL,
    topic_l1_desc      VARCHAR      NOT NULL,   -- <= 25 words
    topic_l2           VARCHAR      NOT NULL,
    topic_l2_desc      VARCHAR      NOT NULL,   -- <= 25 words
    aspect_name        VARCHAR      NOT NULL,   -- AI_SENTIMENT aspect, <= 30 chars
    business_owner     VARCHAR,                 -- who acts on this node
    lever              VARCHAR,                 -- REVENUE_PRODUCT | REVENUE_PRICING | REVENUE_RETENTION | OPEX_RETURNS | OPEX_SUPPORT
    is_active          BOOLEAN      DEFAULT TRUE,
    valid_from         DATE,
    valid_to           DATE,
    CONSTRAINT pk_voc_taxonomy PRIMARY KEY (taxonomy_version, topic_l1, topic_l2)
);

INSERT INTO VOC_TAXONOMY
    (taxonomy_version, topic_l1, topic_l1_desc, topic_l2, topic_l2_desc, aspect_name, business_owner, lever, valid_from)
SELECT 'v1', column1, column2, column3, column4, column5, column6, column7, CURRENT_DATE() FROM VALUES
 ('Product Quality','How well the product itself works, is built, and holds up over time.',
  'Durability','The product breaks, wears out, or stops working over time, or lasts well.','Product Quality','Product engineering','REVENUE_PRODUCT'),
 ('Product Quality','How well the product itself works, is built, and holds up over time.',
  'Performance','How well the product does its core job, such as sound, blending power, warmth or waterproofing.','Product Quality','Product engineering','REVENUE_PRODUCT'),
 ('Product Quality','How well the product itself works, is built, and holds up over time.',
  'Materials and Build','The feel, materials, construction and finish of the product.','Product Quality','Product engineering','REVENUE_PRODUCT'),
 ('Product Quality','How well the product itself works, is built, and holds up over time.',
  'Defective on Arrival','The product did not work at all when it was first received.','Product Quality','Quality assurance','OPEX_RETURNS'),
 ('Fit and Sizing','Whether clothing fits the way the customer expected from their usual size.',
  'Runs Small','The garment is smaller or tighter than the customer expected for the size ordered.','Fit and Sizing','Merchandising','OPEX_RETURNS'),
 ('Fit and Sizing','Whether clothing fits the way the customer expected from their usual size.',
  'Runs Large','The garment is bigger or looser than the customer expected for the size ordered.','Fit and Sizing','Merchandising','OPEX_RETURNS'),
 ('Fit and Sizing','Whether clothing fits the way the customer expected from their usual size.',
  'True to Size','The garment fits as the size chart or usual size suggested.','Fit and Sizing','Merchandising','OPEX_RETURNS'),
 ('Price and Value','The price paid, discounts, and whether the product felt worth the money.',
  'Too Expensive','The customer feels the price is too high for what they received.','Price and Value','Pricing','REVENUE_PRICING'),
 ('Price and Value','The price paid, discounts, and whether the product felt worth the money.',
  'Good Value','The customer feels the product is worth the price or cheaper than alternatives.','Price and Value','Pricing','REVENUE_PRICING'),
 ('Price and Value','The price paid, discounts, and whether the product felt worth the money.',
  'Promotions and Discounts','Sales, promo codes, coupons and discounts, including codes that failed to apply.','Price and Value','Marketing','REVENUE_PRICING'),
 ('Shipping and Delivery','Getting the order from the warehouse to the customer.',
  'Delivery Speed','How long delivery took compared with what was promised.','Shipping and Delivery','Logistics','REVENUE_RETENTION'),
 ('Shipping and Delivery','Getting the order from the warehouse to the customer.',
  'Damaged in Transit','The item or its box arrived damaged by shipping.','Shipping and Delivery','Logistics','OPEX_RETURNS'),
 ('Shipping and Delivery','Getting the order from the warehouse to the customer.',
  'Tracking','Order tracking information was missing, wrong, or did not update.','Shipping and Delivery','Logistics','OPEX_SUPPORT'),
 ('Customer Service','Interactions with support agents, chat, email or phone support.',
  'Agent Helpfulness','Whether support actually understood and solved the problem.','Customer Service','Customer support','OPEX_SUPPORT'),
 ('Customer Service','Interactions with support agents, chat, email or phone support.',
  'Response Time','How quickly support responded.','Customer Service','Customer support','OPEX_SUPPORT'),
 ('Returns and Refunds','Sending a product back and getting money back.',
  'Return Process','The steps, portal, labels or rules involved in returning an item.','Returns and Refunds','Reverse logistics','OPEX_RETURNS'),
 ('Returns and Refunds','Sending a product back and getting money back.',
  'Refund Delay','A refund was slow, missing, or incorrect after a return.','Returns and Refunds','Finance operations','OPEX_SUPPORT'),
 ('Packaging','The box, wrapping and materials the product shipped in.',
  'Excess Packaging','Too much packaging, plastic, or waste for the item.','Packaging','Operations','REVENUE_PRODUCT'),
 ('Packaging','The box, wrapping and materials the product shipped in.',
  'Packaging Quality','The presentation, protection or recyclability of the packaging.','Packaging','Operations','REVENUE_PRODUCT'),
 ('Website and App','The online store and mobile app used to browse and buy.',
  'Checkout','Problems or praise for paying and completing an order online.','Website and App','Digital','REVENUE_RETENTION'),
 ('Website and App','The online store and mobile app used to browse and buy.',
  'Product Information Accuracy','Product pages, specifications or policies that were wrong, missing or confusing.','Website and App','Digital','OPEX_RETURNS'),
 ('Other Feedback','Genuine customer feedback that does not fit any other topic.',
  'Unclassified','Customer feedback about the brand or product that matches no other topic.','Other Feedback','VoC program owner',NULL);

-- v2 = v1 with three governed changes. Each change is recorded in
-- VOC_TAXONOMY_MAP so results from either version stay comparable.
--   1. SPLIT   Product Quality > Durability   -> Durability + Hinge Breakage
--   2. SPLIT   Price and Value > Too Expensive -> Too Expensive + Subscription Fees
--   3. RENAME  Shipping and Delivery > Delivery Speed -> Delivery Time
INSERT INTO VOC_TAXONOMY
    (taxonomy_version, topic_l1, topic_l1_desc, topic_l2, topic_l2_desc, aspect_name, business_owner, lever, valid_from)
SELECT 'v2', topic_l1, topic_l1_desc,
       IFF(topic_l2 = 'Delivery Speed', 'Delivery Time', topic_l2),
       topic_l2_desc, aspect_name, business_owner, lever, CURRENT_DATE()
FROM VOC_TAXONOMY
WHERE taxonomy_version = 'v1';

INSERT INTO VOC_TAXONOMY
    (taxonomy_version, topic_l1, topic_l1_desc, topic_l2, topic_l2_desc, aspect_name, business_owner, lever, valid_from)
VALUES
 ('v2','Product Quality','How well the product itself works, is built, and holds up over time.',
  'Hinge Breakage','A folding hinge, joint or fold mechanism cracks, loosens or snaps.','Product Quality','Product engineering','OPEX_RETURNS',CURRENT_DATE()),
 ('v2','Price and Value','The price paid, discounts, and whether the product felt worth the money.',
  'Subscription Fees','Complaints or praise about recurring subscription, membership or paid feature fees.','Price and Value','Pricing','REVENUE_RETENTION',CURRENT_DATE());

-- Narrow the split parents' descriptions so the model can tell siblings apart.
UPDATE VOC_TAXONOMY
SET topic_l2_desc = 'The product breaks, wears out or stops working over time, excluding folding hinge failures.'
WHERE taxonomy_version = 'v2' AND topic_l2 = 'Durability';
UPDATE VOC_TAXONOMY
SET topic_l2_desc = 'The one-time purchase price feels too high, excluding recurring subscription or membership fees.'
WHERE taxonomy_version = 'v2' AND topic_l2 = 'Too Expensive';

-- Version map. relation:
--   SAME     identical node
--   RENAME   same meaning, new label (1:1, lossless)
--   SPLIT    old node is now covered by several new nodes (1:N; old -> new is ambiguous,
--            new -> old is exact). Trend lines must roll new nodes UP to the old one.
--   MERGE    several old nodes now one new node (N:1; old -> new is exact)
--   RETIRE   old node has no successor
CREATE OR REPLACE TABLE VOC_TAXONOMY_MAP (
    from_version  VARCHAR,
    from_l1       VARCHAR,
    from_l2       VARCHAR,
    to_version    VARCHAR,
    to_l1         VARCHAR,
    to_l2         VARCHAR,
    relation      VARCHAR
);

INSERT INTO VOC_TAXONOMY_MAP
SELECT 'v1', t1.topic_l1, t1.topic_l2, 'v2', t1.topic_l1,
       IFF(t1.topic_l2 = 'Delivery Speed', 'Delivery Time', t1.topic_l2),
       CASE WHEN t1.topic_l2 = 'Delivery Speed' THEN 'RENAME'
            WHEN t1.topic_l2 IN ('Durability', 'Too Expensive') THEN 'SPLIT'
            ELSE 'SAME' END
FROM VOC_TAXONOMY t1
WHERE t1.taxonomy_version = 'v1';

INSERT INTO VOC_TAXONOMY_MAP VALUES
 ('v1','Product Quality','Durability','v2','Product Quality','Hinge Breakage','SPLIT'),
 ('v1','Price and Value','Too Expensive','v2','Price and Value','Subscription Fees','SPLIT');

-- Few-shot examples, per version and level. Kept short: every example is
-- billed as input tokens on every AI_CLASSIFY call.
CREATE OR REPLACE TABLE VOC_TAXONOMY_EXAMPLES (
    taxonomy_version  VARCHAR,
    level             VARCHAR,      -- L1 | L2
    parent_l1         VARCHAR,      -- NULL for L1 examples
    example_input     VARCHAR,
    example_labels    ARRAY,
    explanation       VARCHAR
);

-- Examples are deliberately NOT copied from the sandbox fragments: an
-- example identical to a test row inflates accuracy and measures recall of
-- the prompt, not the classifier.
INSERT INTO VOC_TAXONOMY_EXAMPLES
SELECT 'v1', 'L1', NULL, column1, PARSE_JSON(column2)::ARRAY, column3 FROM VALUES
 ('The speaker crackles at high volume and the box was half the size I expected for the price.',
  '["Product Quality","Price and Value"]',
  'Crackling is a product performance problem; the price comparison is about value for money.'),
 ('Took ages to arrive and when I asked support where it was they never replied.',
  '["Shipping and Delivery","Customer Service"]',
  'Slow arrival is delivery; the unanswered question is a support response problem.'),
 ('Lovely gift box, and returning the spare one was easy.',
  '["Packaging","Returns and Refunds"]',
  'Gift box praise is packaging; the easy return is the return process.');

INSERT INTO VOC_TAXONOMY_EXAMPLES
SELECT 'v2', level, parent_l1, example_input, example_labels, explanation
FROM VOC_TAXONOMY_EXAMPLES WHERE taxonomy_version = 'v1';

INSERT INTO VOC_TAXONOMY_EXAMPLES
SELECT 'v2', 'L2', 'Product Quality', column1, PARSE_JSON(column2)::ARRAY, column3 FROM VALUES
 ('The joint where the arm folds now wobbles and squeaks.', '["Hinge Breakage"]',
  'A loosening fold joint is a hinge failure, not general wear.'),
 ('The coating peeled off the handle after a month.', '["Durability"]',
  'Peeling with use is wear over time and involves no hinge.');

-- ---------------------------------------------------------------------
-- Classifier-ready category arrays. The pipeline binds these instead of
-- re-assembling labels inline, so the categories that ran are exactly the
-- taxonomy rows for the pinned version.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW VOC_TAXONOMY_L1_CATEGORIES AS
SELECT taxonomy_version,
       ARRAY_AGG(OBJECT_CONSTRUCT('label', topic_l1, 'description', topic_l1_desc))
           WITHIN GROUP (ORDER BY topic_l1) AS categories,
       COUNT(*) AS n_categories
FROM (SELECT DISTINCT taxonomy_version, topic_l1, topic_l1_desc
      FROM VOC_TAXONOMY WHERE is_active)
GROUP BY taxonomy_version;

CREATE OR REPLACE VIEW VOC_TAXONOMY_L2_CATEGORIES AS
SELECT taxonomy_version, topic_l1,
       ARRAY_AGG(OBJECT_CONSTRUCT('label', topic_l2, 'description', topic_l2_desc))
           WITHIN GROUP (ORDER BY topic_l2) AS categories,
       COUNT(*) AS n_categories
FROM VOC_TAXONOMY
WHERE is_active
GROUP BY taxonomy_version, topic_l1;

CREATE OR REPLACE VIEW VOC_TAXONOMY_ASPECTS AS
SELECT taxonomy_version,
       ARRAY_AGG(DISTINCT aspect_name) WITHIN GROUP (ORDER BY aspect_name) AS aspects,
       COUNT(DISTINCT aspect_name) AS n_aspects
FROM VOC_TAXONOMY
WHERE is_active AND topic_l1 <> 'Other Feedback'
GROUP BY taxonomy_version;

CREATE OR REPLACE VIEW VOC_TAXONOMY_EXAMPLES_CFG AS
SELECT taxonomy_version, level, parent_l1,
       ARRAY_AGG(OBJECT_CONSTRUCT('input', example_input,
                                  'labels', example_labels,
                                  'explanation', explanation)) AS examples
FROM VOC_TAXONOMY_EXAMPLES
GROUP BY 1, 2, 3;

-- ---------------------------------------------------------------------
-- Contract checks. Run and show results; any non-zero row is a defect.
-- ---------------------------------------------------------------------
SELECT 'description_over_25_words' AS check_name, COUNT(*) AS bad
FROM VOC_TAXONOMY
WHERE ARRAY_SIZE(SPLIT(TRIM(topic_l2_desc), ' ')) > 25
   OR ARRAY_SIZE(SPLIT(TRIM(topic_l1_desc), ' ')) > 25
UNION ALL
SELECT 'aspect_name_over_30_chars', COUNT(*) FROM VOC_TAXONOMY WHERE LENGTH(aspect_name) > 30
UNION ALL
SELECT 'more_than_10_aspects_in_version', COUNT(*) FROM VOC_TAXONOMY_ASPECTS WHERE n_aspects > 10
UNION ALL
SELECT 'l1_list_over_20', COUNT(*) FROM VOC_TAXONOMY_L1_CATEGORIES WHERE n_categories > 20
UNION ALL
SELECT 'l2_list_over_20', COUNT(*) FROM VOC_TAXONOMY_L2_CATEGORIES WHERE n_categories > 20
UNION ALL
SELECT 'l2_list_under_2', COUNT(*) FROM VOC_TAXONOMY_L2_CATEGORIES
WHERE n_categories < 2 AND topic_l1 <> 'Other Feedback'
UNION ALL
SELECT 'duplicate_l2_label_across_l1', COUNT(*) FROM (
    SELECT taxonomy_version, topic_l2 FROM VOC_TAXONOMY
    GROUP BY 1, 2 HAVING COUNT(DISTINCT topic_l1) > 1)
UNION ALL
SELECT 'v1_node_without_v2_mapping', COUNT(*) FROM VOC_TAXONOMY t
WHERE t.taxonomy_version = 'v1'
  AND NOT EXISTS (SELECT 1 FROM VOC_TAXONOMY_MAP m
                  WHERE m.from_version = 'v1' AND m.from_l1 = t.topic_l1 AND m.from_l2 = t.topic_l2);
