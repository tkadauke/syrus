# frozen_string_literal: true

module Syrus
  module Plugin
    module Families; end

    data_policy_definition = Family.define(:data_policy, built_in: true) do
      shape :facet
      absorbs(*DataPolicy::CAPABILITY_FOR_LEGACY.keys)
      # Retention and purge must account for every contributor: a failure is
      # reported through the UNAVAILABLE marker instead of dropping out.
      %i[retention_policies purge_contributors].each do |capability_name|
        capability capability_name, composition: :collect, absent: [], decline: nil,
          failure: -> { [ DataPolicy::UNAVAILABLE ] }, tier: :provisional,
          context: Context::HookContext, returns: ContributionProvider::OPTIONAL_PROVIDER
      end
      capability :preview_panel_retentions, composition: :collect, absent: [], decline: nil, tier: :provisional,
        context: Context::HookContext, returns: ContributionProvider::OPTIONAL_PROVIDER
      DataPolicy::CAPABILITY_FOR_LEGACY.each do |legacy_point, capability_name|
        legacy legacy_point, capability: capability_name,
          adapter: ContributionProvider::LegacyAdapter.new(capability_name, Context::HookContext)
      end
    end
    Families.const_set(:DataPolicy, data_policy_definition)
    def DataPolicy.restore_definition! = Family.restore(Families::DataPolicy)
  end
end
