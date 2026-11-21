class PluginTickJob < ApplicationJob
  queue_as :control_plane

  def perform(plugin_name)
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == plugin_name }
    return unless manifest
    # PluginTickSchedulerJob checked both when it enqueued; the plugin may have
    # been disabled or turned unhealthy while the tick waited in the queue.
    return unless manifest.enabled? && Syrus::PluginRegistry.health.healthy?(manifest.name)

    providers = Array(manifest.provides[:callbacks])
    providers.each(&:on_tick)
  end
end
