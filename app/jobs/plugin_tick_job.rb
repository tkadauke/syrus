class PluginTickJob < ApplicationJob
  queue_as :control_plane

  def perform(plugin_name)
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == plugin_name }
    return unless manifest
    # PluginTickSchedulerJob checked both when it enqueued; the plugin may have
    # been disabled or turned unhealthy while the tick waited in the queue.
    return unless manifest.enabled? && Syrus::PluginRegistry.health.healthy?(manifest.name)

    providers = Syrus::Plugin::Lifecycle.callback_providers_for(manifest)
    providers.each(&:on_tick)
  end
end
