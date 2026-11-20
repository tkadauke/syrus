module Admin
  class PluginHostSurfaceAudit
    # Keep exceptions here rare and explain why exposing a stable contract is
    # impossible. There are currently no such references.
    INTENTIONAL_INTERNAL_REFERENCES = [].freeze

    def initialize(inventory: PluginHostSurfaceInventory.new, surface: Syrus::PluginHostSurface.new)
      @inventory = inventory
      @surface = surface
    end

    def findings
      internal_findings + legacy_growth_findings + stale_legacy_findings
    end

    private

    def internal_findings
      @inventory.results.filter_map do |result|
        next unless result.tier == "internal"
        next if INTENTIONAL_INTERNAL_REFERENCES.include?(result.constant)

        "#{result.constant} is referenced by #{result.plugins.keys.join(', ')} but is internal; add a facade under Syrus::Host with an API contract, or stop using it"
      end
    end

    def legacy_growth_findings
      count = @surface.legacy_entries.size
      if count < @surface.legacy_baseline
        return [ "legacy plugin host surface shrank from #{@surface.legacy_baseline} to #{count}; lower legacy_baseline to #{count} so it cannot grow back" ]
      end
      return [] if count == @surface.legacy_baseline

      [ "legacy plugin host surface grew from #{@surface.legacy_baseline} to #{count}; add facades under Syrus::Host with API contracts, or stop using the new references" ]
    end

    def stale_legacy_findings
      referenced = @inventory.results.map(&:constant).to_set
      @surface.legacy_entries.filter_map do |entry|
        next if referenced.include?(entry.name)

        "#{entry.name} is legacy but no built-in plugin references it; remove it from config/plugin_host_surface.yml"
      end
    end
  end
end
