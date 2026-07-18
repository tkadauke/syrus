class CodingHandoffConfirmJob < ApplicationJob
  queue_as :chat
  discard_on ActiveRecord::RecordNotFound

  def perform(pending_action_id)
    action = ChatPendingAction.find(pending_action_id)
    @chat_session = action.chat_session
    user = action.user
    payload = action.payload.to_h

    repository = user.repositories.active.find(payload.fetch("repository_id"))
    branch = payload.fetch("branch").to_s
    description = payload.fetch("description")
    title = payload["title"].presence
    handoff_branch = "syrus/chat-#{@chat_session.id}-handoff-#{action.id}"

    snapshot = CodingHandoffCapture.capture!(
      chat_session: @chat_session,
      repository: repository,
      user: user,
      source_branch: branch,
      handoff_branch: handoff_branch
    )

    artifacts = build_artifacts(snapshot: snapshot, title: title, description: description)

    job = user.jobs.create!(
      repository: repository,
      kind: "direct",
      issue_title: title || GenerateJobTitleJob::PENDING_TITLE,
      title_pending: title.nil?,
      issue_body: description,
      branch_name: snapshot.fetch("handoff_branch"),
      linked_chat_id: @chat_session.id,
      agent_provider: repository.effective_agent_provider,
      state: "queued"
    )

    job.claim_for_coding! if job.may_claim_for_coding?
    job.save!

    workflow = job.start_coding_handoff!(artifacts: artifacts)
    raise ArgumentError, "could not start coding handoff (feature may be disabled or state invalid)" unless workflow

    GenerateJobTitleJob.perform_later(job) if title.nil?

    post_to_chat("Coding handoff submitted: JOB-#{job.id} created on branch `#{workflow.job.branch_name}`. Graders are now running.")
  rescue CodingHandoffCapture::CaptureError, ArgumentError => e
    post_to_chat("Coding handoff failed: #{e.message}. Please fix the issue and try again.")
  end

  private

  def post_to_chat(text)
    return unless @chat_session

    message = @chat_session.messages.create!(role: "system", content: { "text" => text })
    @chat_session.update!(last_message_at: Time.current)
    ChatTurnJob.perform_later(@chat_session.id, message.id)
  end

  def build_artifacts(snapshot:, title:, description:)
    {
      "coding_handoff" => snapshot,
      "pr_title" => pr_title(title: title, description: description),
      "pr_body" => pr_body(description: description, snapshot: snapshot),
      "summary" => description.to_s,
      "test_plan" => { "steps" => [], "notes" => nil }
    }
  end

  def pr_title(title:, description:)
    title.presence || description.to_s.lines.first.to_s.strip.presence || "Coding handoff from chat ##{@chat_session.id}"
  end

  def pr_body(description:, snapshot:)
    changed_files = Array(snapshot["changed_files"]).presence || [ "(unknown)" ]
    <<~BODY.strip
      #{description}

      ## Coding handoff

      Captured chat workspace commit `#{snapshot["head_sha"]}` from `#{snapshot["source_branch"]}` and published immutable handoff branch `#{snapshot["handoff_branch"]}`.

      Changed files:
      #{changed_files.map { |path| "- `#{path}`" }.join("\n")}
    BODY
  end
end
