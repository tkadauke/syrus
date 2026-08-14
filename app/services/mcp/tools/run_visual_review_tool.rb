require "mcp"

module Mcp::Tools
  class RunVisualReviewTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "run_visual_review"

    description <<~DESC
      Request an on-demand visual review pass for a Syrus Job — re-checks the
      current implementation in a headless browser. Only available for
      implemented or approved Jobs with no active run, and only when visual
      review is configured/enabled for the repository. Not enqueued until the
      operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to run a visual review pass for." }
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
          action: "run_visual_review",
          payload: { "job_id" => job.id },
          message: "Run a visual review pass for #{job.slug}?"
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
