# frozen_string_literal: true

module Syrus
  module Plugin
    # Review-family contributions: gates, reviewer targets, review context and
    # presentation, post-implementation review, diff annotations, and
    # adjudicators. Each capability returns the established behavior module(s);
    # per-operation invocation, decline values, and gate semantics stay with the
    # core callers, which still wrap every operation in PluginInvocation.
    #
    # Review gates are evidence about one exact implementation HEAD and fail
    # closed. This module only changes where the provider list comes from; a
    # provider whose selector fails contributes nothing, exactly as a provider
    # whose `review_gates` operation fails did before.
    module ReviewContributions
      CAPABILITIES = %i[
        review_gates reviewer_target_providers review_context_contributors
        review_presentation_contributors post_implementation_review_providers
        diff_review_annotation_providers adjudicators
      ].freeze

      def self.provider(key:, display_name:, **contributions) =
        ContributionProvider.build(key:, display_name:, **contributions)

      def self.contributions(capability)
        Dispatch.call(:review, capability, Context::ReviewContributionContext.new).flatten.compact
      end
    end
  end
end
