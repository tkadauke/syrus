module PendingActions
  class RunVisualReview < Base
    action_key "run_visual_review"

    def execute
      job = action_user_job
      progress!("Creating visual review workflow for #{job.slug}...")
      result = ManualVisualReviewSubmission.call(job: job)
      raise ArgumentError, result.error unless result.success?

      result.workflow
    end

    def execution_label
      "Starting visual review..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end
  end
end
