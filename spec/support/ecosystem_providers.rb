module EcosystemProviderHelpers
  def register_prompt_context_provider(callable)
    provider = Class.new do
      define_singleton_method(:prompt_context) do |context|
        callable.call(repository: context.repository, job: context.job)
      end
    end
    register_ecosystem_provider(name: "prompt-context-#{provider.object_id}", provider:,
      implements: %i[prompt_context])
  end

  def register_ecosystem_provider(name:, provider:, implements: [], provisional: [], key: nil, **manifest)
    provider.define_singleton_method(:key) { key || name.to_s.parameterize.underscore.to_sym } unless provider.respond_to?(:key)
    provider.define_singleton_method(:display_name) { name.to_s.humanize } unless provider.respond_to?(:display_name)
    safe_name = name.to_s.gsub(/[^a-zA-Z0-9]/, "_").camelize
    constant_name = "EcosystemProviderFixture#{safe_name}#{provider.object_id}"
    stub_const(constant_name, provider)
    declaration = Syrus::Plugin::FamilyDeclaration.build(
      family: :ecosystem, provider: constant_name, key:, implements:, provisional:
    )
    Syrus::PluginRegistry.register(
      name: name.to_s, version: "1.0.0", family_provides: [ declaration ], **manifest
    )
    provider
  end
end

RSpec.configure { |config| config.include EcosystemProviderHelpers }
