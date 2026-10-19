module PendingActions
  class CancelJob < Base
    action_key "cancel_job"

    def execute
      eligibility = JobCancellationEligibility.call(job: action_job)
      raise ArgumentError, eligibility.message unless eligibility.eligible?

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

    def presentation_label
      "Cancel #{presentation_job_slug}"
    end
  end
end
