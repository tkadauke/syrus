require "mcp"

module Mcp::Tools
  class UnlandJobTool < MCP::Tool
    extend ProposalToolSupport
    extend AuthorizationSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "unland_job"
    description "Preflight or request an operator-confirmed unland of a landed Job. Confirmation creates a linked rollback Job; it never reopens the original or rolls back deployments."
    input_schema(properties: { job_id: { type: "integer" }, dry_run: { type: "boolean", default: false } }, required: %w[job_id])

    class << self
      def call(job_id:, server_context:, dry_run: false)
        job = find_job!(job_id)
        plan = Unlanding::Create.plan!(original: job, user: server_context.fetch(:chat_session).user)
        return Mcp::Tools.success(plan.to_h) if dry_run

        pending = create_pending_action_for_current_message!(server_context, server_context.fetch(:chat_session), action: "unland_job", payload: { "job_id" => job.id, "plan" => plan.to_h }, requested_by: "agent")
        Mcp::Tools.success(plan.to_h.merge(pending_confirmation_id: pending.id, pending_action_id: pending.id, state: pending.state, message: "Unland #{job.slug}? Operator confirmation is required."))
      rescue Unlanding::Create::Ineligible => e
        Mcp::Tools.invalid(e.message)
      end
    end
  end
end
