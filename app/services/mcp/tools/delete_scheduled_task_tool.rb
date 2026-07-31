require "mcp"

module Mcp::Tools
  class DeleteScheduledTaskTool < MCP::Tool
    extend ScheduledTaskToolSupport

    tool_name "delete_scheduled_task"

    description <<~DESC
      Delete a scheduled task for this chat session's repository.
    DESC

    input_schema(
      properties: {
        scheduled_task_id: { type: "integer", description: "ScheduledTask id to delete." }
      },
      required: %w[scheduled_task_id]
    )

    class << self
      def call(scheduled_task_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        task, error = find_scheduled_task(chat_session, scheduled_task_id)
        return error if error

        label = task.name
        task.soft_delete!

        Mcp::Tools.success(
          scheduled_task_id: task.id,
          label: label,
          deleted: true
        )
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
