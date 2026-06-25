module SyrusChatMcp
  module ScheduledTaskToolSupport
    private

    def scheduled_tasks_for(chat_session)
      ScheduledTask.alive.where(user: chat_session.user)
    end

    def find_scheduled_task(chat_session, scheduled_task_id)
      task_id = Integer(scheduled_task_id, exception: false)
      return [ nil, SyrusChatMcp.invalid("scheduled_task_id is required") ] unless task_id

      task = scheduled_tasks_for(chat_session).find_by(id: task_id)
      return [ nil, SyrusChatMcp.invalid("scheduled task not found: #{task_id}") ] unless task

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
        cron_expression: task.cron_expression,
        enabled: scheduled_task_enabled?(task),
        last_fired_at: task.last_fired_at&.iso8601,
        created_at: task.created_at.iso8601
      }
    end
  end
end
