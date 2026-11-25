module Admin
  class PluginHostSurfaceAudit
    def initialize(inventory: PluginHostSurfaceInventory.new, surface: Syrus::PluginHostSurface.new)
      @inventory = inventory
      @surface = surface
    end

    def findings
      internal_findings
    end

    private

    def internal_findings
      @inventory.results.filter_map do |result|
        next unless result.tier == "internal"
        next if @surface.allowed_internal?(result.constant)

        "#{result.constant} is referenced by #{result.plugins.keys.join(', ')} but is internal; add a facade under Syrus::Host with an API contract, or stop using it"
      end
    end
  end
end
