require "mcp"

module ScheduledTasks
  module McpTools
    class PauseScheduledTaskTool < MCP::Tool
      extend ScheduledTaskToolSupport

      tool_name "pause_scheduled_task"

      description <<~DESC
        Pause an enabled scheduled task for this chat session's repository.
      DESC

      input_schema(
        properties: {
          scheduled_task_id: { type: "integer", description: "ScheduledTasks::Task id to pause." }
        },
        required: %w[scheduled_task_id]
      )

      class << self
        def call(scheduled_task_id:, server_context:)
          chat_session = server_context.fetch(:chat_session)
          task, error = find_mutable_scheduled_task(chat_session, scheduled_task_id)
          return error if error
          return Mcp::Tools.invalid("scheduled task is already disabled") unless scheduled_task_enabled?(task)

          previous_state = task.state
          next_fire_at = task.next_fire_at&.iso8601
          task.pause!(reason: "operator")

          Mcp::Tools.success(
            scheduled_task_id: task.id,
            label: task.name,
            enabled: false,
            previous_state: previous_state,
            state: task.state,
            next_fire_at: next_fire_at,
            repository_id: task.repository_id,
            repository_slug: task.repository&.slug
          )
        rescue ActiveRecord::RecordInvalid => e
          Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
        end
      end
    end
  end
end
