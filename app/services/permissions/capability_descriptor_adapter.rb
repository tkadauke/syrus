module Permissions
  class CapabilityDescriptorAdapter
    # Exposed through Syrus::Host::CapabilityDescriptor so plugins need not name
    # the core descriptor class to declare how long an approval may last.
    AUTHORITY_DURATIONS = CapabilityDescriptor::AUTHORITY_DURATIONS

    REDACTED_KEYS = /(?:token|secret|password|credential|authorization|api[_-]?key)/i

    class << self
      def for_coworker_parity(descriptor, default_policy: nil)
        descriptor = coerce(descriptor)
        roles = descriptor.requestable_roles | [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ]
        ordinary_default = default_policy || descriptor.defaults.fetch(AgentRole::CHAT_PLANNER, :ask)
        ordinary_default = :ask if ordinary_default == :allow &&
          !CoworkerDefaultPolicy.descriptor_auto_allowable?(descriptor)
        defaults = descriptor.defaults.merge(
          AgentRole::COWORKER_CHAT => ordinary_default,
          AgentRole::COWORKER => ordinary_default
        )
        # A coworker has its own rules but the same essentials, so the
        # projection keeps the descriptor's consequence classification.
        CapabilityDescriptor.new(**descriptor.to_h.merge(
          presentation: descriptor.presentation,
          requestable_roles: roles,
          defaults: defaults
        ))
      end

      def for_registry_entry(tool_name:, capability:, mutation:, required_roles: [], admin_only: false, descriptor: nil,
        default_policy: nil)
        return coerce(descriptor) if descriptor

        roles = Array(required_roles).presence || default_roles(admin_only: admin_only)
        build_legacy(
          tool_name: tool_name,
          capability: capability,
          mutation: mutation,
          roles: roles,
          policy: default_policy&.to_sym
        )
      end

      def for_plugin_definition(definition)
        definition = definition.symbolize_keys
        return coerce(definition[:capability_descriptor]) if definition[:capability_descriptor]

        roles = Array(definition[:requestable_roles])
        roles |= [ AgentRole::COWORKER_CHAT, AgentRole::COWORKER ] if definition[:coworker_safe]

        build_legacy(
          tool_name: definition.fetch(:name),
          capability: definition[:capability],
          mutation: definition.fetch(:mutation, false),
          roles: roles.presence || default_roles,
          policy: coworker_default_policy(definition[:coworker_default_policy]),
          essential: definition[:essential] == true
        )
      end

      # Public so plugin descriptors redact and fingerprint arguments exactly
      # as registry-derived descriptors do.
      def redact_arguments(value) = deep_redact(value)
      def normalize_arguments(value) = deep_normalize(value)

      private

      def coerce(descriptor)
        descriptor.is_a?(CapabilityDescriptor) ? descriptor : CapabilityDescriptor.new(**descriptor.symbolize_keys)
      end

      def build_legacy(tool_name:, capability:, mutation:, roles:, policy: nil, essential: false)
        family = identifier_component(capability.presence || tool_name)
        operation = identifier_component(tool_name)
        policy ||= mutation ? :ask : :allow
        effects = mutation ? [ :internal_write ] : [ :local_read ]

        CapabilityDescriptor.new(
          capability: "#{family}@v1",
          operation: "#{family}/#{operation}@v1",
          presentation: CapabilityPresentation.for(
            capability: "#{family}@v1", operation: "#{family}/#{operation}@v1"
          ),
          effects: effects,
          risk: mutation ? :medium : :low,
          requestable_roles: roles,
          defaults: roles.index_with { policy },
          maximum_autonomy: mutation ? :invocation : :permanent,
          authority_durations: mutation ? [ :invocation ] : CapabilityDescriptor::AUTHORITY_DURATIONS,
          resource_scope: { type: :none },
          essential: essential,
          classifier: ->(_arguments) { { operation: "#{family}/#{operation}@v1", effects: effects, confidence: :legacy } },
          fingerprint_normalizer: ->(arguments) { deep_normalize(arguments) },
          redactor: ->(arguments) { deep_redact(arguments) }
        )
      end

      def coworker_default_policy(value)
        return if value.blank?

        { "auto" => :allow, "confirm" => :ask, "queue" => :ask }.fetch(value.to_s)
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
