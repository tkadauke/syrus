require "mcp"

module Coworkers::McpTools
  class ListCoworkerGrantsTool < MCP::Tool
    tool_name "list_coworker_grants"
    description "List every catalog grant for the signed-in owner's coworkers, including its current policy, scope, and unlocked tools."
    input_schema(properties: {})

    class << self
      def call(server_context:)
        owner = server_context.fetch(:chat_session).user
        coworkers = Coworkers::OwnerResolver.new(owner: owner).scope.order(Arel.sql("LOWER(name) ASC"), :id).to_a
        rules_by_coworker_id = PermissionRule.active.where(
          owner_user: owner, subject_selector_type: "agent",
          subject_selector_id: coworkers.map { |coworker| coworker.id.to_s }
        ).to_a.group_by { |rule| rule.subject_selector_id.to_i }
        catalog = Coworkers::GrantCatalog.all
        Mcp::Tools.success(coworkers: coworkers.map do |coworker|
          coworker_payload(coworker, catalog, owner, rules_by_coworker_id.fetch(coworker.id, []))
        end)
      rescue StandardError => error
        Mcp::Tools.invalid(error.message)
      end

      private

      def coworker_payload(coworker, catalog, owner, rules)
        held = Coworkers::PermissionRules.new(coworker, preloaded_rules: rules).entries.index_by { |entry| entry.fetch(:capability) }
        {
          id: coworker.id, name: coworker.name, handle: coworker.handle,
          grants: catalog.map { |descriptor| grant_payload(descriptor, held[descriptor.name], owner) }
        }
      end

      def grant_payload(descriptor, grant, owner)
        payload = {
          capability: descriptor.name, label: descriptor.label,
          approval_policy: grant&.fetch(:approval_policy, nil) || "off", tools: descriptor.tools
        }
        return payload unless descriptor.scopeable?

        scope = grant&.fetch(:scope, nil)
        payload.merge(scope:, scope_label: scope.nil? ? nil : descriptor.scope_label(scope),
          scope_options: descriptor.scope_options(user: owner).map { |value| { value: value, label: descriptor.scope_label(value) } })
      end
    end
  end
end
