class EmergencyLandConfirmJob < ApplicationJob
  SOURCE = "emergency_land_result"

  queue_as :chat
  discard_on ActiveRecord::RecordNotFound

  def perform(pending_action_id)
    action = ChatPendingAction.find(pending_action_id)
    return unless action.confirming?

    payload = action.payload.to_h
    chat = action.chat_session
    user = action.user
    repository = if payload["repository_id"].present?
      user.repositories.active.find(payload.fetch("repository_id"))
    else
      user.repositories.active.find(Job.find(payload.fetch("job_id")).repository_id)
    end

    raise ArgumentError, "Emergency land is not enabled on this instance" unless Feature.emergency_land_enabled?
    raise ArgumentError, "emergency_land is only available in Coding Mode chat sessions" unless chat.coding?
    raise ArgumentError, "Emergency land requires repository admin permissions" unless EmergencyLand::Permission.granted?(user: user, repository: repository)

    action.update_confirmation_progress!("running", "Capturing and emergency landing the confirmed change...")
    job = payload["job_id"].present? ? existing_job!(payload, repository) : capture_direct_job!(payload, chat, user, repository, action)
    result = EmergencyLand::Lander.land(job: job, user: user)
    raise ArgumentError, result.message if result.refused?
    raise StandardError, result.message if result.failure?

    action.complete_confirmation!(result.job)
    post_message!(chat, "Emergency landed #{result.job.slug} from #{result.job.emergency_land_source_sha} via PR ##{result.pr_number}.")
  rescue StandardError => e
    action&.fail_confirmation!(e) if action&.confirming?
    post_message!(chat, "Emergency land failed: #{e.message}") if chat
  end

  private

  def existing_job!(payload, repository)
    job = repository.jobs.find(payload.fetch("job_id"))
    branch = GitBranchName.normalize(payload["branch_name"])
    raise ArgumentError, "branch_name must match #{job.slug}'s recorded branch #{job.branch_name}" if branch.present? && branch != job.branch_name
    job
  end

  def capture_direct_job!(payload, chat, user, repository, action)
    branch = payload["branch_name"].to_s
    handoff_branch = "syrus/chat-#{chat.id}-emergency-#{action.id}"
    snapshot = CodingHandoffCapture.capture!(chat_session: chat, repository: repository, user: user,
      source_branch: branch, handoff_branch: handoff_branch)

    user.jobs.create!(repository: repository, kind: "direct", issue_title: payload.fetch("title"),
      issue_body: payload.fetch("description"), branch_name: snapshot.fetch("handoff_branch"),
      agent_provider: repository.effective_agent_provider, state: "implemented")
  end

  def post_message!(chat, text)
    message = chat.messages.create!(role: "system", content: { "text" => text, "source" => SOURCE })
    chat.update!(last_message_at: Time.current)
    ChatTurnJob.perform_later(chat.id, message.id)
  end
end
