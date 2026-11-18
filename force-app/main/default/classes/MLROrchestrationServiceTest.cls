@isTest
private class MLROrchestrationServiceTest {

    @testSetup
    static void setup() {
        MLR_Submission__c sub = new MLR_Submission__c(
            Asset_Type__c = 'Brochure',
            Program__c = 'Test Program',
            Asset_Text__c = 'Sample asset text for testing.',
            Citation_Reference__c = 'Label Section 4.1',
            Status__c = 'Draft'
        );
        insert sub;

        List<MLR_Agent_Result__c> results = new List<MLR_Agent_Result__c>{
            new MLR_Agent_Result__c(MLR_Submission__c = sub.Id, Agent_Type__c = 'Medical', Confidence__c = 'Low', Processing_Status__c = 'Pending', Rationale__c = 'Pending'),
            new MLR_Agent_Result__c(MLR_Submission__c = sub.Id, Agent_Type__c = 'Legal', Confidence__c = 'Low', Processing_Status__c = 'Pending', Rationale__c = 'Pending'),
            new MLR_Agent_Result__c(MLR_Submission__c = sub.Id, Agent_Type__c = 'Regulatory', Confidence__c = 'Low', Processing_Status__c = 'Pending', Rationale__c = 'Pending')
        };
        insert results;
    }

    @isTest
    static void testOrchestrationInvocable() {
        MLR_Submission__c sub = [SELECT Id FROM MLR_Submission__c LIMIT 1];
        Test.startTest();
        MLROrchestrationService.invokeOrchestration(new List<String>{ sub.Id });
        Test.stopTest();

        MLR_Submission__c updated = [SELECT Agent_Run_Status__c FROM MLR_Submission__c WHERE Id = :sub.Id];
        System.assertNotEquals('Failed', updated.Agent_Run_Status__c, 'Orchestration should not fail');
    }

    @isTest
    static void testAgentResultWriter() {
        MLR_Submission__c sub = [SELECT Id FROM MLR_Submission__c LIMIT 1];

        MLRAgentResultWriter.AgentOutputRequest req = new MLRAgentResultWriter.AgentOutputRequest();
        req.submissionId = sub.Id;
        req.agentType = 'Medical';
        req.confidence = 'High';
        req.rationale = 'All claims align with approved label Section 4.1.';
        req.citedSource = 'Approved Label Section 4.1';
        req.groundingReference = 'CHUNK-001';
        req.flags = 'none';
        req.groundingScore = 0.92;
        req.promptVersion = 'v1.0';

        Test.startTest();
        MLRAgentResultWriter.writeAgentResult(new List<MLRAgentResultWriter.AgentOutputRequest>{ req });
        Test.stopTest();

        MLR_Agent_Result__c result = [SELECT Confidence__c, Processing_Status__c FROM MLR_Agent_Result__c WHERE MLR_Submission__c = :sub.Id AND Agent_Type__c = 'Medical' AND Confidence__c = 'High' ORDER BY LastModifiedDate DESC LIMIT 1];
        System.assertEquals('High', result.Confidence__c, 'Confidence should be High');
        System.assertEquals('Complete', result.Processing_Status__c, 'Status should be Complete');
    }

    @isTest
    static void testConfidenceRollup_LowWins() {
        MLR_Submission__c sub = [SELECT Id FROM MLR_Submission__c LIMIT 1];
        List<MLR_Agent_Result__c> results = [SELECT Id, Agent_Type__c FROM MLR_Agent_Result__c WHERE MLR_Submission__c = :sub.Id];

        for (MLR_Agent_Result__c r : results) {
            r.Processing_Status__c = 'Complete';
            r.Confidence__c = r.Agent_Type__c == 'Medical' ? 'Low' : 'High';
        }
        update results;

        Test.startTest();
        MLRConfidenceRollup.rollupIfComplete(new Set<String>{ sub.Id });
        Test.stopTest();

        MLR_Submission__c updated = [SELECT Overall_Confidence__c, Status__c FROM MLR_Submission__c WHERE Id = :sub.Id];
        System.assertEquals('Low', updated.Overall_Confidence__c, 'Lowest agent confidence should win');
        System.assertEquals('Pre-Screened', updated.Status__c, 'Status should be Pre-Screened');
    }

    @isTest
    static void testEmptyInvocable() {
        Test.startTest();
        MLROrchestrationService.invokeOrchestration(new List<String>());
        Test.stopTest();
        System.assert(true, 'Empty list should not throw');
    }
}
