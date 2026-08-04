class WorkflowAdmissionBudget
  Decision = Data.define(:action, :reason, :pressure, :delay_until, :override, :details) do
    def admit?
      action.in?(%w[admit_now admit_low_risk_only])
    end

    def requires_override?
      action == "requires_override"
    end

    def delay?
      action == "delay_until"
    end

    def artifact
      {
        "action" => action,
        "reason" => reason,
        "pressure" => pressure,
        "delay_until" => delay_until&.iso8601,
        "override" => override,
        "details" => details
      }.compact
    end
  end

  ACTIONS = %w[admit_now delay_until admit_low_risk_only requires_override].freeze
  SOFT_DELAY = 10.minutes
  HOST_SAMPLE_WINDOW = 2.minutes
  ACTIVE_WORKFLOW_WINDOW = 90.minutes
  MAX_REPOSITORY_ACTIVE_WORKFLOWS = 2
  HIGH_COST_SECONDS = 20.minutes.to_i
  LOW_RISK_SECONDS = 8.minutes.to_i
  LOW_RISK_PRESSURE = 35.0
  CPU_BUDGET = 100.0
  IO_BUDGET = 100.0
  MEMORY_BUDGET = 92.0
  HARD_MEMORY_USED_PERCENT = 96.0
  HARD_DATA_ROOT_USED_PERCENT = 96.0
  SOFT_HOST_PRESSURE = 85.0

  def self.call(...) = new(...).call

  def initialize(workflow:, step: nil, now: Time.current)
    @workflow = workflow
    @step = step
    @job = workflow.job
    @repository = @job.repository
    @now = now
  end

  def call
    return admit("non_admitted_queue") unless admission_controlled_workflow?

    candidate = predicted_candidate_pressure
    active = active_workflow_pressure
    pressure = pressure_payload(candidate:, active:)
    hard_reason = hard_host_pressure_reason

    if hard_reason
      return decision("requires_override", hard_reason, pressure, details: details_payload(candidate, active, decision_basis: "ambient_pressure"))
    end

    if soft_host_pressure? && !urgent?
      return low_risk_or_delay("worker_host_pressure_high", candidate, active, pressure, decision_basis: "ambient_pressure")
    end

    if bootstrap_missing_profiles?(candidate)
      return admit("bootstrap_missing_profiles", pressure)
    end

    if over_budget?(pressure) && !urgent?
      return low_risk_or_delay("predicted_budget_pressure_high", candidate, active, pressure, decision_basis: "predicted_command_cost")
    end

    if pending_high_cost_work?(active) && high_cost?(candidate) && medium_or_lower? && !urgent?
      return delay("pending_high_cost_work", pressure, details: details_payload(candidate, active, decision_basis: "predicted_command_cost"))
    end

    if repository_active_workflow_count >= MAX_REPOSITORY_ACTIVE_WORKFLOWS && pending_high_cost_work?(active) && !urgent?
      return low_risk_or_delay("repository_concurrency_budget_exhausted", candidate, active, pressure, decision_basis: "predicted_command_cost")
    end

    urgent? && pressure_detected?(pressure) ? urgent_override("urgent_priority_override", pressure) : admit("within_budget", pressure)
  end

  private

  attr_reader :workflow, :job, :repository, :now, :step

  def admission_controlled_workflow?
    queue_name.in?(%i[runs merges]) && !workflow.infrastructure_workflow?
  end

  def queue_name
    Workflow::TriggerKind.template_for(workflow.trigger_kind).queue_name
  rescue ArgumentError
    :runs
  end

  def urgent?
    job.priority == "urgent" || MainHealthChangedService.fix_main_job?(job)
  end

  def medium_or_lower?
    %w[medium low].include?(job.priority.to_s)
  end

  def predicted_candidate_pressure
    step ? predicted_pressure_for_step(step) : predicted_pressure_for(workflow)
  end

  def predicted_pressure_for(candidate_workflow, remaining_only: false)
    step_kinds = step_kinds_for(candidate_workflow, remaining_only:)
    pressure_from_profiles(step_kinds, profiles_for(candidate_workflow, step_kinds:))
  end

  def predicted_pressure_for_step(candidate_step)
    step_kinds = [ candidate_step.kind ]
    pressure_from_profiles(step_kinds, profiles_for_step(candidate_step))
  end

  def pressure_from_profiles(step_kinds, profiles)
    predictions = predictions_for(step_kinds, profiles)
    duration = predictions.sum { |prediction| prediction.fetch(:duration_seconds).to_f }
    cpu = predictions.sum { |prediction| prediction.fetch(:cpu_pressure).to_f }
    io = predictions.sum { |prediction| prediction.fetch(:io_pressure).to_f }
    memory = predictions.map { |prediction| prediction.fetch(:memory_used_percent).to_f }.max || 0.0
    prediction_sources = predictions.map { |prediction| prediction.fetch(:prediction_source) }.tally
    fallback_reasons = predictions.filter_map { |prediction| prediction.fetch(:fallback_reason) }.uniq
    attribution_confidence_levels = predictions.map { |prediction| prediction.fetch(:attribution_confidence_level) }.uniq

    {
      "duration_seconds" => duration.round,
      "cpu_pressure" => cpu.round(1),
      "io_pressure" => io.round(1),
      "memory_used_percent" => memory.round(1),
      "predicted_command_cost" => {
        "duration_seconds" => duration.round,
        "cpu_pressure" => cpu.round(1),
        "io_pressure" => io.round(1),
        "memory_used_percent" => memory.round(1)
      },
      "prediction_sources" => prediction_sources,
      "primary_prediction_source" => primary_prediction_source(prediction_sources),
      "attribution_confidence_levels" => attribution_confidence_levels,
      "fallback_reasons" => fallback_reasons,
      "confidence_levels" => predictions.map { |prediction| prediction.fetch(:confidence_level) }.uniq,
      "profile_count" => profiles.size,
      "missing_profile_count" => missing_profile_count(predictions),
      "attributed_profile_count" => predictions.count { |prediction| prediction.fetch(:prediction_source) == "command_attributed" },
      "step_kinds" => step_kinds.uniq,
      "high_cost" => duration >= HIGH_COST_SECONDS || cpu >= CPU_BUDGET || io >= IO_BUDGET || memory >= MEMORY_BUDGET
    }
  end

  def primary_prediction_source(sources)
    return "command_attributed" if sources.key?("command_attributed")
    return "host_correlated" if sources.key?("host_correlated")

    "defaults_only"
  end

  def missing_profile_count(predictions)
    predictions.count do |prediction|
      prediction.fetch(:prediction_source) == "defaults_only" && prediction.fetch(:sample_count).zero?
    end
  end

  def step_kinds_for(candidate_workflow, remaining_only:)
    scope = candidate_workflow.steps.order(:position)
    scope = scope.active if remaining_only
    scope.pluck(:kind)
  end

  def profiles_for(candidate_workflow, step_kinds:)
    base = profile_scope_for(candidate_workflow)
    selected = base.where(step_kind: step_kinds, grader_name: "").to_a
    if step_kinds.include?("grader_fanout")
      selected.concat(base.where(step_kind: "grader").to_a)
    end
    if step_kinds.include?("preflight_grader_fanout")
      selected.concat(base.where(step_kind: "preflight_grader").to_a)
    end

    selected
  end

  def profiles_for_step(candidate_step)
    base = profile_scope_for(workflow)
    case candidate_step.kind
    when "grader"
      base.where(step_kind: "grader", grader_name: candidate_step.details.to_h["name"].to_s).to_a
    when "grader_fanout"
      base.where(step_kind: "grader_fanout", grader_name: "").to_a + base.where(step_kind: "grader").to_a
    when "preflight_grader_fanout"
      base.where(step_kind: "preflight_grader_fanout", grader_name: "").to_a + base.where(step_kind: "preflight_grader").to_a
    else
      base.where(step_kind: candidate_step.kind, grader_name: "").to_a
    end
  end

  def profile_scope_for(candidate_workflow)
    candidate_job = candidate_workflow.job
    WorkflowStepResourceProfile.where(
      repository: candidate_job.repository,
      agent_provider: candidate_workflow.agent_provider,
      trigger_kind: candidate_workflow.trigger_kind,
      job_kind: candidate_job.kind.to_s
    )
  end

  def predictions_for(step_kinds, profiles)
    grouped_profiles = profiles.group_by(&:step_kind)
    step_predictions = step_kinds.flat_map do |step_kind|
      matching = grouped_profiles.fetch(step_kind, [])
      matching = [ missing_profile_prediction(step_kind) ] if matching.empty?
      matching.map { |profile| profile.respond_to?(:conservative_prediction) ? profile.conservative_prediction : profile }
    end
    extra_dynamic_predictions = profiles
      .reject { |profile| step_kinds.include?(profile.step_kind) }
      .map(&:conservative_prediction)

    step_predictions + extra_dynamic_predictions
  end

  def missing_profile_prediction(step_kind)
    WorkflowStepResourceProfile::CONSERVATIVE_DEFAULTS.merge(
      prediction_source: "defaults_only",
      fallback_reason: "missing_workflow_step_resource_profile",
      confidence_level: "defaults_only",
      attribution_confidence_level: "defaults_only",
      sample_count: 0,
      attributed_sample_count: 0,
      step_kind: step_kind
    )
  end

  def active_workflow_pressure
    @active_workflow_pressure ||= begin
      workflows = active_workflows_with_runs
        .where.not(id: workflow.id)
        .where.not(job_id: job.id)
        .where(created_at: (now - ACTIVE_WORKFLOW_WINDOW)..)
        .includes(:job)
        .select { |candidate| admission_controlled_active_workflow?(candidate) }

      aggregate_pressure(workflows.map { |candidate| predicted_pressure_for(candidate, remaining_only: true) })
    end
  end

  def admission_controlled_active_workflow?(candidate)
    Workflow::TriggerKind.template_for(candidate.trigger_kind).queue_name.in?(%i[runs merges]) &&
      !candidate.infrastructure_workflow?
  rescue ArgumentError
    true
  end

  def aggregate_pressure(items)
    {
      "duration_seconds" => items.sum { |item| item.fetch("duration_seconds").to_f }.round,
      "cpu_pressure" => items.sum { |item| item.fetch("cpu_pressure").to_f }.round(1),
      "io_pressure" => items.sum { |item| item.fetch("io_pressure").to_f }.round(1),
      "memory_used_percent" => (items.map { |item| item.fetch("memory_used_percent").to_f }.max || 0.0).round(1),
      "high_cost_count" => items.count { |item| item.fetch("high_cost") },
      "workflow_count" => items.size,
      "profile_count" => items.sum { |item| item.fetch("profile_count").to_i },
      "prediction_sources" => items.flat_map { |item| item.fetch("prediction_sources", {}).to_a }
        .each_with_object(Hash.new(0)) { |(source, count), totals| totals[source] += count }
        .to_h
    }
  end

  def pressure_payload(candidate:, active:)
    {
      "candidate" => candidate,
      "active" => active,
      "projected" => {
        "cpu_pressure" => (candidate.fetch("cpu_pressure") + active.fetch("cpu_pressure")).round(1),
        "io_pressure" => (candidate.fetch("io_pressure") + active.fetch("io_pressure")).round(1),
        "memory_used_percent" => [ candidate.fetch("memory_used_percent"), active.fetch("memory_used_percent") ].max.round(1),
        "high_cost_count" => active.fetch("high_cost_count") + (candidate.fetch("high_cost") ? 1 : 0)
      },
      "host" => host_pressure
    }
  end

  def active_run_count
    @active_run_count ||= Run.running_agent_runs.count
  end

  def repository_active_workflow_count
    @repository_active_workflow_count ||= active_workflows_with_runs.joins(:job)
      .where(jobs: { repository_id: repository.id })
      .where.not(id: workflow.id)
      .where.not(job_id: job.id)
      .count
  end

  def active_workflows_with_runs
    Workflow.active
      .left_outer_joins(steps: :runs)
      .where("workflows.state = ? OR runs.state IN (?)", "running", %w[ queued running ])
      .distinct
  end

  def host_pressure
    @host_pressure ||= begin
      samples = latest_worker_samples
      {
        "sample_count" => samples.size,
        "max_cpu_pressure" => samples.map { |sample| [ sample.cpu_pressure_some, sample.cpu_pressure_full ].compact.max.to_f }.max.to_f.round(1),
        "max_io_pressure" => samples.map { |sample| [ sample.io_pressure_some, sample.io_pressure_full ].compact.max.to_f }.max.to_f.round(1),
        "max_memory_used_percent" => samples.map { |sample| sample.memory_used_percent.to_f }.max.to_f.round(1),
        "max_data_root_used_percent" => samples.map { |sample| sample.data_root_used_percent.to_f }.max.to_f.round(1),
        "headroom" => {
          "cpu_pressure" => [ CPU_BUDGET - samples.map { |sample| [ sample.cpu_pressure_some, sample.cpu_pressure_full ].compact.max.to_f }.max.to_f, 0.0 ].max.round(1),
          "io_pressure" => [ IO_BUDGET - samples.map { |sample| [ sample.io_pressure_some, sample.io_pressure_full ].compact.max.to_f }.max.to_f, 0.0 ].max.round(1),
          "memory_used_percent" => [ MEMORY_BUDGET - samples.map { |sample| sample.memory_used_percent.to_f }.max.to_f, 0.0 ].max.round(1),
          "data_root_used_percent" => [ HARD_DATA_ROOT_USED_PERCENT - samples.map { |sample| sample.data_root_used_percent.to_f }.max.to_f, 0.0 ].max.round(1)
        },
        "observed_since" => (now - HOST_SAMPLE_WINDOW).iso8601
      }
    end
  end

  def latest_worker_samples
    cutoff = now - HOST_SAMPLE_WINDOW
    WorkerHostHealthSample.where("observed_at >= ?", cutoff)
      .where("role LIKE ?", "%worker%")
      .order(observed_at: :desc)
      .group_by(&:hostname)
      .values
      .map(&:first)
  end

  def hard_host_pressure_reason
    return "worker_memory_exhausted" if host_pressure.fetch("max_memory_used_percent") >= HARD_MEMORY_USED_PERCENT
    return "worker_disk_exhausted" if host_pressure.fetch("max_data_root_used_percent") >= HARD_DATA_ROOT_USED_PERCENT

    nil
  end

  def soft_host_pressure?
    host_pressure.fetch("max_cpu_pressure") >= SOFT_HOST_PRESSURE ||
      host_pressure.fetch("max_io_pressure") >= SOFT_HOST_PRESSURE ||
      host_pressure.fetch("max_memory_used_percent") >= SOFT_HOST_PRESSURE ||
      host_pressure.fetch("max_data_root_used_percent") >= SOFT_HOST_PRESSURE
  end

  def over_budget?(pressure)
    projected = pressure.fetch("projected")
    projected.fetch("cpu_pressure") >= CPU_BUDGET ||
      projected.fetch("io_pressure") >= IO_BUDGET ||
      projected.fetch("memory_used_percent") >= MEMORY_BUDGET
  end

  def pending_high_cost_work?(active)
    active.fetch("high_cost_count").positive?
  end

  def high_cost?(candidate)
    candidate.fetch("high_cost")
  end

  def bootstrap_missing_profiles?(candidate)
    candidate.fetch("profile_count").zero? &&
      active_workflow_pressure.fetch("profile_count").zero? &&
      !urgent?
  end

  def low_risk?(candidate)
    candidate.fetch("duration_seconds") <= LOW_RISK_SECONDS &&
      candidate.fetch("cpu_pressure") <= LOW_RISK_PRESSURE &&
      candidate.fetch("io_pressure") <= LOW_RISK_PRESSURE &&
      candidate.fetch("memory_used_percent") <= LOW_RISK_PRESSURE
  end

  def low_risk_or_delay(reason, candidate, active, pressure, decision_basis:)
    if low_risk?(candidate)
      decision("admit_low_risk_only", reason, pressure, details: details_payload(candidate, active, decision_basis: decision_basis))
    else
      delay(reason, pressure, details: details_payload(candidate, active, decision_basis: decision_basis))
    end
  end

  def pressure_detected?(pressure)
    pressure.fetch("active").fetch("workflow_count").positive? || soft_host_pressure? || over_budget?(pressure)
  end

  def urgent_override(reason, pressure)
    decision("admit_now", reason, pressure, override: true, details: { "priority" => job.priority })
  end

  def admit(reason, pressure = nil)
    decision("admit_now", reason, pressure || pressure_payload(candidate: predicted_candidate_pressure, active: active_workflow_pressure))
  end

  def delay(reason, pressure, details: {})
    decision("delay_until", reason, pressure, delay_until: now + SOFT_DELAY, details: details)
  end

  def decision(action, reason, pressure, delay_until: nil, override: false, details: {})
    raise ArgumentError, "unknown admission action=#{action.inspect}" unless ACTIONS.include?(action)

    Decision.new(
      action: action,
      reason: reason,
      pressure: pressure,
      delay_until: delay_until,
      override: override,
      details: details
    )
  end

  def details_payload(candidate, active, decision_basis: nil)
    {
      "candidate_high_cost" => candidate.fetch("high_cost"),
      "active_high_cost_count" => active.fetch("high_cost_count"),
      "repository_active_workflow_count" => repository_active_workflow_count,
      "active_run_count" => active_run_count,
      "job_priority" => job.priority,
      "trigger_kind" => workflow.trigger_kind,
      "decision_basis" => decision_basis,
      "prediction_source" => candidate.fetch("primary_prediction_source"),
      "attribution_confidence_levels" => candidate.fetch("attribution_confidence_levels"),
      "fallback_reasons" => candidate.fetch("fallback_reasons")
    }.compact
  end
end
