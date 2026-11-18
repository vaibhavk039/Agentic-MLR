public without sharing class MLRAgentResultWriter {

    public class AgentOutputRequest {
        @InvocableVariable(label='Submission ID' required=true)
        public String submissionId;

        @InvocableVariable(label='Agent Type (Medical/Legal/Regulatory)' required=true)
        public String agentType;

        @InvocableVariable(label='Confidence (High/Medium/Low)' required=true)
        public String confidence;

        @InvocableVariable(label='Rationale')
        public String rationale;

        @InvocableVariable(label='Cited Source')
        public String citedSource;

        @InvocableVariable(label='Grounding Reference')
        public String groundingReference;

        @InvocableVariable(label='Flags (comma-separated)')
        public String flags;

        @InvocableVariable(label='Grounding Score')
        public Decimal groundingScore;

        @InvocableVariable(label='Prompt Version')
        public String promptVersion;
    }

    @InvocableMethod(label='Write MLR Agent Result' description='Writes the output of an MLR specialist agent to the MLR_Agent_Result__c child record')
    public static void writeAgentResult(List<AgentOutputRequest> requests) {
        if (requests == null || requests.isEmpty()) return;

        List<MLR_Agent_Result__c> toUpdate = new List<MLR_Agent_Result__c>();
        List<String> submissionIds = new List<String>();
        for (AgentOutputRequest req : requests) {
            submissionIds.add(req.submissionId);
        }

        Map<String, List<MLR_Agent_Result__c>> resultsBySubmission = new Map<String, List<MLR_Agent_Result__c>>();
        for (MLR_Agent_Result__c r : [
            SELECT Id, MLR_Submission__c, Agent_Type__c
            FROM MLR_Agent_Result__c
            WHERE MLR_Submission__c IN :submissionIds
        ]) {
            if (!resultsBySubmission.containsKey(r.MLR_Submission__c)) {
                resultsBySubmission.put(r.MLR_Submission__c, new List<MLR_Agent_Result__c>());
            }
            resultsBySubmission.get(r.MLR_Submission__c).add(r);
        }

        for (AgentOutputRequest req : requests) {
            List<MLR_Agent_Result__c> candidates = resultsBySubmission.get(req.submissionId);
            if (candidates == null) continue;

            for (MLR_Agent_Result__c candidate : candidates) {
                if (candidate.Agent_Type__c == req.agentType) {
                    candidate.Confidence__c      = req.confidence;
                    candidate.Rationale__c        = req.rationale;
                    candidate.Cited_Source__c     = req.citedSource;
                    candidate.Grounding_Reference__c = req.groundingReference;
                    candidate.Flags__c            = req.flags;
                    candidate.Grounding_Score__c  = req.groundingScore;
                    candidate.Prompt_Version__c   = req.promptVersion;
                    candidate.Processing_Status__c = 'Complete';
                    toUpdate.add(candidate);
                    break;
                }
            }
        }

        if (!toUpdate.isEmpty()) {
            update as System toUpdate;
        }

        // After writing all results, check if all three agents are done and roll up confidence
        Set<String> subIds = new Set<String>(submissionIds);
        MLRConfidenceRollup.rollupIfComplete(subIds);
    }
}
