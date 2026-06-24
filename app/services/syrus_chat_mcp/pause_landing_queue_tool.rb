require "mcp"

module SyrusChatMcp
  class PauseLandingQueueTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "pause_landing_queue"

    description "Request pausing the operator's landing queue. The queue is not paused until the operator confirms the pending action."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        create_pending_action!(
          server_context,
          chat_session,
          action: "pause_landing_queue",
          payload: {},
          message: "Pause the landing queue?"
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
