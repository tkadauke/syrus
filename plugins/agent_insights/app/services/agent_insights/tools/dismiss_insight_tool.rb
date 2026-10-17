require "mcp"

module AgentInsights
  module Tools
    class DismissInsightTool < MCP::Tool
      extend MutationToolSupport

      tool_name "dismiss_insight"
      description "Dismiss one pending insight or request operator confirmation for a validated batch. Records the shared operator-facing reason and never creates Jobs or memories."
      input_schema(properties: {
        insight_id: { type: "integer", description: "One insight id." },
        insight_ids: { type: "array", items: { type: "integer" }, description: "Two or more insight ids for one grouped confirmation." },
        reason: { type: "string", description: "Required audit reason." }
      }, required: %w[reason])

      class << self
        def call(insight_id: nil, insight_ids: nil, reason:, server_context:)
          ids, error = Mutations::Base.validate_ids(id: insight_id, ids: insight_ids)
          return Mcp::Tools.invalid(error) if error

          _context, chat, owner, audit_actor, scope = mutation_context(server_context)
          mutation = Mutations::Dismiss.new(ids: ids, actor: owner, audit_actor: audit_actor, repository_scope: scope, reason: reason)
          execute_or_confirm(
            mutation: mutation, ids: ids, chat_session: chat, server_context: server_context,
            action: "dismiss_insights", payload: { "insight_ids" => ids, "reason" => mutation.reason }, message: "Dismiss insights #{ids.map { |id| "##{id}" }.join(', ')}?"
          )
        end
      end
    end
  end
end
