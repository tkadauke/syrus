class MaintenanceTaskRunJob < ApplicationJob
  queue_as :low_priority_maintenance

  limits_concurrency to: 2,
    key: ->(task_id) { MaintenanceTask.find_by(id: task_id)&.concurrency_key || "maintenance_task:#{task_id}" },
    duration: 10.minutes,
    on_conflict: :discard

  def perform(task_id)
    task = MaintenanceTask.find_by(id: task_id)
    return unless task

    MaintenanceTasks::Runner.new(task).call
  end
end
