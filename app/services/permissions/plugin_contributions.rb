module Permissions
  # Registry-backed inventory for the Permission Hub. "Installed" means the
  # plugin is enabled on this instance; registered disabled plugins remain
  # visible as available choices without core knowing any plugin names.
  class PluginContributions
    TOOL_EXTENSION_POINTS = %i[ mcp_tool_set chat_mcp_tool_set ].freeze

    def self.as_json
      Syrus::PluginRegistry.all_plugins.map do |manifest|
        contributions = contributions_for(manifest)
        next if contributions[:capabilities].empty? && contributions[:tools].empty?

        {
          name: manifest.name,
          display_name: manifest.display_name.presence || manifest.name.to_s.titleize,
          installed: manifest.enabled?,
          **contributions
        }
      end.compact.sort_by { |plugin| plugin[:display_name].downcase }
    end

    def self.contributions_for(manifest)
      descriptors = permission_descriptors(manifest)
      definitions = tool_definitions(manifest)
      descriptors.concat(definitions.filter_map { |definition| descriptor_for(definition) })

      {
        capabilities: descriptors.uniq { |descriptor| descriptor.capability }.map do |descriptor|
          { identifier: descriptor.capability, name: descriptor.presentation.capability_name }
        end.sort_by { |capability| capability[:name].downcase },
        tools: definitions.filter_map { |definition| value(definition, :name)&.to_s.presence }.uniq.sort
      }
    end
    private_class_method :contributions_for

    def self.permission_descriptors(manifest)
      providers(manifest, :permission_provider).flat_map do |provider|
        provider.respond_to?(:permission_capability_descriptors) ? provider.permission_capability_descriptors : []
      rescue StandardError => error
        log_inventory_error(manifest, :permission_provider, error)
        []
      end
    end
    private_class_method :permission_descriptors

    def self.tool_definitions(manifest)
      TOOL_EXTENSION_POINTS.flat_map do |extension_point|
        providers(manifest, extension_point).flat_map do |provider|
          Syrus::PluginRegistry.all_tool_definitions(provider)
        rescue StandardError => error
          log_inventory_error(manifest, extension_point, error)
          []
        end
      end
    end
    private_class_method :tool_definitions

    def self.providers(manifest, extension_point)
      Array(manifest.provides[extension_point] || manifest.provides[extension_point.to_s])
    end
    private_class_method :providers

    def self.descriptor_for(definition)
      definition = definition.to_h.symbolize_keys
      return unless definition[:capability_descriptor] || definition[:capability]

      CapabilityDescriptorAdapter.for_plugin_definition(definition)
    rescue KeyError, ArgumentError => error
      Rails.logger.warn("[Permissions::PluginContributions] tool descriptor unavailable: #{error.class}: #{error.message}")
      nil
    end
    private_class_method :descriptor_for

    def self.value(definition, key)
      definition[key] || definition[key.to_s]
    end
    private_class_method :value

    def self.log_inventory_error(manifest, extension_point, error)
      Rails.logger.warn(
        "[Permissions::PluginContributions] #{manifest.name} #{extension_point} inventory unavailable: #{error.class}: #{error.message}"
      )
    end
    private_class_method :log_inventory_error
  end
end
