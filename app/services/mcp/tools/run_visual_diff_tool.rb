require "mcp"

module Mcp::Tools
  class RunVisualDiffTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "run_visual_diff"

    description <<~DESC
      Request a before/after visual comparison for a Syrus Job using usable
      screenshots from a prior visual review. Only available for eligible Jobs
      with visual review configured and no conflicting active work. Creates a
      visual_diff workflow only after the operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to run a before/after visual comparison for." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job, error = user_job(chat_session, job_id)
        return error if error

        create_pending_action!(
          server_context,
          chat_session,
          action: "run_visual_diff",
          payload: { "job_id" => job.id },
          message: "Run a before/after visual comparison for #{job.slug}?"
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
