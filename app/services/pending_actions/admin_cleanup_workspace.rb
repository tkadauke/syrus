module PendingActions
  class AdminCleanupWorkspace < Base
    action_key "admin_cleanup_workspace"

    def execute
      workflow = Workflow.find(payload.fetch("workflow_id"))
      progress!("Cleaning workspace for #{workflow.slug}...")
      raise ArgumentError, "Workflow workspace is still in use by active steps or runs." unless workflow.cleanup_workspace!

      nil
    end

    def execution_label
      "Cleaning workflow workspace..."
    end

    def validate_payload(errors)
      errors.add(:payload, "workflow_id is required") unless payload["workflow_id"].present?
      errors.add(:reason, "is required") if reason.blank?
    end

    def action_detail
      "workflow_id: #{payload["workflow_id"]}"
    end

    def repair_action?
      true
    end

    def repair_snapshot_targets
      workflow = Workflow.find_by(id: payload["workflow_id"])
      [ workflow&.job ]
    end
  end
end
