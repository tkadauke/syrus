class ChatFeedbackSubmission
  ACTIVE_STATES = Workflow::TriggerKind::ACTIVE_STATES

  Result = Data.define(:workflow, :error) do
    def success? = error.blank?
  end

  def self.call(job:, feedback:, allowed_states:, extra_artifacts: {}, chat_session: nil, media: [])
    feedback = feedback.to_s.strip
    return Result.new(workflow: nil, error: "Feedback body can't be blank.") if feedback.blank?

    unless allowed_states.include?(job.state)
      states = allowed_states.map { |state| state.tr("_", " ") }.to_sentence
      return Result.new(workflow: nil, error: "#{job.state} jobs are not actionable for chat feedback; the job must be #{states}.")
    end

    if WorkUnits::Ownership.active_for_job_kind?(job, "chat_feedback")
      return Result.new(workflow: nil, error: "a chat_feedback workflow is already queued or running for this job")
    end

    attach_media!(job: job, chat_session: chat_session, media: media)

    iteration = job.workflows.where(trigger_kind: Workflow::TriggerKind.feedback_values).count + 1
    base_artifacts = {
      "chat_feedback" => feedback,
      "pr_feedback_iteration" => iteration,
      "pr_feedback_auto" => false
    }
    artifacts = base_artifacts.merge(extra_artifacts)
    workflow = WorkUnits::Launcher.instantiate(
      kind: "chat_feedback",
      job: job,
      artifacts: artifacts
    )
    Job::ApprovalUnapprover.call(job: job.reload, user: job.user) if job.may_unapprove?
    WorkUnits::Launcher.start!(workflow)

    Result.new(workflow: workflow, error: nil)
  rescue WorkUnits::Launcher::LockConflict => e
    if e.work_unit&.kind != "chat_feedback" && defined?(workflow) && workflow.present?
      block_behind_active_work!(workflow, e)
      return Result.new(workflow: workflow, error: nil)
    end

    Result.new(workflow: nil, error: "a chat_feedback workflow is already queued or running for this job")
  end

  def self.attach_media!(job:, chat_session:, media:)
    return if media.blank? || chat_session.nil?

    ChatMediaAttacher.new(chat_session: chat_session, job: job).attach!(media)
  end
  private_class_method :attach_media!

  def self.block_behind_active_work!(workflow, error)
    unit = workflow.work_unit
    return unless unit

    gate_result = WorkUnits::GateResult.block(
      reason: WorkUnits::Gates::ActiveWorkLock::REASON,
      retry_at: WorkUnits::Gates::ActiveWorkLock::RETRY_DELAY.from_now,
      details: {
        "lock_key" => error.lock_key,
        "work_unit_id" => error.work_unit&.id,
        "workflow_id" => error.work_unit&.workflow_id
      }.compact
    )
    unit.block!(
      reason: gate_result.reason,
      blocked_until: gate_result.retry_at,
      details: gate_result.details
    )
    WorkUnits::Launcher.schedule_blocked_recheck!(workflow, gate_result)
  end
  private_class_method :block_behind_active_work!
end
