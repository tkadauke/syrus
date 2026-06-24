require "mcp"

module SyrusChatMcp
  class FireScheduledTaskNowTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

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
        task_id = Integer(scheduled_task_id, exception: false)
        return SyrusChatMcp.invalid("scheduled_task_id is required") unless task_id

        task = ScheduledTask.alive.where(user: chat_session.user).find_by(id: task_id)
        return SyrusChatMcp.invalid("scheduled task not found: #{task_id}") unless task

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
