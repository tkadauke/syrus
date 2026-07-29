require "mcp"

module SyrusMcp
  # MCP tool available to reconciliation Jobs running in feedback mode.
  # Directly submits a chat_feedback workflow on a sibling Job without
  # requiring operator confirmation — the reconciliation agent acts on
  # behalf of the Epic owner who configured feedback mode.
  class SubmitReconciliationFeedbackTool < MCP::Tool
    tool_name "submit_chat_feedback"

    description <<~DESC
      Submit targeted feedback on a sibling Job in this Epic. Creates a chat_feedback workflow
      on the target Job that will address the identified cross-Job inconsistency. Call once per
      Job that needs changes; after all feedback is submitted make no further code changes and
      this reconciliation Job will close automatically.
    DESC

    input_schema(
      properties: {
        job_id: {
          type: "integer",
          description: "Syrus Job id of the sibling Job that needs changes."
        },
        feedback: {
          type: "string",
          description: "Focused, actionable description of what to change. Markdown, 1–5 paragraphs."
        }
      },
      required: %w[job_id feedback]
    )

    class << self
      def call(job_id:, feedback:, server_context:)
        run = SyrusMcp.run_from_context(server_context)
        context = McpToolContext.from_run(run)
        return SyrusMcp.not_authorized unless McpToolPolicy.capability_permitted?(context, :submit_chat_feedback)

        job_id_int = Integer(job_id, exception: false)
        return SyrusMcp.invalid("job_id must be an integer") unless job_id_int

        feedback_text = SyrusMcp.utf8(feedback.to_s).strip
        return SyrusMcp.invalid("feedback is required") if feedback_text.blank?

        target_job = Job.find_by(id: job_id_int)
        return SyrusMcp.invalid("Job #{job_id_int} not found") unless target_job

        result = ChatFeedbackSubmission.call(
          job: target_job,
          feedback: feedback_text,
          allowed_states: %w[implemented approved]
        )

        return SyrusMcp.invalid(result.error) unless result.success?

        SyrusMcp.write_log(run, "[mcp] submit_chat_feedback: submitted feedback for #{target_job.slug}")
        MCP::Tool::Response.new([ { type: "text", text: "Feedback submitted to #{target_job.slug}." } ])
      rescue StandardError => e
        Rails.logger.error("[SyrusMcp::SubmitReconciliationFeedbackTool] #{e.class}: #{e.message}")
        MCP::Tool::Response.new([ { type: "text", text: "Error: #{e.class}: #{e.message}" } ], error: true)
      end
    end
  end
end
