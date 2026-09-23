module Tailscale
  # Container lifecycle (starting/stopping tailscaled, applying config
  # changes) is owned by Plugin Runtime's own reconcile tick once this plugin
  # contributes RuntimeService -- see PluginRuntime::Callbacks. This plugin's
  # own callbacks are left with exactly one job: keeping Rails'
  # config.hosts allowlist in sync with the tailnet identity the container
  # reports, so requests arriving over `tailscale serve` with the tailnet
  # hostname pass host authorization.
  class Callbacks
    include Syrus::Plugin::Callbacks

    class << self
      def on_boot
        sync_and_register_cleanup
      end

      def on_enable
        sync_and_register_cleanup
      end

      def on_tick
        HostAllowlist.sync if available?
      end

      private

      def sync_and_register_cleanup
        return unless available?

        HostAllowlist.sync
        effect { HostAllowlist.clear }
      end

      def available?
        PluginRuntime::Services.endpoint_for("tailscale").present?
      end
    end
  end
end
