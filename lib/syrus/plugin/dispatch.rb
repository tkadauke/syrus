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
      ProviderResult = Data.define(:value, :provider_name)
      class ProviderFailure < StandardError
        attr_reader :exception_class, :reason

        def initialize(failure)
          @exception_class = failure.exception_class
          @reason = failure.reason
          super([ failure.exception_class, failure.message ].compact.join(": ").presence || failure.reason.to_s)
        end
      end
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

      def call(family, capability, context, key: nil, timeout: nil, with_provider: false, **args)
        definition = Family.fetch(family)
        contract = definition.capabilities.fetch(capability.to_sym) do
          raise ArgumentError, "Unknown capability #{capability.inspect} for family #{family.inspect}"
        end
        providers = Syrus::PluginRegistry.capability_providers(definition.name, contract.name)
        if providers.empty?
          handled, value = EMPTY_PROVIDERS[contract.composition].call(absent_value(contract))
          return value if handled
        end

        invoke_result = lambda do |provider, implementation|
          result = Syrus::PluginInvocation.call(
            extension_point: definition.name, provider: implementation,
            operation: contract.name, timeout:, on_decline: failure_value(contract),
          ) do
            value = implementation.public_send(contract.name, context, **args)
            unless contract.return_contract.valid?(value)
              next Syrus::PluginInvocation.decline(failure_value(contract))
            end
            value
          rescue ValidationError => error
            ExpectedValidation.new(error:)
          end
          value = Syrus::PluginInvocation.value(result)
          raise value.error if value.is_a?(ExpectedValidation)

          [ value, result ]
        end
        invocation = ->(provider, implementation) { invoke_result.call(provider, implementation).first }

        invoked_providers = providers.map { |provider| InvocationProvider.new(provider:, invocation:) }
        if with_provider
          raise ArgumentError, "with_provider is only supported for keyed capabilities" unless contract.composition == :keyed
          selected = invoked_providers.find { |provider| provider.key.to_s == key.to_s }
          raise MissingKey, "No capability provider for key #{key.inspect}" unless selected
          value, result = selected.provider.invoke do |implementation|
            invoke_result.call(selected.provider, implementation)
          end
          raise ProviderFailure, result if result.is_a?(Syrus::PluginInvocation::Failed)

          return ProviderResult.new(value:, provider_name: selected.provider.provider_name)
        end
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

      # The value substituted for a provider that failed. Fail-closed families
      # set it apart from the provider decline value so an unavailable provider
      # can never read as "nothing to contribute".
      def failure_value(contract)
        contract.failure.respond_to?(:call) ? contract.failure.call : contract.failure
      end
      private_class_method :failure_value
    end
  end
end
