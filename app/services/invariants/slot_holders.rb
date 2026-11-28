module Invariants
  # Concurrency slots are held only by runnable work.
  #
  # Syrus bounds parallel work with slots: the per-repository rebase cap
  # (RebaseWorkflowSelector.active_in_repository against
  # PollRebaseJob::CONCURRENT_REBASES_PER_REPO), the repository landing lanes
  # (WorkDefinitions landing lane locks), and the WorkUnitLock mutexes in
  # general. A slot held by work that cannot run starves everything queued
  # behind it while nothing is recorded as failed -- three manually paused
  # rebases once held every rebase slot in a repository for days.
  #
  # Violations, each after `grace` so a transition in flight is not reported:
  # * rebase_slot: a unit counted against the rebase cap whose workflow is no
  #   longer queued/running, whose Job is manually paused, or that was asked
  #   to pause;
  # * leaked_lock: any active lock held by a terminal unit;
  # * landing_lane: a landing lock held by a unit blocked on a reason only an
  #   operator clears, or by a runnable unit whose workflow is not runnable.
  class SlotHolders < Base
    DEFAULTS = { grace: 15.minutes }.freeze

    def violations
      rebase_slot_violations + leaked_lock_violations + landing_lane_violations
    end

    private

    def grace = options.fetch(:grace)

    def rebase_slot_violations
      units = scoped_units(
        WorkUnit.where(state: WorkUnits::Ownership::RUNNABLE_STATES, kind: RebaseWorkflowSelector::TRIGGER_KINDS)
                .where.not(workflow_id: nil)
      ).includes(:repository, workflow: :job).to_a
      held_by_repository = units.group_by(&:repository_id).transform_values(&:size)

      units.filter_map do |unit|
        workflow = unit.workflow
        reason, since = rebase_slot_problem(unit, workflow)
        next unless reason
        next unless older_than?(since, grace)

        held = held_by_repository[unit.repository_id].to_i
        cap = PollRebaseJob::CONCURRENT_REBASES_PER_REPO
        violation(
          severity: held >= cap ? :critical : :warning,
          subject_type: "WorkUnit",
          subject_id: unit.id,
          discriminator: "rebase_slot",
          since: since,
          message_params: { unit: unit.slug, slot: "rebase", reason: reason, repository: unit.repository&.slug.to_s },
          affected_ids: { work_unit_ids: [ unit.id ], workflow_ids: [ workflow&.id ], job_ids: [ workflow&.job_id ] },
          details: {
            slot: "rebase",
            reason: reason,
            repository: repository_ref(unit.repository),
            slots_held: held,
            slots_cap: cap,
            work_unit: unit_ref(unit),
            workflow: workflow_ref(workflow),
            job: workflow&.job && job_ref(workflow.job)
          }
        )
      end
    end

    def rebase_slot_problem(unit, workflow)
      return [ "workflow_#{workflow.state}", workflow.finished_at || workflow.updated_at ] unless workflow.state.in?(Workflow::TriggerKind::ACTIVE_STATES)
      return [ "job_manually_paused", workflow.job.manual_paused_at || workflow.job.updated_at ] if workflow.job&.manual_paused?
      return [ "pause_requested", unit.updated_at ] if unit.pause_requested?

      nil
    end

    def leaked_lock_violations
      locks = WorkUnitLock.active.joins(:work_unit).where(work_units: { state: WorkUnit::TERMINAL_STATES })
      locks = locks.where(work_unit_id: scoped_unit_ids) unless scope.all?
      locks.includes(work_unit: :repository).filter_map do |lock|
        unit = lock.work_unit
        since = unit.finished_at || unit.updated_at
        next unless older_than?(since, grace)

        violation(
          severity: :critical,
          subject_type: "WorkUnit",
          subject_id: unit.id,
          discriminator: "lock:#{lock.lock_key}",
          since: since,
          message_params: { unit: unit.slug, slot: lock.lock_key, reason: "work_unit_#{unit.state}", repository: unit.repository&.slug.to_s },
          affected_ids: { work_unit_ids: [ unit.id ], workflow_ids: [ unit.workflow_id ] },
          details: {
            slot: "lock",
            reason: "work_unit_#{unit.state}",
            lock_key: lock.lock_key,
            lock_acquired_at: iso(lock.acquired_at),
            repository: repository_ref(unit.repository),
            work_unit: unit_ref(unit)
          }
        )
      end
    end

    def landing_lane_violations
      locks = WorkUnitLock.active.joins(:work_unit)
                          .where(work_units: { state: WorkUnits::Ownership::ACTIVE_STATES })
                          .where("work_unit_locks.lock_key LIKE ?", "#{WorkUnit::LANDING_LOCK_KEY_PREFIX}%")
      locks = locks.where(work_unit_id: scoped_unit_ids) unless scope.all?
      locks.includes(work_unit: [ :repository, :workflow ]).filter_map do |lock|
        unit = lock.work_unit
        reason, since = landing_lane_problem(unit)
        next unless reason
        next unless older_than?(since, grace)

        lane = WorkDefinitions.landing_lane_for_key(lock.lock_key)
        violation(
          severity: :critical,
          subject_type: "WorkUnit",
          subject_id: unit.id,
          discriminator: "landing:#{lock.lock_key}",
          since: since,
          message_params: { unit: unit.slug, slot: "landing lane #{lane}", reason: reason, repository: unit.repository&.slug.to_s },
          affected_ids: { work_unit_ids: [ unit.id ], workflow_ids: [ unit.workflow_id ] },
          details: {
            slot: "landing_lane",
            reason: reason,
            lane: lane,
            lock_key: lock.lock_key,
            lock_acquired_at: iso(lock.acquired_at),
            repository: repository_ref(unit.repository),
            work_unit: unit_ref(unit),
            workflow: workflow_ref(unit.workflow)
          }
        )
      end
    end

    def landing_lane_problem(unit)
      if unit.blocked?
        return [ "blocked_#{unit.blocked_reason}", unit.blocked_at || unit.updated_at ] if unit.blocked_reason.in?(WorkUnit::EXTERNALLY_CLEARED_BLOCKED_REASONS)

        return nil
      end

      workflow = unit.workflow
      return nil unless workflow
      return [ "workflow_#{workflow.state}", workflow.finished_at || workflow.updated_at ] unless workflow.state.in?(Workflow::TriggerKind::ACTIVE_STATES)

      nil
    end

    def scoped_units(relation)
      scope.all? ? relation : relation.where(id: scoped_unit_ids)
    end

    def scoped_unit_ids
      @scoped_unit_ids ||= begin
        member_ids = WorkUnitMember.where(job_id: scope.job_ids).pluck(:work_unit_id)
        workflow_ids = WorkUnit.joins(:workflow).where(workflows: { job_id: scope.job_ids }).pluck(:id)
        (member_ids + workflow_ids).uniq
      end
    end

    def unit_ref(unit)
      {
        id: unit.id,
        kind: unit.kind,
        state: unit.state,
        blocked_reason: unit.blocked_reason,
        blocked_at: iso(unit.blocked_at),
        pause_requested: unit.pause_requested,
        finished_at: iso(unit.finished_at)
      }
    end

    def workflow_ref(workflow)
      return nil unless workflow

      { id: workflow.id, state: workflow.state, trigger_kind: workflow.trigger_kind, finished_at: iso(workflow.finished_at) }
    end

    def repository_ref(repository)
      repository && { id: repository.id, slug: repository.slug }
    end
  end
end
