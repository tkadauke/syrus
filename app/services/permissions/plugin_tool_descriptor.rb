module Permissions
  # Small authoring helper for plugin tool sets. The caller still declares the
  # complete capability contract; this only supplies stable argument handling
  # shared by descriptors that travel through the same MCP protocol.
  module PluginToolDescriptor
    module_function

    def build(capability:, operation:, effects:, risk:, roles:, default:, maximum_autonomy:, authority_durations:,
      scope_keys: [])
      CapabilityDescriptor.new(
        capability:, operation:, effects:, risk:, requestable_roles: roles,
        defaults: roles.index_with { default }, maximum_autonomy:, authority_durations:,
        resource_scope: {
          type: :plugin_resource,
          options: {
            fields: scope_keys.map { |key| { name: key.to_s, label: key.to_s.humanize, type: "string" } }
          }
        },
        resource_scope_resolver: ->(arguments) { normalize(arguments).slice(*scope_keys.map(&:to_s)) },
        classifier: ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } },
        fingerprint_normalizer: ->(arguments) { normalize(arguments) },
        redactor: ->(arguments) { CapabilityDescriptorAdapter.send(:deep_redact, arguments) },
        presentation: CapabilityPresentation.for(capability:, operation:)
      )
    end

    def normalize(value) = CapabilityDescriptorAdapter.send(:deep_normalize, value)
  end
end
