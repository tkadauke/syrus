class RepairPreflight
  Result = Data.define(:eligible, :operation, :target, :blockers, :expected_mutations) do
    def eligible? = eligible
    def rejection_message = blockers.join("; ").presence || "repair is not eligible"

    def as_json(*)
      { eligible: eligible?, operation: operation, target: target, blockers: blockers, expected_mutations: expected_mutations }
    end
  end

  def self.reconcile_job_state(job:, mode:)
    if mode.to_s == "auto"
      plan = ReconcileJobStatesJob::Plan.for(job)
      if plan.nil? && job.state.in?(%w[closed implemented approved landing]) && job.active_runtime_work?
        return Result.new(eligible: true, operation: "cancel_terminal_job_work", target: { job_id: job.id, state: job.state }, blockers: [], expected_mutations: { runtime_cancellations: 1 })
      end
      return Result.new(eligible: false, operation: "reconcile_job_state", target: { job_id: job.id, state: job.state }, blockers: [ "#{job.slug} has no applicable state-drift plan" ], expected_mutations: {}) unless plan

      return Result.new(eligible: true, operation: "reconcile_job_state", target: { job_id: job.id, state: job.state, target_state: plan.target_state }, blockers: [], expected_mutations: { job_state_changes: 1 })
    end

    Result.new(eligible: true, operation: mode.to_s, target: { job_id: job.id, state: job.state }, blockers: [], expected_mutations: { job_state_changes: 1 })
  end

  def self.cancel_stale_work(job:, workflow_ids:, run_ids:)
    requested_workflows = Array(workflow_ids).map { |id| Integer(id, exception: false) }.compact
    requested_runs = Array(run_ids).map { |id| Integer(id, exception: false) }.compact
    workflows = job.active_runtime_workflows
    workflows = workflows.select { |workflow| requested_workflows.include?(workflow.id) } if requested_workflows.any?
    runs = job.runs.active
    runs = runs.where(id: requested_runs) if requested_runs.any?
    cancellable_workflows = workflows.select(&:may_cancel?)
    cancellable_runs = runs.select(&:may_cancel?)
    missing_workflows = requested_workflows - workflows.map(&:id)
    missing_runs = requested_runs - runs.map(&:id)
    blockers = []
    blockers << "Workflow ids are not active work for #{job.slug}: #{missing_workflows.join(', ')}" if missing_workflows.any?
    blockers << "Run ids are not active work for #{job.slug}: #{missing_runs.map { |id| "RUN-#{id}" }.join(', ')}" if missing_runs.any?
    uncancellable_workflows = workflows.reject(&:may_cancel?).map(&:id)
    uncancellable_runs = runs.reject(&:may_cancel?).map(&:id)
    blockers << "Workflows cannot transition to cancelled: #{uncancellable_workflows.join(', ')}" if uncancellable_workflows.any?
    blockers << "Runs cannot transition to cancelled: #{uncancellable_runs.map { |id| "RUN-#{id}" }.join(', ')}" if uncancellable_runs.any?
    blockers << "no requested Run or Workflow can transition to cancelled" if blockers.empty? && cancellable_workflows.empty? && cancellable_runs.empty?
    Result.new(eligible: blockers.empty?, operation: "cancel_stale_work", target: { job_id: job.id, workflow_ids: cancellable_workflows.map(&:id), run_ids: cancellable_runs.map(&:id) }, blockers: blockers, expected_mutations: { workflows: cancellable_workflows.size, runs: cancellable_runs.size })
  end

  def self.job_locks(job:, operation:)
    locks = WorkUnitLock.active.where(lock_key: "job:#{job.id}").includes(work_unit: :workflow).to_a
    blockers = locks.map { |lock| "#{lock.work_unit.slug} owns #{lock.lock_key}; use retire_terminal_work_unit if its Workflow is terminal" }
    Result.new(eligible: blockers.empty?, operation: operation, target: { job_id: job.id, requested_lock_keys: [ "job:#{job.id}" ], owning_work_unit_ids: locks.map(&:work_unit_id) }, blockers: blockers, expected_mutations: blockers.empty? ? { workflows: 1, work_units: 1 } : {})
  end
end
