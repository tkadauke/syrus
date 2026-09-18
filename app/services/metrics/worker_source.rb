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

    # Keyed by worker_storage_key -- the stable identity a Prometheus gauge's
    # tag must carry for the series to survive a pod restart. A hostname is
    # not safe here even as a second tag: series identity is the whole tag
    # combination, so pairing a stable key with a churning hostname on the
    # same gauge would still fork a new series every reschedule.
    def worker_cpu_percentages
      latest_samples.transform_values(&:cpu_used_percent).compact
    end

    def worker_memory_percentages
      latest_samples.transform_values(&:memory_used_percent).compact
    end

    def worker_disk_percentages
      latest_samples.transform_values(&:data_root_used_percent).compact
    end

    # Hash[worker_storage_key => hostname] for the latest sample of each
    # currently-fresh worker -- the join key that lets a human-readable
    # hostname label be recovered from the storage-key-tagged gauges above
    # without putting hostname on their own tag set. Backs
    # syrus_worker_identity_info.
    def worker_hostname_labels
      latest_samples.transform_values(&:hostname)
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

    # Grouped by the durable worker_storage_key (WorkerStorageIdentity), not
    # hostname, so a Deployment pod restart -- a new hostname, same storage --
    # does not fork the series. Rows written before this column existed have
    # no worker_storage_key, so they fall back to hostname for the rollout
    # window. Stays keyed by that identity -- callers that want the
    # human-readable hostname use #worker_hostname_labels instead of losing
    # the stable key by re-indexing on it.
    def latest_samples
      @latest_samples ||= WorkerHostHealthSample.worker_role
        .where("observed_at >= ?", SAMPLE_WINDOW.ago)
        .order(observed_at: :desc)
        .group_by { |sample| sample.worker_storage_key.presence || sample.hostname }
        .transform_values(&:first)
    end
  end
end
