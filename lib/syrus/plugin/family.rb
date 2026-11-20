# frozen_string_literal: true

module Syrus
  module Plugin
    class Family
      COMPOSITIONS = %i[collect broadcast first_claim keyed].freeze
      TIERS = %i[stable provisional].freeze
      MethodContract = Data.define(:required_positionals, :optional_positionals, :required_keywords, :optional_keywords) do
        def self.from(parameters)
          parameters = Array(parameters)
          unsupported = parameters.reject { |kind, name| %i[req opt keyreq key].include?(kind) && name }
          raise ArgumentError, "Unsupported method parameters: #{unsupported.inspect}" if unsupported.any?

          new(
            required_positionals: parameters.count { |kind, _| kind == :req },
            optional_positionals: parameters.count { |kind, _| kind == :opt },
            required_keywords: parameters.filter_map { |kind, name| name.to_sym if kind == :keyreq }.sort,
            optional_keywords: parameters.filter_map { |kind, name| name.to_sym if kind == :key }.sort
          )
        end
      end
      Capability = Data.define(:name, :composition, :absent, :tier, :context, :method_contract)
      CORE_METHOD_CONTRACTS = {
        key: MethodContract.from([]),
        display_name: MethodContract.from([]),
        available_for?: MethodContract.from([ [ :req, :context ] ])
      }.freeze
      class Definition
        attr_reader :name, :capabilities
        def initialize(name) = (@name, @capabilities = name.to_sym, {})
        def shape(value = nil) = value ? @shape = value.to_sym : @shape
        def capability(name, composition:, absent:, tier:, context:, parameters: [ [ :req, :context ] ])
          name = name.to_sym
          raise ArgumentError, "Capability context contract is required" if context.nil?
          raise ArgumentError, "Duplicate capability #{name.inspect} in family #{@name.inspect}" if capabilities.key?(name)
          raise ArgumentError, "Unknown composition #{composition.inspect}" unless COMPOSITIONS.include?(composition.to_sym)
          raise ArgumentError, "Unknown capability tier #{tier.inspect}" unless TIERS.include?(tier.to_sym)
          capabilities[name] = Capability.new(
            name:, composition: composition.to_sym, absent:, tier: tier.to_sym, context:,
            method_contract: MethodContract.from(parameters)
          )
        end
        def required_core = shape == :service ? %i[key display_name available_for?] : %i[key display_name]
        def method_contract(method_name) = capabilities.fetch(method_name).method_contract
        def core_method_contract(method_name) = CORE_METHOD_CONTRACTS.fetch(method_name)
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
