class MacosWorkerRollout
  Result = Data.define(:state, :worker, :drain, :message, :active_run_count, :remaining_worker_count) do
    def as_json(*)
      {
        state: state,
        worker: worker,
        drain: drain&.directive_payload,
        message: message,
        active_run_count: active_run_count,
        remaining_worker_count: remaining_worker_count
      }.compact
    end
  end

  UPDATE_STALE_AFTER = 15.minutes

  def self.advance!(...) = new(...).advance!
  def self.drain!(...) = new(...).drain!
  def self.clear!(...) = new(...).clear!
  def self.force_terminate!(...) = new(...).force_terminate!

  def initialize(desired_version: AppSetting.macos_worker_desired_release, worker_storage_key: nil, hostname: nil, now: Time.current)
    @desired_version = desired_version.to_h
    @worker_storage_key = worker_storage_key.to_s.presence
    @hostname = hostname.to_s.presence
    @now = now
  end

  def advance!
    drain = active_drain || create_next_drain
    return result("idle", message: "No macOS workers need an update.") unless drain

    settle_drain!(drain)
  end

  def drain!
    worker = selected_worker || workers.first
    raise ArgumentError, "No matching macOS worker is currently heartbeating." unless worker

    drain = create_or_update_drain(worker)
    result("draining", worker: worker_payload(worker), drain: drain, active_run_count: active_run_count(drain), message: "Worker is draining.")
  end

  def clear!
    drain = selected_drain
    raise ArgumentError, "No matching macOS drain exists." unless drain

    drain.update!(state: MacosWorkerDrain::COMPLETED, completed_at: now, last_error: nil)
    result("completed", drain: drain, message: "Worker drain cleared.")
  end

  def force_terminate!
    drain = selected_drain || drain!.drain
    drain.update!(force_terminate_at: now, metadata: drain.metadata.to_h.merge("force_terminate_requested_at" => now.iso8601))
    result("force_terminate_requested", drain: drain, active_run_count: active_run_count(drain), message: "Worker will restart even if active work remains.")
  end

  private

  attr_reader :desired_version, :worker_storage_key, :hostname, :now

  def settle_drain!(drain)
    worker = worker_for_drain(drain)
    active_count = active_run_count(drain)
    return fail_drain!(drain, "Worker heartbeat is stale or missing.") unless worker
    return fail_drain!(drain, updater_failure_message(worker)) if updater_failed?(worker)

    if active_count.positive? && !drain.force_termination_requested?
      drain.update!(state: MacosWorkerDrain::DRAINING, hostname: worker.hostname, worker_storage_key: worker_storage_key_for(worker))
      return result("waiting_for_active_work", worker: worker_payload(worker), drain: drain, active_run_count: active_count, message: "Waiting for active work to finish.")
    end

    unless worker_at_desired_version?(worker)
      drain.update!(
        state: MacosWorkerDrain::UPDATING,
        hostname: worker.hostname,
        worker_storage_key: worker_storage_key_for(worker),
        update_started_at: drain.update_started_at || now
      )
      return fail_drain!(drain, "Worker did not heartbeat at the desired version before the update timeout.") if drain.update_started_at && drain.update_started_at < now - UPDATE_STALE_AFTER

      return result("updating", worker: worker_payload(worker), drain: drain, active_run_count: active_count, message: "Worker is updating to the desired release.")
    end

    unless smoke_check_passed?(worker)
      return fail_drain!(drain, "Worker heartbeat reached the desired version but did not advertise macOS/Xcode capability.")
    end

    drain.update!(state: MacosWorkerDrain::COMPLETED, completed_at: now, last_error: nil)
    result("completed", worker: worker_payload(worker), drain: drain, active_run_count: active_count, message: "Worker updated and passed capability smoke checks.")
  end

  def create_next_drain
    worker = workers.find { |candidate| !worker_at_desired_version?(candidate) }
    return nil unless worker

    create_or_update_drain(worker)
  end

  def create_or_update_drain(worker)
    key = worker_storage_key_for(worker)
    drain = MacosWorkerDrain.for_identity(worker_storage_key: key, hostname: worker.hostname).first ||
      MacosWorkerDrain.new(worker_storage_key: key, hostname: worker.hostname)
    drain.assign_attributes(
      worker_storage_key: key,
      hostname: worker.hostname,
      state: MacosWorkerDrain::DRAINING,
      desired_git_sha: desired_git_sha,
      desired_version: desired_version,
      drain_started_at: drain.drain_started_at || now,
      completed_at: nil,
      failed_at: nil,
      last_error: nil
    )
    drain.save!
    drain
  end

  def fail_drain!(drain, message)
    drain.update!(state: MacosWorkerDrain::FAILED, failed_at: now, last_error: message)
    result("failed", drain: drain, active_run_count: active_run_count(drain), message: message)
  end

  def active_drain
    @active_drain ||= MacosWorkerDrain.where(state: %w[draining updating failed]).order(:created_at).first
  end

  def selected_drain
    MacosWorkerDrain.for_identity(worker_storage_key: worker_storage_key, hostname: hostname).active.first
  end

  def selected_worker
    workers.find do |worker|
      (worker_storage_key.present? && worker_storage_key_for(worker) == worker_storage_key) ||
        (hostname.present? && worker.hostname == hostname)
    end
  end

  def worker_for_drain(drain)
    workers.find do |worker|
      (drain.worker_storage_key.present? && worker_storage_key_for(worker) == drain.worker_storage_key) ||
        (drain.hostname.present? && worker.hostname == drain.hostname)
    end
  end

  def workers
    @workers ||= InstanceVersion.fresh.where(role: "worker").order(:hostname).select { |worker| macos_worker?(worker) }
  end

  def macos_worker?(worker)
    Array(WorkerCapabilities.normalize(worker.capabilities)["os"]).map(&:to_s).include?("macos")
  end

  def smoke_check_passed?(worker)
    capabilities = WorkerCapabilities.normalize(worker.capabilities)
    Array(capabilities["os"]).map(&:to_s).include?("macos") &&
      Array(capabilities["toolchains"]).map(&:to_s).include?("xcode")
  end

  def worker_at_desired_version?(worker)
    desired_git_sha.present? && worker.version.to_s == desired_git_sha
  end

  def updater_failed?(worker)
    worker.macos_updater_status.to_h["state"].to_s == "failed"
  end

  def updater_failure_message(worker)
    worker.macos_updater_status.to_h["message"].presence || "Worker updater reported failure."
  end

  def worker_storage_key_for(worker)
    latest_samples_by_hostname[worker.hostname]&.worker_storage_key.presence || worker.hostname
  end

  def latest_samples_by_hostname
    @latest_samples_by_hostname ||= WorkerHostHealthSample
      .worker_role
      .where(hostname: workers.map(&:hostname))
      .order(observed_at: :desc)
      .to_a
      .index_by(&:hostname)
  end

  def active_run_count(drain)
    scope = Run.where(state: "running").joins(step: :workflow).left_outer_joins(:spawned_processes)
    clauses = []
    values = {}
    if drain.hostname.present?
      clauses << "workflows.worker_hostname = :hostname"
      clauses << "(spawned_processes.hostname = :hostname AND spawned_processes.finished_at IS NULL)"
      values[:hostname] = drain.hostname
    end
    if drain.worker_storage_key.present?
      clauses << "workflows.worker_storage_key = :worker_storage_key"
      values[:worker_storage_key] = drain.worker_storage_key
    end
    return 0 if clauses.empty?

    scope.where(clauses.join(" OR "), values).distinct.count
  end

  def desired_git_sha
    @desired_git_sha ||= desired_version["git_sha"].presence || desired_version[:git_sha].presence
  end

  def remaining_worker_count
    workers.count { |worker| !worker_at_desired_version?(worker) }
  end

  def worker_payload(worker)
    return nil unless worker

    {
      hostname: worker.hostname,
      worker_storage_key: worker_storage_key_for(worker),
      version: worker.version,
      desired_version: worker.desired_version || {},
      macos_updater_state: worker.macos_updater_state,
      capabilities: worker.capabilities || {},
      last_heartbeat_at: worker.last_heartbeat_at&.iso8601
    }
  end

  def result(state, worker: nil, drain: nil, active_run_count: nil, message:)
    Result.new(
      state: state,
      worker: worker,
      drain: drain,
      message: message,
      active_run_count: active_run_count,
      remaining_worker_count: remaining_worker_count
    )
  end
end
