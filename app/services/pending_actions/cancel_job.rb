module PendingActions
  class CancelJob < Base
    action_key "cancel_job"

    def execute
      progress!("Cancelling active work for #{action_job.slug}...")
      action_job.cancel_active_runs_and_close!("cancelled")
      nil
    end

    def execution_label
      "Cancelling job..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end
  end
end
