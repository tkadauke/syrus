module PendingActions
  class DelegateIssue < Base
    action_key "delegate_issue"

    def execute
      repo = action_user_repository
      issue_number = Integer(payload.fetch("issue_number"), exception: false)
      raise ArgumentError, "issue_number is required" unless issue_number&.positive?

      GithubClient.for(repository: repo, user: user).add_label_to_issue(repo.slug, issue_number, repo.trigger_label)
      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "repository_id is required") unless payload["repository_id"].present?
      errors.add(:payload, "issue_number is required") unless payload["issue_number"].present?
    end

    def action_detail
      "issue_number: #{payload["issue_number"]}"
    end
  end
end
