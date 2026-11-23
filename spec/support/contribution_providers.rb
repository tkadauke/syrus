# Registers Review and Policy contributions through their capability families,
# the only way a plugin can contribute them now that the legacy extension points
# are gone. +contributes+ is keyed by the contribution kind it names.
module ContributionProviderHelpers
  CONTRIBUTIONS = {
    review_gate: [ :review, :review_gates ],
    reviewer_target_provider: [ :review, :reviewer_target_providers ],
    review_context_contributor: [ :review, :review_context_contributors ],
    review_presentation_contributor: [ :review, :review_presentation_contributors ],
    post_implementation_review_provider: [ :review, :post_implementation_review_providers ],
    diff_review_annotation_provider: [ :review, :diff_review_annotation_providers ],
    adjudicator: [ :review, :adjudicators ],
    job_visibility_restriction: [ :policy, :job_visibility_restrictions ],
    repository_filter: [ :policy, :repository_filters ]
  }.freeze

  def register_contributions(name:, contributes:, version: "1.0.0", **manifest)
    manifest = { default_enabled: true, disableable: true, experimental: false, requires_syrus: nil }.merge(manifest)
    declarations = contributes.group_by { |kind, _| CONTRIBUTIONS.fetch(kind).first }.map do |family, entries|
      capabilities = entries.to_h { |kind, modules| [ CONTRIBUTIONS.fetch(kind).last, modules ] }
      provider = Syrus::Plugin::ContributionProvider.build(key: name.to_s, display_name: name.to_s, **capabilities)
      constant = "ContributionFixture#{name.to_s.gsub(/\W/, '_').camelize}#{family.to_s.camelize}#{provider.object_id}"
      stub_const(constant, provider)
      Syrus::Plugin::FamilyDeclaration.build(family:, provider: constant, provisional: capabilities.keys)
    end
    Syrus::PluginRegistry.register(name: name.to_s, version:, family_provides: declarations, **manifest)
  end
end

RSpec.configure { |config| config.include ContributionProviderHelpers }
