require "mcp"

module SyrusChatMcp
  class SubmitChatFeedbackTool < MCP::Tool
    tool_name "submit_chat_feedback"

    description <<~DESC
      Submit operator feedback on a job to trigger a new agent workflow that will improve the implementation. Call this only after discussing the feedback with the operator and reaching agreement on what to change. The job must be in `implemented` or `open` state. Submitting feedback on an approved job will unapprove it. Use `list_job_workflows` first to confirm there is no active chat_feedback workflow already running.
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

        workflow = Workflows::ChatFeedback.instantiate(
          job: job,
          artifacts: { "chat_feedback" => feedback },
          agent_provider: job.agent_provider
        )
        StepDispatcher.start_workflow(workflow)
        job.unapprove! if job.reload.may_unapprove?

        SyrusChatMcp.success(
          workflow_id: workflow.id,
          trigger_kind: "chat_feedback",
          message: "Feedback submitted. Workflow ##{workflow.id} has been queued."
        )
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
