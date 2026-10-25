require "mcp"

module Mcp::Tools
  class AdminCleanupWorkspaceTool < MCP::Tool
    extend AdminPendingActionToolSupport
    extend BulkPendingActionToolSupport

    tool_name "admin_cleanup_workspace"
    description "Request deleting a Workflow workspace directory. Requires operator confirmation."

    input_schema(
      properties: {
        workflow_id: { type: "integer", description: "Workflow id whose workspace should be cleaned." },
        workflow_ids: { type: "array", items: { type: "integer" }, maxItems: BulkPendingActionToolSupport::MAX_BATCH_SIZE, description: "Multiple Workflow ids to clean as one grouped pending action." },
        reason: { type: "string", description: "Operator-facing reason for deleting this workspace." }
      },
      required: %w[reason]
    )

    class << self
      def call(workflow_id: nil, workflow_ids: nil, reason:, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)

        ids, bulk, error = resolve_ids(id: workflow_id, ids: workflow_ids, param_name: "workflow_id")
        return error if error
        reason = reason.to_s.strip
        return Mcp::Tools.invalid("reason is required") if reason.empty?

        workflows = ids.map { |id| Workflow.find_by(id: id) }
        missing = ids.zip(workflows).filter_map { |id, workflow| id unless workflow }
        return Mcp::Tools.invalid("workflow not found: #{missing.join(', ')}") if missing.any?

        unless bulk
          workflow = workflows.first
          return create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "admin_cleanup_workspace",
          payload: { "workflow_id" => workflow.id },
          reason: reason,
          message: "Delete workspace for workflow ##{workflow.id}?"
          )
        end
        group = create_pending_action_group!(server_context:, chat_session:, reason:, member_attributes: workflows.map { |workflow|
          { action: "admin_cleanup_workspace", payload: { "workflow_id" => workflow.id }, requested_by: "agent", reason: reason }
        })
        bulk_action_response(group:, message: I18n.t("server.mcp.bulk_confirmation.cleanup_workspaces", count: workflows.size))
      end
    end
  end
end
