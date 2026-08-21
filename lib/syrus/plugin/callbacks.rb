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

      # Registers a cleanup block for this plugin at the point an effect
      # takes hold (e.g. right after a daemon process is spawned), instead
      # of reconstructing the inverse later in a hand-written teardown
      # method. Runs in reverse registration order when the plugin's
      # effects are drained (see Syrus::Plugin::EffectRegistry).
      def effect(&cleanup)
        Syrus::Plugin::EffectRegistry.register(effect_plugin_name, &cleanup)
      end

      private

      def effect_plugin_name
        manifest = Syrus::PluginRegistry.all_plugins.find { |m| Array(m.provides[:callbacks]).include?(self) }
        unless manifest
          raise "Unable to resolve plugin name for #{self} — is it registered via " \
                "Syrus::PluginRegistry.register(provides: { callbacks: #{self} })?"
        end

        manifest.name
      end
    end
  end
end
