module Tailscale
  class Callbacks
    include Syrus::Plugin::Callbacks

    class << self
      def on_boot
        start_if_authkey_present
        HostAllowlist.sync if DaemonManager.instance.alive?
      end

      def on_enable
        start_if_authkey_present
        HostAllowlist.sync if DaemonManager.instance.alive?
      end

      def on_tick
        if ENV["TS_AUTHKEY"].present?
          DaemonManager.instance.restart_if_dead
          HostAllowlist.sync if DaemonManager.instance.alive?
        end
      end

      def on_disable
        HostAllowlist.clear
        DaemonManager.instance.stop
      end

      def on_shutdown
        HostAllowlist.clear
        DaemonManager.instance.stop
      end

      private

      def start_if_authkey_present
        DaemonManager.instance.start if ENV["TS_AUTHKEY"].present?
      end
    end
  end
end
