-- =====================================================================
-- Synthetic support / IT ticket corpus with ground truth, for ticket
-- triage pipeline development and accuracy measurement.
--
-- SUBSTITUTE BEFORE RUNNING:
--   {{DB}}            target database
--   {{SCHEMA}}        sandbox schema the pipeline reads from
--   {{EVAL_SCHEMA}}   separate schema for the answer key (quarantine)
--   {{SCALE}}         integer multiplier on non-cluster scenario volume
--                     (1 = ~400 tickets, 3 = ~1,150; max 6, the generator row cap)
--
-- Every identifier is prefixed SYN- so a synthetic row can never be
-- mistaken for a real one. People, companies, assets and credentials are
-- fabricated; the "pasted password" rows use an obviously fake SYN-FAKE-
-- token so redaction can be tested without real secrets.
--
-- Truth is generated FIRST into {{EVAL_SCHEMA}}.SYNTH_TICKET_GEN, then the
-- pipeline-visible tables are projected from it WITHOUT truth columns.
-- Nothing in {{SCHEMA}} carries a true label. The historical label columns
-- in SYNTH_TICKETS are deliberately noisy (see section 6).
-- =====================================================================

USE DATABASE {{DB}};
CREATE SCHEMA IF NOT EXISTS {{DB}}.{{SCHEMA}};
CREATE SCHEMA IF NOT EXISTS {{DB}}.{{EVAL_SCHEMA}};

-- ---------------------------------------------------------------------
-- 1. Customer priority policy: impact x urgency -> priority. In a real
--    build this comes from the customer; the pipeline derives priority
--    from it in SQL rather than asking a model (best-practices rule 6).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.SYNTH_PRIORITY_POLICY (
    impact   VARCHAR,
    urgency  VARCHAR,
    priority VARCHAR
);
INSERT INTO {{DB}}.{{SCHEMA}}.SYNTH_PRIORITY_POLICY VALUES
    ('HIGH','HIGH','P1'), ('HIGH','MEDIUM','P2'), ('HIGH','LOW','P3'),
    ('MEDIUM','HIGH','P2'), ('MEDIUM','MEDIUM','P3'), ('MEDIUM','LOW','P4'),
    ('LOW','HIGH','P3'), ('LOW','MEDIUM','P4'), ('LOW','LOW','P4');

-- ---------------------------------------------------------------------
-- 2. Knowledge base. Includes a DRAFT and a RETIRED article that must not
--    be indexed, and a process article (access requests) that is on topic
--    for many tickets but resolves none of them by self-service.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.SYNTH_KB_ARTICLES (
    article_id     VARCHAR,
    title          VARCHAR,
    body           VARCHAR,
    workflow_state VARCHAR,
    product        VARCHAR,
    category       VARCHAR,
    article_type   VARCHAR,     -- HOWTO | KNOWN_ISSUE | PROCESS | POLICY
    updated_at     TIMESTAMP_NTZ
);

INSERT INTO {{DB}}.{{SCHEMA}}.SYNTH_KB_ARTICLES
SELECT column1, column2, column3, column4, column5, column6, column7,
       DATEADD(DAY, -column8, CURRENT_TIMESTAMP())::TIMESTAMP_NTZ
FROM VALUES
('KB-SYN-0001','Reset your password with the self-service portal',
 'Use this article when you have forgotten your password or it has expired. 1. Go to the Synthetic Identity Portal sign-in page and select Forgot password. 2. Enter your username and approve the prompt on your registered authenticator. 3. Choose a new password that meets the complexity rules: at least 14 characters, not one of your last 10 passwords. 4. Wait two minutes, then sign in to your laptop with the new password while connected to the office network or VPN so the cached credential updates. This article does not apply if the portal reports that your account is locked by an administrator; in that case contact the service desk.',
 'published','Identity Portal','Access and Identity','HOWTO',40),
('KB-SYN-0002','Register a new phone for multi-factor authentication',
 'Use this article when you have a new phone or reinstalled the authenticator app. 1. On a computer, open the Synthetic Identity Portal and sign in. 2. Open Security info and select Add sign-in method, then Authenticator app. 3. Scan the QR code with the authenticator app on the new phone. 4. Approve the test notification. 5. Remove the old phone from the list. If you have no other way to sign in, the service desk must issue a temporary access pass.',
 'published','Authenticator','Access and Identity','HOWTO',65),
('KB-SYN-0003','Install and connect the VPN client on a new laptop',
 'Use this article to set up remote access. 1. Open the Software Center and install Synthetic VPN Client. 2. Launch the client and enter the gateway address vpn.synthetic.example. 3. Sign in with your normal username and approve the authenticator prompt. 4. The status icon turns green when connected. If the client reports that the gateway is unreachable for everyone, check the service status page before raising a ticket.',
 'published','VPN Client','Network and VPN','HOWTO',90),
('KB-SYN-0004','Known issue: VPN client 5.2 disconnects after the laptop wakes from sleep (VPN-809)',
 'Symptoms: after the laptop resumes from sleep, Synthetic VPN Client 5.2 shows error VPN-809 and will not reconnect until restarted. Cause: a defect in client version 5.2.0 when the network adapter powers down. Workaround: open the VPN client, select Disconnect, then Connect; or restart the client from the system tray. Permanent fix: version 5.2.3 is being deployed through the Software Center; install it to stop the issue recurring.',
 'published','VPN Client','Network and VPN','KNOWN_ISSUE',12),
('KB-SYN-0005','Add a network printer to your laptop',
 'Use this article to add a printer. 1. Open Settings, then Printers and scanners, then Add device. 2. Select the printer whose name matches the label on the device, for example SYN-PRN-301. 3. If it is not listed, select Add manually and enter the print server path. This article covers adding a printer; it does not cover printers that show as offline or have hardware faults.',
 'published','Print Services','Printing','HOWTO',120),
('KB-SYN-0006','Known issue: Outlook does not start after the October update (0x800CCC0E)',
 'Symptoms: after the latest Office update, Outlook closes on start or reports error 0x800CCC0E. Cause: a corrupted cached profile after the update. Workaround: close Outlook, open Control Panel, Mail, Show Profiles, add a new profile, and set it as the default. Outlook rebuilds the cache on first start, which can take several minutes. The web version of Outlook is unaffected and can be used meanwhile.',
 'published','Outlook','Email and Collaboration','KNOWN_ISSUE',8),
('KB-SYN-0007','How to request access to a shared drive or application',
 'Access to shared drives and business applications requires approval from the data owner. Submit an access request in the service portal, select the resource, and give a business justification. The request is routed to the owner for approval and then to the Identity and Access team, who apply the change. The service desk cannot grant access directly.',
 'published','File Shares','Access and Identity','PROCESS',200),
('KB-SYN-0008','Known issue: invoice posting fails with FI-204 in the finance application',
 'Symptoms: posting a vendor invoice fails with message FI-204 period not open for posting. Cause: the posting period was not opened after month end. Workaround: the Business Applications team reopens the period; end users cannot apply this workaround. Raise a ticket to Business Applications with the company code and invoice number.',
 'published','Finance Application','Business Applications','KNOWN_ISSUE',20),
('KB-SYN-0009','Fix audio problems in Teams meetings by clearing the cache',
 'Use this article when meeting audio is choppy, others cannot hear you, or the wrong device is used. 1. Quit Teams completely from the system tray. 2. Delete the contents of the Teams cache folder. 3. Restart Teams and open Settings, Devices, and choose the correct speaker and microphone. 4. Make a test call. If audio still fails on every device, contact the service desk.',
 'published','Teams','Email and Collaboration','HOWTO',75),
('KB-SYN-0010','Report a suspicious email',
 'Do not click links or open attachments. Use the Report Phishing button in Outlook, which forwards the message to Security Operations and removes it from your inbox. If you already clicked a link or entered your password, contact the service desk immediately so your account can be secured.',
 'published','Outlook','Security','POLICY',150),
('KB-SYN-0011','Laptop battery replacement process',
 'Swollen, overheating or rapidly draining batteries must be replaced by End User Computing. Stop using a swollen battery immediately. Raise a hardware ticket with the asset tag; a technician will arrange a swap or loaner device.',
 'published','Laptop','Hardware','PROCESS',300),
('KB-SYN-0012','DRAFT: new VPN gateway migration FAQ',
 'Draft content not yet reviewed. Gateway addresses in this draft are placeholders.',
 'draft','VPN Gateway','Network and VPN','HOWTO',3),
('KB-SYN-0013','Connect with the legacy VPN client 4.x',
 'Retired. The 4.x client is no longer supported. Steps in this article no longer work.',
 'retired','VPN Client','Network and VPN','HOWTO',700);

CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.SYNTH_KNOWN_ISSUES (
    known_issue_id VARCHAR,
    title          VARCHAR,
    article_id     VARCHAR,
    product        VARCHAR,
    error_code     VARCHAR,
    status         VARCHAR
);
INSERT INTO {{DB}}.{{SCHEMA}}.SYNTH_KNOWN_ISSUES VALUES
    ('KI-SYN-001','VPN client 5.2 disconnects after sleep','KB-SYN-0004','VPN Client','VPN-809','OPEN'),
    ('KI-SYN-002','Outlook fails to start after October update','KB-SYN-0006','Outlook','0x800CCC0E','OPEN'),
    ('KI-SYN-003','Invoice posting FI-204 period not open','KB-SYN-0008','Finance Application','FI-204','OPEN');

-- ---------------------------------------------------------------------
-- 3. Scenario catalogue (truth). Each scenario fixes the correct labels;
--    tickets are generated as variants of it. Lives in the EVAL schema.
--
--    case_role values and what each tests:
--      STANDARD            ordinary routing
--      DEFLECTABLE         KB resolves the ask by self-service
--      DEFLECT_DISTRACTOR  on topic for a KB article, but the user already
--                          tried it -- must NOT be a deflection candidate
--      ACCESS_REQUEST      on topic for a PROCESS article; needs approval
--      KNOWN_ISSUE         should link to a known issue
--      DUPLICATE_CLUSTER   same incident, many reporters, narrow window
--      LEXICAL_TRAP        shares words ("offline") with another category
--      TONE_TRAP           shouting, low real priority
--      QUIET_P1            polite wording, major impact
--      MULTI_INTENT        two asks in one ticket
--      SUBJECT_ONLY        body is NULL
--      NON_ENGLISH         Spanish text, same truth as an English scenario
--      SECRET_PASTE        contains a (fake) pasted password
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{DB}}.{{EVAL_SCHEMA}}.SYNTH_SCENARIOS (
    scenario_id         VARCHAR,
    case_role           VARCHAR,
    n_base              INT,        -- tickets at SCALE = 1
    is_cluster          BOOLEAN,    -- cluster scenarios ignore SCALE
    cluster_days_ago    INT,
    true_category       VARCHAR,
    secondary_category  VARCHAR,
    true_impact         VARCHAR,
    true_urgency        VARCHAR,
    true_queue          VARCHAR,
    true_product        VARCHAR,
    true_error_code     VARCHAR,
    asset_kind          VARCHAR,    -- LAPTOP | PRINTER | NULL
    known_issue_id      VARCHAR,
    is_deflectable      BOOLEAN,
    deflection_type     VARCHAR,
    deflect_article_id  VARCHAR,
    channel_bias        VARCHAR,    -- preferred channel, or NULL for mixed
    language            VARCHAR,
    subject_template    VARCHAR,
    body_template       VARCHAR,
    variants            ARRAY
);

INSERT INTO {{DB}}.{{EVAL_SCHEMA}}.SYNTH_SCENARIOS
SELECT column1, column2, column3, column4, column5, column6, column7, column8, column9,
       column10, column11, column12, column13, column14, column15, column16, column17,
       column18, column19, column20, column21, PARSE_JSON(column22)::ARRAY
FROM VALUES
('S01','DEFLECTABLE',30,FALSE,NULL,'Access and Identity',NULL,'LOW','LOW','SERVICE_DESK','Identity Portal',NULL,NULL,NULL,TRUE,'SELF_SERVICE_HOWTO','KB-SYN-0001',NULL,'en',
 'Forgot my password',
 '{V} I need to get back into my account. How do I reset it myself?',
 '["My password expired over the weekend.","I forgot my password after the holiday.","I changed my password last week and now cannot remember it.","Password is not accepted anymore, I think it expired.","Locked out of email because I forgot the password I set."]'),
('S02','DEFLECT_DISTRACTOR',12,FALSE,NULL,'Access and Identity',NULL,'LOW','HIGH','IDENTITY_ACCESS','Identity Portal',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,NULL,'en',
 'Self-service reset not working',
 'I already followed the self-service password reset article. {V} I cannot work until this is fixed.',
 '["The portal says my account is locked by an administrator.","After step 2 it says account disabled, contact administrator.","The reset completes but sign-in still says account locked.","It tells me my account is locked and the reset option is greyed out."]'),
('S03','DEFLECTABLE',20,FALSE,NULL,'Access and Identity',NULL,'LOW','MEDIUM','SERVICE_DESK','Authenticator',NULL,NULL,NULL,TRUE,'SELF_SERVICE_HOWTO','KB-SYN-0002',NULL,'en',
 'New phone - authenticator',
 '{V} How do I move my sign-in approvals to the new one? I can still sign in on my laptop.',
 '["I got a new phone today.","My old phone broke and I replaced it.","I reinstalled the authenticator app and it is empty.","Switched from one phone to another this morning."]'),
('S04','ACCESS_REQUEST',18,FALSE,NULL,'Access and Identity',NULL,'LOW','LOW','IDENTITY_ACCESS','File Shares',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,'portal','en',
 'Access request - shared drive',
 'Please give me access to {V}. My manager has approved it.',
 '["the Finance shared drive","the HR policies folder","the Projects share for the regional team","the Procurement contracts folder","the Marketing assets drive"]'),
('S05','DEFLECTABLE',25,FALSE,NULL,'Network and VPN',NULL,'LOW','LOW','SERVICE_DESK','VPN Client',NULL,'LAPTOP',NULL,TRUE,'SELF_SERVICE_HOWTO','KB-SYN-0003',NULL,'en',
 'How to set up VPN on new laptop',
 '{V} Laptop asset {ASSET}. How do I install and connect the VPN?',
 '["I just received a replacement laptop.","Starting remote work next week and need VPN.","New starter here, VPN is not installed yet.","My laptop was reimaged and VPN is gone."]'),
('S06','KNOWN_ISSUE',22,FALSE,NULL,'Network and VPN',NULL,'LOW','MEDIUM','NETWORK_OPS','VPN Client','VPN-809','LAPTOP','KI-SYN-001',TRUE,'KNOWN_ISSUE_WORKAROUND','KB-SYN-0004',NULL,'en',
 'VPN keeps dropping',
 '{V} The client shows error VPN-809. Laptop {ASSET}, client version 5.2.',
 '["Every time I open my laptop after lunch the VPN is disconnected and will not come back.","VPN fails after the laptop has been asleep.","When I come back to my desk VPN shows an error and I have to reboot.","VPN connection is lost after closing the lid."]'),
('S07','DUPLICATE_CLUSTER',14,TRUE,40,'Network and VPN',NULL,'HIGH','HIGH','NETWORK_OPS','VPN Gateway',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,NULL,'en',
 'Cannot connect to VPN',
 '{V}',
 '["VPN is not connecting at all, it says gateway unreachable. My whole team working from home has the same problem.","Hi, sorry to bother you, I cannot connect to the VPN this morning. Colleagues say the same. Gateway unreachable.","Nobody in our department can get on the VPN. Gateway not responding.","VPN gateway unreachable since about 9. Several of us affected.","Unable to connect to remote access. The client times out on the gateway. Others too.","Just flagging that VPN seems down for everyone on my team."]'),
('S27','DUPLICATE_CLUSTER',8,TRUE,10,'Network and VPN',NULL,'HIGH','HIGH','NETWORK_OPS','VPN Gateway',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,NULL,'en',
 'VPN down again',
 '{V}',
 '["VPN gateway unreachable again today, whole team affected.","Cannot connect to VPN, gateway not responding, same as last month.","Remote access is down for everyone again, client times out.","VPN not connecting, gateway unreachable, colleagues too."]'),
('S08','LEXICAL_TRAP',15,FALSE,NULL,'Printing',NULL,'LOW','MEDIUM','END_USER_COMPUTING','Print Services',NULL,'PRINTER',NULL,FALSE,'NOT_DEFLECTABLE',NULL,NULL,'en',
 'Printer offline',
 'Printer {ASSET} on floor 3 {V}',
 '["shows offline and nothing prints.","is offline again, the screen shows a paper feed error.","went offline after the power cut and will not come back.","says offline, jobs are stuck in the queue."]'),
('S09','DEFLECTABLE',12,FALSE,NULL,'Printing',NULL,'LOW','LOW','SERVICE_DESK','Print Services',NULL,'PRINTER',NULL,TRUE,'SELF_SERVICE_HOWTO','KB-SYN-0005',NULL,'en',
 'Add printer',
 '{V} The printer label says {ASSET}. How do I add it?',
 '["I moved desks and need to print to the printer near me.","How do I add the printer in the new office?","My laptop does not show the printer by the kitchen."]'),
('S10','KNOWN_ISSUE',20,FALSE,NULL,'Email and Collaboration',NULL,'LOW','HIGH','MESSAGING_COLLAB','Outlook','0x800CCC0E',NULL,'KI-SYN-002',TRUE,'KNOWN_ISSUE_WORKAROUND','KB-SYN-0006','email','en',
 'Outlook will not open',
 '{V} Error 0x800CCC0E. I cannot see my email.',
 '["Outlook closes straight away since the update last night.","After the Office update Outlook will not start.","Outlook crashes on launch since this morning.","Outlook shows an error and closes when I open it."]'),
('S11','DUPLICATE_CLUSTER',10,TRUE,25,'Email and Collaboration',NULL,'HIGH','MEDIUM','MESSAGING_COLLAB','Exchange',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,NULL,'en',
 'Emails delayed',
 '{V}',
 '["External emails are arriving an hour late, customers are chasing us.","Mail delivery seems very slow today, messages from outside take ages.","Our team is not receiving external email on time, big delays.","Emails from customers are delayed by 45 minutes or more."]'),
('S12','DEFLECTABLE',20,FALSE,NULL,'Email and Collaboration',NULL,'LOW','MEDIUM','SERVICE_DESK','Teams',NULL,NULL,NULL,TRUE,'SELF_SERVICE_HOWTO','KB-SYN-0009',NULL,'en',
 'Teams audio problem',
 '{V} Is there something I can do myself?',
 '["People cannot hear me in Teams meetings.","Teams audio is choppy on calls.","Teams uses the wrong speaker every time I join a meeting.","My microphone works elsewhere but not in Teams."]'),
('S13','KNOWN_ISSUE',15,FALSE,NULL,'Business Applications',NULL,'MEDIUM','HIGH','BUSINESS_APPS','Finance Application','FI-204',NULL,'KI-SYN-003',FALSE,'NOT_DEFLECTABLE','KB-SYN-0008',NULL,'en',
 'Invoice posting error',
 '{V} Message FI-204 period not open for posting.',
 '["Cannot post vendor invoices for company code 1200.","Invoice posting fails for our whole AP team today.","Month end close blocked, invoices will not post.","Getting an error posting invoices since the first of the month."]'),
('S14','STANDARD',22,FALSE,NULL,'Business Applications',NULL,'MEDIUM','MEDIUM','BUSINESS_APPS','Finance Application',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,NULL,'en',
 'Finance report timing out',
 '{V}',
 '["The aged debtors report in the finance application times out after 10 minutes.","Monthly cost centre report never finishes running.","Finance reports are extremely slow this week for our team.","Report export to spreadsheet fails with a timeout."]'),
('S15','STANDARD',25,FALSE,NULL,'Hardware',NULL,'LOW','HIGH','END_USER_COMPUTING','Laptop',NULL,'LAPTOP',NULL,FALSE,'NOT_DEFLECTABLE',NULL,'phone','en',
 'Laptop will not start',
 'Laptop {ASSET} {V}',
 '["shows a blue screen on every boot.","will not power on even when plugged in.","is stuck on the logo screen.","restarts itself every few minutes."]'),
('S16','STANDARD',12,FALSE,NULL,'Hardware',NULL,'LOW','MEDIUM','END_USER_COMPUTING','Laptop',NULL,'LAPTOP',NULL,FALSE,'NOT_DEFLECTABLE',NULL,NULL,'en',
 'Battery problem',
 'The battery on {ASSET} {V}',
 '["is swollen and the trackpad is lifting.","drains from full in under an hour.","gets very hot while charging."]'),
('S17','TONE_TRAP',12,FALSE,NULL,'Hardware',NULL,'LOW','LOW','END_USER_COMPUTING','Peripherals',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,NULL,'en',
 'URGENT!!! {V}',
 'URGENT PLEASE FIX ASAP!!! {V} I have a spare one at home so I can bring that tomorrow.',
 '["MOUSE NOT WORKING","KEYBOARD KEY STUCK","HEADSET CRACKLING","MONITOR CABLE LOOSE"]'),
('S18','QUIET_P1',6,FALSE,NULL,'Business Applications',NULL,'HIGH','HIGH','BUSINESS_APPS','Payments Portal',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,'email','en',
 'FYI payments portal',
 'Hi, just letting you know {V} Thanks, no rush on replying to me personally.',
 '["the customer payments portal is returning errors for every customer who tries to pay since about 10:15.","the payments portal checkout fails for all customers we have spoken to this morning.","no customer payments have gone through the portal in the last hour, it errors at confirmation."]'),
('S19','STANDARD',18,FALSE,NULL,'Security',NULL,'MEDIUM','MEDIUM','SECURITY_OPS','Outlook',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,'email','en',
 'Suspicious email',
 '{V} I have not clicked anything.',
 '["I received an email asking me to confirm my payroll details on an unfamiliar website.","Got a message claiming to be from IT asking for my password.","An invoice email with a strange attachment arrived from an unknown sender."]'),
('S20','STANDARD',8,FALSE,NULL,'Security',NULL,'MEDIUM','HIGH','SECURITY_OPS','Identity Portal',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,NULL,'en',
 'Unusual sign-in alert',
 '{V}',
 '["I got a sign-in alert from a country I have never been to, and I did not approve it.","My account shows a login from an unknown device overnight.","I clicked a link in an email and entered my password, then realised it was fake."]'),
('S21','MULTI_INTENT',10,FALSE,NULL,'Network and VPN','Access and Identity','LOW','MEDIUM','NETWORK_OPS','VPN Client',NULL,'LAPTOP',NULL,FALSE,'NOT_DEFLECTABLE',NULL,NULL,'en',
 'VPN and access',
 'Two things: VPN on {ASSET} {V} Also while you are at it I need access to the HR policies folder.',
 '["fails with a certificate error since yesterday.","keeps saying authentication failed although my password works elsewhere.","connects but I cannot reach any internal sites."]'),
('S22','SUBJECT_ONLY',8,FALSE,NULL,'Software and Applications',NULL,'LOW','LOW','END_USER_COMPUTING','Software Center',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,'portal','en',
 'Software install request - {V}',
 NULL,
 '["diagram tool","statistics package","PDF editor","screen recorder"]'),
('S23','NON_ENGLISH',6,FALSE,NULL,'Email and Collaboration',NULL,'LOW','HIGH','MESSAGING_COLLAB','Outlook','0x800CCC0E',NULL,'KI-SYN-002',TRUE,'KNOWN_ISSUE_WORKAROUND','KB-SYN-0006','email','es',
 'Outlook no abre',
 '{V} Error 0x800CCC0E. No puedo ver mi correo.',
 '["Desde la actualizacion de anoche Outlook se cierra al abrirlo.","Outlook no arranca despues de la actualizacion de Office.","Outlook muestra un error y se cierra."]'),
('S24','STANDARD',20,FALSE,NULL,'Software and Applications',NULL,'LOW','LOW','END_USER_COMPUTING','Software Center',NULL,'LAPTOP',NULL,FALSE,'NOT_DEFLECTABLE',NULL,'portal','en',
 'Install request',
 'Please install {V} on {ASSET}. Licence cost centre approved by my manager.',
 '["the design suite","the project planning tool","the data visualisation desktop app","the code editor extensions pack"]'),
('S25','STANDARD',15,FALSE,NULL,'Network and VPN',NULL,'MEDIUM','MEDIUM','NETWORK_OPS','Wi-Fi',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,NULL,'en',
 'Wi-Fi dropping in building B',
 '{V}',
 '["Wi-Fi in building B second floor drops every few minutes for several of us.","Wireless keeps disconnecting in the building B meeting rooms.","Office Wi-Fi in building B is unusable this afternoon, many people affected."]'),
('S26','SECRET_PASTE',3,FALSE,NULL,'Access and Identity',NULL,'LOW','HIGH','IDENTITY_ACCESS','Identity Portal',NULL,NULL,NULL,FALSE,'NOT_DEFLECTABLE',NULL,'email','en',
 'Cannot sign in',
 'I cannot sign in. {V} Please check why it is rejected.',
 '["My password is SYN-FAKE-Pa55-0001 and it is definitely correct.","password: SYN-FAKE-Pa55-0002 has worked for months.","I am typing SYN-FAKE-Pa55-0003 exactly and it fails."]');

-- ---------------------------------------------------------------------
-- 4. Generate tickets WITH truth into the EVAL schema.
--    Cluster scenarios: fixed count, all within ~90 minutes on one day.
--    Other scenarios: n_base * SCALE, spread over 120 days.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{DB}}.{{EVAL_SCHEMA}}.SYNTH_TICKET_GEN AS
WITH seq AS (
    SELECT SEQ4() AS n FROM TABLE(GENERATOR(ROWCOUNT => 200))
),
expanded AS (
    SELECT s.*, q.n AS variant_seq,
           MOD(ABS(RANDOM()), ARRAY_SIZE(s.variants)) AS v_idx
    FROM {{DB}}.{{EVAL_SCHEMA}}.SYNTH_SCENARIOS s
    JOIN seq q
      ON q.n < IFF(s.is_cluster, s.n_base, s.n_base * {{SCALE}})
),
assets AS (
    SELECT e.*,
           CASE e.asset_kind
               WHEN 'LAPTOP'  THEN 'SYN-LT-'  || LPAD(MOD(ABS(RANDOM()), 90000) + 10000, 5, '0')
               WHEN 'PRINTER' THEN 'SYN-PRN-' || (300 + MOD(ABS(RANDOM()), 12))::VARCHAR
           END AS true_asset_id,
           e.variants[e.v_idx]::STRING AS variant_text
    FROM expanded e
),
timed AS (
    SELECT a.*,
           IFF(a.is_cluster,
               DATEADD(MINUTE, a.variant_seq * 6 + MOD(ABS(RANDOM()), 5),
                       DATEADD(HOUR, 9, DATEADD(DAY, -a.cluster_days_ago, CURRENT_DATE()::TIMESTAMP_NTZ))),
               DATEADD(MINUTE, -MOD(ABS(RANDOM()), 120 * 24 * 60), CURRENT_TIMESTAMP()::TIMESTAMP_NTZ)
           ) AS created_at
    FROM assets a
)
SELECT
    'SYN-TKT-' || LPAD(ROW_NUMBER() OVER (ORDER BY t.created_at, t.scenario_id, t.variant_seq), 6, '0') AS ticket_id,
    t.scenario_id, t.case_role, t.created_at,
    t.true_category, t.secondary_category, t.true_impact, t.true_urgency,
    p.priority AS true_priority,
    t.true_queue, t.true_product, t.true_error_code, t.true_asset_id,
    t.known_issue_id AS true_known_issue_id,
    t.is_deflectable, t.deflection_type, t.deflect_article_id,
    (t.case_role = 'MULTI_INTENT') AS is_multi_intent,
    IFF(t.is_cluster, 'CL-' || t.scenario_id, NULL) AS dup_cluster_id,
    t.language,
    COALESCE(t.channel_bias,
             ARRAY_CONSTRUCT('email','portal','portal','phone','chat')[MOD(ABS(RANDOM()), 5)]::STRING) AS channel,
    'SYN-USR-' || LPAD(MOD(ABS(RANDOM()), 4000) + 1, 5, '0') AS requester_id,
    REPLACE(REPLACE(t.subject_template, '{V}', t.variant_text), '{ASSET}', COALESCE(t.true_asset_id, '')) AS subject,
    IFF(t.body_template IS NULL, NULL,
        REPLACE(REPLACE(t.body_template, '{V}', t.variant_text), '{ASSET}', COALESCE(t.true_asset_id, ''))) AS core_body,
    -- Few-shot pool: ~5% of non-cluster tickets are reserved as examples and
    -- EXCLUDED from evaluation. Never mix the two (best-practices rule 1).
    IFF(NOT t.is_cluster AND MOD(ABS(RANDOM()), 20) = 0, 'EXAMPLE', 'EVAL') AS split
FROM timed t
JOIN {{DB}}.{{SCHEMA}}.SYNTH_PRIORITY_POLICY p
  ON p.impact = t.true_impact AND p.urgency = t.true_urgency;

-- Cluster parent = earliest ticket in each planted cluster.
ALTER TABLE {{DB}}.{{EVAL_SCHEMA}}.SYNTH_TICKET_GEN ADD COLUMN dup_parent_ticket_id VARCHAR;
UPDATE {{DB}}.{{EVAL_SCHEMA}}.SYNTH_TICKET_GEN g
SET dup_parent_ticket_id = x.parent_id
FROM (
    SELECT dup_cluster_id, MIN_BY(ticket_id, created_at) AS parent_id
    FROM {{DB}}.{{EVAL_SCHEMA}}.SYNTH_TICKET_GEN
    WHERE dup_cluster_id IS NOT NULL
    GROUP BY 1
) x
WHERE g.dup_cluster_id = x.dup_cluster_id;

-- ---------------------------------------------------------------------
-- 5. Answer key. The ONLY table the evaluation harness reads for truth.
--    acceptable_article_ids lets a labeller mark more than one article as
--    a correct deflection source; here it is the single planted article.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{DB}}.{{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY AS
SELECT
    ticket_id, scenario_id, case_role, split,
    true_category, secondary_category,
    true_impact, true_urgency, true_priority,
    true_queue, true_product, true_error_code, true_asset_id,
    is_multi_intent,
    dup_cluster_id, dup_parent_ticket_id,
    true_known_issue_id,
    is_deflectable, deflection_type, deflect_article_id,
    IFF(deflect_article_id IS NULL, ARRAY_CONSTRUCT(), ARRAY_CONSTRUCT(deflect_article_id)) AS acceptable_article_ids,
    language
FROM {{DB}}.{{EVAL_SCHEMA}}.SYNTH_TICKET_GEN;

-- ---------------------------------------------------------------------
-- 6. Pipeline-visible tickets. NO truth columns. Historical labels are
--    derived from truth and then deliberately corrupted the way real ITSM
--    data is corrupted:
--      - ~25% of categories left at the form default 'Inquiry / Help'
--      - ~20% first-assigned to SERVICE_DESK when that is wrong, then
--        reassigned (reassignment_count > 0)
--      - ~8% closed by the service desk without reaching the right queue
--        (final assignment group wrong)
--      - ~15% priority left at default P3
--    Email-channel tickets get signatures, a confidentiality footer and a
--    quoted reply chain, so normalization has something to remove.
--    Close notes name the fix and the team: a leakage trap for any
--    classifier that is fed them (best-practices rule 1), and the source
--    for the resolved-ticket half of the knowledge store.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.SYNTH_TICKETS AS
WITH noisy AS (
    SELECT g.*,
           MOD(ABS(RANDOM()), 100) AS r_cat,
           MOD(ABS(RANDOM()), 100) AS r_first,
           MOD(ABS(RANDOM()), 100) AS r_final,
           MOD(ABS(RANDOM()), 100) AS r_pri,
           MOD(ABS(RANDOM()), 5)   AS r_open,
           MOD(ABS(RANDOM()), 5)   AS r_close,
           MOD(ABS(RANDOM()), 4)   AS r_sig,
           MOD(ABS(RANDOM()), 300) AS r_minutes
    FROM {{DB}}.{{EVAL_SCHEMA}}.SYNTH_TICKET_GEN g
),
hist AS (
    SELECT n.*,
           IFF(n.r_cat < 25, 'Inquiry / Help', n.true_category) AS hist_category,
           IFF(n.r_first < 20 AND n.true_queue <> 'SERVICE_DESK', 'SERVICE_DESK', n.true_queue) AS hist_first_queue,
           IFF(n.r_final < 8 AND n.true_queue <> 'SERVICE_DESK', 'SERVICE_DESK', n.true_queue) AS hist_queue,
           IFF(n.r_pri < 15, 'P3', n.true_priority) AS hist_priority
    FROM noisy n
)
SELECT
    h.ticket_id,
    h.created_at,
    DATEADD(MINUTE, 5 + MOD(h.r_minutes, 85), h.created_at)           AS first_assigned_at,
    DATEADD(MINUTE,
            CASE h.true_priority WHEN 'P1' THEN 120 WHEN 'P2' THEN 480
                                 WHEN 'P3' THEN 1440 ELSE 4320 END + h.r_minutes * 3,
            h.created_at)                                              AS resolved_at,
    h.channel,
    h.requester_id,
    h.subject,
    CASE
        WHEN h.core_body IS NULL THEN NULL
        WHEN h.channel = 'email' THEN
            ARRAY_CONSTRUCT('Hi team,', 'Hello,', 'Good morning,', 'Hi IT,', '')[h.r_open]::STRING || '\n\n'
            || h.core_body || '\n\n'
            || ARRAY_CONSTRUCT('Thanks', 'Thank you,', 'Regards', 'Cheers', '')[h.r_close]::STRING || '\n'
            || ARRAY_CONSTRUCT('Alex Synthwood', 'Jordan Fabrica', 'Sam Placeholder', 'Robin Notreal')[h.r_sig]::STRING
            || '\nSenior Analyst | Synthetic Corp | +00 000 000 0000\n'
            || 'CONFIDENTIALITY NOTICE: This message and any attachments are intended solely for the addressee '
            || 'and may contain confidential information. If you have received it in error, please notify the '
            || 'sender and delete it. Synthetic Corp accepts no liability for any damage caused by this email.\n\n'
            || '-----Original Message-----\nFrom: Service Desk\nSent: earlier\nSubject: RE: ' || h.subject || '\n\n'
            || '> Thank you for contacting the service desk. Your request has been logged. Please reply with any\n'
            || '> additional details such as screenshots, the time the problem started and your asset tag.\n'
            || '> Kind regards, Service Desk'
        ELSE
            ARRAY_CONSTRUCT('', 'Hi, ', 'Hello, ', '', '')[h.r_open]::STRING || h.core_body
    END                                                                AS description,
    h.hist_category                                                    AS category,
    h.hist_priority                                                    AS priority,
    h.hist_first_queue                                                 AS first_assignment_group,
    h.hist_queue                                                       AS assignment_group,
    IFF(h.hist_first_queue <> h.hist_queue, 1 + MOD(h.r_minutes, 3), 0) AS reassignment_count,
    CASE
        WHEN h.deflect_article_id IS NOT NULL AND h.is_deflectable
            THEN 'Resolved by ' || h.true_queue || ' - user guided through ' || h.deflect_article_id || '.'
        WHEN h.true_known_issue_id IS NOT NULL
            THEN 'Known issue ' || h.true_known_issue_id || '. Workaround applied by ' || h.true_queue || '.'
        WHEN h.dup_cluster_id IS NOT NULL
            THEN 'Resolved as part of major incident. Service restored by ' || h.true_queue || '.'
        ELSE ARRAY_CONSTRUCT('Resolved.', 'Closed - issue fixed.', 'Fixed by ' || h.true_queue || '.',
                             'User confirmed working.', 'Closed by caller.')[h.r_close]::STRING
    END                                                                AS close_notes,
    NULL::VARCHAR                                                      AS parent_incident,
    NULL::VARCHAR                                                      AS kb_article_linked
FROM hist h;

-- ---------------------------------------------------------------------
-- 7. Comment / work-note thread. One requester follow-up BEFORE first
--    assignment (legitimate classifier input) and, for reassigned
--    tickets, an agent note AFTER first assignment that names the right
--    queue (leakage trap: must be excluded from classifier input).
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.SYNTH_TICKET_COMMENTS AS
SELECT
    t.ticket_id || '-C1'                                   AS comment_id,
    t.ticket_id,
    DATEADD(MINUTE, 2, t.created_at)                        AS commented_at,
    'REQUESTER'                                             AS author_type,
    'Adding detail: this started ' ||
        ARRAY_CONSTRUCT('this morning.', 'yesterday afternoon.', 'after the weekend.', 'about an hour ago.')
        [MOD(ABS(RANDOM()), 4)]::STRING                     AS comment_text
FROM {{DB}}.{{SCHEMA}}.SYNTH_TICKETS t
WHERE MOD(ABS(HASH(t.ticket_id)), 3) = 0
UNION ALL
SELECT
    t.ticket_id || '-C2',
    t.ticket_id,
    DATEADD(MINUTE, 10, t.first_assigned_at),
    'AGENT',
    'Not a service desk issue - reassigning to ' || t.assignment_group || '.'
FROM {{DB}}.{{SCHEMA}}.SYNTH_TICKETS t
WHERE t.reassignment_count > 0;

-- ---------------------------------------------------------------------
-- 8. Few-shot example pool, projected from the EXAMPLE split only. The
--    taxonomy phase may draw AI_CLASSIFY examples from here; the harness
--    excludes split = 'EXAMPLE' from every metric.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE {{DB}}.{{SCHEMA}}.SYNTH_FEWSHOT_POOL AS
SELECT t.ticket_id,
       CONCAT_WS(' ', t.subject, COALESCE(g.core_body, '')) AS example_text,
       ak.true_category, ak.true_queue, ak.true_impact, ak.true_urgency,
       ak.case_role
FROM {{DB}}.{{SCHEMA}}.SYNTH_TICKETS t
JOIN {{DB}}.{{EVAL_SCHEMA}}.SYNTH_ANSWER_KEY ak ON ak.ticket_id = t.ticket_id
JOIN {{DB}}.{{EVAL_SCHEMA}}.SYNTH_TICKET_GEN g  ON g.ticket_id  = t.ticket_id
WHERE ak.split = 'EXAMPLE';

-- The generator table carries truth and core text; keep it in the eval
-- schema only. It is not needed by the pipeline and may be dropped after
-- verification, but the answer key must be kept.
