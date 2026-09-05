module PendingActions
  class ApproveJob < Base
    action_key "approve_job"

    def execute
      job = action_permitted_job
      raise ArgumentError, "job must be in implemented state" unless job.implemented?

      progress!("Approving #{job.slug}...")
      job.approve!(via: "operator", by_user: user)
      job
    end

    def execution_label
      "Approving job..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    private

    def action_permitted_job
      (user.admin? ? Job.all : user.jobs).find(payload.fetch("job_id"))
    end
  end
end
