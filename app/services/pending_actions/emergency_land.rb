module PendingActions
  # Confirmed when the operator accepts the emergency-land escape hatch from a
  # Coding Mode session. Re-validates feature and repo-admin permission at
  # confirmation time before invoking EmergencyLand::Lander.
  class EmergencyLand < Base
    action_key "emergency_land"

    def execute
      job = target_job
      normalized_branch = GitBranchName.normalize(payload["branch_name"])

      job.with_lock do
        raise ArgumentError, "Emergency land is not enabled on this instance" unless Feature.emergency_land_enabled?
        raise ArgumentError, "emergency_land is only available in Coding Mode chat sessions" unless chat_session.coding?
        raise ArgumentError, "job is not in coding state" unless job.coding?
        raise ArgumentError, "job is not linked to this chat session" unless job.linked_chat_id == chat_session.id
        raise ArgumentError, "chat_session_id does not match this chat session" if payload["chat_session_id"].present? && payload["chat_session_id"].to_i != chat_session.id
        raise ArgumentError, "Emergency land requires repository admin permissions" unless ::EmergencyLand::Permission.granted?(user: user, repository: job.repository)
        raise ArgumentError, "branch_name is required because this Job does not have a pushed branch recorded" if normalized_branch.blank? && job.branch_name.blank?
        raise ArgumentError, "branch_name is not a valid branch name" if normalized_branch.present? && !GitBranchName.valid?(normalized_branch)

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

    private

    def target_job
      Job.find(payload.fetch("job_id"))
    end
  end
end
