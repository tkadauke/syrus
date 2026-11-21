# frozen_string_literal: true

require "set"

module Syrus
  module Plugin
    class FamilyPromotion
      Violation = Data.define(:family, :capability, :implementations, :contract_tested) do
        def message
          reasons = []
          reasons << "has #{implementations} independent in-tree implementation(s), needs at least 2" if implementations < 2
          reasons << "has no generated contract test" unless contract_tested
          "#{family}.#{capability} is stable but #{reasons.join(' and ')}"
        end
      end

      def initialize(definitions: Family.all, manifests: PluginRegistry.all_plugins, contracted_capabilities: nil)
        @definitions = definitions
        @manifests = manifests
        @contracted_capabilities = contracted_capabilities || definitions.flat_map do |family|
          family.capabilities.values.filter_map do |capability|
            [ family.name, capability.name ] if capability.return_contract.explicit
          end
        end.to_set
      end

      def violations
        @definitions.flat_map do |family|
          family.capabilities.values.filter_map do |capability|
            next unless capability.tier == :stable
            implementations = implementation_count(family, capability.name)
            contract_tested = @contracted_capabilities.include?([ family.name, capability.name ])
            next if implementations >= 2 && contract_tested
            Violation.new(family: family.name, capability: capability.name, implementations:, contract_tested:)
          end
        end
      end

      private

      def implementation_count(family, capability)
        legacy_points = family.legacy_mappings.values.filter_map do |mapping|
          mapping.extension_point if mapping.capability == capability
        end
        @manifests.count do |manifest|
          Array(manifest.family_provides).any? do |declaration|
            declaration.family == family.name && declaration.capabilities.include?(capability)
          end || legacy_points.any? { |point| Array(manifest.provides[point]).any? }
        end
      end
    end
  end
end
