module PendingActions
  class RunVisualDiff < Base
    action_key "run_visual_diff"

    def execute
      job = action_user_job
      progress!("Creating before/after visual comparison workflow for #{job.slug}...")
      result = VisualDiffSubmission.call(job: job, reject_invalid_after_artifacts: true)
      raise ArgumentError, result.error unless result.success?

      result.workflow
    end

    def execution_label
      "Starting before/after visual comparison..."
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
    end

    def action_detail
      "job_id: #{payload["job_id"]}"
    end

    def presentation_label
      "Run visual diff for #{presentation_job_slug}"
    end

    def tool_card_outcome
      workflow = action.result if action.result_type == "Workflow"
      return unless workflow

      comparison = Array(workflow.artifact("typed_artifacts")).reverse.find do |entry|
        entry.is_a?(Hash) && entry["type"] == "visual_diff_comparison" && entry["renderer_type"] == "before_after_visual_diff"
      end

      {
        workflow_id: workflow.id,
        job_id: workflow.job_id,
        comparison: comparison
      }.compact
    end
  end
end
