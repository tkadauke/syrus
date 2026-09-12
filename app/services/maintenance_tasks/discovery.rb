module MaintenanceTasks
  class Discovery
    def self.call
      new.call
    end

    def call
      Registry.all.each { |definition| reconcile_definition(definition) }
    end

    private

    def reconcile_definition(definition)
      task = existing_task_for(definition)

      if definition.pending?
        ensure_pending_task(definition, task)
      elsif task&.state.in?(%w[pending dismissed failed paused])
        task.update!(state: "not_needed", finished_at: Time.current)
        task.log!("No matching maintenance work remains; task marked not needed.")
      end
    end

    def ensure_pending_task(definition, task)
      return if task && !task.state.in?(%w[not_needed cancelled succeeded])

      MaintenanceTask.create!(
        definition.build_task_attributes(
          trigger_kind: "detector",
          trigger_key: definition.key,
          task_key: task_key_for(definition)
        )
      ).tap do |created|
        created.log!(created.metadata["pending_reason"].presence || "Maintenance task is pending.")
      end
    rescue ActiveRecord::RecordNotUnique
      nil
    end

    def task_key_for(definition)
      "detector:#{definition.key}"
    end

    def existing_task_for(definition)
      task = MaintenanceTask.find_by(task_key: task_key_for(definition))
      return task if task
      return nil unless definition.recurrence == "one_off"

      MaintenanceTask
        .where(definition_key: definition.key, recurrence: "one_off")
        .where(state: %w[pending running paused failed dismissed])
        .order(:created_at, :id)
        .first
    end
  end
end
