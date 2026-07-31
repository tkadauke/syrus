require "mcp"

module Mcp::Tools
  class ReadScheduledTaskTool < MCP::Tool
    extend ScheduledTaskToolSupport

    tool_name "read_scheduled_task"

    description <<~DESC
      Read full details of a scheduled task including its prompt, schedule,
      state, and firing history.
    DESC

    input_schema(
      properties: {
        scheduled_task_id: { type: "integer", description: "Scheduled task id to inspect." }
      },
      required: %w[scheduled_task_id]
    )

    class << self
      def call(scheduled_task_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        task, err = find_scheduled_task(chat_session, scheduled_task_id)
        return err if err

        Mcp::Tools.success(scheduled_task: scheduled_task_payload(task).merge(prompt: task.prompt))
      end
    end
  end
end
