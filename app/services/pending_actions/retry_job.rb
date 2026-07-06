module PendingActions
  class RetryJob < Base
    action_key "retry_job"

    def execute
      job = action_job
      result = RetryWorkflowEnqueuer.call(job: job)
      raise ArgumentError, result.error unless result.success?

      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end
  end
end
