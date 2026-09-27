class ReviewFindingEvents
  def self.record(workflow:, step:, run:, review_kind:, iteration:, verdict:, critique:, skipped: false, skip_reason: nil)
    new(
      workflow: workflow,
      step: step,
      run: run,
      review_kind: review_kind,
      iteration: iteration,
      verdict: verdict,
      critique: critique,
      skipped: skipped,
      skip_reason: skip_reason
    ).record
  end

  def initialize(workflow:, step:, run:, review_kind:, iteration:, verdict:, critique:, skipped:, skip_reason:)
    @workflow = workflow
    @step = step
    @run = run
    @review_kind = review_kind
    @iteration = iteration
    @verdict = verdict
    @critique = critique
    @skipped = skipped
    @skip_reason = skip_reason
  end

  def record
    return unless job&.user

    AppEvents.broadcast(
      user: job.user,
      type: "job.updated",
      resource: "job",
      id: job.id,
      changed: [ "review_finding.#{review_kind}" ],
      payload: payload,
      revision: job.entity_revision
    )
  end

  private

  attr_reader :workflow, :step, :run, :review_kind, :iteration, :verdict, :critique, :skipped, :skip_reason

  def job
    @job ||= workflow.job
  end

  def payload
    {
      review_kind: review_kind,
      workflow_id: workflow.id,
      step_id: step.id,
      run_id: run.id,
      iteration: iteration,
      verdict: verdict,
      critique: critique,
      skipped: skipped,
      skip_reason: skip_reason
    }.compact
  end
end
