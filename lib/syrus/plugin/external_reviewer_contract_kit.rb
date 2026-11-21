# frozen_string_literal: true

module Syrus
  module Plugin
    # Executable contract used by external-review provider authors. Calls are
    # deliberately made through PluginInvocation so the proof covers the same
    # isolation, health, timeout, and circuit behavior as runtime integrations.
    module ExternalReviewerContractKit
      REQUIRED_SIGNATURES = {
        provider_key: [], display_name: [], capabilities: [],
        available_for?: [ [ :req, nil ] ], submit: [ [ :req, nil ] ],
        refresh: [ [ :req, nil ] ], cancel: [ [ :req, nil ] ]
      }.freeze

      module_function

      def validate!(provider:, context:, refresh_context:, timeout: nil)
        provider = provider.class unless provider.is_a?(Module)
        validate_methods!(provider)
        capabilities = Array(provider.capabilities).map(&:to_sym)
        unknown = capabilities - ExternalReviewer::CAPABILITIES
        expectation!(unknown.empty?, "#{provider} declares unknown capabilities: #{unknown.join(', ')}")
        expectation!(capabilities.uniq == capabilities, "#{provider} declares duplicate capabilities")
        cancellation_implemented = provider.method(:cancel).owner != ExternalReviewer::ClassMethods
        expectation!(capabilities.include?(:cancellation) == cancellation_implemented,
          "#{provider} must declare cancellation exactly when it implements .cancel")

        expectation!(provider.available_for?(context) == true,
          "#{provider}.available_for? must accept the supplied public context")
        submit = invoke(provider, :submit, context, timeout:)
        refresh = invoke(provider, :refresh, refresh_context, timeout:)
        cancel = invoke(provider, :cancel, refresh_context, timeout:)
        [ submit, refresh, cancel ].each do |result|
          expectation!(result.is_a?(ExternalReviewResult),
            "#{provider} operations must return ExternalReviewResult; got #{result.inspect}")
        end
        validate_result_capabilities!(provider, submit, capabilities)
        validate_result_capabilities!(provider, refresh, capabilities)
        expectation!(refresh.outcome == :declined || capabilities.include?(:polling),
          "#{provider}.refresh must decline unless polling is declared")
        expectation!(cancel.outcome == (capabilities.include?(:cancellation) ? :completed : :declined),
          "#{provider}.cancel must complete when supported and decline when unsupported")
        { submit:, refresh:, cancel: }
      end

      def invoke(provider, operation, context, timeout: nil, failure_threshold: 5)
        result = Syrus::PluginInvocation.call(
          extension_point: :review, provider:, operation:, timeout:,
          failure_threshold:, on_decline: ExternalReviewResult.declined
        ) { provider.public_send(operation, context) }
        Syrus::PluginInvocation.value(result)
      end

      def validate_methods!(provider)
        REQUIRED_SIGNATURES.each do |name, expected|
          parameters = provider.method(name).parameters.map do |kind, argument|
            %i[key keyreq].include?(kind) ? [ kind, argument ] : [ kind, nil ]
          end
          expectation!(parameters == expected,
            "#{provider}.#{name} must have signature #{expected.inspect}; got #{parameters.inspect}")
        rescue NameError
          expectation!(false, "#{provider} must implement .#{name}")
        end
      end
      private_class_method :validate_methods!

      def validate_result_capabilities!(provider, result, capabilities)
        required = []
        required << :asynchronous_completion if result.outcome == :accepted
        required << :artifact if result.artifacts.any?
        required << :feedback unless result.feedback.nil?
        required << :verdict unless result.verdict.nil?
        required << :provider_managed_github_publication if result.publication == :provider
        missing = required - capabilities
        expectation!(missing.empty?,
          "#{provider} returned behavior without declaring capabilities: #{missing.join(', ')}")
      end
      private_class_method :validate_result_capabilities!

      def expectation!(condition, message)
        return if condition

        raise RSpec::Expectations::ExpectationNotMetError, message
      end
      private_class_method :expectation!
    end
  end
end
