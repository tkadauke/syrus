class WorkflowWorkspaceLifecycle
  class << self
    def record_identity!(workflow, hostname:, storage_key:, actor: "run_job")
      hostname = hostname.presence
      storage_key = storage_key.presence
      return if hostname.blank? && storage_key.blank?

      previous_hostname = workflow.last_workspace_hostname.presence
      previous_storage_key = workflow.last_workspace_storage_key.presence
      changed = previous_hostname != hostname || previous_storage_key != storage_key

      workflow.update_columns(
        worker_hostname: hostname,
        worker_storage_key: storage_key,
        last_workspace_hostname: hostname || previous_hostname,
        last_workspace_storage_key: storage_key || previous_storage_key
      )
      return unless changed && (previous_hostname.present? || previous_storage_key.present?)

      record!(workflow, "ownership_transferred", actor: actor, hostname: hostname,
        storage_key: storage_key, details: {
          "previous_hostname" => previous_hostname,
          "previous_storage_key" => previous_storage_key
        })
    end

    def created!(workflow, actor: "workflow_workspace")
      event_type = workflow.workflow_workspace_events.exists? ? "reconstructed" : "created"
      state = event_type == "created" ? "created" : "reconstructed"
      record!(workflow, event_type, actor: actor)
      workflow.update_columns(workspace_lifecycle_state: state, cleaned_up_at: nil)
    end

    def cleaned_up!(workflow, actor:, reason:)
      record!(workflow, "cleaned_up", actor: actor, reason: reason)
      workflow.update_columns(workspace_lifecycle_state: "cleaned_up", cleaned_up_at: Time.current)
    end

    def storage_lost!(workflow, actor:, reason:)
      preserve_last_known!(workflow)
      record!(workflow, "storage_lost", actor: actor, reason: reason)
      workflow.update_columns(workspace_lifecycle_state: "storage_lost")
    end

    def clear_routing_affinity!(workflow, actor:, reason:, storage_lost: true)
      if storage_lost
        storage_lost!(workflow, actor: actor, reason: reason)
      else
        preserve_last_known!(workflow)
      end
      workflow.update_columns(worker_hostname: nil, worker_storage_key: nil)
    end

    private

    def preserve_last_known!(workflow)
      updates = {}
      updates[:last_workspace_hostname] = workflow.worker_hostname if workflow.worker_hostname.present?
      updates[:last_workspace_storage_key] = workflow.worker_storage_key if workflow.worker_storage_key.present?
      workflow.update_columns(updates) if updates.any?
    end

    def record!(workflow, event_type, actor:, reason: nil, hostname: nil, storage_key: nil, details: nil)
      workflow.workflow_workspace_events.create!(
        event_type: event_type,
        hostname: hostname || workflow.worker_hostname || workflow.last_workspace_hostname,
        storage_key: storage_key || workflow.worker_storage_key || workflow.last_workspace_storage_key,
        actor: actor,
        reason: reason,
        details: details
      )
    end
  end
end
