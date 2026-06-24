require "mcp"

module SyrusChatMcp
  class SubmitChatFeedbackTool < MCP::Tool
    extend ProposalToolSupport

    tool_name "submit_chat_feedback"

    description <<~DESC
      Propose operator feedback on a job for confirmation before triggering a new agent workflow that will improve the implementation. Call this only after discussing the feedback with the operator and reaching agreement on what to change. The job must be in `implemented` or `approved` state. Confirmed feedback on an approved job will unapprove it. Use `list_job_workflows` first to confirm there is no active chat_feedback workflow already running.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to improve." },
        feedback: { type: "string", description: "Markdown feedback from the operator, typically 1-5 paragraphs describing what to change." }
      },
      required: %w[job_id feedback]
    )

    class << self
      def call(job_id:, feedback:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job_id = Integer(job_id, exception: false)
        return SyrusChatMcp.invalid("job_id is required") unless job_id

        feedback = feedback.to_s.strip
        return SyrusChatMcp.invalid("feedback is required") if feedback.blank?

        job = chat_session.repository.jobs.find_by(id: job_id)
        return SyrusChatMcp.invalid("job not found in this repository: #{job_id}") unless job

        return SyrusChatMcp.invalid("#{job.state} jobs are not actionable for chat feedback; the job must be implemented or approved.") unless actionable?(job)
        if active_chat_feedback_workflow?(job)
          return SyrusChatMcp.invalid("a chat_feedback workflow is already queued or running for this job")
        end

        pending_action = create_pending_action_message!(
          chat_session,
          action: "submit_chat_feedback",
          payload: { "job_id" => job.id, "feedback" => feedback },
          requested_by: "agent"
        )

        SyrusChatMcp.success(
          pending_confirmation_id: pending_action.id,
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Chat feedback requires operator confirmation."
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def actionable?(job)
        job.implemented? || job.approved?
      end

      def active_chat_feedback_workflow?(job)
        job.workflows.where(trigger_kind: "chat_feedback", state: %w[queued running]).exists?
      end
    end
  end
end
