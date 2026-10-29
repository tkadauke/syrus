# Declarative source of truth for every DB-table row retention window Syrus
# enforces. Each entry documents one prunable table: which model/scope
# deletes its expired rows, its stable persistence key and display unit, and
# which optional executor handles table-specific side effects. RetentionPolicySetting stores only the
# operator choice in canonical seconds; nil means infinite retention.
#
# Core-owned tables are declared inline below. A plugin that owns a prunable
# table (e.g. metrics_dashboard) must NOT be hand-listed here — a core file
# naming a plugin's model/job class would make that plugin undeletable in
# practice (see CLAUDE.md's "core specs must not enumerate plugin-provided
# things" rule and bin/plugin-boundary-audit). Instead the plugin implements
# the `:retention_policy` extension point (see Syrus::Plugin::RetentionPolicy)
# and `.definitions` merges its contributions in on every read.
class RetentionPolicyRegistry
  Definition = Data.define(
    :key,
    :model,
    :table_name,
    :age_column,
    :scope_name,
    :setting_key,
    :default_value,
    :unit,
    :executor_class,
    :description,
    :category,
    :archivable
  ) do
    def model_class
      model.constantize
    end

    def executor
      (executor_class || "RetentionPolicyExecutors::Default").constantize.new(self)
    end

    def default_seconds
      default_value.public_send(unit).to_i
    end

    def seconds_for(value)
      numeric = Integer(value)
      numeric.zero? ? nil : numeric.public_send(unit).to_i
    end

    def value_for(seconds)
      return 0 if seconds.nil?

      seconds / (unit == :hours ? 1.hour.to_i : 1.day.to_i)
    end

    def setting
      RetentionPolicySetting.for(self)
    end

    def retention_value
      value_for(setting.retention_seconds)
    end

    def retention_window
      setting.retention_seconds&.seconds
    end

    def archive_setting_key
      :"#{key}_archive_before_delete"
    end

    def as_json(*)
      {
        key: key.to_s,
        model: model,
        table_name: table_name,
        age_column: age_column.to_s,
        scope_name: scope_name.to_s,
        setting_key: setting_key.to_s,
        default_value: default_value,
        unit: unit.to_s,
        executor_class: executor_class,
        description: description,
        category: category,
        archivable: archivable
      }
    end
  end
  CORE_DEFINITIONS = [
    Definition.new(
      key: :job_log,
      model: "JobLog",
      table_name: "job_logs",
      age_column: :created_at,
      scope_name: :prunable,
      setting_key: :job_log_retention_days,
      default_value: 30,
      unit: :days,
      executor_class: nil,
      description: "User-visible Run output; pruning removes the detailed stdout, stderr, tool-call, and system log history while keeping the Run itself.",
      category: "Product",
      archivable: true
    ),
    Definition.new(
      key: :performance_log_event,
      model: "PerformanceLogEvent",
      table_name: "performance_log_events",
      age_column: :occurred_at,
      scope_name: :prunable,
      setting_key: :performance_log_event_retention_hours,
      default_value: 24,
      unit: :hours,
      executor_class: nil,
      description: "High-volume request, SQL, job, and browser performance diagnostics used to investigate recent regressions.",
      category: "Diagnostics",
      archivable: false
    ),
    Definition.new(
      key: :run_diagnostic,
      model: "RunDiagnostic",
      table_name: "run_diagnostics",
      age_column: :created_at,
      scope_name: :prunable,
      setting_key: :run_diagnostic_retention_days,
      default_value: 30,
      unit: :days,
      executor_class: nil,
      description: "Per-failed-Run diagnostic snapshots (exception backtrace, git/environment snapshot) used for incident triage.",
      category: "Diagnostics",
      archivable: true
    ),
    Definition.new(
      key: :run_resource_summary,
      model: "RunResourceSummary",
      table_name: "run_resource_summaries",
      age_column: :created_at,
      scope_name: :prunable,
      setting_key: :run_resource_summary_retention_days,
      default_value: 30,
      unit: :days,
      executor_class: nil,
      description: "Per-Run resource/pressure summaries used for admission control and worker health correlation.",
      category: "Diagnostics",
      archivable: false
    ),
    Definition.new(
      key: :worker_host_health_sample,
      model: "WorkerHostHealthSample",
      table_name: "worker_host_health_samples",
      age_column: :observed_at,
      scope_name: :prunable,
      setting_key: :worker_host_health_sample_retention_days,
      default_value: 7,
      unit: :days,
      executor_class: nil,
      description: "Per-host CPU/memory/disk/pressure samples used for live and historical worker health.",
      category: "Diagnostics",
      archivable: false
    ),
    Definition.new(
      key: :work_engine_reconciler_activity,
      model: "WorkEngineReconcilerActivityEvent",
      table_name: "work_engine_reconciler_activity_events",
      age_column: :occurred_at,
      scope_name: :prunable,
      setting_key: :work_engine_reconciler_activity_retention_days,
      default_value: 7,
      unit: :days,
      executor_class: nil,
      description: "Append-only WorkEngine::Reconciler activity log (repair detection/planning/execution events).",
      category: "Diagnostics",
      archivable: true
    ),
    Definition.new(
      key: :provider_session,
      model: "ProviderSession",
      table_name: "provider_sessions",
      age_column: :updated_at,
      scope_name: :prunable,
      setting_key: :provider_session_retention_days,
      default_value: 14,
      unit: :days,
      executor_class: "RetentionPolicyExecutors::ProviderSession",
      description: "Captured agent provider sessions for terminal Runs, kept for diagnostics and resume rehydration.",
      category: "Diagnostics",
      archivable: true
    ),
    Definition.new(
      key: :spawned_process,
      model: "SpawnedProcess",
      table_name: "spawned_processes",
      age_column: :finished_at,
      scope_name: :prunable,
      setting_key: :spawned_process_retention_days,
      default_value: 7,
      unit: :days,
      executor_class: "RetentionPolicyExecutors::SpawnedProcess",
      description: "Subprocess inventory (agent CLIs, graders, git, prepare) used for the admin Processes list.",
      category: "Diagnostics",
      archivable: false
    ),
    Definition.new(
      key: :notification,
      model: "Notification",
      table_name: "notifications",
      age_column: :created_at,
      scope_name: :prunable,
      setting_key: :notification_retention_days,
      default_value: 30,
      unit: :days,
      executor_class: nil,
      description: "In-app user notifications (Job failed/implemented/merged, Epic status, etc).",
      category: "Product",
      archivable: false
    ),
    Definition.new(
      key: :operational_log_event,
      model: "OperationalLogEvent",
      table_name: "operational_log_events",
      age_column: :occurred_at,
      scope_name: :expired,
      setting_key: :operational_log_event_retention_hours,
      default_value: 6,
      unit: :hours,
      executor_class: "RetentionPolicyExecutors::OperationalLogEvent",
      description: "Syrus's own operational log index (Rails app logs ingested for self-diagnosis).",
      category: "Diagnostics",
      archivable: false
    ),
    Definition.new(
      key: :run_health_snapshot,
      model: "RunHealthSnapshot",
      table_name: "run_health_snapshots",
      age_column: :created_at,
      scope_name: :prunable,
      setting_key: :run_health_snapshot_retention_days,
      default_value: 7,
      unit: :days,
      executor_class: nil,
      description: "Point-in-time health snapshots recorded during a Run for operator diagnostics.",
      category: "Diagnostics",
      archivable: true
    ),
    Definition.new(
      key: :main_branch_health_check,
      model: "MainBranchHealthCheck",
      table_name: "main_branch_health_checks",
      age_column: :checked_at,
      scope_name: :pruneable,
      setting_key: :main_branch_health_check_retention_days,
      default_value: 7,
      unit: :days,
      executor_class: nil,
      description: "Recorded CI/grader health checks per repository SHA, used for main-branch breakage detection.",
      category: "Diagnostics",
      archivable: true
    ),
    Definition.new(
      key: :workflow_step_resource_profile,
      model: "WorkflowStepResourceProfile",
      table_name: "workflow_step_resource_profiles",
      age_column: :last_observed_at,
      scope_name: :stale,
      setting_key: :workflow_step_resource_profile_retention_days,
      default_value: 180,
      unit: :days,
      executor_class: nil,
      description: "Per-step-key resource prediction profiles used for admission control; stale profiles are dropped rather than trusted.",
      category: "Diagnostics",
      archivable: false
    )
  ].freeze

  # Recomputed on every call rather than frozen once, so a plugin's
  # contribution is picked up at whatever point its `:retention_policy`
  # provider is registered (also matching Rails dev-mode reload semantics,
  # where a plugin's manifest is rebuilt on every `to_prepare`).
  def self.definitions
    CORE_DEFINITIONS + plugin_definitions
  end

  def self.fetch(key)
    find(key) || raise(KeyError, "key not found: #{key}")
  end

  def self.find(key) = definitions.find { |definition| definition.key == key.to_sym }

  def self.validate!
    duplicates = definitions.group_by(&:key).select { |_key, entries| entries.many? }.keys
    raise ArgumentError, "duplicate retention keys: #{duplicates.join(', ')}" if duplicates.any?

    definitions.each do |definition|
      model = definition.model_class
      raise ArgumentError, "#{definition.key} table mismatch" unless model.table_name == definition.table_name
      raise ArgumentError, "#{definition.key} has no #{definition.scope_name} scope" unless model.respond_to?(definition.scope_name)
      raise ArgumentError, "#{definition.key} has no #{definition.age_column} column" unless model.column_names.include?(definition.age_column.to_s)
      definition.setting
      definition.executor
    end
  end

  def self.plugin_definitions
    Syrus::PluginRegistry.providers_for(:retention_policy).flat_map do |provider|
      Array(provider.retention_definitions)
    rescue StandardError => error
      Rails.logger.error(
        "[RetentionPolicyRegistry] provider=#{provider.name} " \
        "error=#{error.class}: #{error.message}"
      )
      []
    end
  end
end
