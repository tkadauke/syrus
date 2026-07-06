module PendingActions
  class AdminRetryStep < Base
    action_key "admin_retry_step"

    def execute
      workflow = Workflow.find(payload.fetch("workflow_id"))
      step_slug = payload.fetch("step_slug").to_s
      failed_step = RetryFailedStepEnqueuer.failed_step_for(workflow)
      unless failed_step&.kind == step_slug
        raise ArgumentError, "Step '#{step_slug}' is not the retryable failed step on #{workflow.slug}."
      end

      result = RetryFailedStepEnqueuer.call(workflow: workflow)
      raise ArgumentError, result.error unless result.success?

      result.run
    end

    def validate_payload(errors)
      errors.add(:payload, "workflow_id is required") unless payload["workflow_id"].present?
      errors.add(:payload, "step_slug is required") if payload["step_slug"].to_s.strip.blank?
    end

    def action_detail
      "workflow_id: #{payload["workflow_id"]}, step_slug: #{payload["step_slug"]}"
    end
  end
end
