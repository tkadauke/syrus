require "mcp"

module Mcp::Tools
  class MutateProviderRoutingRulesTool < MCP::Tool
    extend ProposalToolSupport
    extend PendingActionToolSupport
    extend ProviderRoutingToolSupport
    singleton_class.prepend(AuthorizationSupport::ToolDispatch)

    tool_name "mutate_provider_routing_rules"
    description "Validate and request an atomic provider-routing rule-set mutation. Supports create, update, set_enabled, delete, and reorder operations. Requires the revision returned by read_provider_routing_rules; nothing changes until the operator confirms the human-readable pending action."

    input_schema(
      properties: {
        scope_type: { type: "string", enum: %w[user repository job] },
        repository_id: { type: "integer" },
        job_id: { type: "integer" },
        expected_revision: { type: "string" },
        operations: {
          type: "array",
          items: {
            type: "object",
            properties: {
              type: { type: "string", enum: %w[create update set_enabled delete reorder] },
              id: { type: "integer" },
              enabled: { type: "boolean" },
              ids: { type: "array", items: { type: "integer" } },
              rule: { type: "object" }
            },
            required: %w[type]
          }
        }
      },
      required: %w[scope_type expected_revision operations]
    )

    class << self
      def call(scope_type:, expected_revision:, operations:, server_context:, repository_id: nil, job_id: nil)
        chat_session = server_context.fetch(:chat_session)
        rule_set = provider_routing_rule_set!(scope_type: scope_type, repository_id: repository_id, job_id: job_id)
        before = rule_set.snapshot
        after = rule_set.mutate!(operations: operations, expected_revision: expected_revision, preview: true)
        summary = change_summary(operations)

        create_pending_action!(
          server_context,
          chat_session,
          action: "mutate_provider_routing_rules",
          payload: {
            "scope" => rule_set.scope.stringify_keys,
            "expected_revision" => expected_revision,
            "operations" => operations,
            "before" => concise_snapshot(before),
            "after" => concise_snapshot(after),
            "summary" => summary
          },
          message: "Apply provider-routing changes? #{summary}"
        )
      rescue ProviderRouting::RuleSet::StaleRevision, ProviderRouting::RuleSet::InvalidOperation, ActiveRecord::RecordInvalid => e
        Mcp::Tools.invalid(e.message)
      end

      private

      def change_summary(operations)
        Array(operations).map { |operation| operation.to_h.with_indifferent_access[:type].to_s.humanize(capitalize: false) }.join(", ")
      end

      def concise_snapshot(snapshot)
        {
          "revision" => snapshot.fetch(:revision),
          "rules" => snapshot.fetch(:rules).map do |rule|
            rule.slice(:id, :position, :enabled, :task_key, :trigger, :conditions, :action)
          end
        }
      end
    end
  end
end
