public without sharing class MLRDashboardController {

    public class DashboardStats {
        @AuraEnabled public Integer total;
        @AuraEnabled public Integer draft;
        @AuraEnabled public Integer inReview;
        @AuraEnabled public Integer preScreened;
        @AuraEnabled public Integer approved;
        @AuraEnabled public Integer rejected;
        @AuraEnabled public Integer revisionsRequired;
        @AuraEnabled public Integer highConfidence;
        @AuraEnabled public Integer mediumConfidence;
        @AuraEnabled public Integer lowConfidence;
    }

    @AuraEnabled(cacheable=true)
    public static DashboardStats getDashboardStats() {
        DashboardStats s = new DashboardStats();
        s.total       = [SELECT COUNT() FROM MLR_Submission__c];
        s.draft       = [SELECT COUNT() FROM MLR_Submission__c WHERE Status__c = 'Draft'];
        s.inReview    = [SELECT COUNT() FROM MLR_Submission__c WHERE Status__c = 'In Review'];
        s.preScreened = [SELECT COUNT() FROM MLR_Submission__c WHERE Status__c = 'Pre-Screened'];
        s.approved    = [SELECT COUNT() FROM MLR_Submission__c WHERE Status__c = 'Approved'];
        s.rejected          = [SELECT COUNT() FROM MLR_Submission__c WHERE Status__c = 'Rejected'];
        s.revisionsRequired = [SELECT COUNT() FROM MLR_Submission__c WHERE Status__c = 'Revisions Required'];
        s.highConfidence   = [SELECT COUNT() FROM MLR_Submission__c WHERE Overall_Confidence__c = 'High'];
        s.mediumConfidence = [SELECT COUNT() FROM MLR_Submission__c WHERE Overall_Confidence__c = 'Medium'];
        s.lowConfidence    = [SELECT COUNT() FROM MLR_Submission__c WHERE Overall_Confidence__c = 'Low'];
        return s;
    }

    @AuraEnabled(cacheable=true)
    public static List<MLR_Submission__c> getRecentSubmissions() {
        return [
            SELECT Id, Name, Asset_Type__c, Status__c, Overall_Confidence__c,
                   Current_Stage__c, Submitted_Date__c, Program__c, Agent_Run_Status__c
            FROM MLR_Submission__c
            ORDER BY CreatedDate DESC
            LIMIT 10
        ];
    }

    @AuraEnabled(cacheable=true)
    public static List<MLR_Agent_Result__c> getAgentResultsForSubmission(String submissionId) {
        return [
            SELECT Id, Agent_Type__c, Processing_Status__c, Confidence__c,
                   Rationale__c, Flags__c, Grounding_Score__c, Grounding_Reference__c,
                   Cited_Source__c, Prompt_Version__c, Model_Run_Id__c
            FROM MLR_Agent_Result__c
            WHERE MLR_Submission__c = :submissionId
            ORDER BY Agent_Type__c ASC
        ];
    }
}
