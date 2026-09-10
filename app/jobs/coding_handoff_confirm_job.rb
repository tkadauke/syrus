class CodingHandoffConfirmJob < ApplicationJob
  SOURCE = "coding_handoff_result"

  queue_as :chat
  discard_on ActiveRecord::RecordNotFound

  def perform(pending_action_id)
    action = ChatPendingAction.find(pending_action_id)
    chat_session = action.chat_session
    user = action.user
    payload = action.payload.to_h

    repository = user.repositories.active.find(payload.fetch("repository_id"))
    branch = payload.fetch("branch").to_s
    description = payload.fetch("description")
    title = payload["title"].presence
    handoff_branch = "syrus/chat-#{chat_session.id}-handoff-#{action.id}"
    stack_base = stack_base_for(chat_session, repository)

    snapshot = CodingHandoffCapture.capture!(
      chat_session: chat_session,
      repository: repository,
      user: user,
      source_branch: branch,
      handoff_branch: handoff_branch,
      base_ref: stack_base&.fetch("head_sha")
    )

    artifacts = workflow_artifacts(snapshot: snapshot, title: title, description: description, chat_session_id: chat_session.id)

    job = user.jobs.create!(
      repository: repository,
      kind: "direct",
      issue_title: title || GenerateJobTitleJob::PENDING_TITLE,
      title_pending: title.nil?,
      issue_body: description,
      branch_name: snapshot.fetch("handoff_branch"),
      linked_chat_id: chat_session.id,
      agent_provider: repository.effective_agent_provider,
      state: "queued"
    )

    create_stack_dependency!(job, stack_base, snapshot: snapshot, user: user)
    job.claim_for_coding! if job.may_claim_for_coding?
    job.save!

    workflow = job.start_coding_handoff!(artifacts: artifacts)
    raise ArgumentError, "could not start coding handoff (feature may be disabled or state invalid)" unless workflow

    record_stack_handoff!(chat_session, repository: repository, job: job, snapshot: snapshot)
    GenerateJobTitleJob.perform_later(job) if title.nil?

    post_message!(
      chat_session,
      "Coding handoff dispatched: #{job.slug} is running graders and will open a PR when ready. " \
        "The chat checkout remains at submitted HEAD #{snapshot["head_sha"]}; use reset_workspace when you want to start fresh from #{repository.default_branch}."
    )

  rescue CodingHandoffCapture::CaptureError, ArgumentError => e
    post_message!(chat_session, "Coding handoff failed: #{e.message}")
  end

  private

  def post_message!(chat_session, text)
    message = chat_session.messages.create!(
      role: "system",
      content: { "text" => text, "source" => SOURCE }
    )
    chat_session.update!(last_message_at: Time.current)
    ChatTurnJob.perform_later(chat_session.id, message.id)
  end

  def workflow_artifacts(snapshot:, title:, description:, chat_session_id:)
    {
      "coding_handoff" => snapshot,
      "pr_title" => pr_title(title: title, description: description, chat_session_id: chat_session_id),
      "pr_body" => pr_body(description: description, snapshot: snapshot),
      "summary" => description.to_s,
      "test_plan" => {
        "steps" => [],
        "notes" => nil
      }
    }
  end

  def pr_title(title:, description:, chat_session_id:)
    title.presence || description.to_s.lines.first.to_s.strip.presence || "Coding handoff from chat ##{chat_session_id}"
  end

  def pr_body(description:, snapshot:)
    changed_files = Array(snapshot["changed_files"]).presence || [ "(unknown)" ]
    <<~BODY.strip
      #{description}

      ## Coding handoff

      Captured chat workspace commits `#{snapshot["base_sha"]}..#{snapshot["head_sha"]}` from `#{snapshot["source_branch"]}` and published immutable handoff branch `#{snapshot["handoff_branch"]}`.

      Changed files:
      #{changed_files.map { |path| "- `#{path}`" }.join("\n")}
    BODY
  end

  def stack_base_for(chat_session, repository)
    stack = chat_session.artifact("coding_handoff_stack")
    return unless stack.is_a?(Hash)
    return unless stack["repository_id"].to_i == repository.id
    return unless stack["lineage"] == "continuous"
    return if stack["last_handoff_job_id"].blank? || stack["last_head_sha"].blank?

    {
      "job_id" => stack.fetch("last_handoff_job_id"),
      "head_sha" => stack.fetch("last_head_sha")
    }
  end

  def create_stack_dependency!(job, stack_base, snapshot:, user:)
    return unless stack_base
    return unless snapshot["base_sha"] == stack_base.fetch("head_sha")

    depends_on_job = user.jobs.find_by(id: stack_base.fetch("job_id"))
    return unless depends_on_job

    JobDependency.create!(
      job: job,
      depends_on_job: depends_on_job,
      source: "manual",
      created_by_user: user
    )
  end

  def record_stack_handoff!(chat_session, repository:, job:, snapshot:)
    chat_session.set_artifact!(
      "coding_handoff_stack",
      {
        "repository_id" => repository.id,
        "lineage" => "continuous",
        "last_handoff_job_id" => job.id,
        "last_base_sha" => snapshot["base_sha"],
        "last_head_sha" => snapshot["head_sha"],
        "last_handoff_branch" => snapshot["handoff_branch"],
        "last_source_branch" => snapshot["source_branch"],
        "updated_at" => Time.current.iso8601
      }
    )
  end
end
