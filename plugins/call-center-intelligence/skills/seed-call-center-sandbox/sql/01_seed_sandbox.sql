-- =====================================================================
-- Synthetic contact-center corpus with ground truth, for the
-- call-center-intelligence play.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}            target database
--   {{SCHEMA}}        sandbox schema (pipeline may read this)
--   {{EVAL_SCHEMA}}   answer-key schema (pipeline must NEVER read this)
--   {{CALL_COUNT}}    number of base calls, e.g. 600
--   {{REPEAT_SHARE}}  share of unresolved calls that generate a follow-up, e.g. 0.6
--   {{AUDIO_SHARE}}   share of calls with NO vendor transcript (audio-only), e.g. 0.25
--   {{FULLTEXT_SHARE}} share of transcript calls delivered as one full-text blob, e.g. 0.10
--   {{START_DATE}}    first call date, e.g. '2026-09-01'
--   {{MIN_CALL_SECONDS}} must equal definitions.min_call_seconds, e.g. 20
--
-- SYNTH_SCENARIOS (turn templates + labels) is created in {{EVAL_SCHEMA}}:
-- it is an answer key in disguise and the pipeline must not read it.
--
-- Every identifier is prefixed SYN- and every person is fabricated.
-- Planted PII uses formats that look real to a detector but are
-- synthetic: card numbers are published test numbers, phone numbers use
-- the fictional 555-01xx range, national IDs use the 9xx area range that
-- is never issued as an SSN. Do not replace these with anything real.
--
-- Contact-reason labels here MUST match the taxonomy seeded by
-- classify-contact-reasons (tax_v1). QA criterion ids MUST match the
-- generic rubric seeded by score-agent-qa (rub_v1).
-- =====================================================================

USE DATABASE {{DB}};
CREATE SCHEMA IF NOT EXISTS {{SCHEMA}};
CREATE SCHEMA IF NOT EXISTS {{EVAL_SCHEMA}};
USE SCHEMA {{DB}}.{{SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Agents and customers. Values are fabricated; monthly_value is a
--    sandbox placeholder for arithmetic only and is never shown as a
--    customer metric.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_AGENTS AS
SELECT 'SYN-AGT-' || LPAD(SEQ4() + 1, 3, '0')                         AS agent_id,
       ARRAY_CONSTRUCT('Riley','Jordan','Casey','Morgan','Avery','Quinn',
                       'Rowan','Sage','Emerson','Harper','Kendall','Reese')[SEQ4() % 12]::VARCHAR AS agent_first_name,
       ARRAY_CONSTRUCT('Care','Care','Care','Retention','Tech','Tech')[SEQ4() % 6]::VARCHAR        AS team,
       ARRAY_CONSTRUCT('0-6m','6-24m','24m+')[SEQ4() % 3]::VARCHAR     AS tenure_band
FROM TABLE(GENERATOR(ROWCOUNT => 24));

CREATE OR REPLACE TABLE SYNTH_CUSTOMERS AS
SELECT 'SYN-CUS-' || LPAD(SEQ4() + 1, 5, '0')                         AS customer_id,
       ARRAY_CONSTRUCT('Synthia','Testa','Mocky','Faux','Sample','Demo',
                       'Proxy','Dummy','Fictus','Placido','Nemo','Vera')[SEQ4() % 12]::VARCHAR  AS first_name,
       ARRAY_CONSTRUCT('Testerson','Exampleton','Fakely','Placeholder','Synthwood',
                       'Mockridge','Dataford','Sandbury','Nullman','Labelle')[SEQ4() % 10]::VARCHAR AS last_name,
       ARRAY_CONSTRUCT('Basic','Standard','Premium')[SEQ4() % 3]::VARCHAR AS plan,
       1 + (SEQ4() * 7) % 60                                         AS tenure_months,
       ARRAY_CONSTRUCT(30, 55, 90)[SEQ4() % 3]::NUMBER               AS monthly_value_placeholder
FROM TABLE(GENERATOR(ROWCOUNT => 900));

-- ---------------------------------------------------------------------
-- 2. Scenarios. Each is a hand-authored conversation with known labels.
--    Turn text uses placeholders substituted per call:
--      {{AGENT}} agent first name     {{CUST}} customer full name
--      {{PHONE}} phone digits          {{EMAIL}} email address
--      {{ADDR}}  street address        {{DOB}}   date of birth
--      {{CARD}}  card digits           {{CARD_WORDS}} card read out in words
--      {{NATID}} national id digits    {{PHONE_WORDS}} phone in words
--    case_role: STANDARD | BORDERLINE | DISTRACTOR | EXCLUDE
--    qa_expected: criterion_id -> 1..5, or null when NOT APPLICABLE.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_SCENARIOS (
    scenario_id          VARCHAR,
    weight               NUMBER,        -- relative frequency in the generated population
    case_role            VARCHAR,
    contact_reason       VARCHAR,
    secondary_reasons    ARRAY,
    resolved             BOOLEAN,
    self_service_candidate BOOLEAN,     -- reason+intent a self-service flow could handle
    transferred          BOOLEAN,
    supervisor_request   BOOLEAN,
    references_prior     BOOLEAN,
    cancel_intent        BOOLEAN,
    save_offer_made      BOOLEAN,
    save_outcome         VARCHAR,       -- ACCEPTED | DECLINED | UNDECIDED | NOT_OFFERED | NOT_APPLICABLE
    buying_signal        BOOLEAN,
    upsell_offered       BOOLEAN,
    upsell_outcome       VARCHAR,       -- ACCEPTED | DECLINED | UNDECIDED | NOT_OFFERED | NOT_APPLICABLE
    followup_scenario_id VARCHAR,       -- scenario used when this call generates a repeat
    opening_sentiment    VARCHAR,
    closing_sentiment    VARCHAR,
    qa_expected          VARIANT,
    turns                VARIANT
);

INSERT INTO {{EVAL_SCHEMA}}.SYNTH_SCENARIOS
SELECT 'BILL_DOUBLE_CHARGE', 12, 'STANDARD', 'Billing and payments', ARRAY_CONSTRUCT(),
       TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'negative', 'positive',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":5,"DISCOVERY":5,"ACCURACY":5,"RESOLUTION":5,"EMPATHY":5,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":5}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Thank you for calling, my name is {{AGENT}}. Who do I have the pleasure of speaking with today?"},
 {"r":"CUSTOMER","t":"Hi, this is {{CUST}}. I was charged twice for my subscription this month and I am pretty annoyed about it."},
 {"r":"AGENT","t":"I am sorry about that, a double charge is frustrating. Can you confirm the phone number on the account so I can pull it up?"},
 {"r":"CUSTOMER","t":"Sure, it is {{PHONE}}."},
 {"r":"AGENT","t":"Thank you. And for security, the email address on file?"},
 {"r":"CUSTOMER","t":"{{EMAIL}}."},
 {"r":"AGENT","t":"Perfect, you are verified. I can see two charges on the third of the month for the same amount. When did you first notice it?"},
 {"r":"CUSTOMER","t":"Yesterday when I checked my bank statement."},
 {"r":"AGENT","t":"The second charge was a duplicate from a payment retry. I have refunded it now. It will take three to five business days to show on your statement."},
 {"r":"CUSTOMER","t":"Okay, that is a relief. Thank you for sorting it out so quickly."},
 {"r":"AGENT","t":"Of course. I have also added a note so the retry does not happen again. Is there anything else I can help with today?"},
 {"r":"CUSTOMER","t":"No, that is everything."},
 {"r":"AGENT","t":"Thanks for your patience, {{CUST}}. Have a great day."}
]$$)
UNION ALL
SELECT 'BILL_LATE_FEE_POOR', 8, 'STANDARD', 'Billing and payments', ARRAY_CONSTRUCT(),
       FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', 'BILL_LATE_FEE_FOLLOWUP',
       'negative', 'negative',
       PARSE_JSON($${"GREETING":2,"VERIFICATION":3,"DISCOVERY":1,"ACCURACY":2,"RESOLUTION":1,"EMPATHY":1,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":1}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Billing."},
 {"r":"CUSTOMER","t":"Hi, I got a late fee on my bill but I paid on time. My name is {{CUST}}."},
 {"r":"AGENT","t":"Phone number on the account."},
 {"r":"CUSTOMER","t":"{{PHONE}}."},
 {"r":"AGENT","t":"Yeah, it shows the payment came in late so the fee stands."},
 {"r":"CUSTOMER","t":"But I paid on the due date. I have the confirmation. Can you not look at it?"},
 {"r":"AGENT","t":"Payments take a day to post. That is in the terms. There is nothing I can do."},
 {"r":"CUSTOMER","t":"Nobody told me that. This is really unfair."},
 {"r":"AGENT","t":"You can submit a dispute online if you want."},
 {"r":"CUSTOMER","t":"Fine. I guess I will call back."},
 {"r":"AGENT","t":"Okay. Bye."}
]$$)
UNION ALL
SELECT 'BILL_LATE_FEE_FOLLOWUP', 0, 'STANDARD', 'Billing and payments', ARRAY_CONSTRUCT('Complaint about service'),
       TRUE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'negative', 'neutral',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":5,"DISCOVERY":4,"ACCURACY":5,"RESOLUTION":5,"EMPATHY":4,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":4}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Thanks for calling, this is {{AGENT}}, how can I help?"},
 {"r":"CUSTOMER","t":"I called a few days ago about a late fee and the person just told me to dispute it online. I still have the fee."},
 {"r":"AGENT","t":"I am sorry you had to call back. Let me look. Can I get your name and the phone number on the account?"},
 {"r":"CUSTOMER","t":"{{CUST}}, {{PHONE}}."},
 {"r":"AGENT","t":"Thank you. I see the previous note. Your payment was made on the due date, it just posted the next morning. That should not trigger a fee."},
 {"r":"CUSTOMER","t":"That is what I said last time."},
 {"r":"AGENT","t":"You were right. I have removed the late fee and the credit shows on your next bill. I will also flag the earlier interaction for review."},
 {"r":"CUSTOMER","t":"Okay. Thank you for actually fixing it."},
 {"r":"AGENT","t":"Anything else today?"},
 {"r":"CUSTOMER","t":"No, that is it."}
]$$)
UNION ALL
SELECT 'CANCEL_SAVED', 6, 'STANDARD', 'Cancel or downgrade', ARRAY_CONSTRUCT(),
       TRUE, FALSE, TRUE, FALSE, FALSE, TRUE, TRUE, 'ACCEPTED', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'negative', 'positive',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":5,"DISCOVERY":5,"ACCURACY":5,"RESOLUTION":5,"EMPATHY":5,"RETENTION_SALES":5,"COMPLIANCE":5,"CLOSING":5}$$),
       PARSE_JSON($$[
 {"r":"IVR","t":"Please hold while we connect you to the retention team."},
 {"r":"AGENT","t":"Hi, you have reached the account team, my name is {{AGENT}}. May I have your name?"},
 {"r":"CUSTOMER","t":"{{CUST}}. I want to cancel my subscription."},
 {"r":"AGENT","t":"I can help with that. To verify, can you give me your date of birth?"},
 {"r":"CUSTOMER","t":"{{DOB}}."},
 {"r":"AGENT","t":"Thank you. Before I process anything, may I ask what is making you want to leave?"},
 {"r":"CUSTOMER","t":"Honestly it is the price. It went up and I found something cheaper."},
 {"r":"AGENT","t":"That makes sense. Since you have been with us for a while, I can offer thirty percent off for the next twelve months, which would bring you below what you paid before the increase."},
 {"r":"CUSTOMER","t":"Thirty percent for a year? Okay, that I would stay for."},
 {"r":"AGENT","t":"Great. Just so you know, the discounted rate renews at the standard price after twelve months and you can cancel any time. Do you agree to that change?"},
 {"r":"CUSTOMER","t":"Yes, I agree."},
 {"r":"AGENT","t":"Done. You will get an email confirmation. Thank you for staying with us, {{CUST}}."}
]$$)
UNION ALL
SELECT 'CANCEL_NO_OFFER', 6, 'STANDARD', 'Cancel or downgrade', ARRAY_CONSTRUCT(),
       TRUE, FALSE, FALSE, FALSE, FALSE, TRUE, FALSE, 'NOT_OFFERED', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'neutral', 'neutral',
       PARSE_JSON($${"GREETING":4,"VERIFICATION":4,"DISCOVERY":1,"ACCURACY":4,"RESOLUTION":4,"EMPATHY":3,"RETENTION_SALES":1,"COMPLIANCE":3,"CLOSING":3}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Thank you for calling, this is {{AGENT}}."},
 {"r":"CUSTOMER","t":"Hi, I need to cancel my account. It is {{CUST}}."},
 {"r":"AGENT","t":"Sure. What is the phone number on the account?"},
 {"r":"CUSTOMER","t":"{{PHONE}}."},
 {"r":"AGENT","t":"Okay, I have it. I will go ahead and cancel that for you."},
 {"r":"CUSTOMER","t":"Thanks. It has just gotten too expensive for what I use."},
 {"r":"AGENT","t":"Understood. The cancellation is effective at the end of the billing period."},
 {"r":"CUSTOMER","t":"Okay."},
 {"r":"AGENT","t":"Anything else?"},
 {"r":"CUSTOMER","t":"No."}
]$$)
UNION ALL
SELECT 'CANCEL_DECLINED', 4, 'STANDARD', 'Cancel or downgrade', ARRAY_CONSTRUCT(),
       TRUE, FALSE, FALSE, FALSE, FALSE, TRUE, TRUE, 'DECLINED', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'neutral', 'neutral',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":5,"DISCOVERY":4,"ACCURACY":5,"RESOLUTION":5,"EMPATHY":4,"RETENTION_SALES":4,"COMPLIANCE":5,"CLOSING":5}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Good afternoon, thanks for calling, you are speaking with {{AGENT}}."},
 {"r":"CUSTOMER","t":"Hello, I am moving abroad so I need to cancel. My name is {{CUST}}."},
 {"r":"AGENT","t":"Congratulations on the move. Can you verify your address on file for me?"},
 {"r":"CUSTOMER","t":"{{ADDR}}."},
 {"r":"AGENT","t":"Thank you. Would pausing the account for up to six months help instead, so you keep your history and rate?"},
 {"r":"CUSTOMER","t":"No, I will be gone for at least three years. I just want to close it."},
 {"r":"AGENT","t":"Completely understand. I have closed the account effective today and there are no further charges. You will get a confirmation email."},
 {"r":"CUSTOMER","t":"Great, thanks for making it easy."},
 {"r":"AGENT","t":"Safe travels, {{CUST}}."}
]$$)
UNION ALL
SELECT 'TECH_OUTAGE_ESCALATED', 8, 'STANDARD', 'Technical support', ARRAY_CONSTRUCT('Complaint about service'),
       FALSE, FALSE, TRUE, TRUE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', 'TECH_OUTAGE_FOLLOWUP',
       'negative', 'negative',
       PARSE_JSON($${"GREETING":4,"VERIFICATION":4,"DISCOVERY":3,"ACCURACY":3,"RESOLUTION":2,"EMPATHY":2,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":3}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Technical support, this is {{AGENT}}, can I start with your name?"},
 {"r":"CUSTOMER","t":"{{CUST}}. My service has been down for two days and this is the third time this month. I work from home, this is not okay."},
 {"r":"AGENT","t":"Let me check. What is the phone number on the account?"},
 {"r":"CUSTOMER","t":"{{PHONE_WORDS}}."},
 {"r":"AGENT","t":"Okay. Have you tried restarting the equipment?"},
 {"r":"CUSTOMER","t":"Yes, obviously, five times. Every time I call I get told to restart it."},
 {"r":"AGENT","t":"I see there is an area outage. I do not have a time for the fix yet."},
 {"r":"CUSTOMER","t":"Then I want to speak to a supervisor right now."},
 {"r":"AGENT","t":"Okay, I will transfer you to my supervisor. Please hold."},
 {"r":"CUSTOMER","t":"Fine."}
]$$)
UNION ALL
SELECT 'TECH_OUTAGE_FOLLOWUP', 0, 'STANDARD', 'Technical support', ARRAY_CONSTRUCT(),
       TRUE, FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'negative', 'neutral',
       PARSE_JSON($${"GREETING":4,"VERIFICATION":4,"DISCOVERY":4,"ACCURACY":5,"RESOLUTION":4,"EMPATHY":5,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":4}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Hello, technical support, {{AGENT}} speaking."},
 {"r":"CUSTOMER","t":"I am calling again about the outage. I spoke to a supervisor on my last call and was promised a credit."},
 {"r":"AGENT","t":"I am really sorry for the trouble this week. May I have your name and phone number?"},
 {"r":"CUSTOMER","t":"{{CUST}}, {{PHONE}}."},
 {"r":"AGENT","t":"Thank you. The outage was fixed this morning. I can see the supervisor note, and I have applied a credit for the four days the service was down."},
 {"r":"CUSTOMER","t":"Okay. It is working now, I just want to make sure the credit is there."},
 {"r":"AGENT","t":"It is on the account and will show on the next bill. I have also set an alert so you get a text if there is an outage in your area."},
 {"r":"CUSTOMER","t":"That helps, thanks."}
]$$)
UNION ALL
SELECT 'TECH_SLOW_UPSELL', 6, 'STANDARD', 'Technical support', ARRAY_CONSTRUCT('Plan change or upgrade'),
       TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', TRUE, TRUE, 'ACCEPTED', NULL,
       'neutral', 'positive',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":5,"DISCOVERY":5,"ACCURACY":5,"RESOLUTION":5,"EMPATHY":4,"RETENTION_SALES":5,"COMPLIANCE":5,"CLOSING":5}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Thanks for calling technical support, this is {{AGENT}}. Who am I speaking with?"},
 {"r":"CUSTOMER","t":"{{CUST}}. Everything gets really slow in the evenings when the kids are all streaming."},
 {"r":"AGENT","t":"Let me take a look. Can you confirm the email on the account?"},
 {"r":"CUSTOMER","t":"{{EMAIL}}."},
 {"r":"AGENT","t":"Thanks. Your line is healthy, but you are on the Basic plan and you have six devices active at once in the evening, which is more than that plan is sized for."},
 {"r":"CUSTOMER","t":"Is there something faster? I would pay a bit more if it actually fixed it."},
 {"r":"AGENT","t":"The Standard plan doubles the speed and is twenty dollars more per month. There is no contract and you can change back any time."},
 {"r":"CUSTOMER","t":"Okay, let us do that."},
 {"r":"AGENT","t":"Done. The new monthly price will show on your next bill and you agreed to the plan change today. The speed change takes effect within an hour."},
 {"r":"CUSTOMER","t":"Perfect, thank you."}
]$$)
UNION ALL
SELECT 'ACCOUNT_LOCKED', 8, 'STANDARD', 'Account access', ARRAY_CONSTRUCT(),
       TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'negative', 'positive',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":5,"DISCOVERY":4,"ACCURACY":5,"RESOLUTION":5,"EMPATHY":4,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":5}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Hi, thanks for calling, my name is {{AGENT}}. How can I help?"},
 {"r":"CUSTOMER","t":"I am locked out of my online account. I tried resetting the password three times."},
 {"r":"AGENT","t":"Let us get you back in. Can I have your full name, date of birth, and the last four of your national ID?"},
 {"r":"CUSTOMER","t":"{{CUST}}, born {{DOB}}, and my ID is {{NATID}}, sorry, you only needed the last four."},
 {"r":"AGENT","t":"No problem, you are verified. I see the account was locked after too many attempts. I have unlocked it and sent a reset link to the email on file."},
 {"r":"CUSTOMER","t":"Is that still {{EMAIL}}?"},
 {"r":"AGENT","t":"Yes, that is the one. The link is valid for thirty minutes."},
 {"r":"CUSTOMER","t":"Got it, I am in. Thank you."},
 {"r":"AGENT","t":"You are welcome. Have a good day."}
]$$)
UNION ALL
SELECT 'PAYMENT_BY_PHONE', 6, 'STANDARD', 'Billing and payments', ARRAY_CONSTRUCT(),
       TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'neutral', 'positive',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":5,"DISCOVERY":4,"ACCURACY":5,"RESOLUTION":5,"EMPATHY":4,"RETENTION_SALES":null,"COMPLIANCE":2,"CLOSING":5}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Thank you for calling, this is {{AGENT}}, may I have your name?"},
 {"r":"CUSTOMER","t":"{{CUST}}. I want to pay my balance by card."},
 {"r":"AGENT","t":"Happy to help. Can you confirm your address on the account?"},
 {"r":"CUSTOMER","t":"{{ADDR}}."},
 {"r":"AGENT","t":"Thank you. Your balance is eighty-four dollars. Go ahead with the card number when you are ready."},
 {"r":"CUSTOMER","t":"It is {{CARD_WORDS}}, expiry twelve twenty-eight."},
 {"r":"AGENT","t":"Let me read that back, {{CARD}}. And the security code on the back?"},
 {"r":"CUSTOMER","t":"Three two one."},
 {"r":"AGENT","t":"The payment of eighty-four dollars went through. Your confirmation number is in your email."},
 {"r":"CUSTOMER","t":"Great, thanks."},
 {"r":"AGENT","t":"Anything else I can help with? No? Have a great day."}
]$$)
UNION ALL
SELECT 'ORDER_STATUS', 10, 'STANDARD', 'Order and delivery', ARRAY_CONSTRUCT(),
       TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'neutral', 'positive',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":4,"DISCOVERY":4,"ACCURACY":5,"RESOLUTION":5,"EMPATHY":4,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":5}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Thanks for calling, this is {{AGENT}}. What can I do for you?"},
 {"r":"CUSTOMER","t":"Hi, I ordered a new router last week and wanted to know when it is arriving."},
 {"r":"AGENT","t":"Sure, can I have the phone number on the order?"},
 {"r":"CUSTOMER","t":"{{PHONE}}."},
 {"r":"AGENT","t":"Thank you {{CUST}}. It shipped yesterday and is scheduled for delivery on Thursday. You can also track it with the link in your order email."},
 {"r":"CUSTOMER","t":"Oh I did not see that link. Okay, Thursday works."},
 {"r":"AGENT","t":"Great, anything else?"},
 {"r":"CUSTOMER","t":"No, thanks."}
]$$)
UNION ALL
SELECT 'PLAN_UPGRADE_INBOUND', 5, 'STANDARD', 'Plan change or upgrade', ARRAY_CONSTRUCT(),
       TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', TRUE, TRUE, 'ACCEPTED', NULL,
       'positive', 'positive',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":5,"DISCOVERY":4,"ACCURACY":5,"RESOLUTION":5,"EMPATHY":4,"RETENTION_SALES":4,"COMPLIANCE":5,"CLOSING":5}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Good morning, this is {{AGENT}}, how can I help today?"},
 {"r":"CUSTOMER","t":"Hi, I would like to add the premium sports package to my plan. My name is {{CUST}}."},
 {"r":"AGENT","t":"Sounds good. Can you confirm the email address on the account?"},
 {"r":"CUSTOMER","t":"{{EMAIL}}."},
 {"r":"AGENT","t":"Thanks. The sports package is fifteen dollars a month. Since you are also on Standard, moving to Premium includes sports and is only ten dollars more than adding the package alone. Would you like that instead?"},
 {"r":"CUSTOMER","t":"Oh, Premium then, if it includes everything."},
 {"r":"AGENT","t":"Done. You have agreed to the Premium plan at the new monthly price starting next cycle, and you can change plans any time."},
 {"r":"CUSTOMER","t":"Perfect."}
]$$)
UNION ALL
SELECT 'DISTRACTOR_CANCEL_APPOINTMENT', 5, 'DISTRACTOR', 'Technical support', ARRAY_CONSTRUCT(),
       TRUE, TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'neutral', 'positive',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":4,"DISCOVERY":4,"ACCURACY":5,"RESOLUTION":5,"EMPATHY":4,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":5}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Thank you for calling, this is {{AGENT}}."},
 {"r":"CUSTOMER","t":"Hi, I need to cancel. I have a technician appointment tomorrow and I will not be home, can we cancel it and rebook?"},
 {"r":"AGENT","t":"Of course. What is the phone number on the account?"},
 {"r":"CUSTOMER","t":"{{PHONE}}, under {{CUST}}."},
 {"r":"AGENT","t":"Got it. I have cancelled tomorrow's appointment. I have Monday morning or Tuesday afternoon available."},
 {"r":"CUSTOMER","t":"Tuesday afternoon please."},
 {"r":"AGENT","t":"You are booked for Tuesday between one and five. You will get a text reminder."},
 {"r":"CUSTOMER","t":"Thanks so much."}
]$$)
UNION ALL
SELECT 'DISTRACTOR_DISCOUNT_HEARSAY', 4, 'DISTRACTOR', 'Billing and payments', ARRAY_CONSTRUCT(),
       TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_OFFERED', NULL,
       'neutral', 'neutral',
       PARSE_JSON($${"GREETING":4,"VERIFICATION":4,"DISCOVERY":4,"ACCURACY":5,"RESOLUTION":4,"EMPATHY":4,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":4}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Thanks for calling, {{AGENT}} speaking."},
 {"r":"CUSTOMER","t":"Hi, my neighbor said she got a discount by calling in, and I was told on a forum I could get one too. Is that true? I am {{CUST}}."},
 {"r":"AGENT","t":"Let me check your account. Can I have the phone number?"},
 {"r":"CUSTOMER","t":"{{PHONE}}."},
 {"r":"AGENT","t":"Thank you. There are no promotions on your plan right now. Promotions are sometimes tied to specific plans or new sign-ups."},
 {"r":"CUSTOMER","t":"Okay, I figured. No worries, I am happy with the service anyway."},
 {"r":"AGENT","t":"Glad to hear it. Anything else?"},
 {"r":"CUSTOMER","t":"No, that is all."}
]$$)
UNION ALL
SELECT 'COMPLAINT_SUPERVISOR_UNAVAILABLE', 4, 'BORDERLINE', 'Complaint about service', ARRAY_CONSTRUCT('Technical support'),
       FALSE, FALSE, FALSE, TRUE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', 'TECH_OUTAGE_FOLLOWUP',
       'negative', 'negative',
       PARSE_JSON($${"GREETING":4,"VERIFICATION":4,"DISCOVERY":4,"ACCURACY":4,"RESOLUTION":2,"EMPATHY":4,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":3}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Thank you for calling, this is {{AGENT}}."},
 {"r":"CUSTOMER","t":"I want to make a complaint. The technician who came out was two hours late and left without fixing anything. I want a manager."},
 {"r":"AGENT","t":"I am sorry, that is not the experience we want. Can I get your name and phone number?"},
 {"r":"CUSTOMER","t":"{{CUST}}, {{PHONE}}."},
 {"r":"AGENT","t":"Thank you. My supervisor is not available right now, but I have logged a formal complaint and requested a callback from a manager within one business day."},
 {"r":"CUSTOMER","t":"So nobody can help me right now."},
 {"r":"AGENT","t":"I can rebook the technician for the first slot tomorrow morning while you wait for the callback. Would that help?"},
 {"r":"CUSTOMER","t":"Fine, book it. But I expect that call."}
]$$)
UNION ALL
SELECT 'MULTI_BILLING_AND_ORDER', 4, 'BORDERLINE', 'Billing and payments', ARRAY_CONSTRUCT('Order and delivery'),
       TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'neutral', 'positive',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":5,"DISCOVERY":5,"ACCURACY":5,"RESOLUTION":5,"EMPATHY":4,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":5}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Hello, this is {{AGENT}}, how can I help?"},
 {"r":"CUSTOMER","t":"I have a question about a charge on my bill for equipment, and also when that equipment is actually arriving."},
 {"r":"AGENT","t":"Sure, I can cover both. Your name and the email on the account?"},
 {"r":"CUSTOMER","t":"{{CUST}}, {{EMAIL}}."},
 {"r":"AGENT","t":"Thanks. The charge is the one-time equipment fee you agreed to when ordering. The equipment itself ships tomorrow and arrives within two days."},
 {"r":"CUSTOMER","t":"Okay, that makes sense on both."},
 {"r":"AGENT","t":"Anything else?"},
 {"r":"CUSTOMER","t":"No, thank you."}
]$$)
UNION ALL
SELECT 'MISROUTED_OTHER', 3, 'STANDARD', 'Other', ARRAY_CONSTRUCT(),
       TRUE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'neutral', 'neutral',
       PARSE_JSON($${"GREETING":5,"VERIFICATION":null,"DISCOVERY":4,"ACCURACY":5,"RESOLUTION":4,"EMPATHY":4,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":4}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Thanks for calling, this is {{AGENT}}."},
 {"r":"CUSTOMER","t":"Hi, is this the pharmacy? I am trying to refill a prescription."},
 {"r":"AGENT","t":"I am afraid you have reached a subscription services company, not a pharmacy. It sounds like the number may have been misdialed."},
 {"r":"CUSTOMER","t":"Oh, sorry about that."},
 {"r":"AGENT","t":"No problem at all. Have a good day."}
]$$)
UNION ALL
SELECT 'SHORT_ABANDON', 3, 'EXCLUDE', 'Other', ARRAY_CONSTRUCT(),
       FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, FALSE, 'NOT_APPLICABLE', FALSE, FALSE, 'NOT_APPLICABLE', NULL,
       'neutral', 'neutral',
       PARSE_JSON($${"GREETING":null,"VERIFICATION":null,"DISCOVERY":null,"ACCURACY":null,"RESOLUTION":null,"EMPATHY":null,"RETENTION_SALES":null,"COMPLIANCE":null,"CLOSING":null}$$),
       PARSE_JSON($$[
 {"r":"AGENT","t":"Thank you for calling, this is {{AGENT}}, hello?"},
 {"r":"CUSTOMER","t":"Hello? I cannot hear..."}
]$$);

-- ---------------------------------------------------------------------
-- 3. Base call population. Scenario chosen by weighted bucket so the
--    reason distribution is long-tailed like a real queue.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_SCENARIO_BUCKETS AS
SELECT scenario_id,
       COALESCE(SUM(weight) OVER (ORDER BY scenario_id ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0) AS lo,
       SUM(weight) OVER (ORDER BY scenario_id ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS hi,
       SUM(weight) OVER ()                                                                     AS total
FROM {{EVAL_SCHEMA}}.SYNTH_SCENARIOS
WHERE weight > 0;

CREATE OR REPLACE TABLE SYNTH_CALLS_BASE AS
WITH g AS (
    SELECT SEQ4() AS n,
           UNIFORM(0, 1000000, RANDOM(42)) AS r1,
           UNIFORM(0, 1000000, RANDOM(43)) AS r2,
           UNIFORM(0, 1000000, RANDOM(44)) AS r3
    FROM TABLE(GENERATOR(ROWCOUNT => {{CALL_COUNT}}))
)
SELECT 'SYN-CALL-' || LPAD(g.n + 1, 6, '0')                               AS call_id,
       b.scenario_id,
       c.customer_id,
       a.agent_id,
       DATEADD(minute, (g.n * 53) % (60 * 24 * 21),
               TO_TIMESTAMP_NTZ('{{START_DATE}}'))                         AS call_start_ts,
       g.r2, g.r3
FROM g
JOIN SYNTH_SCENARIO_BUCKETS b
  ON (g.r1 % b.total) >= b.lo AND (g.r1 % b.total) < b.hi
JOIN (SELECT customer_id, ROW_NUMBER() OVER (ORDER BY customer_id) - 1 AS k FROM SYNTH_CUSTOMERS) c
  ON c.k = (g.n * 7919) % 900
JOIN (SELECT agent_id, ROW_NUMBER() OVER (ORDER BY agent_id) - 1 AS k FROM SYNTH_AGENTS) a
  ON a.k = (g.r2 % 24);

-- Follow-up (repeat) calls: unresolved scenarios generate a second call
-- from the same customer 1-5 days later, using the follow-up scenario.
CREATE OR REPLACE TABLE SYNTH_CALLS_FOLLOWUP AS
SELECT 'SYN-CALL-F' || SUBSTR(cb.call_id, 10)                          AS call_id,
       s.followup_scenario_id                                          AS scenario_id,
       cb.customer_id,
       a.agent_id,
       DATEADD(hour, 24 + (cb.r3 % 96), cb.call_start_ts)              AS call_start_ts,
       cb.call_id                                                      AS prior_call_id
FROM SYNTH_CALLS_BASE cb
JOIN {{EVAL_SCHEMA}}.SYNTH_SCENARIOS s ON s.scenario_id = cb.scenario_id
JOIN (SELECT agent_id, ROW_NUMBER() OVER (ORDER BY agent_id) - 1 AS k FROM SYNTH_AGENTS) a
  ON a.k = (cb.r3 % 24)
WHERE s.followup_scenario_id IS NOT NULL
  AND (cb.r2 % 1000) < 1000 * {{REPEAT_SHARE}};

-- ---------------------------------------------------------------------
-- 4. Call detail records (the metadata table the pipeline maps).
--    Disposition is deliberately noisy: correct about 60% of the time,
--    otherwise a generic code, to mirror agent-selected dispositions.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_CALL_DETAIL_RECORDS AS
WITH all_calls AS (
    SELECT call_id, scenario_id, customer_id, agent_id, call_start_ts, NULL::VARCHAR AS prior_call_id
    FROM SYNTH_CALLS_BASE
    UNION ALL
    SELECT call_id, scenario_id, customer_id, agent_id, call_start_ts, prior_call_id
    FROM SYNTH_CALLS_FOLLOWUP
),
words AS (
    SELECT s.scenario_id,
           SUM(ARRAY_SIZE(SPLIT(t.value:t::STRING, ' '))) AS word_count,
           COUNT_IF(t.value:r::STRING = 'IVR') > 0       AS has_ivr
    FROM {{EVAL_SCHEMA}}.SYNTH_SCENARIOS s, LATERAL FLATTEN(input => s.turns) t
    GROUP BY 1
)
SELECT ac.call_id,
       ac.customer_id,
       ac.agent_id,
       CASE WHEN s.contact_reason = 'Cancel or downgrade' OR s.transferred THEN 'Retention'
            WHEN s.contact_reason = 'Technical support' THEN 'Tech'
            ELSE 'Care' END                                                  AS queue_name,
       ac.call_start_ts,
       -- Spoken-English pace ~2.5 words/s plus think time; IVR adds a fixed prefix.
       ROUND(w.word_count / 2.5 * 1.6) + IFF(w.has_ivr, 25, 8)                 AS recording_seconds,
       ROUND(w.word_count / 2.5 * 1.6) + 45 + ABS(HASH(ac.call_id)) % 90    AS handle_seconds,
       IFF(s.scenario_id IN ('TECH_OUTAGE_ESCALATED','PAYMENT_BY_PHONE','BILL_DOUBLE_CHARGE'),
           30 + ABS(HASH(ac.call_id)) % 60, 0)                           AS hold_seconds,
       s.transferred                                                         AS was_transferred,
       CASE WHEN ABS(HASH(ac.call_id, 'disp')) % 10 < 6
            THEN UPPER(REPLACE(s.contact_reason, ' ', '_'))
            ELSE ARRAY_CONSTRUCT('GENERAL', 'OTHER', 'RESOLVED')[ABS(HASH(ac.call_id)) % 3]::VARCHAR
       END                                                                   AS disposition_code,
       'en'                                                                  AS language_code,
       -- Calls with no vendor transcript are the audio-only set.
       (ABS(HASH(ac.call_id, 'audio')) % 1000) < 1000 * {{AUDIO_SHARE}} AS audio_only,
       'synth/' || ac.call_id || '.wav'                                     AS recording_path
FROM all_calls ac
JOIN {{EVAL_SCHEMA}}.SYNTH_SCENARIOS s ON s.scenario_id = ac.scenario_id
JOIN words w ON w.scenario_id = ac.scenario_id;

-- Hidden mapping of call -> scenario. Lives in the EVAL schema.
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_CALL_SCENARIO AS
SELECT call_id, scenario_id, NULL::VARCHAR AS prior_call_id FROM SYNTH_CALLS_BASE
UNION ALL
SELECT call_id, scenario_id, prior_call_id FROM SYNTH_CALLS_FOLLOWUP;

-- ---------------------------------------------------------------------
-- 5. Per-call fabricated PII values. Formats chosen so a detector should
--    fire, values chosen so they belong to no one.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_CALL_PII_VALUES AS
WITH base AS (
    SELECT d.call_id,
           cu.first_name || ' ' || cu.last_name                                    AS cust,
           ag.agent_first_name                                                     AS agent,
           '555-01' || LPAD((ABS(HASH(d.call_id, 'p')) % 100)::VARCHAR, 2, '0')    AS phone_tail,
           ARRAY_CONSTRUCT('4111 1111 1111 1111', '5555 5555 5555 4444',
                           '4012 8888 8888 1881')[ABS(HASH(d.call_id, 'c')) % 3]::VARCHAR AS card,
           '9' || LPAD((ABS(HASH(d.call_id, 'n')) % 100)::VARCHAR, 2, '0') || '-7'
               || LPAD((ABS(HASH(d.call_id, 'm')) % 10)::VARCHAR, 1, '0') || '-'
               || LPAD((ABS(HASH(d.call_id, 'o')) % 10000)::VARCHAR, 4, '0')       AS natid,
           LOWER(cu.first_name) || '.' || LOWER(cu.last_name)
               || (ABS(HASH(d.call_id)) % 90 + 10)::VARCHAR || '@example.com'      AS email,
           (ABS(HASH(d.call_id, 'a')) % 9000 + 100)::VARCHAR || ' '
               || ARRAY_CONSTRUCT('Sample','Fictional','Placeholder','Synthetic')[ABS(HASH(d.call_id, 's')) % 4]::VARCHAR
               || ' Street, Testville'                                             AS addr,
           TO_VARCHAR(DATEADD(day, -(ABS(HASH(d.call_id, 'd')) % 18000) - 7000,
                              DATE '2026-01-01'), 'MMMM DD, YYYY')                  AS dob
    FROM SYNTH_CALL_DETAIL_RECORDS d
    JOIN SYNTH_CUSTOMERS cu ON cu.customer_id = d.customer_id
    JOIN SYNTH_AGENTS ag    ON ag.agent_id    = d.agent_id
),
spoken AS (
    SELECT b.*, '206-' || phone_tail AS phone
    FROM base b
)
SELECT call_id, cust, agent, phone, card, natid, email, addr, dob,
       -- Digit-by-digit spoken forms, the way a caller reads them out.
       TRIM(REGEXP_REPLACE(
         REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
           REPLACE(card, ' ', ''),
           '0',' zero'),'1',' one'),'2',' two'),'3',' three'),'4',' four'),
           '5',' five'),'6',' six'),'7',' seven'),'8',' eight'),'9',' nine'),
         '\\s+', ' '))                                                   AS card_words,
       TRIM(REGEXP_REPLACE(
         REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
           REPLACE(phone, '-', ''),
           '0',' zero'),'1',' one'),'2',' two'),'3',' three'),'4',' four'),
           '5',' five'),'6',' six'),'7',' seven'),'8',' eight'),'9',' nine'),
         '\\s+', ' '))                                                   AS phone_words
FROM spoken;

-- ---------------------------------------------------------------------
-- 6. Ground-truth segments (all calls, true roles, raw PII). This is the
--    source for the vendor transcript table AND for audio rendering. It
--    lives in EVAL: the true role column is an answer.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_TRUE_SEGMENTS AS
SELECT cs.call_id,
       t.index + 1                         AS seq,
       t.value:r::STRING                   AS true_role,
       t.value:t::STRING                   AS template_text,
       REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(
           t.value:t::STRING,
           '{{CARD_WORDS}}',  p.card_words),
           '{{PHONE_WORDS}}', p.phone_words),
           '{{CUST}}',  p.cust),
           '{{AGENT}}', p.agent),
           '{{PHONE}}', p.phone),
           '{{EMAIL}}', p.email),
           '{{ADDR}}',  p.addr),
           '{{DOB}}',   p.dob),
           '{{CARD}}',  p.card),
           '{{NATID}}', p.natid)          AS text
FROM {{EVAL_SCHEMA}}.SYNTH_CALL_SCENARIO cs
JOIN {{EVAL_SCHEMA}}.SYNTH_SCENARIOS s ON s.scenario_id = cs.scenario_id
JOIN {{EVAL_SCHEMA}}.SYNTH_CALL_PII_VALUES p ON p.call_id = cs.call_id,
LATERAL FLATTEN(input => s.turns) t;

-- ---------------------------------------------------------------------
-- 7. Vendor transcript table (what a CCaaS export looks like). Audio-only
--    calls are absent. A share are delivered as one full-text blob with
--    inline speaker markers and NULL speaker_role, to exercise the
--    full-text path. IVR turns are labeled SYSTEM by the "vendor".
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE SYNTH_CALL_TRANSCRIPTS AS
WITH eligible AS (
    SELECT call_id,
           ((ABS(HASH(call_id, 'ft')) % 1000)) < 1000 * {{FULLTEXT_SHARE}} AS full_text
    FROM SYNTH_CALL_DETAIL_RECORDS
    WHERE NOT audio_only
)
SELECT ts.call_id, ts.seq,
       DECODE(ts.true_role, 'IVR', 'SYSTEM', ts.true_role) AS speaker_role,
       ts.text                                             AS utterance_text
FROM {{EVAL_SCHEMA}}.SYNTH_TRUE_SEGMENTS ts
JOIN eligible e ON e.call_id = ts.call_id AND NOT e.full_text
UNION ALL
SELECT ts.call_id, 0 AS seq, NULL AS speaker_role,
       LISTAGG(INITCAP(ts.true_role) || ': ' || ts.text, '\n') WITHIN GROUP (ORDER BY ts.seq) AS utterance_text
FROM {{EVAL_SCHEMA}}.SYNTH_TRUE_SEGMENTS ts
JOIN eligible e ON e.call_id = ts.call_id AND e.full_text
GROUP BY ts.call_id;

-- ---------------------------------------------------------------------
-- 8. Answer key (EVAL schema only).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_CALLS AS
SELECT cs.call_id,
       cs.scenario_id,
       s.case_role,
       s.contact_reason,
       s.secondary_reasons,
       s.resolved,
       s.self_service_candidate,
       cs.prior_call_id IS NOT NULL         AS is_repeat,
       cs.prior_call_id,
       s.references_prior,
       s.transferred,
       s.supervisor_request,
       s.cancel_intent,
       s.save_offer_made,
       s.save_outcome,
       s.buying_signal,
       s.upsell_offered,
       s.upsell_outcome,
       s.opening_sentiment,
       s.closing_sentiment,
       d.audio_only,
       d.recording_seconds,
       d.recording_seconds >= {{MIN_CALL_SECONDS}} AND s.case_role <> 'EXCLUDE' AS in_scope
FROM {{EVAL_SCHEMA}}.SYNTH_CALL_SCENARIO cs
JOIN {{EVAL_SCHEMA}}.SYNTH_SCENARIOS s ON s.scenario_id = cs.scenario_id
JOIN SYNTH_CALL_DETAIL_RECORDS d ON d.call_id = cs.call_id;

CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_QA AS
SELECT cs.call_id,
       q.key                                    AS criterion_id,
       NOT IS_NULL_VALUE(q.value)               AS applicable,
       IFF(IS_NULL_VALUE(q.value), NULL, q.value::INT) AS expected_score
FROM {{EVAL_SCHEMA}}.SYNTH_CALL_SCENARIO cs
JOIN {{EVAL_SCHEMA}}.SYNTH_SCENARIOS s ON s.scenario_id = cs.scenario_id,
LATERAL FLATTEN(input => s.qa_expected) q
WHERE s.case_role <> 'EXCLUDE';

-- One row per planted PII occurrence: which value, which category,
-- which form, which segment. The redaction leak check reads this.
CREATE OR REPLACE TABLE {{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY_PII AS
WITH placements AS (
    SELECT ts.call_id, ts.seq, m.ph, m.category, m.form
    FROM {{EVAL_SCHEMA}}.SYNTH_TRUE_SEGMENTS ts
    JOIN (
        SELECT '{{CUST}}'        AS ph, 'NAME'              AS category, 'text'   AS form UNION ALL
        SELECT '{{AGENT}}',             'NAME',                          'text'          UNION ALL
        SELECT '{{PHONE}}',             'PHONE_NUMBER',                  'digits'        UNION ALL
        SELECT '{{PHONE_WORDS}}',       'PHONE_NUMBER',                  'words'         UNION ALL
        SELECT '{{EMAIL}}',             'EMAIL',                         'text'          UNION ALL
        SELECT '{{ADDR}}',              'ADDRESS',                       'text'          UNION ALL
        SELECT '{{DOB}}',               'DATE_OF_BIRTH',                 'text'          UNION ALL
        SELECT '{{CARD}}',              'PAYMENT_CARD_DATA',             'digits'        UNION ALL
        SELECT '{{CARD_WORDS}}',        'PAYMENT_CARD_DATA',             'words'         UNION ALL
        SELECT '{{NATID}}',             'NATIONAL_ID',                   'digits'
    ) m ON CONTAINS(ts.template_text, m.ph)
)
SELECT pl.call_id, pl.seq, pl.category, pl.form,
       CASE pl.ph
            WHEN '{{CUST}}'        THEN p.cust
            WHEN '{{AGENT}}'       THEN p.agent
            WHEN '{{PHONE}}'       THEN p.phone
            WHEN '{{PHONE_WORDS}}' THEN p.phone_words
            WHEN '{{EMAIL}}'       THEN p.email
            WHEN '{{ADDR}}'        THEN p.addr
            WHEN '{{DOB}}'         THEN p.dob
            WHEN '{{CARD}}'        THEN p.card
            WHEN '{{CARD_WORDS}}'  THEN p.card_words
            WHEN '{{NATID}}'       THEN p.natid
       END                                       AS planted_value,
       -- Digits-only form for numeric matching, so "4111-1111..." and
       -- "4111 1111..." both count as a leak.
       IFF(pl.form = 'digits',
           REGEXP_REPLACE(CASE pl.ph WHEN '{{PHONE}}' THEN p.phone
                                     WHEN '{{CARD}}'  THEN p.card
                                     WHEN '{{NATID}}' THEN p.natid END, '[^0-9]', ''),
           NULL)                                 AS planted_digits
FROM placements pl
JOIN {{EVAL_SCHEMA}}.SYNTH_CALL_PII_VALUES p ON p.call_id = pl.call_id;

-- Audio rendering manifest, read by build-call-test-corpus. Lives in EVAL
-- because it carries true roles; the rendering script writes only audio.
CREATE OR REPLACE VIEW {{EVAL_SCHEMA}}.SYNTH_AUDIO_RENDER_MANIFEST AS
SELECT d.call_id, d.recording_path, d.audio_only, ts.seq, ts.true_role, ts.text
FROM SYNTH_CALL_DETAIL_RECORDS d
JOIN {{EVAL_SCHEMA}}.SYNTH_TRUE_SEGMENTS ts ON ts.call_id = d.call_id;

-- Clean up generator scaffolding that the pipeline has no use for.
DROP TABLE IF EXISTS SYNTH_SCENARIO_BUCKETS;
DROP TABLE IF EXISTS SYNTH_CALLS_BASE;
DROP TABLE IF EXISTS SYNTH_CALLS_FOLLOWUP;
