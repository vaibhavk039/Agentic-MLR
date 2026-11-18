public without sharing class MLRConfidenceRollup {

    // Confidence priority: Low wins over Medium wins over High
    private static final Map<String, Integer> CONFIDENCE_RANK = new Map<String, Integer>{
        'Low' => 0,
        'Medium' => 1,
        'High' => 2
    };

    public static void rollupIfComplete(Set<String> submissionIds) {
        Map<String, List<MLR_Agent_Result__c>> resultsBySubmission = new Map<String, List<MLR_Agent_Result__c>>();

        for (MLR_Agent_Result__c r : [
            SELECT Id, MLR_Submission__c, Agent_Type__c, Confidence__c, Processing_Status__c
            FROM MLR_Agent_Result__c
            WHERE MLR_Submission__c IN :submissionIds
        ]) {
            if (!resultsBySubmission.containsKey(r.MLR_Submission__c)) {
                resultsBySubmission.put(r.MLR_Submission__c, new List<MLR_Agent_Result__c>());
            }
            resultsBySubmission.get(r.MLR_Submission__c).add(r);
        }

        List<MLR_Submission__c> toUpdate = new List<MLR_Submission__c>();

        for (String subId : submissionIds) {
            List<MLR_Agent_Result__c> results = resultsBySubmission.get(subId);
            if (results == null || results.size() < 3) continue;

            Boolean allComplete = true;
            for (MLR_Agent_Result__c r : results) {
                if (r.Processing_Status__c != 'Complete' && r.Processing_Status__c != 'Low Confidence Fallback') {
                    allComplete = false;
                    break;
                }
            }
            if (!allComplete) continue;

            // All three agents done — compute lowest confidence
            Integer lowestRank = 2;
            for (MLR_Agent_Result__c r : results) {
                Integer rank = CONFIDENCE_RANK.containsKey(r.Confidence__c) ? CONFIDENCE_RANK.get(r.Confidence__c) : 0;
                if (rank < lowestRank) lowestRank = rank;
            }

            String overallConfidence = 'High';
            if (lowestRank == 0) overallConfidence = 'Low';
            else if (lowestRank == 1) overallConfidence = 'Medium';

            toUpdate.add(new MLR_Submission__c(
                Id = subId,
                Overall_Confidence__c = overallConfidence,
                Status__c = 'Pre-Screened',
                Agent_Run_Status__c = 'Complete',
                Current_Stage__c = 'Medical'
            ));
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }
}
