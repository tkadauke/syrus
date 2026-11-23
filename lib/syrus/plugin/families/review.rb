# frozen_string_literal: true

module Syrus
  module Plugin
    definition = Family.define(:review, built_in: true) do
      shape :facet
      capability :external_reviewer,
        composition: :first_claim,
        absent: nil,
        tier: :provisional,
        context: ExternalReviewContext,
        returns: ExternalReviewer
      migrated
      ReviewContributions::CAPABILITIES.each do |capability_name|
        capability capability_name, composition: :collect, absent: [], decline: nil, tier: :provisional,
          context: Context::ReviewContributionContext, returns: ContributionProvider::OPTIONAL_PROVIDER
      end
    end

    module Families; end
    Families.const_set(:Review, definition)

    # Restores the built-in family for specs that reset the registry.
    def ReviewContributions.restore_definition! = Family.restore(Families::Review)

    policy_definition = Family.define(:policy, built_in: true) do
      shape :facet
      migrated
      Policy::CAPABILITIES.each do |capability_name|
        # A failed restriction must never silently disappear: the failure value
        # is the FAIL_CLOSED marker, so callers deny rather than widen access.
        capability capability_name, composition: :collect, absent: [], decline: nil,
          failure: -> { [ Policy::FAIL_CLOSED ] }, tier: :provisional,
          context: Context::PolicyContext, returns: ContributionProvider::OPTIONAL_PROVIDER
      end
    end
    Families.const_set(:Policy, policy_definition)
    def Policy.restore_definition! = Family.restore(Families::Policy)
  end
end
