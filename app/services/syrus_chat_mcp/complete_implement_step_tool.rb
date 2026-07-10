require "mcp"

module SyrusChatMcp
  class CompleteImplementStepTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "complete_implement_step"

    description <<~DESC
      Signal that the Coding Mode session is complete and ready for Syrus automation
      (graders, PR creation, and the review queue). Push the branch before calling
      this tool: `git push origin <branch>`. Grader failures will arrive as a
      follow-up message in this chat; address them and call this tool again to
      re-trigger automation.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id for the work just completed." }
      },
      required: %w[job_id]
    )

    class << self
      def call(job_id:, server_context:)
        chat_session = server_context.fetch(:chat_session)
        job_id = Integer(job_id, exception: false)
        return SyrusChatMcp.invalid("job_id is required") unless job_id

        job = find_job_for_session(chat_session, job_id)
        return SyrusChatMcp.invalid("job #{job_id} not found or not attached to this chat") unless job

        pending_action = chat_session.pending_actions.create!(
          action: "complete_implement_step",
          state: "pending",
          payload: { "job_id" => job.id },
          requested_by: "agent"
        )

        SyrusChatMcp.success(
          pending_action_id: pending_action.id,
          state: pending_action.state,
          message: "Coding session handoff is pending operator confirmation."
        )
      rescue ActiveRecord::RecordInvalid => e
        SyrusChatMcp.invalid(e.record.errors.full_messages.to_sentence)
      end

      private

      def find_job_for_session(chat_session, job_id)
        chat_session.attached_jobs.find { |j| j.id == job_id } ||
          (chat_session.repository && chat_session.repository.jobs.find_by(id: job_id))
      end
    end
  end
end
