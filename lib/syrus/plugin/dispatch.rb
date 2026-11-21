# frozen_string_literal: true

module Syrus
  module Plugin
    # Resolves, composes, and safely invokes one declared family capability.
    module Dispatch
      class MissingKey < KeyError; end
      InvocationProvider = Data.define(:provider, :invocation) do
        def key = provider.key
        def invoke
          value = provider.invoke { |implementation| invocation.call(provider, implementation) }
          yield value
        end
      end
      private_constant :InvocationProvider
      ExpectedValidation = Data.define(:error)
      private_constant :ExpectedValidation

      COMPOSITION_ARGUMENTS = Hash.new { |_modes, _mode| ->(_key) { [] } }.merge(
        keyed: ->(key) { [ key ] }
      ).freeze
      RESULT_FINALIZERS = Hash.new { |_modes, _mode| ->(result, _absent) { result } }.merge(
        first_claim: ->(result, absent) { result.nil? ? absent : result }
      ).freeze
      EMPTY_PROVIDERS = Hash.new { |_modes, _mode| ->(absent) { [ true, absent ] } }.merge(
        keyed: ->(_absent) { [ false, nil ] }
      ).freeze
      private_constant :COMPOSITION_ARGUMENTS, :RESULT_FINALIZERS, :EMPTY_PROVIDERS

      # Providers may raise this for deliberate, caller-visible input errors.
      # It passes through the invocation boundary without affecting health.
      class ValidationError < StandardError
        include Composition::CallerError

        attr_reader :code, :details

        def initialize(message, code: :invalid, details: nil)
          @code = code.to_sym
          @details = details
          super(message)
        end
      end

      module_function

      def call(family, capability, context, key: nil, timeout: nil, **args)
        definition = Family.fetch(family)
        contract = definition.capabilities.fetch(capability.to_sym) do
          raise ArgumentError, "Unknown capability #{capability.inspect} for family #{family.inspect}"
        end
        providers = Syrus::PluginRegistry.capability_providers(definition.name, contract.name)
        if providers.empty?
          handled, value = EMPTY_PROVIDERS[contract.composition].call(absent_value(contract))
          return value if handled
        end

        invocation = lambda do |provider, implementation|
          result = Syrus::PluginInvocation.call(
            extension_point: definition.name, provider: implementation,
            operation: contract.name, timeout:, on_decline: decline_value(contract),
          ) do
            value = implementation.public_send(contract.name, context, **args)
            unless contract.return_contract.valid?(value)
              next Syrus::PluginInvocation.decline(decline_value(contract))
            end
            value
          rescue ValidationError => error
            ExpectedValidation.new(error:)
          end
          value = Syrus::PluginInvocation.value(result)
          raise value.error if value.is_a?(ExpectedValidation)

          value
        end

        invoked_providers = providers.map { |provider| InvocationProvider.new(provider:, invocation:) }
        composition_args = COMPOSITION_ARGUMENTS[contract.composition].call(key)
        result = Composition.public_send(contract.composition, invoked_providers, *composition_args) { |value| value }
        RESULT_FINALIZERS[contract.composition].call(result, absent_value(contract))
      rescue Composition::MissingKey => error
        raise MissingKey, error.message
      end

      def absent_value(contract)
        contract.absent.respond_to?(:call) ? contract.absent.call : contract.absent
      end
      private_class_method :absent_value

      def decline_value(contract)
        contract.decline.respond_to?(:call) ? contract.decline.call : contract.decline
      end
      private_class_method :decline_value
    end
  end
end
