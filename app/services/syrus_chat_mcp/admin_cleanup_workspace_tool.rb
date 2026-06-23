require "mcp"

module SyrusChatMcp
  class AdminCleanupWorkspaceTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "admin_cleanup_workspace"
    description "Request deleting a Workflow workspace directory. Requires operator confirmation."

    input_schema(
      properties: {
        workflow_id: { type: "integer", description: "Workflow id whose workspace should be cleaned." }
      },
      required: %w[workflow_id]
    )

    class << self
      def call(workflow_id:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        workflow_id = integer_param(workflow_id, "workflow_id")
        return workflow_id if workflow_id.is_a?(MCP::Tool::Response)

        workflow = Workflow.find_by(id: workflow_id)
        return SyrusChatMcp.invalid("workflow not found: #{workflow_id}") unless workflow

        create_pending_admin_action(
          chat_session: chat_session,
          action: "admin_cleanup_workspace",
          payload: { "workflow_id" => workflow.id },
          message: "Delete workspace for workflow ##{workflow.id}?"
        )
      end
    end
  end
end
