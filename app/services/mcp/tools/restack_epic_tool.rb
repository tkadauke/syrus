require "mcp"

module SyrusChatMcp
  class RestackEpicTool < MCP::Tool
    extend AdminPendingActionToolSupport

    tool_name "restack_epic"
    description "Plan or request an audited Epic restack using the child Job dependency topology. Requires operator confirmation unless dry_run is true."

    input_schema(
      properties: {
        epic_id: { type: "integer", description: "Syrus Epic id." },
        reason: { type: "string", description: "Operator-facing audit reason for restacking the Epic." },
        strategy: { type: "string", enum: %w[dependency_topology], description: "Restack strategy.", default: "dependency_topology" },
        dry_run: { type: "boolean", description: "Return planned branch order and skipped nodes without creating a pending action.", default: false }
      },
      required: %w[epic_id]
    )

    class << self
      def call(epic_id:, reason: nil, strategy: "dependency_topology", dry_run: false, server_context:)
        chat_session = require_admin(server_context)
        return chat_session if chat_session.is_a?(MCP::Tool::Response)
        return SyrusChatMcp.invalid("strategy must be dependency_topology") unless strategy.to_s == "dependency_topology"

        epic_id = integer_param(epic_id, "epic_id")
        return epic_id if epic_id.is_a?(MCP::Tool::Response)
        epic = Epic.find_by(id: epic_id)
        return SyrusChatMcp.invalid("epic not found: #{epic_id}") unless epic

        plan = EpicRestackPlan.for(epic)
        return SyrusChatMcp.success(plan: plan) if dry_run

        reason = reason.to_s.strip
        return SyrusChatMcp.invalid("reason is required") if reason.empty?

        create_pending_admin_action(
          server_context: server_context,
          chat_session: chat_session,
          action: "restack_epic",
          payload: {
            "epic_id" => epic.id,
            "strategy" => "dependency_topology",
            "plan" => plan
          },
          reason: reason,
          message: "Restack #{epic.slug}? Planned branch count: #{plan.fetch("branch_order").size}; skipped: #{plan.fetch("skipped_nodes").size}."
        )
      end
    end
  end
end
