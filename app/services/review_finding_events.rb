class ReviewFindingEvents
  EVENT_NAME = "operator_briefing.review_finding_recorded".freeze

  def self.record(...) = new(...).record

  def initialize(workflow:, step:, run:, review_kind:, iteration:, verdict:, critique:, artifacts: [], skipped: false, skip_reason: nil)
    @workflow = workflow
    @step = step
    @run = run
    @review_kind = review_kind
    @iteration = iteration
    @verdict = verdict
    @critique = critique
    @artifacts = artifacts
    @skipped = skipped
    @skip_reason = skip_reason
  end

  def record
    return unless Syrus::Events.known?(EVENT_NAME)

    Syrus::Events.publish(
      EVENT_NAME,
      workflow_id: workflow.id,
      step_id: step&.id,
      run_id: run&.id,
      review_kind: review_kind,
      iteration: iteration,
      verdict: verdict,
      critique: critique,
      artifacts: artifacts,
      skipped: skipped,
      skip_reason: skip_reason
    )
  rescue StandardError => e
    Rails.logger.warn("[ReviewFindingEvents] review finding record failed: #{e.class}: #{e.message}")
  end

  private

  attr_reader :workflow, :step, :run, :review_kind, :iteration, :verdict, :critique, :artifacts, :skipped, :skip_reason
end
