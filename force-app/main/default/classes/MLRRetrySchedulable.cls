public class MLRRetrySchedulable implements Schedulable {
    private String submissionId;
    private Integer retryCount;

    public MLRRetrySchedulable(String submissionId, Integer retryCount) {
        this.submissionId = submissionId;
        this.retryCount = retryCount;
    }

    public void execute(SchedulableContext ctx) {
        System.enqueueJob(new MLROrchestrationService.MLROrchestrationQueueable(submissionId, retryCount));
    }
}
