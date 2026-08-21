module Syrus
  module Plugin
    # Per-plugin-name stack of cleanup procs, registered at the point an
    # effect takes hold (e.g. a daemon process spawned, a host allowlist
    # synced) instead of being reconstructed later by hand in a separately
    # maintained teardown method. Mutex-guarded, same style as
    # Syrus::PluginRegistry.
    class EffectRegistry
      @mutex = Mutex.new
      @effects = Hash.new { |h, k| h[k] = [] }

      class << self
        def register(plugin_name, &cleanup)
          raise ArgumentError, "cleanup block required" unless cleanup

          @mutex.synchronize { @effects[plugin_name.to_s] << cleanup }
        end

        # Pops and runs every registered cleanup for plugin_name, most
        # recently registered first, then clears the stack. A raising
        # cleanup is rescued and logged so it never blocks the rest.
        def drain!(plugin_name)
          cleanups = @mutex.synchronize { @effects.delete(plugin_name.to_s) || [] }

          cleanups.reverse_each do |cleanup|
            cleanup.call
          rescue StandardError => e
            Rails.logger.warn("[EffectRegistry] cleanup failed for #{plugin_name}: #{e.class}: #{e.message}")
          end
        end

        def reset!
          @mutex.synchronize { @effects = Hash.new { |h, k| h[k] = [] } }
        end
      end
    end
  end
end
