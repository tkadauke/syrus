module PendingActions
  class ReopenJob < Base
    action_key "reopen_job"

    def execute
      job = action_user_job
      raise ArgumentError, "Job isn't closed." unless job.may_reopen?

      job.reopen!
      job.save!
      job
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end
  end
end
