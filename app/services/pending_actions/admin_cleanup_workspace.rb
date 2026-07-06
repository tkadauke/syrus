module PendingActions
  class AdminCleanupWorkspace < Base
    action_key "admin_cleanup_workspace"

    def execute
      workflow = Workflow.find(payload.fetch("workflow_id"))
      raise ArgumentError, "Workflow workspace is still in use by active steps or runs." unless workflow.cleanup_workspace!

      nil
    end

    def validate_payload(errors)
      errors.add(:payload, "workflow_id is required") unless payload["workflow_id"].present?
    end

    def action_detail
      "workflow_id: #{payload["workflow_id"]}"
    end
  end
end
