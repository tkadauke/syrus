module PluginRuntime
  module DesiredServiceCollection
    Entry = Data.define(:name, :plugin, :provider)

    def all
      # Contributions from plugins that are enabled *and* healthy, with the
      # plugin that made each one. Reading manifests with enabled? alone kept
      # a degraded or failed plugin's service running (NY18).
      entries = Syrus::PluginRegistry.providers_with_owner_for(point).filter_map do |plugin_name, ref|
        next unless eligible_plugin?(plugin_name)

        entry_for(plugin_name, ref)
      end
      deduplicate(entries)
    end

    def entry_for(plugin, ref)
      provider = ref.is_a?(String) ? ref.safe_constantize : ref
      unless provider && contract.implemented_by?(provider)
        Rails.logger.warn("[PluginRuntime] #{plugin} contributes #{ref.inspect} to #{point}, which does not implement the #{label} contract")
        return nil
      end
      Entry.new(name: public_name_for(provider).to_s, plugin: plugin, provider: provider)
    rescue StandardError => e
      Rails.logger.warn("[PluginRuntime] #{plugin} #{label} #{ref.inspect} could not be read: #{e.class}: #{e.message}")
      nil
    end

    # Two plugins claiming one service name would fight over one container,
    # each replacing the other's spec every tick. The first claim wins and the
    # conflict is logged, so it is stable and visible instead.
    def deduplicate(entries)
      entries.group_by(&:name).map do |name, claims|
        if claims.size > 1
          Rails.logger.warn("[PluginRuntime] #{label} #{name} is claimed by #{claims.map(&:plugin).join(', ')}; using #{claims.first.plugin}")
        end
        claims.first
      end
    end

    def eligible_plugin?(_plugin_name) = true
  end
end
