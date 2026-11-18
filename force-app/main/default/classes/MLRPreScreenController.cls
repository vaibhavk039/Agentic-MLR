public with sharing class MLRPreScreenController {

    @AuraEnabled
    public static String runPreScreen(String submissionId) {
        try {
            List<MLR_Agent_Result__c> existing = [
                SELECT Id FROM MLR_Agent_Result__c WHERE MLR_Submission__c = :submissionId
            ];
            if (!existing.isEmpty()) {
                delete existing;
            }
            System.enqueueJob(new MLROrchestrationService.MLROrchestrationQueueable(submissionId));
            return 'Pre-screen running. Results will appear below automatically.';
        } catch (Exception e) {
            throw new AuraHandledException('Failed to start pre-screen: ' + e.getMessage());
        }
    }

    @AuraEnabled(cacheable=false)
    public static List<MLR_Agent_Result__c> getResults(String submissionId) {
        return [
            SELECT Id, Name, Agent_Type__c, Confidence__c, Processing_Status__c,
                   Flags__c, Rationale__c, CreatedDate
            FROM MLR_Agent_Result__c
            WHERE MLR_Submission__c = :submissionId
            ORDER BY CreatedDate DESC
            LIMIT 9
        ];
    }
}
