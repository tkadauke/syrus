require "mcp"

module SyrusChatMcp
  class PauseScheduledTaskTool < MCP::Tool
    extend ScheduledTaskToolSupport

    tool_name "pause_scheduled_task"

    description <<~DESC
      Pause an enabled scheduled task for this chat session's repository.
    DESC

    input_schema(
      properties: {
        scheduled_task_id: { type: "integer", description: "ScheduledTask id to pause." }
      },
      required: %w[scheduled_task_id]
    )

    class << self
      def call(scheduled_task_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        task, error = find_scheduled_task(chat_session, scheduled_task_id)
        return error if error
        return SyrusChatMcp.invalid("scheduled task is already disabled") unless scheduled_task_enabled?(task)

        task.pause!(reason: "operator")

        SyrusChatMcp.success(
          scheduled_task_id: task.id,
          label: task.name,
          enabled: false
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
