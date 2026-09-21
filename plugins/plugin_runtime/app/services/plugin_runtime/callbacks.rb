module PluginRuntime
  # Fires once a minute while the plugin is enabled (PluginTickSchedulerJob only
  # ticks enabled plugins). Every tick is a full reconcile: ensure what is
  # wanted, remove what is not. Ensure is idempotent on the manager's side, so
  # a tick that finds nothing to do changes nothing.
  class Callbacks
    include Syrus::Plugin::Callbacks

    def self.on_tick
      Services.reconcile!
    rescue StandardError => e
      # A raising tick would be marked failed and could retry into a loop.
      # Services stay as they are until the next tick, and their cached
      # statuses expire if ticks keep failing, so callers fall back safely.
      Rails.logger.warn("[PluginRuntime] reconcile failed: #{e.class}: #{e.message}")
    end
  end
end
