module Metrics
  # The only place that touches WorkerHostHealthSample/Run/Step/AppSetting for
  # the "Workers and admission" metric group.
  #
  # Every table here is an ordinary ActiveRecord table (unlike solid_queue_*,
  # see CLAUDE.md), so this is exercised directly in specs rather than through
  # a fake.
  class WorkerSource
    # Same window RunHostAdmission/WorkflowAdmissionBudget use to decide a
    # worker sample is still fresh -- long enough to survive one missed
    # heartbeat tick (sampled every minute), short enough that a dead worker
    # drops out of the gauge instead of reporting a stale reading forever.
    SAMPLE_WINDOW = 2.minutes

    def worker_cpu_percentages
      latest_samples.transform_values(&:cpu_used_percent).compact
    end

    def worker_memory_percentages
      latest_samples.transform_values(&:memory_used_percent).compact
    end

    def worker_disk_percentages
      latest_samples.transform_values(&:data_root_used_percent).compact
    end

    def active_agent_run_count
      Run.running_agent_runs.count
    end

    def max_concurrent_agent_runs
      AppSetting.max_concurrent_agent_runs
    end

    # Steps that reached a terminal state in `[after, through)`, for
    # syrus_workflow_step_duration_seconds{kind}. Unlike
    # Metrics::LandingSource#finished_runs (one Run attempt), a Step's
    # started_at/finished_at spans every Run attempt within it -- a Step that
    # failed once and was repaired still reports one wall-clock duration for
    # the whole Step, not one per Run.
    def finished_steps(after:, through:)
      Step.terminal.where(finished_at: after...through).pluck(:kind, :started_at, :finished_at)
    end

    private

    def latest_samples
      @latest_samples ||= WorkerHostHealthSample.worker_role
        .where("observed_at >= ?", SAMPLE_WINDOW.ago)
        .order(observed_at: :desc)
        .group_by(&:hostname)
        .transform_values(&:first)
    end
  end
end
