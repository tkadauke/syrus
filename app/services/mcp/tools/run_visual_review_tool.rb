require "mcp"

module Mcp::Tools
  class RunVisualReviewTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport

    tool_name "run_visual_review"
    MAX_PROMPT_LENGTH = ManualVisualReviewSubmission::MAX_PROMPT_LENGTH

    description <<~DESC
      Request an on-demand visual review pass for a Syrus Job — re-checks the
      current implementation in a headless browser. Only available for
      implemented or approved Jobs with no active run, and only when visual
      review is configured/enabled for the repository. Not enqueued until the
      operator confirms the pending action.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to run a visual review pass for." },
        prompt: {
          type: "string",
          maxLength: MAX_PROMPT_LENGTH,
          description: "Optional focused reproduction and evidence-capture instructions for the visual reviewer (up to #{MAX_PROMPT_LENGTH} characters)."
        }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:, prompt: nil)
        chat_session = server_context.fetch(:chat_session)
        job, error = user_job(chat_session, job_id)
        return error if error

        prompt = prompt.to_s.strip if prompt
        return Mcp::Tools.invalid("prompt cannot be blank") if prompt && prompt.blank?
        return Mcp::Tools.invalid("prompt must be #{MAX_PROMPT_LENGTH} characters or fewer") if prompt&.length.to_i > MAX_PROMPT_LENGTH

        create_pending_action!(
          server_context,
          chat_session,
          action: "run_visual_review",
          payload: { "job_id" => job.id, "prompt" => prompt }.compact,
          message: "Run a visual review pass for #{job.slug}?"
        )
      rescue ActiveRecord::RecordInvalid => e
        invalid_record(e)
      end
    end
  end
end
