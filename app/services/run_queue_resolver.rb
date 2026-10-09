class RunQueueResolver
  BLOCKED_OUTCOME = "no_capable_worker".freeze
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
  end

  def self.resolve(...) = new(...).resolve

  def self.resolve_candidate(workflow:, step:)
    new(workflow: workflow, step: step).resolve
  end

  def initialize(run: nil, workflow: nil, step: nil)
    @run = run || Candidate.new(workflow: workflow, step: step, trigger_kind: workflow&.trigger_kind)
    @workflow = workflow || run&.workflow
    @step = step || run&.step
    @trigger_kind = @workflow&.trigger_kind || run&.trigger_kind
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
    queue = run.resume_worker_queue
    return nil if queue.blank?
    return queue if requirements == DEFAULT_RUN_CAPABILITIES
    return queue if live_capable_worker_for?(queue, requirements, allow_unknown_default: true)

    nil
  end

  def blocked_reason_for(queue, requirements)
    return nil unless live_capability_check_required?(queue, requirements)
    return nil if live_capable_worker_for?(queue, requirements)

    "no_live_worker_for_capabilities"
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

    arch = default_queue_arch_for(os)
    return nil if arch.blank? || arch == TargetGraph::ExecutionCapabilities::CONFLICTING_WILDCARD

    queue = [ base_queue_name, queue_token(os), queue_arch_token(arch) ].join("-")
    return queue if live_capable_worker_for?(queue, requirements)
    return nil if requirements == DEFAULT_RUN_CAPABILITIES && live_capable_worker_for?(base_queue_name, requirements)

    queue
  end

  def capability_specific_requirements?(requirements)
    return false if requirements.blank?
    return false if requirements == DEFAULT_RUN_CAPABILITIES && !explicit_target_requirements?

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

  def live_capable_worker_for?(queue, requirements, allow_unknown_default: false)
    live_worker_payloads.any? do |payload|
      next false unless WorkerQueueTopology.queues_include?(payload.fetch(:queues), queue)
      next false if payload.fetch(:macos_worker, false) && MacosWorkerDrain.admission_blocked?(
        worker_storage_key: payload[:worker_storage_key],
        hostname: payload[:hostname]
      )

      capabilities = payload.fetch(:capabilities)
      next true if allow_unknown_default && requirements == DEFAULT_RUN_CAPABILITIES && capabilities.blank?

      satisfies?(capabilities, requirements)
    end
  end

  def live_worker_payloads
    @live_worker_payloads ||= solid_queue_worker_payloads + legacy_instance_worker_payloads
  end

  def solid_queue_worker_payloads
    SolidQueue::Process.where.not(last_heartbeat_at: nil).filter_map do |process|
      next if process.last_heartbeat_at < InstanceVersion::HEARTBEAT_STALE_THRESHOLD.ago

      capabilities = capabilities_for_process(process)
      {
        hostname: process.metadata&.dig("hostname").presence || process.hostname,
        worker_storage_key: process.metadata&.dig("worker_storage_key").presence || latest_sample_for(process)&.worker_storage_key,
        queues: InstanceVersion.queue_names(process.metadata&.dig("queues")),
        capabilities: capabilities,
        macos_worker: macos_worker_capabilities?(capabilities)
      }
    end
  rescue NameError, ActiveRecord::StatementInvalid
    []
  end

  def legacy_instance_worker_payloads
    InstanceVersion.fresh.where(role: "worker").map do |instance|
      capabilities = WorkerCapabilities.normalize(instance.capabilities)
      {
        hostname: instance.hostname,
        worker_storage_key: latest_sample_by_hostname[instance.hostname]&.worker_storage_key,
        queues: [ Workflow.resume_queue_name(instance.hostname) ],
        capabilities: capabilities,
        macos_worker: macos_worker_capabilities?(capabilities)
      }
    end
  end

  def instance_for_process(process)
    hostname = process.metadata&.dig("hostname")
    return nil if hostname.blank?

    InstanceVersion.fresh.where(hostname: hostname, role: "worker").first
  end

  def latest_sample_for(process)
    latest_sample_by_hostname[process.metadata&.dig("hostname").presence || process.hostname]
  end

  def latest_sample_by_hostname
    @latest_sample_by_hostname ||= WorkerHostHealthSample
      .worker_role
      .where("observed_at >= ?", InstanceVersion::HEARTBEAT_STALE_THRESHOLD.ago)
      .order(observed_at: :desc)
      .to_a
      .index_by(&:hostname)
  end

  def capabilities_for_process(process)
    WorkerCapabilities.normalize(process.metadata&.dig("capabilities").presence || instance_for_process(process)&.capabilities)
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
      "run_id" => run.id,
      "workflow_id" => run.workflow_id,
      "step_id" => run.step_id,
      "step_kind" => step&.kind,
      "placement_policy" => step&.placement_policy
    }.compact
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
