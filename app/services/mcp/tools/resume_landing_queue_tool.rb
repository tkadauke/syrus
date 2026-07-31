require "mcp"

module Mcp::Tools
  class ResumeLandingQueueTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "resume_landing_queue"

    description "Request resuming the operator's landing queue. The queue is not resumed until the operator confirms the pending action."

    input_schema(properties: {})

    class << self
      def call(server_context:)
        chat_session = server_context.fetch(:chat_session)
        create_pending_action!(
          server_context,
          chat_session,
          action: "resume_landing_queue",
          payload: {},
          message: "Resume the landing queue?"
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
