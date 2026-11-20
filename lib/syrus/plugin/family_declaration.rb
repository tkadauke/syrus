# frozen_string_literal: true

module Syrus
  module Plugin
    FamilyDeclaration = Data.define(:family, :provider, :implements, :provisional) do
      def capabilities = implements + provisional
      def self.build(family:, provider:, implements: [], provisional: [])
        definition = Family.fetch(family)
        stable, experimental = Array(implements).map(&:to_sym), Array(provisional).map(&:to_sym)
        duplicates = (stable & experimental) + stable.tally.select { |_k, n| n > 1 }.keys + experimental.tally.select { |_k, n| n > 1 }.keys
        raise ArgumentError, "Duplicate capabilities: #{duplicates.uniq.join(', ')}" if duplicates.any?
        (stable + experimental).each do |capability|
          declared = definition.capabilities.fetch(capability) { raise ArgumentError, "Unknown capability #{capability.inspect} for family #{family.inspect}" }
          expected = experimental.include?(capability) ? :provisional : :stable
          raise ArgumentError, "Capability #{capability.inspect} is #{declared.tier}, not #{expected}" unless declared.tier == expected
        end
        new(family: definition.name, provider: provider.to_s, implements: stable.freeze, provisional: experimental.freeze)
      end
    end
  end
end
