# frozen_string_literal: true

module Syrus
  module Plugin
    # Answers legacy lookups from family declarations during incremental migration.
    module LegacyBridge
      DuplicateRegistration = Data.define(:plugin, :family, :extension_point, :capability)

      class Provider
        def initialize(reference, adapter)
          @reference = reference
          @adapter = adapter
        end

        def method_missing(name, ...)
          return super unless @adapter.respond_to?(name)
          @reference.invoke { |implementation| @adapter.public_send(name, implementation, ...) }
        end

        def respond_to_missing?(name, include_private = false)
          @adapter.respond_to?(name, include_private) || super
        end
      end

      module_function

      def mapping_for(extension_point) = Family.legacy_mapping(extension_point)

      def providers_for_manifest(manifest, extension_point, conformance: nil)
        definition, mapping = mapping_for(extension_point)
        return [] unless mapping
        return [] if conformance && !conformance.conforming?(plugin: manifest.name, family: definition.name)

        manifest.family_provides.filter_map do |declaration|
          next unless declaration.family == definition.name && declaration.capabilities.include?(mapping.capability)
          reference = CapabilityProvider.new(plugin_name: manifest.name, family: definition.name,
            capability: mapping.capability, provider_name: declaration.provider,
            key: declaration.key, priority: manifest.prepare_priority)
          Provider.new(reference, mapping.adapter)
        end
      end

      def duplicates_for(manifests)
        manifests.flat_map do |manifest|
          Family.all.flat_map do |definition|
            definition.legacy_mappings.values.filter_map do |mapping|
              next if Array(manifest.provides[mapping.extension_point]).empty?
              next unless manifest.family_provides.any? { |declaration|
                declaration.family == definition.name && declaration.capabilities.include?(mapping.capability)
              }
              DuplicateRegistration.new(plugin: manifest.name, family: definition.name,
                extension_point: mapping.extension_point, capability: mapping.capability)
            end
          end
        end
      end
    end
  end
end
