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

    if job.workflows.where(trigger_kind: "chat_feedback", state: ACTIVE_STATES).exists?
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
    if job.may_unapprove?
      Job::ApprovalUnapprover.call(job: job.reload, user: job.user)
    end
    StepDispatcher.start_workflow(workflow)

    Result.new(workflow: workflow, error: nil)
  end

  def self.attach_media!(job:, chat_session:, media:)
    return if media.blank? || chat_session.nil?

    ChatMediaAttacher.new(chat_session: chat_session, job: job).attach!(media)
  end
  private_class_method :attach_media!
end
