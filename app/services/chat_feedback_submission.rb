class ChatFeedbackSubmission
  ACTIVE_STATES = %w[queued running].freeze

  Result = Data.define(:workflow, :error) do
    def success? = error.blank?
  end

  def self.call(job:, feedback:, allowed_states:, extra_artifacts: {})
    feedback = feedback.to_s.strip
    return Result.new(workflow: nil, error: "Feedback body can't be blank.") if feedback.blank?

    unless allowed_states.include?(job.state)
      states = allowed_states.map { |state| state.tr("_", " ") }.to_sentence
      return Result.new(workflow: nil, error: "#{job.state} jobs are not actionable for chat feedback; the job must be #{states}.")
    end

    if job.workflows.where(trigger_kind: "chat_feedback", state: ACTIVE_STATES).exists?
      return Result.new(workflow: nil, error: "a chat_feedback workflow is already queued or running for this job")
    end

    iteration = job.workflows.where(trigger_kind: %w[ pr_comment chat_feedback ]).count + 1
    base_artifacts = {
      "chat_feedback" => feedback,
      "pr_feedback_iteration" => iteration,
      "pr_feedback_auto" => false
    }
    artifacts = base_artifacts.merge(extra_artifacts)
    workflow = Workflows::ChatFeedback.instantiate(
      job: job,
      artifacts: artifacts,
      agent_provider: job.agent_provider
    )
    StepDispatcher.start_workflow(workflow)
    job.reload.unapprove! if job.may_unapprove?

    Result.new(workflow: workflow, error: nil)
  end
end
