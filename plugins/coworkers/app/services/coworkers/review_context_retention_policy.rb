class Coworkers::ReviewContextRetentionPolicy
  include Syrus::Plugin::RetentionPolicy

  def self.retention_definitions
    [
      RetentionPolicyRegistry::Definition.new(
        key: :coworker_review_context,
        model: "Coworkers::ReviewContext",
        table_name: "coworker_review_contexts",
        age_column: :created_at,
        scope_name: :retention_candidates,
        setting_key: :coworker_review_context_retention_days,
        default_value: 30,
        unit: :days,
        executor_class: "Coworkers::ReviewContextRetentionExecutor",
        description: "Encrypted coworker review prompt text and recoverable isolated workspace paths; tombstoning preserves the safe manifest and evidence lineage.",
        category: "Plugins",
        archivable: false
      )
    ]
  end
end
