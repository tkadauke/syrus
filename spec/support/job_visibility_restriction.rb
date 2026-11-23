module JobVisibilityRestrictionSpecHelper
  THREAD_KEY = :syrus_spec_job_visibility_restriction

  Rails.application.reloader.to_prepare do
    provider = Thread.current[THREAD_KEY]
    JobVisibilityRestrictionSpecHelper.register_job_visibility_restriction(provider) if provider
  end

  # Policy contributions come only from family declarations, so each fixture
  # restriction declares itself as a plugin. Re-registering one by name replaces
  # it, which keeps the reloader's re-registration idempotent.
  def self.register_job_visibility_restriction(provider, name: "job_visibility_restriction_fixture")
    constant = name.to_s.camelize
    contribution = Syrus::Plugin::ContributionProvider.build(key: name.to_s, display_name: name.to_s, job_visibility_restrictions: provider)
    Object.send(:remove_const, constant) if Object.const_defined?(constant)
    Object.const_set(constant, contribution)
    Syrus::PluginRegistry.register(
      name: name.to_s, version: "1.0.0",
      family_provides: [ Syrus::Plugin::FamilyDeclaration.build(
        family: :policy, provider: constant, provisional: [ :job_visibility_restrictions ]
      ) ]
    )
  end

  def with_job_visibility_restriction(origin:, visible_origin_ids:)
    provider = Class.new do
      include Syrus::Plugin::JobVisibilityRestriction
    end
    provider.define_singleton_method(:origin_key) { origin }
    provider.define_singleton_method(:visible_origin_ids) { |user:| visible_origin_ids.respond_to?(:call) ? visible_origin_ids.call(user) : visible_origin_ids }

    snapshot = Syrus::PluginRegistry.snapshot
    boot_snapshot = Syrus::PluginRegistry.boot_snapshot
    Thread.current[THREAD_KEY] = provider
    JobVisibilityRestrictionSpecHelper.register_job_visibility_restriction(provider)
    Syrus::PluginRegistry.boot_snapshot = Syrus::PluginRegistry.snapshot
    yield provider
  ensure
    Thread.current[THREAD_KEY] = nil
    Syrus::PluginRegistry.boot_snapshot = boot_snapshot
    Syrus::PluginRegistry.restore(snapshot) if snapshot
  end
end

RSpec.configure do |config|
  config.include JobVisibilityRestrictionSpecHelper
end
