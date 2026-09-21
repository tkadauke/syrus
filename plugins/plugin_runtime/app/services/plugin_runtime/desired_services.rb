module PluginRuntime
  # The services that should exist right now: one per enabled plugin that
  # contributes to "plugin_runtime:service".
  #
  # This reads the manifests directly rather than through
  # PluginRegistry.providers_for, because providers_for hands back bare
  # classes and the reconciler also needs to know which plugin owns each one
  # -- the runtime manager labels the container with it, so an operator
  # looking at `docker ps` can tell whose it is.
  #
  # Disabled plugins drop out of this set, which is the whole of how disabling
  # works: the reconciler removes any managed service no longer listed here.
  class DesiredServices
    POINT = "plugin_runtime:service".freeze

    Entry = Data.define(:name, :plugin, :provider)

    def self.all
      entries = Syrus::PluginRegistry.all_plugins.select(&:enabled?).flat_map do |manifest|
        Array(manifest.provides[POINT] || manifest.provides[POINT.to_sym]).filter_map do |ref|
          entry_for(manifest.name, ref)
        end
      end
      deduplicate(entries)
    end

    def self.entry_for(plugin, ref)
      provider = ref.is_a?(String) ? ref.safe_constantize : ref
      unless provider && Service.implemented_by?(provider)
        Rails.logger.warn("[PluginRuntime] #{plugin} contributes #{ref.inspect} to #{POINT}, which does not implement the service contract")
        return nil
      end
      Entry.new(name: provider.service_name.to_s, plugin: plugin, provider: provider)
    rescue StandardError => e
      Rails.logger.warn("[PluginRuntime] #{plugin} service #{ref.inspect} could not be read: #{e.class}: #{e.message}")
      nil
    end

    # Two plugins claiming one service name would fight over one container,
    # each replacing the other's spec every tick. The first claim wins and the
    # conflict is logged, so it is stable and visible instead.
    def self.deduplicate(entries)
      entries.group_by(&:name).map do |name, claims|
        if claims.size > 1
          Rails.logger.warn("[PluginRuntime] service #{name} is claimed by #{claims.map(&:plugin).join(', ')}; using #{claims.first.plugin}")
        end
        claims.first
      end
    end
  end
end
