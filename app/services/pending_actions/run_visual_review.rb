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

    def presentation_label
      "Run visual review for #{presentation_job_slug}"
    end

    def tool_card_outcome
      workflow = action.result if action.result_type == "Workflow"
      return unless workflow

      media = Array(workflow.artifact("typed_artifacts")).filter_map do |entry|
        next unless entry.is_a?(Hash) && entry["renderer_type"] == "image_diff"

        artifact_payload = entry["payload"]
        next unless artifact_payload.is_a?(Hash)
        next unless artifact_payload["content_type"].to_s.start_with?("image/")
        next if artifact_payload["image_url"].blank?

        {
          type: entry["type"],
          title: entry["title"],
          image_url: artifact_payload["image_url"],
          content_type: artifact_payload["content_type"],
          byte_size: artifact_payload["byte_size"],
          page: artifact_payload["page"],
          viewport: artifact_payload["viewport"],
          captured_at: artifact_payload["captured_at"]
        }.compact
      end

      { workflow_id: workflow.id, job_id: workflow.job_id, media: media }
    end
  end
end
