module MetricsDashboard
  # Resolves the dashboard tabs contributed by other plugins through this
  # plugin's hosted "metrics_dashboard:tab" point (see MetricsDashboard::Tab
  # and docs/syrus_docs/plugins.md's "Hosting a point for other plugins").
  #
  # Mirrors App::UiSlotsPayload / WorkspaceTabsPayload: this plugin never
  # names its contributors, so a contributing plugin (spending_insights,
  # throughput, ...) stays independently deletable -- exactly what
  # bin/plugin-boundary-audit exists to catch between sibling plugins, not
  # just between a plugin and core.
  #
  # `Syrus::PluginRegistry.providers_for` already filters to currently
  # enabled, healthy plugins, so a disabled contributor simply contributes
  # nothing -- the same `while_enabled` reading its own `metrics do ... end`
  # block uses.
  class PluginTabs
    def self.build = new.build

    def build
      Syrus::PluginRegistry.providers_for("metrics_dashboard:tab")
        .flat_map { |provider| tabs_for(provider) }
        .sort_by { |tab| tab[:label] }
    end

    private

    def tabs_for(provider)
      PerformanceLogging.plugin_call(extension_point: "metrics_dashboard:tab", provider: provider, operation: :metrics_dashboard_tabs) do
        Array(provider.metrics_dashboard_tabs).map { |tab| tab_payload(tab) }
      end
    end

    def tab_payload(tab)
      tab = tab.to_h.symbolize_keys
      {
        id: tab.fetch(:id).to_s,
        label: tab.fetch(:label).to_s,
        panels: Array(tab[:panels]).map { |panel| panel.to_h.symbolize_keys }
      }
    end
  end
end
