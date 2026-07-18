module PendingActions
  # Creates a new direct Job from committed branch changes and immediately
  # dispatches a CodingHandoff workflow (graders → summarize → PR open).
  # Used by the `submit_coding_changes` MCP tool in coding-mode chat sessions.
  class SubmitCodingChanges < Base
    action_key "submit_coding_changes"

    def execute
      # Validate the repository belongs to the user before enqueuing.
      user.repositories.active.find(payload.fetch("repository_id"))

      # CodingHandoffCapture.capture! needs filesystem access to the coding
      # checkout, which only exists on the worker pod. Enqueue to :chat queue
      # (worker pod) so it runs with access to the local git checkout, then
      # post the result back to the chat session as a system message.
      CodingHandoffConfirmJob.perform_later(action.id)
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "repository_id is required") unless payload["repository_id"].present?
      errors.add(:payload, "branch is required") unless payload["branch"].present?
      errors.add(:payload, "title is required") unless payload["title"].present?
      errors.add(:payload, "description is required") unless payload["description"].present?
    end

    def action_detail
      "branch: #{payload["branch"]}, repository_id: #{payload["repository_id"]}"
    end

  end
end
