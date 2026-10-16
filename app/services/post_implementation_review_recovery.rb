class PostImplementationReviewRecovery
  Result = Data.define(:workflow, :run, :warning, :error) do
    def success? = error.blank?
  end

  def self.retry(warning:, actor:)
    return failure(warning, "This warning is already resolved.") unless warning.pending?
    return failure(warning, "Only post-implementation review warnings can be retried.") unless eligible?(warning)
    return failure(warning, "The implementation PR is not available for review.") unless warning.job.pr_number.present?

    active = warning.job.workflows.where(trigger_kind: "manual_post_implementation_review", state: %w[queued running]).first
    return Result.new(workflow: active, run: active.runs.where(state: %w[queued running]).last, warning: warning, error: nil) if active

    launch = WorkUnits::Launcher.create_and_start!(
      kind: "manual_post_implementation_review",
      job: warning.job,
      artifacts: { "post_implementation_review_retry" => { "warning_id" => warning.id, "requested_by_id" => actor.id, "requested_at" => Time.current.iso8601 } }
    )
    warning.update!(evidence: warning.evidence.to_h.merge(
      "latest_retry_workflow_id" => launch.workflow.id,
      "latest_retry_requested_by_id" => actor.id,
      "latest_retry_requested_at" => Time.current.iso8601
    ))
    Result.new(workflow: launch.workflow, run: launch.run, warning: warning, error: nil)
  rescue WorkUnits::Launcher::LockConflict
    active = warning.job.workflows.where(trigger_kind: "manual_post_implementation_review", state: %w[queued running]).first
    return Result.new(workflow: active, run: active.runs.where(state: %w[queued running]).last, warning: warning, error: nil) if active

    failure(warning, "Another workflow is already active for this Job.")
  end

  def self.skip(warning:, actor:)
    return failure(warning, "Only post-implementation review warnings can be skipped.") unless eligible?(warning)

    warning.with_lock do
      warning.reload
      return Result.new(workflow: nil, run: nil, warning: warning, error: nil) unless warning.pending?

      warning.update!(
        state: "dismissed",
        evidence: warning.evidence.to_h.merge(
          "resolution" => "skipped",
          "resolved_at" => Time.current.iso8601,
          "resolved_by_id" => actor.id
        )
      )
    end
    Result.new(workflow: nil, run: nil, warning: warning, error: nil)
  end

  def self.eligible?(warning) = warning.kind == PostImplementationReviewFailure::KIND
  def self.failure(warning, message) = Result.new(workflow: nil, run: nil, warning: warning, error: message)
  private_class_method :eligible?, :failure
end
