module PluginRuntime
  # The privileged services that should exist right now: one per enabled
  # plugin that both contributes to "plugin_runtime:privileged_service" and is
  # named in FIRST_PARTY_PRIVILEGED_PLUGINS.
  #
  # That constant and the runtime manager's own compiled
  # internal/privileged.Registry (Go) are two independently-maintained
  # allowlists that do not derive from one another: a stray manifest
  # declaration here does nothing unless the Go binary also has a compiled
  # Definition for the same name, and a name missing from this constant is
  # never even attempted, whatever the manifest says. Either mistake fails
  # closed. See docs/plans/tailscale-privileged-service-lane.md.
  #
  # Disabled plugins drop out of this set the same way DesiredServices works:
  # the reconciler removes any managed privileged service no longer listed.
  class DesiredPrivilegedServices
    POINT = "plugin_runtime:privileged_service".freeze

    # The only plugins allowed to reach the privileged lane at all. Adding a
    # second entry here is a Plugin Runtime change, reviewed as one -- never
    # something a plugin's own manifest can opt into.
    FIRST_PARTY_PRIVILEGED_PLUGINS = %w[tailscale].freeze

    Entry = Data.define(:name, :plugin, :provider)

    def self.all
      entries = Syrus::PluginRegistry.all_plugins.select(&:enabled?).flat_map do |manifest|
        next [] unless FIRST_PARTY_PRIVILEGED_PLUGINS.include?(manifest.name)

        Array(manifest.provides[POINT] || manifest.provides[POINT.to_sym]).filter_map do |ref|
          entry_for(manifest.name, ref)
        end
      end
      deduplicate(entries)
    end

    def self.entry_for(plugin, ref)
      provider = ref.is_a?(String) ? ref.safe_constantize : ref
      unless provider && PrivilegedService.implemented_by?(provider)
        Rails.logger.warn("[PluginRuntime] #{plugin} contributes #{ref.inspect} to #{POINT}, which does not implement the privileged service contract")
        return nil
      end
      Entry.new(name: provider.privileged_service_name.to_s, plugin: plugin, provider: provider)
    rescue StandardError => e
      Rails.logger.warn("[PluginRuntime] #{plugin} privileged service #{ref.inspect} could not be read: #{e.class}: #{e.message}")
      nil
    end

    # Two plugins claiming one service name would fight over one container,
    # each replacing the other's spec every tick. The first claim wins and the
    # conflict is logged, so it is stable and visible instead.
    def self.deduplicate(entries)
      entries.group_by(&:name).map do |name, claims|
        if claims.size > 1
          Rails.logger.warn("[PluginRuntime] privileged service #{name} is claimed by #{claims.map(&:plugin).join(', ')}; using #{claims.first.plugin}")
        end
        claims.first
      end
    end
  end
end
