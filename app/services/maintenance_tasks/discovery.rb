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
      if task
        return unless task.state.in?(%w[not_needed cancelled succeeded])

        task.update!(
          definition.build_task_attributes(
            trigger_kind: task.trigger_kind,
            trigger_key: task.trigger_key,
            task_key: task.task_key
          ).except(:state).merge(
            state: "pending",
            completed_units: 0,
            failed_units: 0,
            current_step_key: nil,
            current_step_title: nil,
            eta_seconds: nil,
            started_at: nil,
            finished_at: nil,
            paused_at: nil,
            cancelled_at: nil,
            dismissed_at: nil,
            dismissed_by_user: nil,
            last_error: nil,
            checkpoint: {}
          )
        )
        task.log!(task.metadata["pending_reason"].presence || "Maintenance task is pending again.")
        return
      end

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
      reconcile_racing_task(definition)
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.of_kind?(:task_key, :taken)

      reconcile_racing_task(definition)
    end

    # Another discovery call (or a migration-seeded task) created a task with the
    # same task_key between our lookup and our insert. Re-read it and, if it needs
    # reviving, fall through to the same update path a sequential call would take.
    def reconcile_racing_task(definition)
      task = MaintenanceTask.find_by(task_key: task_key_for(definition))
      return unless task
      return unless task.state.in?(%w[not_needed cancelled succeeded])

      ensure_pending_task(definition, task)
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
