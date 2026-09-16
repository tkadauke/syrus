# Declarative source of truth for every DB-table row retention window Syrus
# enforces. Each entry documents one prunable table: which model/scope
# deletes its expired rows, which AppSetting column controls the window
# (0 = infinite retention), and which recurring PruneJob (if any) runs it.
#
# AppSettingRegistry merges these entries in as admin-editable integer
# settings (see app_setting_registry.rb) so validations and admin metadata
# don't need to be hand-listed per key; a future admin page can read this
# registry directly for table sizing / retention UI.
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
    :job_class,
    :description,
    :category
  ) do
    def model_class
      model.constantize
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
        job_class: job_class,
        description: description,
        category: category
      }
    end

    # Folded into AppSettingRegistry.definitions so the existing generic
    # numericality-validation and admin-metadata machinery covers these
    # columns without per-key duplication.
    def as_app_setting_definition
      AppSettingRegistry::Definition.new(
        key: setting_key,
        type: :integer,
        default: default_value,
        category: "Data retention",
        operational_meaning: description,
        min: 0,
        max: nil,
        zero_means: "Retention is infinite; rows are never pruned by age.",
        admin_editable: true,
        secret: false
      )
    end
  end

  DEFINITIONS = [
    Definition.new(
      key: :run_diagnostic,
      model: "RunDiagnostic",
      table_name: "run_diagnostics",
      age_column: :created_at,
      scope_name: :prunable,
      setting_key: :run_diagnostic_retention_days,
      default_value: 30,
      unit: :days,
      job_class: "RunDiagnosticPruneJob",
      description: "Per-failed-Run diagnostic snapshots (exception backtrace, git/environment snapshot) used for incident triage.",
      category: "Diagnostics"
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
      job_class: "RunResourceSummaryPruneJob",
      description: "Per-Run resource/pressure summaries used for admission control and worker health correlation.",
      category: "Diagnostics"
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
      job_class: "WorkerHostHealthSamplePruneJob",
      description: "Per-host CPU/memory/disk/pressure samples used for live and historical worker health.",
      category: "Diagnostics"
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
      job_class: "WorkEngineReconcilerActivityPruneJob",
      description: "Append-only WorkEngine::Reconciler activity log (repair detection/planning/execution events).",
      category: "Diagnostics"
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
      job_class: "ProviderSessionPruneJob",
      description: "Captured agent provider sessions for terminal Runs, kept for diagnostics and resume rehydration.",
      category: "Diagnostics"
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
      job_class: "SpawnedProcessPruneJob",
      description: "Subprocess inventory (agent CLIs, graders, git, prepare) used for the admin Processes list.",
      category: "Diagnostics"
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
      job_class: "PruneOldNotificationsJob",
      description: "In-app user notifications (Job failed/implemented/merged, Epic status, etc).",
      category: "Product"
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
      job_class: "PruneOperationalLogsJob",
      description: "Syrus's own operational log index (Rails app logs ingested for self-diagnosis).",
      category: "Diagnostics"
    ),
    Definition.new(
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
      category: "Plugins"
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
      job_class: "RunHealthSnapshotPruneJob",
      description: "Point-in-time health snapshots recorded during a Run for operator diagnostics.",
      category: "Diagnostics"
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
      job_class: "MainBranchHealthCheckPruneJob",
      description: "Recorded CI/grader health checks per repository SHA, used for main-branch breakage detection.",
      category: "Diagnostics"
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
      job_class: "WorkflowStepResourceProfilePruneJob",
      description: "Per-step-key resource prediction profiles used for admission control; stale profiles are dropped rather than trusted.",
      category: "Diagnostics"
    ),
    Definition.new(
      key: :workflow_step_resource_profile_input,
      model: "WorkflowStepResourceProfile",
      table_name: "run_resource_summaries",
      age_column: :finished_at,
      scope_name: nil,
      setting_key: :workflow_step_resource_profile_input_retention_days,
      default_value: 180,
      unit: :days,
      job_class: nil,
      description: "How far back RunResourceSummary rows are considered as input when rebuilding resource profiles (a lookback window, not a row deletion).",
      category: "Diagnostics"
    )
  ].freeze

  BY_KEY = DEFINITIONS.index_by(&:key).freeze

  def self.definitions
    DEFINITIONS
  end

  def self.fetch(key)
    BY_KEY.fetch(key.to_sym)
  end
end
