class RunQueueResolver
  BLOCKED_OUTCOME = "no_capable_worker".freeze
  # Every worker that could take the step reports a failed environment smoke
  # check the step needs (WorkerEnvironmentSmoke). Same outcome as a missing
  # capability -- a wait, not a failure -- with the failing checks in the
  # decision details so an operator sees which worker is broken and why.
  ENVIRONMENT_CHECK_BLOCKED_REASON = "worker_environment_check_failed".freeze
  DEFAULT_RUN_CAPABILITIES = { "os" => [ "linux" ] }.freeze

  Candidate = Data.define(:workflow, :step, :trigger_kind) do
    def distributed_parallel_run?
      step&.placement_policy == Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT &&
        workflow&.job&.repository.present? &&
        Feature.distributed_workflow_dag_enabled?(workflow.job.repository)
    end

    def resume_worker_queue
      return nil if distributed_parallel_run?

      storage_key = workflow&.worker_storage_key.presence
      if storage_key.present?
        queue = Workflow.resume_queue_name(storage_key)
        return queue if InstanceVersion.worker_queue_live?(queue)
        return nil
      end

      host = workflow&.worker_hostname
      return nil if host.blank?
      return nil unless InstanceVersion.worker_live?(host)

      Workflow.resume_queue_name(host)
    end

    def id = nil
    def workflow_id = workflow&.id
    def step_id = step&.id
  end

  Decision = Data.define(:queue_name, :requirements, :sticky_resume, :blocked_reason, :details) do
    def blocked? = blocked_reason.present?

    # "host: check (reason), ..." for every live worker kept off this step by a
    # failed environment smoke check, or nil.
    def environment_check_summary
      Array(details["live_workers"]).filter_map do |worker|
        failures = worker["environment_check_failures"]
        next if failures.blank?

        "#{worker['hostname']}: #{failures.map { |name, reason| reason.present? ? "#{name} (#{reason})" : name }.join(', ')}"
      end.uniq.join("; ").presence
    end

    def history_details
      details.merge(
        "live_workers" => Array(details["live_workers"]).map do |worker|
          worker.slice("hostname", "worker_storage_key", "selected_queue", "eligible", "draining", "environment_check_failures")
        end
      )
    end
  end

  def self.resolve(...) = new(...).resolve

  # Whether the worker this process runs on satisfies what `run` requires.
  def self.locally_satisfied?(run:)
    new(run: run).locally_satisfied?
  end

  # Also false when this worker's own environment smoke report failed a check
  # the step needs, so RunJob hands the Run back to a worker that can run it
  # instead of starting it here and failing.
  #
  # A requirement that merely defaults to Linux is a preference, not a
  # contract: it sends the work elsewhere only when a live worker can take it
  # there. Otherwise a worker that serves the shared queue alone -- a single
  # Mac install, or local development -- handed every such Run back to itself.
  def locally_satisfied?
    snapshot = WorkerCapabilities.current
    requirements = required_capabilities
    unless satisfies?(WorkerCapabilities.normalize(snapshot.fetch(:capabilities)), requirements)
      return false unless defaulted_requirements?(requirements)
      return false if live_capable_worker_for?(capability_queue_name(requirements) || base_queue_name, requirements)
    end

    report = snapshot.fetch(:diagnostics, {})[WorkerEnvironmentSmoke::DIAGNOSTIC_KEY]
    environment_failures_for(SyrusVersion.hostname, report).empty?
  end

  # Whether `hostname` is kept off `run` by its environment -- a failed smoke
  # check the step needs or a dependency an earlier failure there showed
  # missing. The work-engine simulator asks it for simulated hosts.
  def self.worker_environment_blocks?(run:, hostname:)
    resolver = new(run: run)
    payload = resolver.send(:live_worker_payloads).find { |candidate| candidate[:hostname] == hostname }
    resolver.send(:environment_failures_for, hostname, payload && resolver.send(:smoke_report_for, payload)).any?
  end

  def self.resolve_candidate(workflow:, step:)
    new(workflow: workflow, step: step).resolve
  end

  # Is a live worker serving `queue` able to satisfy `requirements`? Used to
  # release a LandingCapabilityHold recorded from an earlier blocked Decision.
  def self.live_capable_worker?(queue:, requirements:)
    new.send(:live_capable_worker_for?, queue, WorkerCapabilities.normalize(requirements))
  end

  def initialize(run: nil, workflow: nil, step: nil, ignore_workflow_affinity: false)
    @run = run || Candidate.new(workflow: workflow, step: step, trigger_kind: workflow&.trigger_kind)
    @workflow = workflow || run&.workflow
    @step = step || run&.step
    @trigger_kind = @workflow&.trigger_kind || run&.trigger_kind
    @ignore_workflow_affinity = ignore_workflow_affinity
  end

  def resolve
    requirements = required_capabilities
    if (resume_queue = compatible_resume_queue(requirements))
      return Decision.new(
        queue_name: resume_queue,
        requirements: requirements,
        sticky_resume: true,
        blocked_reason: nil,
        details: details_for(resume_queue, requirements).merge("sticky_resume_queue" => true)
      )
    end

    queue = capability_queue_name(requirements) || base_queue_name
    blocked_reason = blocked_reason_for(queue, requirements)
    Decision.new(
      queue_name: queue,
      requirements: requirements,
      sticky_resume: false,
      blocked_reason: blocked_reason,
      details: details_for(queue, requirements).merge("sticky_resume_queue" => false)
    )
  end

  private

  attr_reader :run, :workflow, :step, :trigger_kind

  def compatible_resume_queue(requirements)
    return nil if @ignore_workflow_affinity

    queue = run.resume_worker_queue
    return nil if queue.blank?
    return queue if live_capable_worker_for?(queue, requirements, allow_unknown_default: true)
    # `resume_worker_queue` already checked storage-affinity liveness. Keep
    # default work sticky when no richer capability heartbeat is available.
    return queue if defaulted_requirements?(requirements) && !live_worker_payload_for_queue?(queue)

    nil
  end

  def blocked_reason_for(queue, requirements)
    unless live_capability_check_required?(queue, requirements)
      return environment_checks_block_queue?(queue, requirements) ? ENVIRONMENT_CHECK_BLOCKED_REASON : nil
    end
    return nil if live_capable_worker_for?(queue, requirements)
    return ENVIRONMENT_CHECK_BLOCKED_REASON if live_capable_worker_for?(queue, requirements, ignore_environment_checks: true)

    "no_live_worker_for_capabilities"
  end

  # Default (Linux) work skips the live capability check -- any worker on the
  # shared queue may take it -- so a smoke failure blocks it only when every
  # live worker that would otherwise qualify reports a failure the step
  # needs. A worker with no report, or one that does not report a needed check,
  # still counts as able: unknown never reads as broken.
  def environment_checks_block_queue?(queue, requirements)
    return false if required_environment_checks.empty?

    candidates = live_worker_payloads.select do |payload|
      worker_eligible?(payload, queue, requirements, allow_unknown_default: true, ignore_environment_checks: true)
    end
    candidates.any? && candidates.all? { |payload| environment_check_failures(payload).any? }
  end

  def required_environment_checks
    @required_environment_checks ||= WorkerEnvironmentSmoke::Requirements.for(
      workflow: workflow, step: step, run: run
    )
  rescue StandardError => e
    Rails.logger.warn("[RunQueueResolver] environment check requirements failed: #{e.class}: #{e.message}")
    @required_environment_checks = []
  end

  # The one view of a worker's environment for this step: the checks its
  # smoke report (WorkerEnvironmentSmoke) failed that the step needs, plus
  # what a failed install on that worker showed missing for this repository
  # (WorkerEnvironmentGap). A probe and a failure that find the same thing
  # name the same check, so they keep a worker off work identically, and one
  # hold reason (ENVIRONMENT_CHECK_BLOCKED_REASON) covers both.
  def environment_check_failures(payload)
    environment_failures_for(payload[:hostname], smoke_report_for(payload))
  end

  def environment_failures_for(hostname, report)
    (WorkerEnvironmentSmoke.blocking_failures(report, required_environment_checks) |
      observed_environment_gaps(hostname, report).keys)
  end

  # check name => reason for the gaps a failed install recorded on `hostname`
  # for this repository. A gap stops counting once the worker's own smoke
  # report passes that same check after the gap was found.
  def observed_environment_gaps(hostname, report)
    return {} if hostname.blank?

    @observed_environment_gaps ||= {}
    @observed_environment_gaps[[ hostname, report.is_a?(Hash) ? report["observed_at"] : nil ]] ||=
      WorkerEnvironmentGap.failed_checks(
        hostname: hostname, repository_id: repository_id, smoke_report: report, prepare_targets: step_prepare_targets
      )
  rescue ActiveRecord::ActiveRecordError => e
    Rails.logger.warn("[RunQueueResolver] could not read worker environment gaps: #{e.class}: #{e.message}")
    {}
  end

  def repository_id
    workflow&.job&.repository_id
  end

  def step_prepare_targets
    Array(step&.details.to_h["prepare_targets"]).filter_map { |target| target.to_h["target_label"].presence }
  end

  def smoke_report_for(payload)
    diagnostics = payload[:capability_diagnostics]
    diagnostics.is_a?(Hash) ? diagnostics[WorkerEnvironmentSmoke::DIAGNOSTIC_KEY] : nil
  end

  def required_capabilities
    raw = if target_step_requirements?
      target_requirement_payload
    elsif workflow_primary_requirements?
      workflow&.planned_execution_capabilities
    end

    WorkerCapabilities.normalize(raw.presence || DEFAULT_RUN_CAPABILITIES)
  end

  def capability_queue_name(requirements)
    return nil unless capability_specific_requirements?(requirements)

    os = single_token(requirements["os"])
    return nil if os.blank? || os == TargetGraph::ExecutionCapabilities::CONFLICTING_WILDCARD
    return nil if os == "linux"

    arch = single_token(requirements["arch"]).presence || default_queue_arch_for(os)
    return nil if arch.blank? || arch == TargetGraph::ExecutionCapabilities::CONFLICTING_WILDCARD

    [ base_queue_name, queue_token(os), queue_arch_token(arch) ].join("-")
  end

  def capability_specific_requirements?(requirements)
    return false if requirements.blank?
    return false if requirements == DEFAULT_RUN_CAPABILITIES

    requirements["os"].present?
  end

  def capability_specific_queue?(queue)
    queue.to_s.start_with?("#{base_queue_name}-")
  end

  def live_capability_check_required?(queue, requirements)
    capability_specific_queue?(queue) || !defaulted_requirements?(requirements)
  end

  def defaulted_requirements?(requirements)
    return true if default_step_requirements?
    return false if explicit_target_requirements?
    return true if requirements == DEFAULT_RUN_CAPABILITIES

    false
  end

  def default_step_requirements?
    !target_step_requirements? && !workflow_primary_requirements?
  end

  def explicit_target_requirements?
    target_step_requirements? && target_requirement_payload.present?
  end

  def target_requirement_payload
    details = step&.details.to_h
    details["required_capabilities"].presence || details["capabilities"].presence
  end

  def target_step_requirements?
    run.distributed_parallel_run?
  end

  def workflow_primary_requirements?
    step&.placement_policy == Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
  end

  def base_queue_name
    @base_queue_name ||= Workflows.for(trigger_kind: trigger_kind).queue_name.to_s
  end

  def live_capable_worker_for?(queue, requirements, allow_unknown_default: false, ignore_environment_checks: false)
    live_worker_payloads.any? do |payload|
      worker_eligible?(payload, queue, requirements, allow_unknown_default:, ignore_environment_checks:)
    end
  end

  def live_worker_payload_for_queue?(queue)
    live_worker_payloads.any? do |payload|
      WorkerQueueTopology.queues_include?(payload.fetch(:queues), queue)
    end
  end

  def live_worker_payloads
    @live_worker_payloads ||= solid_queue_worker_payloads + legacy_instance_worker_payloads
  end

  def solid_queue_worker_payloads
    SolidQueue::Process.where.not(last_heartbeat_at: nil).filter_map do |process|
      next if process.last_heartbeat_at < InstanceVersion::HEARTBEAT_STALE_THRESHOLD.ago
      next if Syrus::QueueDrain.draining?(process)

      capabilities = capabilities_for_process(process)
      {
        hostname: process.metadata&.dig("hostname").presence || process.hostname,
        worker_storage_key: process.metadata&.dig("worker_storage_key").presence || latest_sample_for(process)&.worker_storage_key,
        queues: InstanceVersion.queue_names(process.metadata&.dig("queues")),
        capabilities: capabilities,
        capability_diagnostics: capability_diagnostics_for_process(process),
        macos_worker: macos_worker_capabilities?(capabilities)
      }
    end
  rescue NameError, ActiveRecord::StatementInvalid
    []
  end

  def legacy_instance_worker_payloads
    fresh_worker_instances_by_hostname.each_value.map do |instance|
      capabilities = WorkerCapabilities.normalize(instance.capabilities)
      {
        hostname: instance.hostname,
        worker_storage_key: latest_sample_by_hostname[instance.hostname]&.worker_storage_key,
        queues: [ Workflow.resume_queue_name(instance.hostname) ],
        capabilities: capabilities,
        capability_diagnostics: instance.capability_diagnostics || latest_sample_by_hostname[instance.hostname]&.capability_diagnostics || {},
        macos_worker: macos_worker_capabilities?(capabilities)
      }
    end
  end

  def instance_for_process(process)
    hostname = process.metadata&.dig("hostname").presence || process.hostname
    return nil if hostname.blank?

    fresh_worker_instances_by_hostname[hostname]
  end

  def fresh_worker_instances_by_hostname
    @fresh_worker_instances_by_hostname ||= InstanceVersion.fresh
      .where(role: "worker")
      .order(:id)
      .each_with_object({}) { |instance, instances| instances[instance.hostname] ||= instance }
  end

  def latest_sample_for(process)
    latest_sample_by_hostname[process.metadata&.dig("hostname").presence || process.hostname]
  end

  def latest_sample_by_hostname
    @latest_sample_by_hostname ||= WorkerHostHealthSample
      .worker_role
      .where("observed_at >= ?", InstanceVersion::HEARTBEAT_STALE_THRESHOLD.ago)
      .order(observed_at: :desc, id: :desc)
      .to_a
      .group_by(&:hostname)
      .transform_values(&:first)
  end

  def capabilities_for_process(process)
    WorkerCapabilities.normalize(
      process.metadata&.dig("capabilities").presence ||
        instance_for_process(process)&.capabilities ||
        latest_sample_for(process)&.capabilities
    )
  end

  def capability_diagnostics_for_process(process)
    process.metadata&.dig("capability_diagnostics").presence ||
      instance_for_process(process)&.capability_diagnostics ||
      latest_sample_for(process)&.capability_diagnostics ||
      {}
  end

  def macos_worker_capabilities?(capabilities)
    Array(capabilities["os"]).map(&:to_s).include?("macos")
  end

  def satisfies?(worker_capabilities, requirements)
    requirements.all? do |dimension, required_values|
      worker_values = Array(worker_capabilities[dimension]).map(&:to_s)
      Array(required_values).all? { |required| value_satisfied?(dimension, worker_values, required) }
    end
  end

  def value_satisfied?(dimension, worker_values, required)
    required = required.to_s
    return true if required == TargetGraph::ExecutionCapabilities::CONFLICTING_WILDCARD
    return true if worker_values.include?(TargetGraph::ExecutionCapabilities::CONFLICTING_WILDCARD)

    worker_values.include?(required)
  end

  def details_for(queue, requirements)
    {
      "queue_name" => queue,
      "base_queue_name" => base_queue_name,
      "requirements" => requirements,
      "environment_checks" => required_environment_checks,
      "live_workers" => live_worker_diagnostics(queue, requirements),
      "run_id" => run.id,
      "workflow_id" => run.workflow_id,
      "step_id" => run.step_id,
      "step_kind" => step&.kind,
      "placement_policy" => step&.placement_policy
    }.compact
  end

  def live_worker_diagnostics(queue, requirements)
    live_worker_payloads.map do |payload|
      {
        "hostname" => payload[:hostname],
        "worker_storage_key" => payload[:worker_storage_key],
        "queues" => payload.fetch(:queues),
        "selected_queue" => WorkerQueueTopology.queues_include?(payload.fetch(:queues), queue),
        "eligible" => worker_eligible?(payload, queue, requirements, allow_unknown_default: defaulted_requirements?(requirements)),
        "draining" => payload.fetch(:macos_worker, false) && MacosWorkerDrain.admission_blocked?(
          worker_storage_key: payload[:worker_storage_key],
          hostname: payload[:hostname]
        ),
        "version_skew" => payload.fetch(:macos_worker, false) && macos_version_skewed?(payload[:hostname]),
        "environment_check_failures" => environment_check_failure_details(payload),
        "capabilities" => payload.fetch(:capabilities),
        "capability_diagnostics" => payload.fetch(:capability_diagnostics)
      }.compact
    end
  end

  # name => reason for each failed check this step needs, or nil.
  def environment_check_failure_details(payload)
    failures = environment_check_failures(payload)
    return nil if failures.empty?

    report = smoke_report_for(payload)
    WorkerEnvironmentSmoke.failure_reasons(report, failures)
      .merge(observed_environment_gaps(payload[:hostname], report)) { |_name, probe, gap| probe.presence || gap }
  end

  def worker_eligible?(payload, queue, requirements, allow_unknown_default: false, ignore_environment_checks: false)
    return false unless WorkerQueueTopology.queues_include?(payload.fetch(:queues), queue)
    return false if !ignore_environment_checks && environment_check_failures(payload).any?
    return false if payload.fetch(:macos_worker, false) && MacosWorkerDrain.admission_blocked?(
      worker_storage_key: payload[:worker_storage_key],
      hostname: payload[:hostname]
    )
    return false if payload.fetch(:macos_worker, false) && macos_version_skewed?(payload[:hostname])

    capabilities = payload.fetch(:capabilities)
    return true if allow_unknown_default && requirements == DEFAULT_RUN_CAPABILITIES && capabilities.blank?

    satisfies?(capabilities, requirements)
  end

  # A Mac worker that has not yet installed the active macOS worker release
  # is not capacity: it would run another revision's code against this
  # revision's schema (and RunJob would hand the Run back anyway).
  def macos_version_skewed?(hostname)
    desired = desired_macos_git_sha
    return false if desired.blank?

    instance = fresh_worker_instances_by_hostname[hostname]
    return false if instance.nil? || instance.version.blank?

    !MacosWorkerRelease.same_revision?(instance.version, desired)
  end

  def desired_macos_git_sha
    return @desired_macos_git_sha if defined?(@desired_macos_git_sha)

    @desired_macos_git_sha = MacosWorkerRelease.desired_git_sha
  end

  def single_token(values)
    Array(values).first.to_s.presence
  end

  def default_queue_arch_for(os)
    WorkerCapabilities::DEFAULT_QUEUE_ARCH_BY_OS[os]
  end

  def queue_token(value)
    value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
  end

  def queue_arch_token(value)
    WorkerCapabilities::ARCH_QUEUE_ALIASES.fetch(value.to_s, queue_token(value))
  end
end
