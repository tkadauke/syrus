# frozen_string_literal: true

module Syrus
  module Plugin
    module FamilyContractKit
      module_function

      def validate!(family:, provider:, capabilities:, contexts:, decline_contexts:)
        definition = Family.fetch(family)
        provider = provider.class unless provider.is_a?(Module)

        definition.required_core.each do |method_name|
          raise RSpec::Expectations::ExpectationNotMetError,
            "#{provider} must define required #{family} core method #{method_name}" unless provider.respond_to?(method_name)
          validate_signature!(provider, method_name, definition.core_method_contract(method_name))
        end

        Array(capabilities).map(&:to_sym).each do |capability_name|
          capability = definition.capabilities.fetch(capability_name)
          validate_signature!(provider, capability_name, capability.method_contract)
          context = fetch_context!(contexts, capability_name, capability.context, "call")
          result = invoke!(provider, capability_name, context)
          unless capability.return_contract.valid?(result)
            raise RSpec::Expectations::ExpectationNotMetError,
              "#{provider}.#{capability_name} must return #{capability.return_contract.description}; got #{result.inspect}"
          end

          decline_context = fetch_context!(decline_contexts, capability_name, capability.context, "decline")
          declined = invoke!(provider, capability_name, decline_context)
          next if declined == capability.absent

          raise RSpec::Expectations::ExpectationNotMetError,
            "#{provider}.#{capability_name} must decline with #{capability.absent.inspect}; got #{declined.inspect}"
        end
      end

      def fetch_context!(contexts, capability, expected, purpose)
        context = contexts.fetch(capability) do
          raise RSpec::Expectations::ExpectationNotMetError,
            "missing #{purpose} context for capability #{capability} (expected #{context_label(expected)})"
        end
        expected_class = resolve_context(expected)
        return context unless expected_class && !context.is_a?(expected_class)

        raise RSpec::Expectations::ExpectationNotMetError,
          "#{purpose} context for #{capability} must be a #{context_label(expected)}; got #{context.class}"
      end
      private_class_method :fetch_context!

      def invoke!(provider, capability, context)
        provider.public_send(capability, context)
      rescue ArgumentError => error
        raise RSpec::Expectations::ExpectationNotMetError,
          "#{provider}.#{capability} must be callable with the family context: #{error.message}"
      end
      private_class_method :invoke!

      def validate_signature!(provider, method_name, contract)
        parameters = provider.method(method_name).parameters
        expected = [ [ :req, nil ] ] * contract.required_positionals + [ [ :opt, nil ] ] * contract.optional_positionals +
          contract.required_keywords.map { |name| [ :keyreq, name ] } +
          contract.optional_keywords.map { |name| [ :key, name ] }
        actual = parameters.map { |kind, name| %i[keyreq key].include?(kind) ? [ kind, name ] : [ kind, nil ] }
        return if actual == expected

        raise RSpec::Expectations::ExpectationNotMetError,
          "#{provider}.#{method_name} must be callable with #{contract.required_positionals} required and " \
          "#{contract.optional_positionals} optional positional argument(s); got #{parameters.inspect}"
      rescue NameError
        raise RSpec::Expectations::ExpectationNotMetError, "#{provider} must define capability #{method_name}"
      end
      private_class_method :validate_signature!

      def resolve_context(context)
        return context if context.is_a?(Module)
        context.to_s.safe_constantize
      end
      private_class_method :resolve_context

      def context_label(context) = context.respond_to?(:name) ? context.name : context.to_s
      private_class_method :context_label
    end
  end
end
