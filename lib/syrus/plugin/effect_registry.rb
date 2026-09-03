module Syrus
  module Plugin
    # Per-plugin stack of cleanup procs for **lifecycle** effects: things a
    # plugin does while running rather than while installing -- a daemon
    # spawned in `on_boot`, a host allowlist synced. Registered through
    # `Syrus::Plugin::Callbacks#effect` at the point the effect takes hold,
    # instead of being reconstructed later in a separately maintained teardown
    # method.
    #
    # This shares its mechanism with Syrus::Installer (both are
    # Syrus::EffectScope underneath) but deliberately *not* its lifetime, and
    # the two should not be merged:
    #
    #   installs   disposed and re-applied whenever the active plugin set
    #              moves, because what is installed must match what is enabled
    #   lifecycle  disposed only on this plugin's own on_disable/on_shutdown,
    #              or a failed on_boot/on_enable
    #
    # Folding lifecycle effects into the installer's scope would tear down a
    # running daemon every time some *unrelated* plugin was enabled, since that
    # bumps the generation the installer keys on.
    class EffectRegistry
      @mutex = Mutex.new
      @scopes = {}

      class << self
        def register(plugin_name, &cleanup)
          raise ArgumentError, "cleanup block required" unless cleanup

          scope_for(plugin_name).add_teardown(plugin_name.to_s, &cleanup)
        end

        # Runs every registered cleanup for plugin_name, most recently
        # registered first, then drops the scope. A raising cleanup is logged
        # and never blocks the rest (see EffectScope#dispose).
        def drain!(plugin_name)
          scope = @mutex.synchronize { @scopes.delete(plugin_name.to_s) }
          scope&.dispose
        end

        def reset!
          scopes = @mutex.synchronize { @scopes.values.tap { @scopes = {} } }
          scopes.each(&:dispose)
        end

        private

        # A disposed scope cannot take new effects, so a plugin that registers
        # again after a drain gets a fresh one.
        def scope_for(plugin_name)
          key = plugin_name.to_s
          @mutex.synchronize do
            scope = @scopes[key]
            @scopes[key] = scope = Syrus::EffectScope.new(label: "lifecycle:#{key}") if scope.nil? || scope.disposed?
            scope
          end
        end
      end
    end
  end
end
