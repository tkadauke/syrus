module JobVisibilityRestrictionSpecHelper
  THREAD_KEY = :syrus_spec_job_visibility_restriction

  Rails.application.reloader.to_prepare do
    provider = Thread.current[THREAD_KEY]
    Syrus::PluginRegistry.register(:job_visibility_restriction, provider) if provider
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
    Syrus::PluginRegistry.register(:job_visibility_restriction, provider)
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
