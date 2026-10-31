require "mcp"

module Coworkers::McpTools
  class ListCoworkerGrantsTool < MCP::Tool
    tool_name "list_coworker_grants"
    description "List every catalog grant for the signed-in owner's coworkers, including its current policy, scope, and unlocked tools."
    input_schema(properties: {})

    class << self
      def call(server_context:)
        owner = server_context.fetch(:chat_session).user
        coworkers = Coworkers::OwnerResolver.new(owner: owner).scope.includes(:grants).order(Arel.sql("LOWER(name) ASC"), :id)
        catalog = Coworkers::GrantCatalog.all
        Mcp::Tools.success(coworkers: coworkers.map { |coworker| coworker_payload(coworker, catalog, owner) })
      rescue StandardError => error
        Mcp::Tools.invalid(error.message)
      end

      private

      def coworker_payload(coworker, catalog, owner)
        held = coworker.grants.index_by(&:capability)
        {
          id: coworker.id, name: coworker.name, handle: coworker.handle,
          grants: catalog.map { |descriptor| grant_payload(descriptor, held[descriptor.name], owner) }
        }
      end

      def grant_payload(descriptor, grant, owner)
        payload = {
          capability: descriptor.name, label: descriptor.label,
          approval_policy: grant&.approval_policy || "off", tools: descriptor.tools
        }
        return payload unless descriptor.scopeable?

        payload.merge(scope: grant&.scope, scope_label: grant&.scope.nil? ? nil : descriptor.scope_label(grant.scope),
          scope_options: descriptor.scope_options(user: owner).map { |value| { value: value, label: descriptor.scope_label(value) } })
      end
    end
  end
end
