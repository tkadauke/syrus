module PendingActions
  class BaseRefreshRetryJob < Base
    action_key "base_refresh_retry_job"

    def execute
      job = action_job
      source = job.workflows.find_by(id: payload["source_workflow_id"])
      progress!("Creating base refresh retry for #{job.slug}...")
      result = BaseRefreshRetryEnqueuer.call(job: job, source_workflow: source, reason: payload["reason"])
      raise ArgumentError, result.error unless result.success?
    end

    def validate_payload(errors)
      errors.add(:payload, "job_id is required") unless payload["job_id"].present?
      errors.add(:payload, "source_workflow_id is required") unless payload["source_workflow_id"].present?
      errors.add(:payload, "reason is required") if payload["reason"].blank?
    end

    def execution_label = "Creating base refresh retry..."
    def action_detail = "job_id: #{payload['job_id']}, source_workflow_id: #{payload['source_workflow_id']}"
    def presentation_label = "Refresh base for #{presentation_job_slug}"
  end
end
