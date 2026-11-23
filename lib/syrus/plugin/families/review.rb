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
      absorbs(*ReviewContributions::CAPABILITY_FOR_LEGACY.keys)
      ReviewContributions::CAPABILITY_FOR_LEGACY.each_value do |capability_name|
        capability capability_name, composition: :collect, absent: [], decline: nil, tier: :provisional,
          context: Context::ReviewContributionContext, returns: ContributionProvider::OPTIONAL_PROVIDER
      end
      ReviewContributions::CAPABILITY_FOR_LEGACY.each do |legacy_point, capability_name|
        legacy legacy_point, capability: capability_name,
          adapter: ContributionProvider::LegacyAdapter.new(capability_name, Context::ReviewContributionContext)
      end
    end

    module Families; end
    Families.const_set(:Review, definition)

    # Restores the built-in family for specs that reset the registry.
    def ReviewContributions.restore_definition! = Family.restore(Families::Review)

    policy_definition = Family.define(:policy, built_in: true) do
      shape :facet
      absorbs(*Policy::CAPABILITY_FOR_LEGACY.keys)
      Policy::CAPABILITY_FOR_LEGACY.each_value do |capability_name|
        # A failed restriction must never silently disappear: the failure value
        # is the FAIL_CLOSED marker, so callers deny rather than widen access.
        capability capability_name, composition: :collect, absent: [], decline: nil,
          failure: -> { [ Policy::FAIL_CLOSED ] }, tier: :provisional,
          context: Context::PolicyContext, returns: ContributionProvider::OPTIONAL_PROVIDER
      end
      Policy::CAPABILITY_FOR_LEGACY.each do |legacy_point, capability_name|
        legacy legacy_point, capability: capability_name,
          adapter: ContributionProvider::LegacyAdapter.new(capability_name, Context::PolicyContext)
      end
    end
    Families.const_set(:Policy, policy_definition)
    def Policy.restore_definition! = Family.restore(Families::Policy)
  end
end
