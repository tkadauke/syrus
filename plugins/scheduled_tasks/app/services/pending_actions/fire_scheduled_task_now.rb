module PendingActions
  class FireScheduledTaskNow < Base
    action_key "fire_scheduled_task_now"

    def authorize_execution!
      task = scheduled_task
      raise ArgumentError, "Repository write access is required to fire this scheduled task." unless RepositoryPolicy.new(user, task.repository).write?
    end

    def execute
      authorize_execution!
      task = scheduled_task
      raise ArgumentError, "Task isn't fireable in its current state." if task.archived? || task.fired?

      progress!("Firing scheduled task #{task.id}...")
      result = ScheduledTasks::Fire.new(task).call
      action.update!(payload: payload.merge(
        "fire_outcome" => {
          "fired" => result.fired?,
          "job_id" => result.job&.id,
          "reason" => result.reason
        }.compact
      ))
      result.job
    end

    def execution_label
      "Firing scheduled task..."
    end

    def validate_payload(errors)
      errors.add(:payload, "scheduled_task_id is required") unless payload["scheduled_task_id"].present?
    end

    def action_detail
      "scheduled_task_id: #{payload["scheduled_task_id"]}"
    end

    def presentation_label
      "Fire scheduled task ##{payload["scheduled_task_id"]}"
    end

    def presentation_resource
      job = action.result
      return nil unless job.is_a?(Job)

      { resource_title: job.issue_title, resource_url: "/jobs/#{job.id}" }
    end

    def tool_card_outcome
      outcome = payload["fire_outcome"]
      return nil unless outcome.is_a?(Hash)

      {
        fired: outcome["fired"] == true,
        job_id: outcome["job_id"],
        reason: outcome["reason"]
      }.compact
    end

    private

    def scheduled_task
      scope = user.admin? ? ScheduledTasks::Task.alive : ScheduledTasks::Task.alive.where(user: user)
      scope.find(payload.fetch("scheduled_task_id"))
    end
  end
end
