class RunQueueResolver
  BLOCKED_OUTCOME = "no_capable_worker".freeze
  DEFAULT_RUN_CAPABILITIES = { "os" => [ "linux" ] }.freeze
  ARCH_MATCH_ALIASES = {
    "amd64" => %w[amd64 x86_64 x64],
    "x86_64" => %w[amd64 x86_64 x64],
    "x64" => %w[amd64 x86_64 x64],
    "arm64" => %w[arm64 aarch64],
    "aarch64" => %w[arm64 aarch64]
  }.freeze

  Decision = Data.define(:queue_name, :requirements, :sticky_resume, :blocked_reason, :details) do
    def blocked? = blocked_reason.present?
  end

  def self.resolve(...) = new(...).resolve

  def initialize(run:)
    @run = run
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

  attr_reader :run

  def compatible_resume_queue(requirements)
    queue = run.resume_worker_queue
    return nil if queue.blank?
    return queue if requirements.blank? || requirements == DEFAULT_RUN_CAPABILITIES || live_capable_worker_for?(queue, requirements)

    nil
  end

  def blocked_reason_for(queue, requirements)
    return nil unless capability_specific_queue?(queue)
    return nil if live_capable_worker_for?(queue, requirements)

    "no_live_worker_for_capabilities"
  end

  def required_capabilities
    raw = if run.distributed_parallel_run?
      run.step&.details.to_h["capabilities"].presence || run.step&.details.to_h["required_capabilities"].presence
    else
      run.workflow&.planned_execution_capabilities
    end

    WorkerCapabilities.normalize(raw.presence || DEFAULT_RUN_CAPABILITIES)
  end

  def capability_queue_name(requirements)
    return nil unless capability_specific_requirements?(requirements)

    os = single_token(requirements["os"])
    return nil if os.blank? || os == TargetGraph::ExecutionCapabilities::CONFLICTING_WILDCARD

    arch = single_token(requirements["arch"])
    arch = WorkerCapabilities::DEFAULT_QUEUE_ARCH_BY_OS[os] if arch.blank?
    return nil if arch.blank? || arch == TargetGraph::ExecutionCapabilities::CONFLICTING_WILDCARD

    [ base_queue_name, queue_token(os), queue_arch_token(arch) ].join("-")
  end

  def capability_specific_requirements?(requirements)
    return false if requirements.blank?
    return false if requirements == DEFAULT_RUN_CAPABILITIES

    requirements["os"].present? || requirements["arch"].present?
  end

  def capability_specific_queue?(queue)
    queue.to_s.start_with?("#{base_queue_name}-")
  end

  def base_queue_name
    @base_queue_name ||= Workflows.for(trigger_kind: run.workflow&.trigger_kind || run.trigger_kind).queue_name.to_s
  end

  def live_capable_worker_for?(queue, requirements)
    live_worker_payloads.any? do |payload|
      WorkerQueueTopology.queues_include?(payload.fetch(:queues), queue) &&
        satisfies?(payload.fetch(:capabilities), requirements)
    end
  end

  def live_worker_payloads
    @live_worker_payloads ||= SolidQueue::Process.where.not(last_heartbeat_at: nil).filter_map do |process|
      next if process.last_heartbeat_at < InstanceVersion::HEARTBEAT_STALE_THRESHOLD.ago

      {
        queues: InstanceVersion.queue_names(process.metadata&.dig("queues")),
        capabilities: WorkerCapabilities.normalize(process.metadata&.dig("capabilities").presence || instance_for_process(process)&.capabilities)
      }
    end
  rescue NameError, ActiveRecord::StatementInvalid
    []
  end

  def instance_for_process(process)
    hostname = process.metadata&.dig("hostname")
    return nil if hostname.blank?

    InstanceVersion.fresh.where(hostname: hostname, role: "worker").first
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

    acceptable = dimension == "arch" ? ARCH_MATCH_ALIASES.fetch(required, [ required ]) : [ required ]
    (worker_values & acceptable).any?
  end

  def details_for(queue, requirements)
    {
      "queue_name" => queue,
      "base_queue_name" => base_queue_name,
      "requirements" => requirements,
      "run_id" => run.id,
      "workflow_id" => run.workflow_id,
      "step_id" => run.step_id,
      "step_kind" => run.step&.kind
    }.compact
  end

  def single_token(values)
    Array(values).first.to_s.presence
  end

  def queue_token(value)
    value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")
  end

  def queue_arch_token(value)
    WorkerCapabilities::ARCH_QUEUE_ALIASES.fetch(value.to_s, queue_token(value))
  end
end
