module SyrusDev
  class PermissionProvider
    include Syrus::Host::PermissionProvider

    CAPABILITY = "syrus_dev.read_diagnostics@v1".freeze
    WORKFLOW_DEFAULTS = {
      Syrus::Host::AgentRole::WORKFLOW_IMPLEMENT => :allow,
      Syrus::Host::AgentRole::AGENT_INSIGHT => :allow
    }.freeze
    DIAGNOSTIC_ROLES = [
      Syrus::Host::AgentRole::WORKFLOW_IMPLEMENT,
      Syrus::Host::AgentRole::AGENT_INSIGHT,
      Syrus::Host::AgentRole::COWORKER_CHAT,
      Syrus::Host::AgentRole::COWORKER
    ].freeze
    DIAGNOSTIC_DEFAULTS = WORKFLOW_DEFAULTS.merge(
      Syrus::Host::AgentRole::COWORKER_CHAT => :ask,
      Syrus::Host::AgentRole::COWORKER => :ask
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
          capability: CAPABILITY, operation:,
          presentation: Syrus::Host::CapabilityPresentation.for(capability: CAPABILITY, operation:),
          effects: %i[confidential_read], risk: :medium,
          deniable_reason: :instance_wide_observability,
          requestable_roles: roles, defaults:, maximum_autonomy: :job,
          authority_durations: %i[invocation chat_session job], resource_scope: { type: :none },
          classifier: classifier(operation), fingerprint_normalizer: method(:normalize_arguments),
          redactor: method(:redact_arguments)
        )
      end
    end

    register_read(
      operation: "syrus_dev.performance/read@v1",
      roles: [ Syrus::Host::AgentRole::WORKFLOW_IMPLEMENT, Syrus::Host::AgentRole::COWORKER_CHAT, Syrus::Host::AgentRole::COWORKER ],
      defaults: DIAGNOSTIC_DEFAULTS.except(Syrus::Host::AgentRole::AGENT_INSIGHT)
    )
    register_read(
      operation: "syrus_dev.logs/search@v1",
      roles: DIAGNOSTIC_ROLES,
      defaults: DIAGNOSTIC_DEFAULTS
    )
    register_read(
      operation: "syrus_dev.workspace_reuse/read@v1",
      roles: [ Syrus::Host::AgentRole::WORKFLOW_IMPLEMENT ],
      defaults: WORKFLOW_DEFAULTS.except(Syrus::Host::AgentRole::AGENT_INSIGHT)
    )
  end
end
