module MainBranchHealth
  class RetentionPolicy
    include Syrus::Plugin::RetentionPolicy

    def self.retention_definitions
      [
        RetentionPolicyRegistry::Definition.new(
          key: :main_branch_health_check,
          model: "MainBranchHealth::HealthCheck",
          table_name: "main_branch_health_health_checks",
          age_column: :checked_at,
          scope_name: :pruneable,
          setting_key: :main_branch_health_check_retention_days,
          default_value: 7,
          unit: :days,
          executor_class: nil,
          description: "Recorded CI/grader health checks per repository SHA, used for main-branch breakage detection.",
          category: "Diagnostics",
          archivable: true
        )
      ]
    end
  end
end
