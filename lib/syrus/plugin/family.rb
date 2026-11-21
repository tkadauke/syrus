# frozen_string_literal: true

module Syrus
  module Plugin
    class Family
      COMPOSITIONS = %i[collect broadcast first_claim keyed].freeze
      TIERS = %i[stable provisional].freeze
      MethodContract = Data.define(:required_positionals, :optional_positionals, :required_keywords, :optional_keywords) do
        def self.no_arguments = new(required_positionals: 0, optional_positionals: 0, required_keywords: [], optional_keywords: [])
        def self.context(context)
          raise ArgumentError, "Capability context contract is required" if context.nil?

          new(required_positionals: 1, optional_positionals: 0, required_keywords: [], optional_keywords: [])
        end
      end
      ReturnContract = Data.define(:description, :matcher, :explicit) do
        def valid?(value) = matcher.call(value)

        def self.build(value)
          case value
          when nil
            new(description: "any value", matcher: ->(_result) { true }, explicit: false)
          when Class, Module
            new(description: value.name || value.inspect, matcher: ->(result) { result.is_a?(value) }, explicit: true)
          when Array
            types = value.freeze
            new(description: types.map { |type| type.name || type.inspect }.join(" or "),
              matcher: ->(result) { types.any? { |type| result.is_a?(type) } }, explicit: true)
          else
            raise ArgumentError, "Return contract must be a class, module, or array of classes/modules"
          end
        end
      end
      Capability = Data.define(:name, :composition, :absent, :tier, :context, :method_contract, :return_contract)
      LegacyMapping = Data.define(:extension_point, :capability, :adapter)
      CORE_METHOD_CONTRACTS = {
        key: MethodContract.no_arguments,
        display_name: MethodContract.no_arguments,
        available_for?: MethodContract.context(Object)
      }.freeze
      class Definition
        attr_reader :name, :capabilities, :legacy_mappings
        def initialize(name)
          @name, @capabilities, @legacy_mappings = name.to_sym, {}, {}
          @indicates_language_support = false
          @migrated = false
          @absorbed_legacy_points = []
        end
        def shape(value = nil) = value ? @shape = value.to_sym : @shape
        def indicates_language_support(value = true) = @indicates_language_support = value
        def indicates_language_support? = @indicates_language_support
        def migrated(value = true) = @migrated = value
        def migrated? = @migrated
        def absorbs(*extension_points) = @absorbed_legacy_points.concat(extension_points.flatten.map(&:to_sym)).uniq!
        def unmapped_legacy_points = @absorbed_legacy_points - legacy_mappings.keys
        def capability(name, composition:, absent:, tier:, context:, returns: nil)
          name = name.to_sym
          raise ArgumentError, "Duplicate capability #{name.inspect} in family #{@name.inspect}" if capabilities.key?(name)
          raise ArgumentError, "Unknown composition #{composition.inspect}" unless COMPOSITIONS.include?(composition.to_sym)
          raise ArgumentError, "Unknown capability tier #{tier.inspect}" unless TIERS.include?(tier.to_sym)
          capabilities[name] = Capability.new(
            name:, composition: composition.to_sym, absent:, tier: tier.to_sym, context:,
            method_contract: MethodContract.context(context), return_contract: ReturnContract.build(returns)
          )
        end
        def required_core = shape == :service ? %i[key display_name available_for?] : %i[key display_name]
        def method_contract(method_name) = capabilities.fetch(method_name).method_contract
        def core_method_contract(method_name) = CORE_METHOD_CONTRACTS.fetch(method_name)
        def legacy(extension_point, capability:, adapter:)
          extension_point, capability = extension_point.to_sym, capability.to_sym
          raise ArgumentError, "Duplicate legacy mapping #{extension_point.inspect} in family #{@name.inspect}" if legacy_mappings.key?(extension_point)
          raise ArgumentError, "Unknown capability #{capability.inspect} for family #{@name.inspect}" unless capabilities.key?(capability)
          legacy_mappings[extension_point] = LegacyMapping.new(extension_point:, capability:, adapter:)
        end
      end
      @definitions = {}
      class << self
        def define(name, &block)
          definition = Definition.new(name).tap { |entry| entry.instance_eval(&block) }
          raise ArgumentError, "Family #{name.inspect} must declare a shape" unless definition.shape
          raise ArgumentError, "Family #{name.inspect} must declare at least one capability" if definition.capabilities.empty?
          if definition.unmapped_legacy_points.any?
            raise ArgumentError, "Family #{name.inspect} is missing legacy mappings for #{definition.unmapped_legacy_points.join(', ')}"
          end
          raise ArgumentError, "Family #{name.inspect} is already defined" if @definitions.key?(definition.name)
          @definitions[definition.name] = definition
        end
        def fetch(name) = @definitions.fetch(name.to_sym) { raise ArgumentError, "Unknown plugin family #{name.inspect}" }
        def all = @definitions.values.freeze
        def legacy_mapping(extension_point)
          matches = all.filter_map { |definition| [ definition, definition.legacy_mappings[extension_point.to_sym] ] if definition.legacy_mappings.key?(extension_point.to_sym) }
          raise ArgumentError, "Legacy extension point #{extension_point.inspect} is claimed by multiple families" if matches.many?
          matches.first
        end
        def reset! = @definitions.clear
      end
    end
  end
end
