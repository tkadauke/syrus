module Tailscale
  class Callbacks
    include Syrus::Plugin::Callbacks

    class << self
      def on_boot
        start_if_authkey_present
      end

      def on_enable
        start_if_authkey_present
      end

      def on_tick
        if ENV["TS_AUTHKEY"].present?
          DaemonManager.instance.restart_if_dead
          HostAllowlist.sync if DaemonManager.instance.alive?
        end
      end

      private

      def start_if_authkey_present
        DaemonManager.instance.start if ENV["TS_AUTHKEY"].present?
        return unless DaemonManager.instance.alive?

        HostAllowlist.sync
        effect { HostAllowlist.clear }
      end
    end
  end
end
