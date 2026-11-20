# frozen_string_literal: true

module Syrus
  module Plugin
    class Family
      COMPOSITIONS = %i[collect broadcast first_claim keyed].freeze
      TIERS = %i[stable provisional].freeze
      Capability = Data.define(:name, :composition, :absent, :tier, :context)
      class Definition
        attr_reader :name, :capabilities
        def initialize(name) = (@name, @capabilities = name.to_sym, {})
        def shape(value = nil) = value ? @shape = value.to_sym : @shape
        def capability(name, composition:, absent:, tier:, context:)
          name = name.to_sym
          raise ArgumentError, "Duplicate capability #{name.inspect} in family #{@name.inspect}" if capabilities.key?(name)
          raise ArgumentError, "Unknown composition #{composition.inspect}" unless COMPOSITIONS.include?(composition.to_sym)
          raise ArgumentError, "Unknown capability tier #{tier.inspect}" unless TIERS.include?(tier.to_sym)
          capabilities[name] = Capability.new(name:, composition: composition.to_sym, absent:, tier: tier.to_sym, context:)
        end
        def required_core = shape == :service ? %i[key display_name available_for?] : %i[key display_name]
      end
      @definitions = {}
      class << self
        def define(name, &block)
          definition = Definition.new(name).tap { |entry| entry.instance_eval(&block) }
          raise ArgumentError, "Family #{name.inspect} must declare a shape" unless definition.shape
          raise ArgumentError, "Family #{name.inspect} must declare at least one capability" if definition.capabilities.empty?
          raise ArgumentError, "Family #{name.inspect} is already defined" if @definitions.key?(definition.name)
          @definitions[definition.name] = definition
        end
        def fetch(name) = @definitions.fetch(name.to_sym) { raise ArgumentError, "Unknown plugin family #{name.inspect}" }
        def all = @definitions.values.freeze
        def reset! = @definitions.clear
      end
    end
  end
end
