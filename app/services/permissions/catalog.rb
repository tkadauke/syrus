module Permissions
  class Catalog
    class UnknownCapability < ArgumentError; end

    def self.descriptors
      (McpToolRegistry.entries.map(&:descriptor) + plugin_descriptors)
        .uniq { |descriptor| [ descriptor.capability, descriptor.operation ] }
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

    def self.plugin_descriptors
      registered = Syrus::PluginRegistry.providers_for(:permission_provider)
        .flat_map(&:permission_capability_descriptors)
      tool_definitions = %i[mcp_tool_set chat_mcp_tool_set].flat_map do |extension_point|
        Syrus::PluginRegistry.providers_for(extension_point).flat_map do |provider|
          Syrus::PluginRegistry.all_tool_definitions(provider).filter_map do |definition|
            definition = definition.symbolize_keys
            next unless definition[:capability_descriptor]

            CapabilityDescriptorAdapter.for_plugin_definition(definition)
          end
        end
      end
      registered + tool_definitions
    end
    private_class_method :plugin_descriptors
  end
end
