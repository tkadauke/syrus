module PendingActions
  class UnapproveJob < Base
    action_key "unapprove_job"

    def execute
      job = action_permitted_job
      raise ArgumentError, "job must be in approved state" unless job.approved?

      progress!("Unapproving #{job.slug}...")
      Job::ApprovalUnapprover.call(job: job, user: user)
      job
    end

    def execution_label
      "Unapproving job..."
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
