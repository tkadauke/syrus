require "mcp"

module ScheduledTasks
  module McpTools
    class FireScheduledTaskNowTool < MCP::Tool
      extend ::Mcp::Tools::ProposalToolSupport
      extend ::Mcp::Tools::PendingActionToolSupport
      extend ScheduledTaskToolSupport

      tool_name "fire_scheduled_task_now"

      description "Request firing a scheduled task immediately. The task is not fired until the operator confirms the pending action."

      input_schema(
        properties: {
          scheduled_task_id: { type: "integer", description: "Scheduled task id to fire now." }
        },
        required: %w[scheduled_task_id]
      )

      class << self
        def call(scheduled_task_id:, server_context:)
          chat_session = server_context.fetch(:chat_session)
          task, error = find_mutable_scheduled_task(chat_session, scheduled_task_id)
          return error if error

          create_pending_action!(
            server_context,
            chat_session,
            action: "fire_scheduled_task_now",
            payload: { "scheduled_task_id" => task.id },
            message: "Fire scheduled task #{task.id} immediately?"
          )
        rescue ActiveRecord::RecordInvalid => e
          invalid_record(e)
        end
      end
    end
  end
end
