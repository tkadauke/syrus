module SyrusDev
  class PermissionProvider
    include Syrus::Plugin::PermissionProvider

    ROLES = [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ].freeze
    CAPABILITY = "syrus_dev.read_diagnostics@v1".freeze

    class << self
      def normalize_arguments(arguments)
        case arguments
        when Hash
          arguments.to_h.sort_by { |key, _| key.to_s }
            .to_h { |key, value| [ key.to_s, normalize_arguments(value) ] }
        when Array then arguments.map { |value| normalize_arguments(value) }
        else arguments
        end
      end

      def redact_arguments(arguments)
        case arguments
        when Hash
          arguments.to_h do |key, value|
            [ key, key.to_s.match?(Permissions::CapabilityDescriptorAdapter::REDACTED_KEYS) ? "[REDACTED]" : redact_arguments(value) ]
          end
        when Array then arguments.map { |value| redact_arguments(value) }
        else arguments
        end
      end

      def register_tool(tool_name)
        operation = "syrus_dev.read_diagnostics/#{tool_name}@v1"
        register_capability(
          capability: CAPABILITY,
          operation:,
          presentation: Permissions::CapabilityPresentation.for(capability: CAPABILITY, operation:),
          effects: %i[confidential_read],
          risk: :medium,
          requestable_roles: ROLES,
          defaults: ROLES.index_with { :ask },
          maximum_autonomy: :permanent,
          authority_durations: Permissions::CapabilityDescriptor::AUTHORITY_DURATIONS,
          resource_scope: { type: :none },
          classifier: ->(_arguments) { { operation:, effects: %i[confidential_read], risk: :medium, confidence: :certain } },
          fingerprint_normalizer: method(:normalize_arguments),
          redactor: method(:redact_arguments)
        )
      end
    end

    register_tool "read_performance_diagnostics"
    register_tool "read_syrus_logs"
  end
end
