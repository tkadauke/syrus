module PendingActions
  # Confirmed when the operator accepts the emergency-land escape hatch from a
  # Coding Mode session. Re-validates feature and repo-admin permission at
  # confirmation time before invoking EmergencyLand::Lander.
  class EmergencyLand < Base
    action_key "emergency_land"
    requires_chat_session!

    PRESENTATION_SKIPS_NOTICE = "Skips Syrus graders, adversarial review, and visual review; merges the PR directly through GitHub after confirmation. GitHub branch protection still applies.".freeze

    def execute
      job = target_job
      normalized_branch = GitBranchName.normalize(payload["branch_name"])

      job.with_lock do
        raise ArgumentError, "chat_session_id does not match this chat session" if payload["chat_session_id"].present? && payload["chat_session_id"].to_i != chat_session.id
        eligibility = ::EmergencyLand::Eligibility.call(chat_session: chat_session, job: job, branch_name: normalized_branch, user: user)
        raise ArgumentError, eligibility.message unless eligibility.eligible?

        job.update!(branch_name: normalized_branch) if normalized_branch.present? && job.branch_name != normalized_branch

        progress!("Emergency landing #{job.slug}...")
        result = ::EmergencyLand::Lander.land(job: job.reload, user: user)
        raise ArgumentError, result.message if result.refused?
        raise StandardError, result.message if result.failure?

        result.job
      end
    end

    def execution_label
      "Emergency landing Job..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      branch_name = GitBranchName.normalize(payload["branch_name"])
      errors.add(:payload, "branch_name is not a valid branch name") if branch_name.present? && !GitBranchName.valid?(branch_name)
    end

    def action_detail
      branch = GitBranchName.normalize(payload["branch_name"])
      [ "job_id: #{payload["job_id"]}", branch.present? ? "branch_name: #{branch}" : nil ].compact.join(", ")
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

    private

    def target_job
      Job.find(payload.fetch("job_id"))
    end
  end
end
