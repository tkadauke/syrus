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
    return if stale?(manifest, event)

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

  # The job runs whenever the queue reaches it, possibly after the plugin was
  # toggled back. An on_enable for a plugin that is disabled again would
  # register effects nothing drains; an on_disable for a plugin that is
  # enabled again would drain the effects it is still using. Each event runs
  # only while it still describes the plugin's state; the toggle that made it
  # stale enqueued its own event (formal/SyrusModel/LifecycleOrder.lean).
  def stale?(manifest, event)
    case event.to_s
    when "on_enable" then !manifest.enabled?
    when "on_disable" then manifest.enabled?
    else false
    end
  end

  def dispatch(providers, method_name)
    providers.each { |provider| provider.public_send(method_name) }
  end
end
