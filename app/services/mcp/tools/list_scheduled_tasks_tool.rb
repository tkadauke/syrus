require "mcp"

module Mcp::Tools
  class ListScheduledTasksTool < MCP::Tool
    extend ScheduledTaskToolSupport

    tool_name "list_scheduled_tasks"

    description <<~DESC
      List non-archived scheduled tasks for this chat session's repository.
    DESC

    input_schema(
      properties: {}
    )

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        tasks = scheduled_tasks_for(chat_session).order(:created_at)

        Mcp::Tools.success(tasks: tasks.map { |task| scheduled_task_payload(task) })
      end
    end
  end
end
