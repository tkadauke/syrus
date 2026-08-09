module Syrus
  module Plugin
    # Marker module for plugins that participate in the lifecycle callback system.
    #
    # Include this module in a provider class and override any methods needed.
    # All methods return nil by default so plugins only implement what they care about.
    # Methods are available as both instance and class methods via the included hook.
    module Callbacks
      def self.included(base)
        base.extend(self)
      end

      def on_boot = nil
      def on_shutdown = nil
      def on_enable = nil
      def on_disable = nil
      def on_tick = nil
    end
  end
end
