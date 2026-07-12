module PendingActions
  # Creates a new direct Job from committed branch changes and immediately
  # dispatches a CodingHandoff workflow (graders → summarize → PR open).
  # Used by the `submit_coding_changes` MCP tool in coding-mode chat sessions.
  class SubmitCodingChanges < Base
    action_key "submit_coding_changes"

    def execute
      repository = user.repositories.active.find(payload.fetch("repository_id"))
      branch     = payload.fetch("branch")
      description = payload.fetch("description")

      # Create the job directly in :queued state to skip the triage → queued
      # transition (which would trigger create_initial_run_if_needed). The
      # CodingHandoff workflow dispatched below replaces the initial workflow.
      job = user.jobs.create!(
        repository: repository,
        kind: "direct",
        issue_title: GenerateJobTitleJob::PENDING_TITLE,
        title_pending: true,
        issue_body: description,
        branch_name: branch,
        linked_chat_id: chat_session.id,
        agent_provider: repository.effective_agent_provider,
        state: "queued"
      )

      job.claim_for_coding!
      job.save!

      workflow = job.start_coding_handoff!
      raise ArgumentError, "could not start coding handoff (feature may be disabled or state invalid)" unless workflow

      GenerateJobTitleJob.perform_later(job)

      workflow
    end

    def validate_payload(errors)
      errors.add(:payload, "repository_id is required") unless payload["repository_id"].present?
      errors.add(:payload, "branch is required") unless payload["branch"].present?
      errors.add(:payload, "description is required") unless payload["description"].present?
    end

    def action_detail
      "branch: #{payload["branch"]}, repository_id: #{payload["repository_id"]}"
    end
  end
end
