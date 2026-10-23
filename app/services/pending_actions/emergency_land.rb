module PendingActions
  # Confirmed when the operator accepts the emergency-land escape hatch from a
  # Coding Mode session. Re-validates feature and repo-admin permission at
  # confirmation time before invoking EmergencyLand::Lander.
  class EmergencyLand < Base
    action_key "emergency_land"
    requires_chat_session!

    PRESENTATION_SKIPS_NOTICE = "Skips Syrus graders, adversarial review, and visual review; merges the PR directly through GitHub after confirmation. GitHub branch protection still applies.".freeze

    def execute
      progress!("Queueing emergency landing...")
      EmergencyLandConfirmJob.perform_later(action.id)
      deferred_confirmation
    end

    def execution_label
      "Queueing emergency landing..."
    end

    def validate_payload(errors)
      errors.add(:payload, "repository_id is required for direct submission") if payload["job_id"].blank? && payload["repository_id"].blank?
      branch_name = GitBranchName.normalize(payload["branch_name"])
      errors.add(:payload, "branch_name is not a valid branch name") if branch_name.present? && !GitBranchName.valid?(branch_name)
    end

    def action_detail
      branch = GitBranchName.normalize(payload["branch_name"])
      [ payload["job_id"].present? ? "job_id: #{payload["job_id"]}" : "direct checkout", branch.present? ? "branch_name: #{branch}" : nil ].compact.join(", ")
    end

    def presentation_label
      "Emergency land #{presentation_job_slug}"
    end

    def presentation_detail
      [
        payload["branch_name"].presence&.then { |branch| "Branch: #{branch}" },
        PRESENTATION_SKIPS_NOTICE
      ].compact.join("\n")
    end
  end
end
