require "mcp"

module Mcp::Tools
  class ManageJobStateTool < MCP::Tool
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "manage_job_state"
    description <<~DESC
      Close or cancel one accessible Syrus Job as duplicate or obsolete work.
      A human-readable reason is required. Pass canonical_job_id when the Job
      duplicates a replacement Job in the same repository. This tool cannot
      edit any other Job metadata or close work with landing/deployment evidence.
    DESC

    input_schema(
      properties: {
        job_id: { type: "integer", description: "Syrus Job id to close or cancel." },
        action: { type: "string", enum: Jobs::StateManagement::ACTIONS, description: "Whether to close or cancel the Job." },
        reason: { type: "string", maxLength: 1_000, description: "Required human-readable audit reason." },
        canonical_job_id: { type: "integer", description: "Optional canonical replacement Job id for a duplicate." }
      },
      required: %w[job_id action reason]
    )

    class << self
      def call(job_id:, action:, reason:, server_context:, canonical_job_id: nil)
        job = find_job!(job_id)
        canonical_job = find_job!(canonical_job_id) if canonical_job_id.present?
        context = McpToolContext.from_server_context(server_context)
        result = Jobs::StateManagement.new(
          job:, action:, reason:, canonical_job:, actor: context.agent_actor || context.user,
          chat_session: context.chat_session || server_context.fetch(:chat_session)
        ).call

        Mcp::Tools.success(
          ok: true, job_id: result.job.id, state: result.job.state, closure_reason: result.job.closure_reason,
          canonical_job_id: result.job.canonical_job_id, audit: audit_payload(result.transition)
        )
      rescue Jobs::StateManagement::Invalid => error
        Mcp::Tools.success(ok: false, error: error.message, job_id: error.job.id, state: error.job.reload.state)
      end

      private

      def audit_payload(transition)
        return nil unless transition

        {
          id: transition.id, from_state: transition.from_state, to_state: transition.to_state,
          reason: transition.metadata["human_reason"], chat_session_id: transition.metadata["chat_session_id"],
          actor_type: transition.metadata["actor_type"], actor_id: transition.metadata["actor_id"],
          canonical_job_id: transition.metadata["canonical_job_id"], created_at: transition.created_at.iso8601
        }
      end
    end
  end
end
