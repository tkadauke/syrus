module TestInsights
  class RetentionPolicy
    include Syrus::Plugin::RetentionPolicy

    def self.retention_definitions
      [
        RetentionPolicyRegistry::Definition.new(
          key: :test_insight_case,
          model: "TestInsights::TestCase",
          table_name: "test_insight_cases",
          age_column: :created_at,
          scope_name: :prunable,
          setting_key: :test_insight_case_retention_days,
          default_value: 90,
          unit: :days,
          executor_class: "TestInsights::RetentionExecutor",
          description: "Per-test grader execution history. Ninety days preserves a generous recent sample for failure-rate and flakiness analysis while bounding the plugin's highest-volume table; aggregated identity counters remain available after raw cases expire.",
          category: "Plugins",
          archivable: false
        )
      ]
    end
  end
end
