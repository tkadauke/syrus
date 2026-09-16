module MetricsDashboard
  # The contract for a dashboard tab contributed through this plugin's
  # "metrics_dashboard:tab" point (see docs/syrus_docs/plugins.md's "Hosting
  # a point for other plugins" and TestInsights::Parser for the same shape
  # applied to a different host).
  #
  # Contributors are **not** expected to `include` this module. Doing so
  # would make them load a MetricsDashboard constant, turning an optional
  # hook into a hard load-time dependency on this plugin -- a plugin that
  # declares Prometheus metrics must work perfectly well with
  # metrics_dashboard uninstalled or disabled. The module documents the
  # contract; contributors duck-type it.
  #
  # Register an implementation at boot time, alongside the contributor's own
  # `metrics do ... end` block:
  #
  #   provides "metrics_dashboard:tab" => "MyPlugin::MetricsDashboardTabs"
  #   optionally_depends_on [ "metrics_dashboard" ]
  #
  #   module MyPlugin
  #     class MetricsDashboardTabs
  #       def self.metrics_dashboard_tabs
  #         [
  #           {
  #             id: "my_plugin",
  #             label: "My Plugin",
  #             panels: [
  #               { key: "widgets_total", metric: "syrus_my_plugin_widgets_total",
  #                 group_by: "kind", mode: :rate, unit: "widgets", label: "Widgets processed, by kind" }
  #             ]
  #           }
  #         ]
  #       end
  #     end
  #   end
  #
  # Implementations must define:
  #
  #   metrics_dashboard_tabs -> Array<Hash>
  #     Each entry needs :id (unique, stable -- becomes the tab's panel
  #     `category`), :label (the tab's display text -- typically the
  #     plugin's own `display_name`), and :panels (an array of hashes in the
  #     same shape as MetricsDashboard::DashboardPayload::PANELS entries:
  #     :key, :metric, :group_by, :mode, :unit, plus :label for the panel's
  #     chart title, since a contributing plugin cannot rely on this
  #     plugin's own i18n namespace). :metric must name a series this
  #     plugin's own `metrics do ... end` block declares -- the recorder
  #     already captures every series /metrics exposes, plugin or core,
  #     with no wiring needed here.
  #
  #     Each panel's :key must be unique across the *entire* dashboard, not
  #     just within the contributing tab: the frontend uses it verbatim as a
  #     React list key and as the localStorage key for that panel's
  #     per-series legend-toggle state
  #     (`metrics_dashboard.hidden_series.<key>.<series name>`). A key that
  #     collides with a core panel or another plugin's panel makes toggling
  #     one chart's series silently toggle the other's too. Namespace with
  #     the plugin's own name (e.g. `throughput_jobs_landed`), mirroring how
  #     :metric is already namespaced.
  #
  #     Returning [] contributes nothing (e.g. a plugin that wants to hide
  #     its tab in some mode); this plugin discovers one tab per currently
  #     enabled, healthy contributor, so a disabled contributor's tab is
  #     absent rather than empty.
  module Tab
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def metrics_dashboard_tabs
        raise NotImplementedError, "#{name} must implement .metrics_dashboard_tabs"
      end
    end
  end
end
