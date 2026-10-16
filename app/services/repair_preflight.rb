class RepairPreflight
  class << self
    def reconcile_job_state(job:, mode:)
      if mode.to_s == "auto"
        plan = ReconcileJobStatesJob::Plan.for(job)
        unless plan
          result = WorkEngine::Reconciler.call(source: "repair_preflight:reconcile_job_state", job_id: job.id)
          repair = result.repair_plans.find(&:auto_executable)
          if repair
            return RepairEligibility.new(
              status: "eligible", operation: repair.action, target_state: repair.preconditions["target_state"],
              expected_mutations: repair.affected_ids.transform_values { |ids| Array(ids).size },
              affected_ids: repair.affected_ids.symbolize_keys,
              facts: { job_state: job.state, reason: repair.reason }
            )
          end
        end
        return RepairEligibility.new(
          status: "noop", operation: "reconcile_job_state", target_state: job.state,
          blocking_preconditions: [ "#{job.slug} has no applicable state-drift plan" ],
          expected_mutations: { jobs: 0 }, affected_ids: { job_ids: [ job.id ] },
          facts: { job_state: job.state, workflow_id: job.latest_workflow&.id, workflow_state: job.latest_workflow&.state }
        ) unless plan

        return RepairEligibility.new(
          status: "eligible", operation: "reconcile_job_state", target_state: plan.target_state,
          expected_mutations: { jobs: 1 }, affected_ids: { job_ids: [ job.id ], workflow_ids: [ job.latest_workflow&.id ].compact },
          facts: { job_state: job.state, reason: plan.reason }
        )
      end

      RepairEligibility.new(
        status: "eligible", operation: "reconcile_job_state", target_state: explicit_target_state(mode),
        expected_mutations: { jobs: 1 }, affected_ids: { job_ids: [ job.id ] }, facts: { job_state: job.state }
      )
    end

    def cancel_stale_work(job:, workflow_ids:, run_ids:)
      workflows = resolve_workflows(job, workflow_ids)
      runs = resolve_runs(job, run_ids)
      blockers = []
      blockers.concat(workflows.reject(&:may_cancel?).map { |workflow| "Workflow ##{workflow.id} is #{workflow.state} and cannot transition to cancelled" })
      blockers.concat(runs.reject(&:may_cancel?).map { |run| "Run ##{run.id} is #{run.state} and cannot transition to cancelled" })
      blockers << "no Run or Workflow can transition to cancelled" if workflows.empty? && runs.empty?

      RepairEligibility.new(
        status: blockers.empty? ? "eligible" : "rejected", operation: "cancel_stale_work", target_state: "cancelled",
        blocking_preconditions: blockers,
        expected_mutations: { workflows: workflows.count(&:may_cancel?), runs: runs.count(&:may_cancel?) },
        affected_ids: { job_ids: [ job.id ], workflow_ids: workflows.map(&:id), run_ids: runs.map(&:id) },
        facts: { job_state: job.state }
      )
    end

    def terminal_work_unit(work_unit:)
      workflow = work_unit.workflow
      active_runs = workflow ? workflow.runs.active.pluck(:id) : []
      locks = work_unit.work_unit_locks.active.pluck(:id, :lock_key)
      blockers = []
      blockers << "WorkUnit #{work_unit.slug} is already #{work_unit.state}" unless work_unit.active? || locks.empty?
      blockers << "WorkUnit #{work_unit.slug} has no Workflow" unless workflow
      blockers << "Workflow ##{workflow.id} is #{workflow.state}, not terminal" if workflow && !workflow.terminal?
      blockers << "Workflow ##{workflow.id} still has active Runs: #{active_runs.join(', ')}" if active_runs.any?
      status = if blockers.any? then "rejected" elsif locks.empty? then "noop" else "eligible" end

      RepairEligibility.new(
        status: status, operation: "retire_terminal_work_unit", target_state: "cancelled",
        blocking_preconditions: blockers.presence || ([ "no active locks remain" ] if locks.empty?) || [],
        expected_mutations: { work_units: status == "eligible" ? 1 : 0, locks: status == "eligible" ? locks.size : 0 },
        affected_ids: { work_unit_ids: [ work_unit.id ], workflow_ids: [ workflow&.id ].compact, run_ids: active_runs, lock_ids: locks.map(&:first) },
        facts: { work_unit_state: work_unit.state, workflow_state: workflow&.state, lock_keys: locks.map(&:last), work_intent_id: work_unit.work_intent_id }
      )
    end

    def ci_repair(job:)
      key = "job:#{job.id}"
      lock = WorkUnitLock.active.includes(:work_unit).find_by(lock_key: key)
      blockers = []
      blockers << "#{lock.work_unit.slug} already owns lock #{key}; retire_terminal_work_unit is eligible if its Workflow is terminal and has no active Runs" if lock
      RepairEligibility.new(
        status: blockers.empty? ? "eligible" : "rejected", operation: "rerun_ci_repair", target_state: "queued",
        blocking_preconditions: blockers, expected_mutations: { workflows: blockers.empty? ? 1 : 0, work_units: blockers.empty? ? 1 : 0 },
        affected_ids: { job_ids: [ job.id ], work_unit_ids: [ lock&.work_unit_id ].compact, lock_ids: [ lock&.id ].compact },
        facts: { requested_lock_keys: [ key ], owning_work_unit_id: lock&.work_unit_id }
      )
    end

    private

    def explicit_target_state(mode)
      { "mark_implemented_from_ready_pr" => "implemented", "mark_failed" => "failed", "mark_queued" => "queued" }[mode.to_s]
    end

    def resolve_workflows(job, ids)
      requested = Array(ids).filter_map { |id| Integer(id, exception: false) }
      scope = job.active_runtime_workflows
      return scope if requested.empty?
      records = scope.select { |workflow| requested.include?(workflow.id) }
      missing = requested - records.map(&:id)
      raise ArgumentError, "Workflow ids are not active work for #{job.slug}: #{missing.join(', ')}" if missing.any?
      records
    end

    def resolve_runs(job, ids)
      requested = Array(ids).filter_map { |id| Integer(id, exception: false) }
      scope = job.runs.active
      return scope.to_a if requested.empty?
      records = scope.where(id: requested).to_a
      missing = requested - records.map(&:id)
      raise ArgumentError, "Run ids are not active work for #{job.slug}: #{missing.map { |id| "RUN-#{id}" }.join(', ')}" if missing.any?
      records
    end
  end
end
