public without sharing class ContentDocumentLinkHandler {

    public static void handleAfterInsert(List<ContentDocumentLink> links) {
        // Collect all linked entity IDs
        Set<Id> linkedIds = new Set<Id>();
        for (ContentDocumentLink link : links) {
            if (link.LinkedEntityId != null) {
                linkedIds.add(link.LinkedEntityId);
            }
        }
        if (linkedIds.isEmpty()) return;

        // Filter to MLR_Submission__c records that are still Pending (not yet running)
        List<MLR_Submission__c> pendingSubs = [
            SELECT Id
            FROM MLR_Submission__c
            WHERE Id IN :linkedIds
            AND Agent_Run_Status__c = 'Pending'
        ];
        if (pendingSubs.isEmpty()) return;

        // Invoke orchestration for each pending submission (one file upload = one review run)
        List<String> subIds = new List<String>();
        for (MLR_Submission__c sub : pendingSubs) {
            subIds.add(sub.Id);
        }
        MLROrchestrationService.invokeOrchestration(subIds);
    }
}
