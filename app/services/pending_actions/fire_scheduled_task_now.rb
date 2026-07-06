module PendingActions
  class FireScheduledTaskNow < Base
    action_key "fire_scheduled_task_now"

    def execute
      task = action_scheduled_task
      raise ArgumentError, "Task isn't fireable in its current state." if task.archived? || task.fired?

      result = ScheduledTaskFire.new(task).call
      result.fired? ? result.job : nil
    end

    def validate_payload(errors)
      errors.add(:payload, "scheduled_task_id is required") unless payload["scheduled_task_id"].present?
    end

    def action_detail
      "scheduled_task_id: #{payload["scheduled_task_id"]}"
    end
  end
end
