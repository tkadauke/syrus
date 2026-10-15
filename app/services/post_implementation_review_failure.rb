class PostImplementationReviewFailure
  KIND = "post_implementation_review_failed".freeze

  def self.optional_step?(step) = step&.kind == "post_implementation_review"

  def self.record!(run:, exception:, workspace: nil)
    new(run: run, exception: exception, workspace: workspace).record!
  end

  def initialize(run:, exception:, workspace:)
    @run = run
    @step = run.step
    @workflow = @step.workflow
    @job = run.job
    @exception = exception
    @workspace = workspace
  end

  def record!
    CaptureRunDiagnostic.capture(run, exception, workspace: workspace)
    evidence = workflow.artifact("post_implementation_review_context").to_h.merge(
      "reason" => exception.message,
      "exception_class" => exception.class.name,
      "run_id" => run.id,
      "step_id" => step.id,
      "workflow_id" => workflow.id,
      "failed_at" => Time.current.iso8601
    )

    warning = retried_warning || WorkflowWarning.find_or_initialize_by(job: job, workflow: workflow, step: step, kind: KIND)
    warning.assign_attributes(
      title: "Post-implementation review did not produce notes",
      severity: "medium",
      state: "pending",
      evidence: evidence,
      suggested_prompt: nil
    )
    warning.save!

    run.restore_attributes
    run.agent_outcome ||= exception.is_a?(Steps::Base::CannotProceed) ? "cannot_proceed" : "error"
    run.skip! if run.may_skip?
    run.save!
    step.skip_with_reason!("post_implementation_review_failed")
    StepDispatcher.advance_from(step.reload) if step.skipped?
    warning
  end

  private

  attr_reader :run, :step, :workflow, :job, :exception, :workspace

  def retried_warning
    warning_id = workflow.artifact("post_implementation_review_retry").to_h["warning_id"]
    return if warning_id.blank?

    job.workflow_warnings.find_by(id: warning_id, kind: KIND)
  end
end
