module SyrusDev
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    WORKFLOW_DEFAULTS = {
      AgentRole::WORKFLOW_IMPLEMENT => :allow,
      AgentRole::AGENT_INSIGHT => :allow
    }.freeze
    DIAGNOSTIC_ROLES = [
      AgentRole::WORKFLOW_IMPLEMENT,
      AgentRole::AGENT_INSIGHT,
      AgentRole::COWORKER_CHAT,
      AgentRole::COWORKER
    ].freeze
    DIAGNOSTIC_DEFAULTS = WORKFLOW_DEFAULTS.merge(
      AgentRole::COWORKER_CHAT => :ask,
      AgentRole::COWORKER => :ask
    ).freeze

    class << self
      def normalize_arguments(arguments)
        arguments.to_h.stringify_keys.slice(
          "limit", "revision_scope", "include_events", "query", "since",
          "level", "role", "hostname", "until_time"
        )
      end

      def redact_arguments(arguments)
        normalize_arguments(arguments).tap do |normalized|
          normalized["query"] = "[REDACTED LOG QUERY]" if normalized.key?("query")
        end
      end

      def classifier(operation)
        ->(_arguments) do
          { operation:, effects: %i[confidential_read], risk: :medium, confidence: :certain }
        end
      end

      def register_read(operation:, roles:, defaults:)
        register_capability(
          capability: "syrus_dev.diagnostics@v1", operation:,
          presentation: Permissions::CapabilityPresentation.for(
            capability: "syrus_dev.diagnostics@v1", operation:
          ),
          effects: %i[confidential_read], risk: :medium,
          requestable_roles: roles, defaults:, maximum_autonomy: :job,
          authority_durations: %i[invocation chat_session job], resource_scope: { type: :none },
          classifier: classifier(operation), fingerprint_normalizer: method(:normalize_arguments),
          redactor: method(:redact_arguments)
        )
      end
    end

    register_read(
      operation: "syrus_dev.performance/read@v1",
      roles: [ AgentRole::WORKFLOW_IMPLEMENT, AgentRole::COWORKER_CHAT, AgentRole::COWORKER ],
      defaults: DIAGNOSTIC_DEFAULTS.except(AgentRole::AGENT_INSIGHT)
    )
    register_read(
      operation: "syrus_dev.logs/search@v1",
      roles: DIAGNOSTIC_ROLES,
      defaults: DIAGNOSTIC_DEFAULTS
    )
    register_read(
      operation: "syrus_dev.workspace_reuse/read@v1",
      roles: [ AgentRole::WORKFLOW_IMPLEMENT ],
      defaults: WORKFLOW_DEFAULTS.except(AgentRole::AGENT_INSIGHT)
    )
  end
end
