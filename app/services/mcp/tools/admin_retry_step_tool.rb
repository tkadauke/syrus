require "mcp"

module Mcp::Tools
  class AdminRetryStepTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_retry_step"
    description "Request retrying a failed Step on a Workflow. Requires operator confirmation."

    input_schema(
      properties: {
        workflow_id: { type: "integer", description: "Workflow id that owns the failed Step." },
        step_slug: { type: "string", description: "Step kind to retry, for example implement or graders." },
        reason: { type: "string", description: "Operator-facing reason for retrying this failed Step." }
      },
      required: %w[workflow_id step_slug reason]
    )

    class << self
      def call(workflow_id:, step_slug:, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        workflow_id = integer_param(workflow_id, "workflow_id")
        return workflow_id if workflow_id.is_a?(MCP::Tool::Response)

        step_slug = step_slug.to_s.strip
        return Mcp::Tools.invalid("step_slug is required") if step_slug.empty?
        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        workflow = Workflow.find_by(id: workflow_id)
        return Mcp::Tools.invalid("workflow not found: #{workflow_id}") unless workflow
        unless workflow.steps.exists?(kind: step_slug)
          return Mcp::Tools.invalid("step '#{step_slug}' not found on workflow ##{workflow.id}")
        end

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "admin_retry_step",
          payload: { "workflow_id" => workflow.id, "step_slug" => step_slug },
          reason: reason,
          message: "Retry step '#{step_slug}' on workflow ##{workflow.id}?"
        )
      end
    end
  end
end
