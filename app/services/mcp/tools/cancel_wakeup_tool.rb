require "mcp"

module Mcp::Tools
  class CancelWakeupTool < MCP::Tool
    tool_name "cancel_wakeup"

    description <<~DESC
      Cancel a pending one-shot wakeup turn for this chat session.
    DESC

    input_schema(
      properties: {
        wakeup_id: { type: "integer", description: "ID of the pending wakeup to cancel." }
      },
      required: %w[wakeup_id]
    )

    class << self
      def call(wakeup_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        wakeup_id = Integer(wakeup_id, exception: false)
        return Mcp::Tools.invalid("wakeup not found or not pending") unless wakeup_id

        wakeup = chat_session.wakeups.pending.find_by(id: wakeup_id)
        return Mcp::Tools.invalid("wakeup not found or not pending") unless wakeup

        wakeup.update!(state: "cancelled")

        Mcp::Tools.success(cancelled: true, wakeup_id: wakeup.id)
      rescue ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
