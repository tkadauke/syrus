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
        resource_scope_resolver: ->(arguments) { normalized(arguments).slice(*scope_keys.map(&:to_s)) },
        classifier: ->(_arguments) { { operation:, effects:, risk:, confidence: :certain } },
        fingerprint_normalizer: ->(arguments) { normalized(arguments) },
        redactor: ->(arguments) { redact(arguments) },
        presentation: CapabilityPresentation.for(capability:, operation:)
      )
    end

    def normalized(value)
      case value
      when Hash then value.to_h.sort_by { |key, _| key.to_s }.to_h { |key, item| [ key.to_s, normalized(item) ] }
      when Array then value.map { |item| normalized(item) }
      else value
      end
    end

    def redact(value)
      case value
      when Hash
        value.to_h.sort_by { |key, _| key.to_s }.to_h do |key, item|
          [ key.to_s, key.to_s.match?(CapabilityDescriptorAdapter::REDACTED_KEYS) ? "[REDACTED]" : redact(item) ]
        end
      when Array then value.map { |item| redact(item) }
      else value
      end
    end
  end
end
