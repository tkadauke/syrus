class PluginTickJob < ApplicationJob
  queue_as :control_plane

  def perform(plugin_name)
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == plugin_name }
    return unless manifest

    providers = Array(manifest.provides[:callbacks])
    providers.each(&:on_tick)
  end
end
