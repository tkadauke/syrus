require "mcp"

module SyrusChatMcp
  class AdminRetryStepTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_retry_step"
    description "Request retrying a failed Step on a Workflow. Requires operator confirmation."

    input_schema(
      properties: {
        workflow_id: { type: "integer", description: "Workflow id that owns the failed Step." },
        step_slug: { type: "string", description: "Step kind to retry, for example implement or graders." }
      },
      required: %w[workflow_id step_slug]
    )

    class << self
      def call(workflow_id:, step_slug:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        workflow_id = integer_param(workflow_id, "workflow_id")
        return workflow_id if workflow_id.is_a?(MCP::Tool::Response)

        step_slug = step_slug.to_s.strip
        return SyrusChatMcp.invalid("step_slug is required") if step_slug.empty?

        workflow = Workflow.find_by(id: workflow_id)
        return SyrusChatMcp.invalid("workflow not found: #{workflow_id}") unless workflow
        unless workflow.steps.exists?(kind: step_slug)
          return SyrusChatMcp.invalid("step '#{step_slug}' not found on workflow ##{workflow.id}")
        end

        create_pending_admin_action(
          chat_session: chat_session,
          action: "admin_retry_step",
          payload: { "workflow_id" => workflow.id, "step_slug" => step_slug },
          message: "Retry step '#{step_slug}' on workflow ##{workflow.id}?"
        )
      end
    end
  end
end
