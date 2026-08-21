class PluginLifecycleJob < ApplicationJob
  queue_as :control_plane

  discard_on ActiveRecord::RecordNotFound

  DRAIN_ALWAYS_EVENTS = %w[on_disable on_shutdown].freeze
  DRAIN_ON_FAILURE_EVENTS = %w[on_boot on_enable].freeze

  def perform(plugin_name, event)
    manifest = Syrus::PluginRegistry.all_plugins.find { |m| m.name == plugin_name }
    return unless manifest

    providers = Array(manifest.provides[:callbacks])
    return if providers.empty?

    method_name = event.to_sym

    if DRAIN_ALWAYS_EVENTS.include?(event.to_s)
      begin
        dispatch(providers, method_name)
      ensure
        Syrus::Plugin::EffectRegistry.drain!(plugin_name)
      end
    elsif DRAIN_ON_FAILURE_EVENTS.include?(event.to_s)
      begin
        dispatch(providers, method_name)
      rescue StandardError
        Syrus::Plugin::EffectRegistry.drain!(plugin_name)
        raise
      end
    else
      dispatch(providers, method_name)
    end
  end

  private

  def dispatch(providers, method_name)
    providers.each { |provider| provider.public_send(method_name) }
  end
end
