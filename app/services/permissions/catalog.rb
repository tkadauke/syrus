module Permissions
  class Catalog
    class UnknownCapability < ArgumentError; end

    def self.descriptors
      existing = (McpToolRegistry.entries.map(&:descriptor) + plugin_tool_descriptors)
        .uniq { |descriptor| [ descriptor.capability, descriptor.operation ] }
      (existing + permission_provider_descriptors)
        .group_by { |descriptor| [ descriptor.capability, descriptor.operation ] }
        .map do |(capability, operation), registrations|
          contracts = registrations.map(&:contract_key).uniq
          if contracts.many?
            raise ArgumentError,
              "permission operation #{operation.inspect} for capability #{capability.inspect} has conflicting contracts"
          end
          registrations.first
        end
    end

    def self.resource_scopes
      Syrus::PluginRegistry.providers_for(:permission_provider).each_with_object({}) do |provider, schemas|
        provider.permission_resource_scopes.each do |type, schema|
          existing = schemas[type]
          if existing && !existing.equal?(schema)
            raise ArgumentError, "permission resource scope #{type.inspect} is registered by more than one provider"
          end
          schemas[type] = schema
        end
      end.freeze
    end

    def self.presets
      Syrus::PluginRegistry.providers_for(:permission_provider).each_with_object({}) do |provider, presets|
        provider.permission_presets.each do |name, preset|
          raise ArgumentError, "permission preset #{name.inspect} is registered by more than one provider" if presets.key?(name)

          presets[name] = preset
        end
      end.freeze
    end

    def self.find!(capability:, operation: nil)
      matches = descriptors.select { |descriptor| descriptor.capability == capability.to_s }
      matches.select! { |descriptor| descriptor.operation == operation.to_s } if operation.present?
      raise UnknownCapability, "unknown permission capability or operation" unless matches.one?

      matches.first
    end

    def self.as_json(descriptor)
      descriptor.to_h.except(:classifier, :fingerprint_normalizer, :redactor).merge(
        resource_scope: descriptor.resource_scope.to_h
      )
    end

    def self.permission_provider_descriptors
      Syrus::PluginRegistry.providers_for(:permission_provider)
        .flat_map(&:permission_capability_descriptors)
    end
    private_class_method :permission_provider_descriptors

    def self.plugin_tool_descriptors
      %i[mcp_tool_set chat_mcp_tool_set].flat_map do |extension_point|
        Syrus::PluginRegistry.providers_for(extension_point).flat_map do |provider|
          Syrus::PluginRegistry.all_tool_definitions(provider).filter_map do |definition|
            definition = definition.symbolize_keys
            next unless definition[:capability_descriptor]

            CapabilityDescriptorAdapter.for_plugin_definition(definition)
          end
        end
      end
    end
    private_class_method :plugin_tool_descriptors
  end
end
