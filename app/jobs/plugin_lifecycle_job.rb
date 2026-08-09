class PluginLifecycleJob < ApplicationJob
  queue_as :control_plane

  discard_on ActiveRecord::RecordNotFound

  def perform(plugin_name, event)
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == plugin_name }
    return unless manifest

    providers = Array(manifest.provides[:callbacks])
    return if providers.empty?

    method_name = event.to_sym

    providers.each do |provider|
      provider.public_send(method_name)
    end
  end
end
