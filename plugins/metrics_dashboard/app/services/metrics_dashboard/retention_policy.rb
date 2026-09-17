module MetricsDashboard
  # Contributes this plugin's own retention window into core's
  # RetentionPolicyRegistry via the `:retention_policy` extension point,
  # instead of core hand-listing MetricsDashboard::Sample/PruneJob by name.
  class RetentionPolicy
    include Syrus::Plugin::RetentionPolicy

    def self.retention_definitions
      [
        RetentionPolicyRegistry::Definition.new(
          key: :metrics_dashboard_sample,
          model: "MetricsDashboard::Sample",
          table_name: "metrics_dashboard_samples",
          age_column: :recorded_at,
          scope_name: :prunable,
          setting_key: :metrics_dashboard_sample_retention_days,
          default_value: 30,
          unit: :days,
          job_class: "MetricsDashboard::PruneJob",
          description: "One-minute-resolution metric series samples backing the Metrics Dashboard plugin.",
          category: "Plugins",
          archivable: false
        )
      ]
    end
  end
end
