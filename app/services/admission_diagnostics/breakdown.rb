module AdmissionDiagnostics
  # Presents an already-recorded WorkflowAdmissionBudget::Decision#artifact
  # hash (persisted as a workflow's "start_blocked_details",
  # "workflow_admission_decision", or "workflow_admission_override" artifact)
  # as an operator-facing pressure breakdown: which dimension tripped, its
  # current value vs the threshold that tripped it, and whether the host
  # telemetry backing that decision was actually present. This never re-runs
  # WorkflowAdmissionBudget — it only re-presents numbers Syrus already
  # recorded, reusing its budget/threshold constants so the numbers shown
  # here can't drift from the numbers that made the decision.
  #
  # Shared by App::JobDetailPayload (operator-facing Job detail view) and
  # Admin::ResourceAdmissionDiagnosticsPayload (admin diagnostics page) so
  # both surfaces compute the breakdown identically.
  class Breakdown
    HARD_HOST_REASONS = {
      "worker_memory_exhausted" => %w[memory_used_percent max_memory_used_percent],
      "worker_disk_exhausted" => %w[data_root_used_percent max_data_root_used_percent]
    }.freeze

    HARD_HOST_THRESHOLDS = {
      "worker_memory_exhausted" => WorkflowAdmissionBudget::HARD_MEMORY_USED_PERCENT,
      "worker_disk_exhausted" => WorkflowAdmissionBudget::HARD_DATA_ROOT_USED_PERCENT
    }.freeze

    SOFT_HOST_METRICS = [
      %w[cpu_pressure max_cpu_pressure],
      %w[io_pressure max_io_pressure],
      %w[memory_used_percent max_memory_used_percent],
      %w[data_root_used_percent max_data_root_used_percent]
    ].freeze

    PROJECTED_METRICS = {
      "cpu_pressure" => WorkflowAdmissionBudget::CPU_BUDGET,
      "io_pressure" => WorkflowAdmissionBudget::IO_BUDGET,
      "memory_used_percent" => WorkflowAdmissionBudget::MEMORY_BUDGET
    }.freeze

    STEP_PROFILE_REASONS = %w[
      predicted_budget_pressure_high
      pending_high_cost_work
      repository_concurrency_budget_exhausted
    ].freeze

    METRIC_LABELS = {
      "cpu_pressure" => "CPU pressure",
      "io_pressure" => "IO pressure",
      "memory_used_percent" => "Memory used",
      "data_root_used_percent" => "Disk used"
    }.freeze

    def self.for(decision_artifact)
      new(decision_artifact).as_json
    end

    def initialize(decision_artifact)
      artifact = decision_artifact.to_h
      @reason = artifact["reason"].to_s
      @pressure = artifact["pressure"].to_h
      @details = artifact["details"].to_h
    end

    def as_json
      {
        "reason" => reason.presence,
        "category" => category,
        "telemetry_state" => telemetry_state,
        "telemetry_absent" => telemetry_absent?,
        "dimensions" => dimensions
      }
    end

    private

    attr_reader :reason, :pressure, :details

    def host
      @host ||= pressure["host"].to_h
    end

    def category
      return "hard_host_pressure" if HARD_HOST_REASONS.key?(reason)
      return "soft_host_pressure" if reason == "worker_host_pressure_high"
      return "step_profile_pressure" if STEP_PROFILE_REASONS.include?(reason)

      "other"
    end

    def telemetry_state
      host["telemetry_state"] || details["telemetry_state"]
    end

    def telemetry_absent?
      telemetry_state.in?(%w[absent stale])
    end

    def dimensions
      case category
      when "hard_host_pressure"
        [ hard_host_dimension ].compact
      when "soft_host_pressure"
        SOFT_HOST_METRICS.filter_map { |metric, host_key| dimension(metric, host[host_key], WorkflowAdmissionBudget::SOFT_HOST_PRESSURE) }
      when "step_profile_pressure"
        projected = pressure["projected"].to_h
        PROJECTED_METRICS.filter_map { |metric, threshold| dimension(metric, projected[metric], threshold) }
      else
        []
      end
    end

    def hard_host_dimension
      metric, host_key = HARD_HOST_REASONS.fetch(reason)
      dimension(metric, host[host_key], HARD_HOST_THRESHOLDS.fetch(reason))
    end

    def dimension(metric, current, threshold)
      return nil if current.nil?

      {
        "metric" => metric,
        "label" => METRIC_LABELS.fetch(metric, metric.tr("_", " ")),
        "current" => current.to_f.round(1),
        "threshold" => threshold.to_f.round(1),
        "over_threshold" => current.to_f >= threshold.to_f
      }
    end
  end
end
