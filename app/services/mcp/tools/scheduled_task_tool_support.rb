module Mcp::Tools
  module ScheduledTaskToolSupport
    private

    def scheduled_tasks_for(chat_session)
      chat_session.user.admin? ? ScheduledTask.alive : ScheduledTask.alive.where(user: chat_session.user)
    end

    def find_scheduled_task(chat_session, scheduled_task_id)
      task_id = Integer(scheduled_task_id, exception: false)
      return [ nil, Mcp::Tools.invalid("scheduled_task_id is required") ] unless task_id

      task = scheduled_tasks_for(chat_session).find_by(id: task_id)
      return [ nil, Mcp::Tools.invalid("scheduled task not found: #{task_id}") ] unless task

      [ task, nil ]
    end

    def scheduled_task_enabled?(task)
      task.active?
    end

    def scheduled_task_payload(task)
      {
        id: task.id,
        repository_slug: task.repository&.slug,
        label: task.name,
        kind: task.kind,
        state: task.state,
        cron_expression: task.cron_expression,
        schedule_input: task.schedule_input,
        schedule_expression: task.schedule_expression,
        schedule_explanation: task.schedule_explanation,
        schedule_timezone: task.schedule_timezone,
        fire_at: task.fire_at&.iso8601,
        pr_pileup_policy: task.pr_pileup_policy,
        enabled: scheduled_task_enabled?(task),
        last_fired_at: task.last_fired_at&.iso8601,
        last_successful_fire_at: task.last_successful_fire_at&.iso8601,
        consecutive_failure_count: task.consecutive_failure_count,
        next_fire_at: task.next_fire_at&.iso8601,
        created_at: task.created_at.iso8601
      }
    end
  end
end
