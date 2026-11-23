# frozen_string_literal: true

module Syrus
  module Plugin
    module Families; end

    lifecycle_definition = Family.define(:lifecycle, built_in: true) do
      shape :facet
      absorbs(*Lifecycle::CAPABILITY_FOR_LEGACY.keys)
      Lifecycle::CAPABILITY_FOR_LEGACY.each_value do |capability_name|
        capability capability_name, composition: :collect, absent: [], decline: nil, tier: :provisional,
          context: Context::HookContext, returns: ContributionProvider::OPTIONAL_PROVIDER
      end
      Lifecycle::CAPABILITY_FOR_LEGACY.each do |legacy_point, capability_name|
        legacy legacy_point, capability: capability_name,
          adapter: ContributionProvider::LegacyAdapter.new(capability_name, Context::HookContext)
      end
    end
    Families.const_set(:Lifecycle, lifecycle_definition)
    def Lifecycle.restore_definition! = Family.restore(Families::Lifecycle)
  end
end
