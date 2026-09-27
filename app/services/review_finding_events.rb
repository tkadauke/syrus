class ReviewFindingEvents
  def self.record(workflow:, step:, run:, review_kind:, iteration:, verdict:, critique:, skipped: false, skip_reason: nil)
    AppEvents.broadcast_job_resource(
      job_id: workflow.job_id,
      type: "review_finding.recorded",
      resource: "workflow",
      id: workflow.id,
      changed: [ "#{review_kind}.iterations" ],
      payload: {
        workflow_id: workflow.id,
        step_id: step.id,
        run_id: run.id,
        review_kind: review_kind,
        iteration: iteration,
        verdict: verdict,
        critique: critique,
        skipped: skipped,
        skip_reason: skip_reason
      }.compact
    )
  end
end
