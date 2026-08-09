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
        DaemonManager.instance.restart_if_dead if ENV["TS_AUTHKEY"].present?
      end

      def on_disable
        DaemonManager.instance.stop
      end

      def on_shutdown
        DaemonManager.instance.stop
      end

      private

      def start_if_authkey_present
        DaemonManager.instance.start if ENV["TS_AUTHKEY"].present?
      end
    end
  end
end
