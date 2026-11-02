module PlannedExecutionOverrides
class Operation
  Unsafe = Class.new(ArgumentError)
  Result = Data.define(:eligible, :reason, :job, :workflow, :runs, :profile, :before, :after, :worker_available, :audit, :dispatch_status, :dispatch_error) do
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
        audit_id: audit&.id,
        dispatch_status: dispatch_status,
        dispatch_error: dispatch_error
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

  PLACEMENT_STATES = %w[triaging backlog blocked_by_epic queued].freeze
  LIGHTWEIGHT_WORKFLOW_COLUMNS = %i[id job_id trigger_kind state worker_hostname worker_storage_key created_at].freeze
  LIGHTWEIGHT_RUN_COLUMNS = %i[id job_id state started_at created_at].freeze

  # `lightweight: true` is for read-only display (the Job detail payload): it
  # leaves the caller's loaded Job and its preloaded associations alone, skips
  # the Workflow and Run history when the Job's state alone rules the override
  # out, and otherwise reads only the history columns the decision needs rather
  # than whole rows (Run diffs and Workflow artifacts are large). The refusal
  # reason is unchanged.
  def inspect(lightweight: false)
    @lightweight = lightweight
    job.reload unless lightweight
    return result(false, refusal_reason([], []), nil, []) if lightweight && !job.state.in?(PLACEMENT_STATES)

    workflows = all_workflows
    runs = all_runs
    workflow = eligible_initial_workflow(workflows)
    refusal = refusal_reason(workflows, runs)
    result(!refusal, refusal, workflow, runs)
  end

  # Whether a live worker could take this profile, without loading the Job's
  # history. Eligibility is a property of the Job, not of the profile, so a
  # caller listing every profile inspects once and asks this for the rest.
  def worker_available? = worker_available

  def apply!
    queued_runs = []
    workflow_to_start = nil
    workflow = nil
    runs = []
    audit = nil
    before = nil
    ApplicationRecord.transaction do
      job.lock!
      if expected_revision.present? && job.entity_revision != expected_revision.to_i
        raise Unsafe, "#{job.slug} changed after the repair was proposed; run a new dry-run and confirm again."
      end
      workflows = all_workflows(lock: true)
      runs = all_runs(lock: true)
      workflow = eligible_initial_workflow(workflows)
      refusal = refusal_reason(workflows, runs)
      raise Unsafe, refusal if refusal

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
    end
    dispatch_status, dispatch_error = dispatch_or_reconcile(queued_runs, workflow_to_start)
    result(true, nil, workflow, runs, audit:, before:, dispatch_status:, dispatch_error:)
  end

  private

  attr_reader :job, :profile, :actor, :reason, :provenance, :expected_revision

  def all_workflows(lock: false)
    scope = job.workflows.order(:created_at, :id)
    scope = scope.select(*LIGHTWEIGHT_WORKFLOW_COLUMNS) if @lightweight
    scope = scope.lock if lock
    scope.to_a
  end

  def all_runs(lock: false)
    scope = job.runs.order(:created_at, :id)
    scope = scope.select(*LIGHTWEIGHT_RUN_COLUMNS) if @lightweight
    scope = scope.lock if lock
    scope.to_a
  end

  def eligible_initial_workflow(workflows)
    workflows.one? && workflows.first.trigger_kind == "initial" ? workflows.first : nil
  end

  def refusal_reason(workflows, runs)
    return "Placement cannot be changed once #{job.slug} is #{job.state}; cancel or finish the active work, then create a fresh attempt." unless job.state.in?(PLACEMENT_STATES)
    if job.state.in?(%w[triaging backlog blocked_by_epic])
      affine_workflow = workflows.find { |workflow| workflow.worker_hostname.present? || workflow.worker_storage_key.present? || WorkflowWorkspace.path_for(workflow).directory? }
      if affine_workflow
        return "#{job.slug} is #{job.state} but #{affine_workflow.slug} already has a mutable workspace or worker assignment; remove the inconsistent host-affine execution state or use a fresh attempt."
      end
      if WorkUnitMember.where(job_id: job.id).exists?
        return "#{job.slug} is #{job.state} but already has WorkUnit execution history; reconcile the inconsistent host-affine execution state or use a fresh attempt."
      end
      return nil if workflows.empty? && runs.empty?

      return "#{job.slug} is #{job.state} but already has Workflow or Run history; use a fresh attempt rather than changing placement on inconsistent execution records."
    end
    return "#{job.slug} is queued without exactly one initial Workflow; reconcile or retry it as a fresh attempt before changing placement." unless workflows.one? && workflows.first.trigger_kind == "initial"

    workflow = workflows.first
    return "#{workflow.slug} is #{workflow.state}; placement overrides only support a queued initial Workflow." unless workflow.queued?
    started = runs.find { |run| run.started_at.present? || !run.queued? }
    return "#{started.slug} has already started; retry as a fresh Workflow with the required placement." if started
    if workflow.worker_hostname.present? || workflow.worker_storage_key.present? || WorkflowWorkspace.path_for(workflow).directory?
      return "#{workflow.slug} already has a mutable workspace; retry as a fresh Workflow rather than moving it between hosts."
    end
    nil
  end

  def dispatch_or_reconcile(queued_runs, workflow_to_start)
    delivery_state = replace_queued_deliveries!(queued_runs)
    # A claimed delivery cannot be replaced safely. RunJob's host-admission
    # preflight reads the newly committed Workflow requirements before it
    # acquires execution, so the claimant either runs on a capable host or
    # reroutes itself to the newly resolved lane.
    return [ "claimed_delivery_revalidating", nil ] if delivery_state == :claimed

    queued_runs.each(&:reenqueue!)
    WorkUnits::Launcher.start!(workflow_to_start) if workflow_to_start
    [ "dispatched", nil ]
  rescue StandardError => e
    Rails.logger.error("[PlannedExecutionOverrides::Operation] replacement dispatch failed for #{job.slug}: #{e.class}: #{e.message}")
    request_reconciliation
    [ "reconciliation_requested", "#{e.class}: #{e.message}" ]
  end

  def request_reconciliation
    WorkEngine::Reconciler.request(source: self.class.name, job: job)
  rescue StandardError => e
    # The queued Run/Workflow remains durable and the every-minute stale-work
    # reconciler will discover the missing delivery even if this immediate
    # request cannot itself be enqueued.
    Rails.logger.error("[PlannedExecutionOverrides::Operation] immediate reconciliation request failed for #{job.slug}: #{e.class}: #{e.message}")
  end

  def requirement
    PlannedExecutionRequirement.new(capabilities: profile.capabilities, source: "operator_confirmed")
  end

  def replace_queued_deliveries!(runs)
    return :none if runs.empty?
    return :unavailable unless defined?(SolidQueue::Job) && SolidQueue::Job.connection.table_exists?(:solid_queue_jobs)

    SolidQueue::Job.transaction do
      queue_jobs = SolidQueue::Job.where(class_name: "RunJob", finished_at: nil).lock
      ids = runs.flat_map { |run| SolidQueueRunJobQuery.matching(scope: queue_jobs, run_id: run.id).pluck(:id) }.uniq
      return :none if ids.empty?
      return :claimed if SolidQueue::ClaimedExecution.where(job_id: ids).exists?

      SolidQueue::ReadyExecution.where(job_id: ids).delete_all if defined?(SolidQueue::ReadyExecution)
      SolidQueue::ScheduledExecution.where(job_id: ids).delete_all if defined?(SolidQueue::ScheduledExecution)
      SolidQueue::BlockedExecution.where(job_id: ids).delete_all if defined?(SolidQueue::BlockedExecution)
      SolidQueue::FailedExecution.where(job_id: ids).delete_all if defined?(SolidQueue::FailedExecution)
      SolidQueue::Job.where(id: ids).delete_all
      :replaced
    end
  rescue ActiveRecord::StatementInvalid => e
    raise unless e.message.include?("solid_queue_") && e.message.match?(/no such table|doesn't exist|does not exist/i)

    :unavailable
  end

  def worker_available
    workflow = Workflow.new(job: job, trigger_kind: "initial", planned_execution_capabilities: profile.capabilities)
    step = Step.new(workflow: workflow, kind: "prepare", placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE, details: {})
    !RunQueueResolver.resolve_candidate(workflow: workflow, step: step).blocked?
  rescue StandardError
    nil
  end

  def result(eligible, refusal, workflow, runs, audit: nil, before: job.planned_execution_json, dispatch_status: nil, dispatch_error: nil)
    # A lightweight inspection of an ineligible Job is for display only, and the
    # worker probe is a query it has no use for: nothing can be placed anyway.
    available = @lightweight && !eligible ? nil : worker_available
    Result.new(eligible:, reason: refusal, job:, workflow:, runs:, profile:, before:, after: requirement.to_h, worker_available: available, audit:, dispatch_status:, dispatch_error:)
  end
end
end
