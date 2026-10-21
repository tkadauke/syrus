module PlannedExecutionOverrides
class Operation
  Unsafe = Class.new(ArgumentError)
  Result = Data.define(:eligible, :reason, :job, :workflow, :runs, :profile, :before, :after, :worker_available, :audit) do
    def as_json(*)
      {
        eligible: eligible,
        refusal_reason: reason,
        job: job && { id: job.id, slug: job.slug },
        workflow: workflow && { id: workflow.id, slug: workflow.slug },
        runs: runs.map { |run| { id: run.id, slug: run.slug, state: run.state } },
        profile: profile&.name,
        current_placement: before,
        proposed_placement: after,
        worker_available: worker_available,
        planned_repair: eligible ? "Update the Job#{workflow ? ' and queued initial Workflow' : ''} atomically, record an audit event, and re-resolve queued Run placement." : nil,
        audit_id: audit&.id
      }
    end
  end

  def initialize(job:, profile:, actor:, reason:, provenance:, expected_revision: nil)
    @job = job
    @profile = ExecutionPlacementProfile.fetch(profile)
    @actor = actor
    @reason = reason.to_s.strip
    @provenance = provenance
    @expected_revision = expected_revision
    raise ArgumentError, "audit reason is required" if @reason.blank?
  end

  def inspect
    job.reload
    workflow = initial_workflow
    runs = workflow ? workflow.runs.order(:id).to_a : []
    refusal = refusal_reason(workflow, runs)
    result(!refusal, refusal, workflow, runs)
  end

  def apply!
    queued_runs = []
    workflow_to_start = nil
    outcome = nil
    ApplicationRecord.transaction do
      job.lock!
      if expected_revision.present? && job.entity_revision != expected_revision.to_i
        raise Unsafe, "#{job.slug} changed after the repair was proposed; run a new dry-run and confirm again."
      end
      workflow = initial_workflow
      workflow&.lock!
      runs = workflow ? workflow.runs.lock.order(:id).to_a : []
      refusal = refusal_reason(workflow, runs)
      raise Unsafe, refusal if refusal
      replace_queued_deliveries!(runs.select(&:queued?))

      before = job.planned_execution_json
      replacement = requirement
      replacement.assign_to(job)
      job.save!
      if workflow
        replacement.assign_to(workflow)
        workflow.worker_hostname = nil
        workflow.worker_storage_key = nil
        workflow.save!
      end
      audit = ::PlannedExecutionOverride.create!(
        job: job, workflow: workflow, user: actor, profile: profile.name,
        reason: reason, provenance: provenance, previous_placement: before,
        replacement_placement: replacement.to_h
      )
      queued_runs = runs.select(&:queued?)
      workflow_to_start = workflow if runs.empty?
      outcome = result(true, nil, workflow, runs, audit: audit, before: before)
    end
    queued_runs.each(&:reenqueue!)
    WorkUnits::Launcher.start!(workflow_to_start) if workflow_to_start
    outcome
  end

  private

  attr_reader :job, :profile, :actor, :reason, :provenance, :expected_revision

  def initial_workflow
    job.workflows.where(trigger_kind: "initial").order(:created_at, :id).first
  end

  def refusal_reason(workflow, runs)
    return "Placement cannot be changed once #{job.slug} is #{job.state}; cancel or finish the active work, then create a fresh attempt." unless job.state.in?(%w[triaging backlog queued])
    return nil unless workflow
    return "#{workflow.slug} is #{workflow.state}; placement overrides only support a queued initial Workflow." unless workflow.queued?
    started = runs.find { |run| run.started_at.present? || !run.queued? }
    return "#{started.slug} has already started; retry as a fresh Workflow with the required placement." if started
    if workflow.worker_hostname.present? || workflow.worker_storage_key.present? || WorkflowWorkspace.path_for(workflow).directory?
      return "#{workflow.slug} already has a mutable workspace; retry as a fresh Workflow rather than moving it between hosts."
    end
    nil
  end

  def requirement
    PlannedExecutionRequirement.new(capabilities: profile.capabilities, source: "operator_confirmed")
  end

  def replace_queued_deliveries!(runs)
    return if runs.empty? || !defined?(SolidQueue::Job) || !SolidQueue::Job.table_exists?

    queue_jobs = SolidQueue::Job.where(class_name: "RunJob", finished_at: nil).lock
    ids = runs.flat_map { |run| SolidQueueRunJobQuery.matching(scope: queue_jobs, run_id: run.id).pluck(:id) }.uniq
    return if ids.empty?

    claimed = SolidQueue::ClaimedExecution.where(job_id: ids).pluck(:job_id)
    if claimed.any?
      raise Unsafe, "Queued work is already claimed by a worker; retry as a fresh Workflow after it stops."
    end

    SolidQueue::ReadyExecution.where(job_id: ids).delete_all if defined?(SolidQueue::ReadyExecution)
    SolidQueue::ScheduledExecution.where(job_id: ids).delete_all if defined?(SolidQueue::ScheduledExecution)
    SolidQueue::BlockedExecution.where(job_id: ids).delete_all if defined?(SolidQueue::BlockedExecution)
    SolidQueue::FailedExecution.where(job_id: ids).delete_all if defined?(SolidQueue::FailedExecution)
    SolidQueue::Job.where(id: ids).delete_all
  end

  def worker_available
    workflow = Workflow.new(job: job, trigger_kind: "initial", planned_execution_capabilities: profile.capabilities)
    step = Step.new(workflow: workflow, kind: "prepare", placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE, details: {})
    !RunQueueResolver.resolve_candidate(workflow: workflow, step: step).blocked?
  rescue StandardError
    nil
  end

  def result(eligible, refusal, workflow, runs, audit: nil, before: job.planned_execution_json)
    Result.new(eligible:, reason: refusal, job:, workflow:, runs:, profile:, before:, after: requirement.to_h, worker_available:, audit:)
  end
end
end
