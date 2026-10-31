module Permissions
  class CapabilityDescriptorAdapter
    REDACTED_KEYS = /(?:token|secret|password|credential|authorization|api[_-]?key)/i

    class << self
      def for_registry_entry(tool_name:, capability:, mutation:, required_roles: [], admin_only: false, descriptor: nil)
        return coerce(descriptor) if descriptor

        roles = Array(required_roles).presence || default_roles(admin_only: admin_only)
        build_legacy(
          tool_name: tool_name,
          capability: capability,
          mutation: mutation,
          roles: roles
        )
      end

      def for_plugin_definition(definition)
        definition = definition.symbolize_keys
        return coerce(definition[:capability_descriptor]) if definition[:capability_descriptor]

        build_legacy(
          tool_name: definition.fetch(:name),
          capability: definition[:capability],
          mutation: definition.fetch(:mutation, false),
          roles: Array(definition[:requestable_roles]).presence || default_roles
        )
      end

      private

      def coerce(descriptor)
        descriptor.is_a?(CapabilityDescriptor) ? descriptor : CapabilityDescriptor.new(**descriptor.symbolize_keys)
      end

      def build_legacy(tool_name:, capability:, mutation:, roles:)
        family = identifier_component(capability.presence || tool_name)
        operation = identifier_component(tool_name)
        policy = mutation ? :ask : :allow
        effects = mutation ? [ :internal_write ] : [ :local_read ]

        CapabilityDescriptor.new(
          capability: "#{family}@v1",
          operation: "#{family}/#{operation}@v1",
          effects: effects,
          risk: mutation ? :medium : :low,
          requestable_roles: roles,
          defaults: roles.index_with { policy },
          maximum_autonomy: mutation ? :invocation : :permanent,
          authority_durations: mutation ? [ :invocation ] : CapabilityDescriptor::AUTHORITY_DURATIONS,
          resource_scope: { type: :none },
          classifier: ->(_arguments) { { operation: "#{family}/#{operation}@v1", effects: effects, confidence: :legacy } },
          fingerprint_normalizer: ->(arguments) { deep_normalize(arguments) },
          redactor: ->(arguments) { deep_redact(arguments) }
        )
      end

      def default_roles(admin_only: false)
        roles = AgentRole::CHAT_ROLES + AgentRole::WORKFLOW_ROLES
        # Admin status is a principal attribute enforced by the registration
        # surface, not a distinct runtime role in AgentRole.
        roles
      end

      def identifier_component(value)
        component = value.to_s.sub(/@v\d+\z/, "").tr("/", ".").gsub(/[^a-zA-Z0-9_.-]/, "_").downcase
        component = "legacy.#{component}" unless component.match?(/\A[a-z]/)
        component
      end

      def deep_normalize(value)
        case value
        when Hash then value.to_h.sort_by { |key, _| key.to_s }.to_h { |key, item| [ key.to_s, deep_normalize(item) ] }
        when Array then value.map { |item| deep_normalize(item) }
        else value
        end
      end

      def deep_redact(value)
        case value
        when Hash
          value.to_h { |key, item| [ key, key.to_s.match?(REDACTED_KEYS) ? "[REDACTED]" : deep_redact(item) ] }
        when Array then value.map { |item| deep_redact(item) }
        else value
        end
      end
    end
  end
end
