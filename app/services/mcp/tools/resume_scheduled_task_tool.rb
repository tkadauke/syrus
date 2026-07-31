require "mcp"

module Mcp::Tools
  class ResumeScheduledTaskTool < MCP::Tool
    extend ScheduledTaskToolSupport

    tool_name "resume_scheduled_task"

    description <<~DESC
      Resume a disabled scheduled task for this chat session's repository.
    DESC

    input_schema(
      properties: {
        scheduled_task_id: { type: "integer", description: "ScheduledTask id to resume." }
      },
      required: %w[scheduled_task_id]
    )

    class << self
      def call(scheduled_task_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        task, error = find_scheduled_task(chat_session, scheduled_task_id)
        return error if error
        return Mcp::Tools.invalid("scheduled task is already enabled") if scheduled_task_enabled?(task)
        return Mcp::Tools.invalid("scheduled task cannot be resumed from state: #{task.state}") unless task.paused? || task.auto_paused?

        task.resume!

        Mcp::Tools.success(
          scheduled_task_id: task.id,
          label: task.name,
          enabled: true
        )
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
