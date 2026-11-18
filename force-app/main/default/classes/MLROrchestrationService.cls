public without sharing class MLROrchestrationService {

    @InvocableMethod(label='Run MLR Pre-Screen' description='Call this action to pre-screen an MLR submission document. Pass the Salesforce record ID of the MLR_Submission__c record. Triggers sequential Medical, Legal, and Regulatory review agents — each assesses the document for compliance issues, assigns a confidence rating, and logs flags and rationale. Low confidence at any stage halts downstream review.')
    public static List<String> invokeOrchestration(List<String> submissionIds) {
        if (submissionIds == null || submissionIds.isEmpty()) {
            return new List<String>{ 'Error: No submission ID provided.' };
        }
        String submissionId = submissionIds[0];
        System.enqueueJob(new MLROrchestrationQueueable(submissionId));
        return new List<String>{ 'Pre-screen initiated for submission ' + submissionId + '. Medical, Legal, and Regulatory agents are running. Check the submission record for results.' };
    }

    public class MLROrchestrationQueueable implements Queueable, Database.AllowsCallouts {
        private String submissionId;
        private Integer retryCount;

        public MLROrchestrationQueueable(String submissionId) {
            this(submissionId, 0);
        }

        public MLROrchestrationQueueable(String submissionId, Integer retryCount) {
            this.submissionId = submissionId;
            this.retryCount = retryCount;
        }

        public void execute(QueueableContext ctx) {
            try {
                // ── PHASE 1: SOQL ONLY — no DML, no callouts ─────────────────────────
                MLR_Submission__c submission = [
                    SELECT Id, Asset_Text__c, Asset_Type__c, Program__c, Model_Run_Id__c, Name
                    FROM MLR_Submission__c
                    WHERE Id = :submissionId
                    LIMIT 1
                ];

                // Extract file text via SOQL (no DML here)
                String fileText = extractFileText(submissionId);

                // PDF/Word/PPTX: Salesforce indexes TextPreview asynchronously (takes 2-5 min).
                // Schedule a delayed retry instead of immediate re-enqueue so indexing has time to complete.
                if (String.isBlank(fileText) && retryCount < 3) {
                    Integer fileCount = [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :submissionId];
                    if (fileCount > 0) {
                        Datetime nextRun = Datetime.now().addMinutes(2);
                        String cron = '0 ' + nextRun.minute() + ' ' + nextRun.hour() + ' '
                            + nextRun.day() + ' ' + nextRun.month() + ' ? ' + nextRun.year();
                        String jobName = 'MLR_Retry_' + submissionId.left(8) + '_' + retryCount;
                        try {
                            System.schedule(jobName, cron, new MLRRetrySchedulable(submissionId, retryCount + 1));
                        } catch (System.AsyncException ex) {
                            // Job already scheduled by a concurrent trigger or button click — first one wins
                        }
                        return;
                    }
                }

                String assetText = String.isNotBlank(fileText) ? fileText
                    : (submission.Asset_Text__c != null ? submission.Asset_Text__c : '');
                String assetType = submission.Asset_Type__c != null ? submission.Asset_Type__c : 'Other';
                String program   = submission.Program__c   != null ? submission.Program__c   : 'General';
                String runId     = submission.Model_Run_Id__c != null ? submission.Model_Run_Id__c : submission.Name;

                List<MLR_Agent_Result__c> agentResults = [
                    SELECT Id, Agent_Type__c
                    FROM MLR_Agent_Result__c
                    WHERE MLR_Submission__c = :submissionId
                ];
                Map<String, MLR_Agent_Result__c> resultByType = new Map<String, MLR_Agent_Result__c>();
                for (MLR_Agent_Result__c r : agentResults) {
                    resultByType.put(r.Agent_Type__c, r);
                }

                // Load regulatory grounding via helper (SOQL only — safe before callouts)
                Map<String, String> groundingByStage = MLRRegulatoryRefHelper.getGroundingByStage();

                // ── PHASE 2: ALL CALLOUTS — no DML allowed yet ───────────────────────
                // Salesforce rule: callouts must precede all DML in the same transaction.
                // Run LLM stages in sequence; stop calling as soon as a stage fails,
                // but do NOT commit anything until all callouts are done.
                List<String> stages = new List<String>{ 'Medical', 'Legal', 'Regulatory' };
                Map<String, AgentReview> reviews = new Map<String, AgentReview>();
                String haltedAt = null;

                for (String stage : stages) {
                    if (haltedAt != null) break;
                    String groundingContext = groundingByStage.containsKey(stage) ? groundingByStage.get(stage) : '';
                    AgentReview review = callPromptBuilder(stage, assetText, assetType, program, groundingContext);
                    reviews.put(stage, review);
                    if (review.confidence == 'Low') {
                        haltedAt = stage;
                    }
                }

                // ── PHASE 3: ALL DML — callouts are done ─────────────────────────────
                // Persist extracted file text if we got it
                if (String.isNotBlank(fileText)) {
                    update new MLR_Submission__c(
                        Id = submissionId,
                        Asset_Text__c = fileText.left(131072)
                    );
                }

                // Write all agent results — insert fresh records if none exist, update if they do
                List<MLR_Agent_Result__c> toInsert = new List<MLR_Agent_Result__c>();
                List<MLR_Agent_Result__c> toUpdate = new List<MLR_Agent_Result__c>();
                for (String stage : stages) {
                    MLR_Agent_Result__c result = resultByType.get(stage);
                    Boolean isNew = (result == null);
                    if (isNew) {
                        result = new MLR_Agent_Result__c(
                            MLR_Submission__c = submissionId,
                            Agent_Type__c = stage
                        );
                    }

                    if (reviews.containsKey(stage)) {
                        AgentReview rev = reviews.get(stage);
                        result.Processing_Status__c   = 'Complete';
                        result.Rationale__c           = rev.rationale;
                        result.Flags__c               = rev.flags;
                        result.Confidence__c          = rev.confidence;
                        result.Grounding_Score__c     = rev.groundingScore;
                        result.Grounding_Reference__c = rev.groundingReference;
                        result.Cited_Source__c        = rev.citedSource;
                        result.Prompt_Version__c      = rev.promptVersion;
                        result.Model_Run_Id__c        = runId;
                    } else {
                        // Skipped due to upstream failure
                        result.Processing_Status__c = 'Pending';
                        result.Rationale__c = 'Not reviewed — ' + haltedAt + ' pre-screening did not pass. '
                            + 'Revisions are required before ' + stage + ' review can proceed. '
                            + 'Resubmit after addressing the ' + haltedAt + ' flags.';
                        result.Flags__c = 'Stage skipped due to upstream failure at ' + haltedAt + '.';
                    }

                    if (isNew) toInsert.add(result);
                    else toUpdate.add(result);
                }
                if (!toInsert.isEmpty()) insert toInsert;
                if (!toUpdate.isEmpty()) update toUpdate;

                // Update submission status
                if (haltedAt != null) {
                    update new MLR_Submission__c(
                        Id = submissionId,
                        Agent_Run_Status__c = 'Complete',
                        Status__c = 'Revisions Required',
                        Current_Stage__c = haltedAt,
                        Overall_Confidence__c = 'Low'
                    );
                } else {
                    List<MLR_Agent_Result__c> completed = [
                        SELECT Confidence__c FROM MLR_Agent_Result__c
                        WHERE MLR_Submission__c = :submissionId
                    ];
                    update new MLR_Submission__c(
                        Id = submissionId,
                        Agent_Run_Status__c = 'Complete',
                        Status__c = 'Pre-Screened',
                        Current_Stage__c = 'Complete',
                        Overall_Confidence__c = deriveOverallConfidence(completed)
                    );
                }

            } catch (Exception e) {
                update new MLR_Submission__c(
                    Id = submissionId,
                    Agent_Run_Status__c = 'Failed',
                    Processing_Error__c = e.getMessage() + '\n' + e.getStackTraceString()
                );
            }
        }
    }

    // ─── Phase 2: Einstein Prompt Builder ────────────────────────────────────────

    // Invokes the LLM via Salesforce Named Credential (MLR_LLM_Service).
    // Named Credential is configured in Salesforce Setup — no external SDK, no external dependency.
    // Uses OpenAI-compatible chat completion format; works with OpenAI, Azure OpenAI, or any
    // OpenAI-compatible endpoint configured in the Named Credential.
    // Prompts embed the full regulatory grounding context for each stage.
    // Falls back to keyword simulation if the Named Credential is not yet configured.
    private static AgentReview callPromptBuilder(String stage, String assetText, String assetType, String program, String groundingContext) {
        try {
            String systemPrompt = buildSystemPrompt(stage, assetType, program, groundingContext);
            String userContent = 'Review the following promotional material content:\n\n'
                + assetText.left(30000)
                + (assetText.length() > 30000 ? '\n\n[Content truncated — first 30,000 characters reviewed]' : '');

            // Build OpenAI-compatible chat completion request
            Map<String, Object> requestBody = new Map<String, Object>{
                'model' => 'openai/gpt-oss-120b',
                'temperature' => 0,
                'max_tokens' => 1000,
                'messages' => new List<Object>{
                    new Map<String, String>{ 'role' => 'system', 'content' => systemPrompt },
                    new Map<String, String>{ 'role' => 'user',   'content' => userContent }
                }
            };

            MLR_Config__c config = MLR_Config__c.getInstance();
            String apiKey = (config != null) ? config.LLM_API_Key__c : null;
            if (String.isBlank(apiKey)) {
                throw new CalloutException('LLM API key not configured. Go to Setup > Custom Settings > MLR Config > Manage and add the key.');
            }

            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:MLR_LLM_Service/openai/v1/chat/completions');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Authorization', 'Bearer ' + apiKey);
            req.setBody(JSON.serialize(requestBody));
            req.setTimeout(30000);

            HttpResponse resp = new Http().send(req);
            if (resp.getStatusCode() != 200) {
                throw new CalloutException('LLM returned HTTP ' + resp.getStatusCode()
                    + ': ' + resp.getBody().left(300));
            }

            // Parse OpenAI-format response: choices[0].message.content
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(resp.getBody());
            List<Object> choices = (List<Object>) body.get('choices');
            Map<String, Object> message = (Map<String, Object>) ((Map<String, Object>) choices[0]).get('message');
            String llmText = (String) message.get('content');

            AgentReview review = parseEinsteinResponse(llmText, stage, assetType, program);
            review.promptVersion = 'v3.0-prompt-builder-llm';
            return review;

        } catch (Exception e) {
            AgentReview review = generateReview(stage, assetText, assetType, program);
            review.promptVersion = 'v2.1-mlr-keyword-fallback';
            review.rationale = '[LLM_ERROR: ' + e.getTypeName() + ': ' + e.getMessage() + '] ' + review.rationale;
            return review;
        }
    }

    // Builds the system prompt for the given review stage.
    // Embeds regulatory grounding context so the LLM applies stage-specific standards.
    private static String buildSystemPrompt(String stage, String assetType, String program, String groundingContext) {
        String base = 'You are a Pharmaceutical ' + stage + ' Specialist performing MLR pre-screening '
            + 'of a ' + assetType + ' promotional asset for the ' + program + ' program.\n\n'
            + 'Return your analysis as valid JSON only, with no extra text, in this exact format:\n'
            + '{\n'
            + '  "confidence": "High" or "Medium" or "Low",\n'
            + '  "rationale": "' + stage.toUpperCase() + ' REVIEW — [PASS|REVISIONS REQUIRED|FAIL]\\n\\nAsset Type: ' + assetType + ' | Program: ' + program + '\\n\\nFINDING: [your specific finding]\\n\\nRECOMMENDATION: [actionable guidance]",\n'
            + '  "flags": "[flag code] description, one per line, or \\"No critical flags identified.\\"",\n'
            + '  "groundingScore": 0.0 to 1.0,\n'
            + '  "groundingReference": "cite the specific regulation section(s) that apply",\n'
            + '  "citedSource": "cite the knowledge source used"\n'
            + '}\n\n';

        if (String.isNotBlank(groundingContext)) {
            base += 'REGULATORY GROUNDING — authoritative source material (cite these directly in your response):\n'
                + groundingContext.left(8000) + '\n\n';
        }

        if (stage == 'Medical') {
            return base
                + 'REGULATORY STANDARDS TO APPLY:\n'
                + '- FDA Prescribing Information requirements\n'
                + '- ICMJE Clinical Trial Reporting Standards\n'
                + '- AMA Manual of Style 11th Edition\n'
                + '- PhRMA Code on Interactions with Healthcare Professionals\n\n'
                + 'REVIEW CHECKLIST:\n'
                + '1. Are efficacy claims substantiated by peer-reviewed clinical endpoint data?\n'
                + '2. Do comparative claims reference head-to-head RCT data?\n'
                + '3. Is safety/risk information presented with prominence equal to efficacy (fair balance)?\n'
                + '4. Does absolute language ("only","always","never") have definitive evidentiary support?\n'
                + '5. Are all clinical study references primary endpoints (not exploratory)?\n\n'
                + 'Confidence = High: no issues. Medium: 1-2 issues. Low: 3+ issues.\n'
                + 'citedSource = "Clinical Evidence Repository v2024.Q4"\n'
                + 'groundingReference = "FDA Prescribing Information; ICMJE Clinical Trial Reporting Standards; AMA Manual of Style 11th Ed."';
        } else if (stage == 'Legal') {
            return base
                + 'REGULATORY STANDARDS TO APPLY:\n'
                + '- FTC Act §5 (deceptive trade practices)\n'
                + '- Lanham Act §43(a) (comparative advertising)\n'
                + '- PhRMA Code on Interactions with Healthcare Professionals\n'
                + '- HIPAA / CCPA (patient data privacy)\n'
                + '- Anti-Kickback Statute (pricing/reimbursement references)\n\n'
                + 'REVIEW CHECKLIST:\n'
                + '1. Do comparative advertising claims meet Lanham Act §43(a) truthfulness requirements?\n'
                + '2. Do superlative claims ("best","only") risk FTC Act §5 violations?\n'
                + '3. Do pricing/reimbursement references implicate anti-kickback statutes?\n'
                + '4. Do patient data references comply with HIPAA/CCPA?\n'
                + '5. Are trademark/IP symbols used correctly?\n\n'
                + 'Confidence = High: 0 issues. Medium: 1 issue. Low: 2+ issues.\n'
                + 'citedSource = "Legal Compliance Knowledge Base v2024.3"\n'
                + 'groundingReference = "FTC Act §5; Lanham Act §43(a); PhRMA Code; CAN-SPAM Act"';
        } else {
            return base
                + 'REGULATORY STANDARDS TO APPLY:\n'
                + '- FDA 21 CFR Part 202 (prescription drug advertising)\n'
                + '- FDA 21 CFR §202.1(e)(5) (fair balance requirement)\n'
                + '- FDA 21 CFR §202.1(e)(1) (brief summary of PI)\n'
                + '- FDA OPDP Guidance on Presenting Risk Information\n'
                + '- Pediatric Research Equity Act (PREA)\n'
                + '- EMA Good Practice Guide for Promotional Material\n\n'
                + 'REVIEW CHECKLIST:\n'
                + '1. Is risk information presented with prominence equal to efficacy (21 CFR §202.1(e)(5))?\n'
                + '2. Is there any potential off-label promotion of unapproved uses?\n'
                + '3. Are all efficacy claims supported by FDA-approved clinical data?\n'
                + '4. For Emails/Brochures: is the Brief Summary or PI link present (21 CFR §202.1(e)(1))?\n'
                + '5. Do pediatric population references comply with PREA?\n\n'
                + 'Confidence = High: 0 issues. Medium: 1-2 issues. Low: 3+ issues.\n'
                + 'citedSource = "Regulatory Affairs Knowledge Base v2024.Q4; FDA OPDP Database"\n'
                + 'groundingReference = "FDA 21 CFR Part 202; FDA Guidance on Presenting Risk Information; OPDP Promotional Material Guidelines"';
        }
    }

    // Parses the structured JSON response returned by the Einstein LLM.
    // Expected format: {"confidence":"High|Medium|Low","rationale":"...","flags":"...","groundingScore":0.9,...}
    // Falls back to treating the raw text as the rationale if JSON parsing fails.
    private static AgentReview parseEinsteinResponse(String llmText, String stage, String assetType, String program) {
        AgentReview r = new AgentReview();
        try {
            // Strip markdown code fences if present (LLM sometimes wraps JSON in ```json ... ```)
            String jsonStr = llmText.trim();
            if (jsonStr.startsWith('```')) {
                Integer newline = jsonStr.indexOf('\n');
                Integer closeFence = jsonStr.lastIndexOf('```');
                if (newline > 0 && closeFence > newline) {
                    jsonStr = jsonStr.substring(newline + 1, closeFence).trim();
                }
            }

            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(jsonStr);

            r.confidence         = (String) parsed.get('confidence');
            r.rationale          = (String) parsed.get('rationale');
            r.flags              = (String) parsed.get('flags');
            r.groundingScore     = parsed.get('groundingScore') != null
                                       ? Double.valueOf(String.valueOf(parsed.get('groundingScore'))) : 0.75;
            r.groundingReference = (String) parsed.get('groundingReference');
            r.citedSource        = (String) parsed.get('citedSource');

            // Normalise confidence — guard against unexpected LLM values
            if (r.confidence != 'High' && r.confidence != 'Medium' && r.confidence != 'Low') {
                r.confidence = 'Medium';
            }
            if (String.isBlank(r.rationale))          r.rationale          = llmText;
            if (String.isBlank(r.flags))              r.flags              = 'No critical flags identified.';
            if (String.isBlank(r.groundingReference)) r.groundingReference = stage + ' Regulatory Standards';
            if (String.isBlank(r.citedSource))        r.citedSource        = 'Einstein AI Analysis';

        } catch (Exception e) {
            // JSON parse failed — use raw LLM text as rationale, default to Medium
            r.confidence         = 'Medium';
            r.rationale          = llmText;
            r.flags              = 'No critical flags identified.';
            r.groundingScore     = 0.70;
            r.groundingReference = stage + ' Regulatory Standards';
            r.citedSource        = 'Einstein AI Analysis';
        }
        return r;
    }

    // ─── Phase 1 Fallback: Keyword Simulation ────────────────────────────────────

    // Reads text from the most recently uploaded file attached to the submission.
    // TXT files: decoded directly from VersionData blob (always available, immediate).
    // PDF/Word/PPTX: uses Salesforce's auto-generated TextPreview (indexed asynchronously, up to 32KB).
    // If TextPreview is blank the caller retries up to 3 times before falling back to Asset_Text__c.
    private static String extractFileText(String submissionId) {
        try {
            List<ContentDocumentLink> links = [
                SELECT ContentDocumentId
                FROM ContentDocumentLink
                WHERE LinkedEntityId = :submissionId
                ORDER BY SystemModstamp DESC
                LIMIT 1
            ];
            if (links.isEmpty()) return null;

            List<ContentVersion> versions = [
                SELECT Title, FileExtension, FileType, TextPreview, VersionData
                FROM ContentVersion
                WHERE ContentDocumentId = :links[0].ContentDocumentId
                AND IsLatest = true
                LIMIT 1
            ];
            if (versions.isEmpty()) return null;

            ContentVersion cv = versions[0];
            String ext = cv.FileExtension != null ? cv.FileExtension.toLowerCase() : '';

            // Plain text: decode blob directly — always immediately available
            if (ext == 'txt' || cv.FileType == 'TEXT') {
                return cv.VersionData.toString();
            }

            // PDF, Word, PowerPoint: use Salesforce's auto-extracted preview
            if (String.isNotBlank(cv.TextPreview)) {
                return cv.TextPreview;
            }

            return null;
        } catch (Exception e) {
            return null;
        }
    }

    private static AgentReview generateReview(String agentType, String assetText, String assetType, String program) {
        String lower = assetText.toLowerCase();

        Boolean hasClaim      = lower.contains('efficacy') || lower.contains('effective') || lower.contains('proven') ||
                                lower.contains('superior') || lower.contains('best') || lower.contains('significant') ||
                                lower.contains('reduce') || lower.contains('improve') || lower.contains('increase');
        Boolean hasSafety     = lower.contains('adverse') || lower.contains('side effect') || lower.contains('warning') ||
                                lower.contains('contraindic') || lower.contains('risk') || lower.contains('serious');
        Boolean hasEndpoint   = lower.contains('%') || lower.contains('trial') || lower.contains('study') ||
                                lower.contains('clinical') || lower.contains('placebo') || lower.contains('p-value') ||
                                lower.contains('p <') || lower.contains('hazard ratio');
        Boolean hasComparative = lower.contains('vs.') || lower.contains('versus') || lower.contains('compared to') ||
                                 lower.contains('better than') || lower.contains('more than');
        Boolean hasAbsolute   = lower.contains('only') || lower.contains('always') || lower.contains('never') ||
                                lower.contains('all patients') || lower.contains('100%');

        if (agentType == 'Medical') {
            return buildMedicalReview(assetText, assetType, program, hasClaim, hasSafety, hasEndpoint, hasComparative, hasAbsolute);
        } else if (agentType == 'Legal') {
            return buildLegalReview(assetText, assetType, program, hasClaim, hasComparative, hasAbsolute);
        } else {
            return buildRegulatoryReview(assetText, assetType, program, hasClaim, hasSafety, hasEndpoint);
        }
    }

    private static AgentReview buildMedicalReview(String assetText, String assetType, String program,
            Boolean hasClaim, Boolean hasSafety, Boolean hasEndpoint, Boolean hasComparative, Boolean hasAbsolute) {
        AgentReview r = new AgentReview();
        r.groundingReference = 'FDA Prescribing Information; ICMJE Clinical Trial Reporting Standards; AMA Manual of Style 11th Ed.';
        r.citedSource = 'Clinical Evidence Repository v2024.Q4';

        List<String> findings = new List<String>();
        List<String> flags    = new List<String>();
        Integer issueCount    = 0;

        if (hasClaim && !hasEndpoint) {
            findings.add('FINDING: Efficacy claims present without supporting clinical endpoint data. All promotional claims must be substantiated by peer-reviewed evidence or approved prescribing information.');
            flags.add('[MED-001] Unsubstantiated efficacy claim — clinical data citation required');
            issueCount++;
        }
        if (hasClaim && hasEndpoint) {
            findings.add('FINDING: Efficacy claims are accompanied by clinical endpoint data. Verify that referenced study endpoints are primary (not exploratory) and statistically significant.');
        }
        if (hasComparative) {
            findings.add('FINDING: Comparative claims detected. Head-to-head data must be from a prospective, randomized, controlled trial with the same study design and patient population.');
            flags.add('[MED-002] Comparative claim — head-to-head RCT data required');
            issueCount++;
        }
        if (!hasSafety && hasClaim) {
            findings.add('FINDING: Promotional claims present but safety/tolerability context is limited. Fair balance requires safety information to be presented with equivalent prominence to efficacy claims.');
            flags.add('[MED-003] Fair balance concern — safety data underrepresented');
            issueCount++;
        }
        if (hasSafety) {
            findings.add('FINDING: Safety and adverse event information identified. Confirm completeness against approved PI; verify all boxed warnings and contraindications are included for ' + assetType + ' format.');
        }
        if (hasAbsolute) {
            findings.add('FINDING: Absolute language ("only", "always", "never") detected. These terms may constitute misleading claims unless supported by definitive clinical evidence.');
            flags.add('[MED-004] Absolute language — verify evidentiary support');
            issueCount++;
        }
        if (findings.isEmpty()) {
            findings.add('FINDING: No significant medical accuracy concerns identified. Content appears consistent with approved prescribing information for ' + program + '. Standard medical affairs sign-off recommended before distribution.');
        }

        if (issueCount == 0) {
            r.confidence    = 'High';
            r.groundingScore = 0.91;
            r.rationale     = 'MEDICAL REVIEW — PASS WITH STANDARD REVIEW\n\n';
        } else if (issueCount <= 2) {
            r.confidence    = 'Medium';
            r.groundingScore = 0.74;
            r.rationale     = 'MEDICAL REVIEW — PASS WITH REVISIONS REQUIRED\n\n';
        } else {
            r.confidence    = 'Low';
            r.groundingScore = 0.52;
            r.rationale     = 'MEDICAL REVIEW — HOLD FOR SIGNIFICANT REVISIONS\n\n';
        }

        r.rationale += 'Asset Type: ' + assetType + ' | Program: ' + program + '\n\n'
            + String.join(findings, '\n\n')
            + '\n\nRECOMMENDATION: ' + (issueCount == 0
                ? 'Proceed to Legal review with no medical revisions.'
                : 'Address ' + issueCount + ' identified issue(s) before progressing to Legal review. Re-submit for medical pre-screening after revisions.');
        r.flags = flags.isEmpty() ? 'No critical medical flags identified.' : String.join(flags, '\n');
        return r;
    }

    private static AgentReview buildLegalReview(String assetText, String assetType, String program,
            Boolean hasClaim, Boolean hasComparative, Boolean hasAbsolute) {
        AgentReview r = new AgentReview();
        r.groundingReference = 'FTC Act §5; Lanham Act §43(a); PhRMA Code on Interactions with Healthcare Professionals; CAN-SPAM Act';
        r.citedSource = 'Legal Compliance Knowledge Base v2024.3';

        List<String> findings = new List<String>();
        List<String> flags    = new List<String>();
        Integer issueCount    = 0;

        String lower = assetText.toLowerCase();
        Boolean hasIP      = lower.contains('trademark') || lower.contains('registered') || lower.contains('©') || lower.contains('™') || lower.contains('®');
        Boolean hasPrivacy = lower.contains('patient data') || lower.contains('personal information') || lower.contains('hipaa') || lower.contains('privacy');
        Boolean hasPricing = lower.contains('price') || lower.contains('cost') || lower.contains('reimburs') || lower.contains('copay') || lower.contains('coverage');

        if (hasComparative) {
            findings.add('FINDING: Comparative advertising claims identified. Under the Lanham Act §43(a), all comparative statements must be truthful, non-deceptive, and substantiated. Third-party substantiation documentation required in the approval package.');
            flags.add('[LEG-001] Comparative advertising — Lanham Act §43(a) compliance required');
            issueCount++;
        }
        if (hasAbsolute) {
            findings.add('FINDING: Superlative or absolute claims ("best," "only," "never") present. These may constitute deceptive trade practices under FTC Act §5 if not substantiated. Legal team to confirm evidentiary basis.');
            flags.add('[LEG-002] Superlative claim — FTC Act §5 risk');
            issueCount++;
        }
        if (hasPricing) {
            findings.add('FINDING: Pricing, reimbursement, or coverage references detected. Patient assistance and pricing claims are subject to anti-kickback statutes and state price transparency laws. Legal review of all financial content mandatory.');
            flags.add('[LEG-003] Pricing/reimbursement content — anti-kickback statute review required');
            issueCount++;
        }
        if (hasPrivacy) {
            findings.add('FINDING: Patient or personal data references detected. Ensure HIPAA and CCPA compliance. Any collection of personally identifiable health information requires appropriate consent language and privacy notices.');
            flags.add('[LEG-004] Patient data reference — HIPAA/CCPA compliance check');
            issueCount++;
        }
        if (!hasIP && assetType != 'Email') {
            findings.add('FINDING: Verify trademark registration status of all brand names and logos. Ensure ® and ™ symbols are used correctly per trademark counsel guidelines. First use of brand name should include appropriate trademark notation.');
        }
        if (findings.isEmpty() || issueCount == 0) {
            findings.add('FINDING: ' + assetType + ' content reviewed against standard legal requirements for pharmaceutical promotional materials. No significant legal compliance issues identified. Standard disclaimers and PI reference should be confirmed present.');
        }

        if (issueCount == 0) {
            r.confidence    = 'High';
            r.groundingScore = 0.89;
            r.rationale     = 'LEGAL REVIEW — CLEAR FOR PROGRESSION\n\n';
        } else if (issueCount == 1) {
            r.confidence    = 'Medium';
            r.groundingScore = 0.71;
            r.rationale     = 'LEGAL REVIEW — CONDITIONAL APPROVAL\n\n';
        } else {
            r.confidence    = 'Low';
            r.groundingScore = 0.55;
            r.rationale     = 'LEGAL REVIEW — MATERIAL REVISIONS REQUIRED\n\n';
        }

        r.rationale += 'Asset Type: ' + assetType + ' | Program: ' + program + '\n\n'
            + String.join(findings, '\n\n')
            + '\n\nRECOMMENDATION: ' + (issueCount == 0
                ? 'Clear for Regulatory review. No legal revisions required.'
                : issueCount + ' legal issue(s) require resolution. Legal counsel sign-off mandatory before Regulatory submission.');
        r.flags = flags.isEmpty() ? 'No critical legal flags identified.' : String.join(flags, '\n');
        return r;
    }

    private static AgentReview buildRegulatoryReview(String assetText, String assetType, String program,
            Boolean hasClaim, Boolean hasSafety, Boolean hasEndpoint) {
        AgentReview r = new AgentReview();
        r.groundingReference = 'FDA 21 CFR Part 202; FDA Guidance on Presenting Risk Information; EMA Good Practice Guide for Promotional Material; OPDP Promotional Material Guidelines';
        r.citedSource = 'Regulatory Affairs Knowledge Base v2024.Q4; FDA OPDP Database';

        List<String> findings = new List<String>();
        List<String> flags    = new List<String>();
        Integer issueCount    = 0;

        String lower = assetText.toLowerCase();
        Boolean hasOffLabel  = lower.contains('off-label') || lower.contains('investigational') || lower.contains('unapproved') || lower.contains('pipeline');
        Boolean hasPediatric = lower.contains('pediatric') || lower.contains('children') || lower.contains('adolescent');
        Boolean hasDosage    = lower.contains('dose') || lower.contains('dosage') || lower.contains('mg') || lower.contains('mcg') || lower.contains('once daily') || lower.contains('twice daily');

        if (hasClaim && !hasSafety) {
            findings.add('FINDING: Under 21 CFR §202.1(e)(5), prescription drug promotion must present risk information with a "fair balance" relative to efficacy information. Risk/benefit presentation appears imbalanced in current draft.');
            flags.add('[REG-001] Fair balance violation risk — 21 CFR §202.1(e)(5)');
            issueCount++;
        }
        if (hasOffLabel) {
            findings.add('FINDING: Potential off-label content detected. FDA regulations prohibit promotion of unapproved uses. All claims must align strictly with the FDA-approved labeling. Any off-label references must be removed or substantiated through an approved sNDA/sBLA.');
            flags.add('[REG-002] Potential off-label promotion — FDA Compliance Alert');
            issueCount += 2;
        }
        if (hasClaim && !hasEndpoint) {
            findings.add('FINDING: Per FDA OPDP guidance, all efficacy claims in promotional labeling must reference approved clinical data. Unsubstantiated claims may constitute misbranding under 21 CFR §201.56. Ensure primary endpoint data is cited.');
            flags.add('[REG-003] Claim without endpoint citation — misbranding risk');
            issueCount++;
        }
        if (hasPediatric) {
            findings.add('FINDING: Pediatric population references detected. Verify FDA-approved labeling includes pediatric indication. Per PREA requirements, pediatric promotional materials require additional review layers including specific safety labeling for the target age group.');
            flags.add('[REG-004] Pediatric claim — PREA compliance verification required');
            issueCount++;
        }
        if (assetType == 'Email' || assetType == 'Brochure') {
            findings.add('FINDING: ' + assetType + ' format requires a "Brief Summary" or link to full Prescribing Information per 21 CFR §202.1(e)(1). Confirm PI reference is present and accurate. For digital assets, hyperlink to full PI must be functional at time of distribution.');
            if (assetType == 'Brochure') {
                flags.add('[REG-005] PI brief summary required — 21 CFR §202.1(e)(1)');
                issueCount++;
            }
        }
        if (findings.isEmpty() || issueCount == 0) {
            findings.add('FINDING: ' + assetType + ' content reviewed against FDA promotional material regulations. Content appears to be within the bounds of approved labeling for ' + program + '. Standard regulatory affairs verification of PI cross-reference recommended.');
        }

        if (issueCount == 0) {
            r.confidence    = 'High';
            r.groundingScore = 0.93;
            r.rationale     = 'REGULATORY REVIEW — APPROVED FOR FINAL REVIEW\n\n';
        } else if (issueCount <= 2) {
            r.confidence    = 'Medium';
            r.groundingScore = 0.68;
            r.rationale     = 'REGULATORY REVIEW — APPROVED WITH CONDITIONS\n\n';
        } else {
            r.confidence    = 'Low';
            r.groundingScore = 0.41;
            r.rationale     = 'REGULATORY REVIEW — NOT APPROVED — SIGNIFICANT REGULATORY RISK\n\n';
        }

        r.rationale += 'Asset Type: ' + assetType + ' | Program: ' + program + '\n\n'
            + String.join(findings, '\n\n')
            + '\n\nRECOMMENDATION: ' + (issueCount == 0
                ? 'Asset cleared for final MLR committee approval. No regulatory revisions required.'
                : issueCount + ' regulatory issue(s) identified. ' + (issueCount > 2
                    ? 'DO NOT distribute. Mandatory regulatory revision and re-submission required.'
                    : 'Address identified items and re-confirm with Regulatory Affairs before final approval.'));
        r.flags = flags.isEmpty() ? 'No critical regulatory flags identified.' : String.join(flags, '\n');
        return r;
    }

    private static String deriveOverallConfidence(List<MLR_Agent_Result__c> results) {
        Integer lowCount = 0;
        for (MLR_Agent_Result__c r : results) {
            if (r.Confidence__c == 'Low') lowCount++;
        }
        if (lowCount > 0) return 'Low';
        Integer medCount = 0;
        for (MLR_Agent_Result__c r : results) {
            if (r.Confidence__c == 'Medium') medCount++;
        }
        return medCount > 0 ? 'Medium' : 'High';
    }

    private class AgentReview {
        String rationale;
        String flags;
        String confidence;
        Double groundingScore;
        String groundingReference;
        String citedSource;
        String promptVersion;
    }
}
