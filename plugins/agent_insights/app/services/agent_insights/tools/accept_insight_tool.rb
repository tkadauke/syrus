require "mcp"

module AgentInsights
  module Tools
    class AcceptInsightTool < MCP::Tool
      extend MutationToolSupport

      tool_name "accept_insight"
      description "Accept one insight immediately, or request operator confirmation for a validated batch. Each insight preserves its proposal semantics: Jobs and memories are created only after every target passes validation."
      input_schema(properties: {
        insight_id: { type: "integer", description: "One insight id." },
        insight_ids: { type: "array", items: { type: "integer" }, description: "Two or more insight ids for one grouped confirmation." }
      })

      class << self
        def call(insight_id: nil, insight_ids: nil, server_context:)
          ids, error = Mutations::Base.validate_ids(id: insight_id, ids: insight_ids)
          return Mcp::Tools.invalid(error) if error

          _context, chat, owner, audit_actor, scope = mutation_context(server_context)
          mutation = Mutations::Accept.new(ids: ids, actor: owner, audit_actor: audit_actor, repository_scope: scope)
          execute_or_confirm(
            mutation: mutation, ids: ids, chat_session: chat, server_context: server_context,
            action: "accept_insights", payload: { "insight_ids" => ids }, message: "Accept insights #{ids.map { |id| "##{id}" }.join(', ')}?"
          )
        end
      end
    end
  end
end
