# frozen_string_literal: true

module Syrus
  module Plugin
    # Provider-neutral service contract for external review and explainer
    # systems. Core owns the lifecycle around these calls; implementations only
    # dispatch work and normalize provider responses.
    module ExternalReviewer
      CAPABILITIES = %i[
        artifact asynchronous_completion polling webhook_delivery feedback
        verdict cancellation provider_managed_github_publication
      ].freeze
      REQUIRED_METHODS = %i[provider_key display_name capabilities available_for? submit refresh].freeze

      def self.included(base)
        base.extend(ClassMethods)
      end

      def self.extended(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        REQUIRED_METHODS.each do |method_name|
          define_method(method_name) do |*args|
            raise NotImplementedError, "#{name} must implement .#{method_name}"
          end
        end

        # Cancellation is optional and declines unless the provider declares
        # the corresponding capability and overrides this operation.
        def cancel(_context) = ExternalReviewResult.declined
      end
    end
  end
end
