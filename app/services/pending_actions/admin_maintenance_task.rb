module PendingActions
  class AdminMaintenanceTask < Base
    ACTIONS = %w[start pause resume cancel dismiss].freeze

    action_key "admin_maintenance_task"

    def perform
      task = MaintenanceTask.find(payload.fetch("task_id"))
      task_action = payload.fetch("task_action").to_s
      raise ArgumentError, "unknown maintenance task action: #{task_action}" unless ACTIONS.include?(task_action)

      progress!("Updating maintenance task ##{task.id}...")
      MaintenanceTasks::Actions.public_send("#{task_action}!", task, user: user)
    end

    def execution_label
      "Updating maintenance task..."
    end

    def validate_payload(errors)
      errors.add(:payload, "task_id is required") unless payload["task_id"].present?
      task_action = payload["task_action"].to_s
      errors.add(:payload, "task_action is required") if task_action.blank?
      errors.add(:payload, "task_action is invalid") if task_action.present? && !ACTIONS.include?(task_action)
    end

    def action_detail
      "task_id: #{payload["task_id"]}, task_action: #{payload["task_action"]}"
    end

    def presentation_label
      "#{payload["task_action"].to_s.capitalize} maintenance task ##{payload["task_id"]}"
    end
  end
end
