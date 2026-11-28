module Invariants
  # A paused rebase does not silently hold approved work.
  #
  # An operator-paused rebase (a rebase or stack_rebase WorkUnit blocked on
  # `manual_pause`) no longer counts against the repository's rebase slots
  # (SlotHolders), but it still blocks every merge train and job bundle for
  # its stack: resumed, it would force-push the member branches a train is
  # integrating, so the dispatchers refuse to race it. That is the safe
  # answer, and it never clears without an operator. The dispatchers name it
  # ("paused rebase workflow ... needs an operator"); this check makes the
  # monitor say it too, once the pause has held approved or landing Jobs of
  # the rebase's stack for `min_age`.
  #
  # Detection only: it does not resume or cancel the rebase.
  class PausedRebaseHolds < Base
    DEFAULTS = { min_age: 1.hour }.freeze
    HELD_JOB_STATES = %w[approved landing].freeze

    def violations
      paused_units.filter_map do |unit|
        since = unit.blocked_at || unit.updated_at
        next unless older_than?(since, options.fetch(:min_age))

        held = held_jobs_for(unit)
        next if held.empty?

        workflow = unit.workflow
        violation(
          severity: :warning,
          subject_type: "WorkUnit",
          subject_id: unit.id,
          since: since,
          message_params: {
            workflow: workflow&.slug.to_s,
            job: workflow&.job&.slug.to_s,
            count: held.size,
            held: held.map(&:slug).first(5).join(", "),
            hours: hours_since(since)
          },
          affected_ids: {
            work_unit_ids: [ unit.id ],
            workflow_ids: [ workflow&.id ],
            job_ids: [ workflow&.job_id, *held.map(&:id) ]
          },
          details: {
            work_unit: { id: unit.id, kind: unit.kind, state: unit.state, blocked_reason: unit.blocked_reason, blocked_at: iso(unit.blocked_at) },
            workflow: workflow && { id: workflow.id, slug: workflow.slug, state: workflow.state, trigger_kind: workflow.trigger_kind },
            paused_job: workflow&.job && job_ref(workflow.job),
            held_jobs: held.map { |job| job_ref(job).merge(epic_id: job.epic_id) },
            held_epic_ids: held.filter_map(&:epic_id).uniq
          }
        )
      end
    end

    private

    def paused_units
      WorkUnit.where(
        state: "blocked",
        blocked_reason: WorkUnits::Gates::ManualPause::REASON,
        kind: RebaseWorkflowSelector::TRIGGER_KINDS
      ).where.not(workflow_id: nil).includes(:work_unit_members, workflow: :job).order(:id)
    end

    # The approved or landing Jobs whose landing this rebase blocks: every Job
    # in the stack of one of its members (RebaseWorkflowSelector.paused_for_jobs
    # matches on the same stack relation).
    def held_jobs_for(unit)
      member_ids = unit.work_unit_members.map(&:job_id)
      member_ids << unit.workflow.job_id if unit.workflow&.job_id
      related_ids = Job.where(id: member_ids.uniq).flat_map { |job| StackRebasePlan.related_job_ids_for(job) }.uniq
      Job.where(id: related_ids, state: HELD_JOB_STATES).order(:id).select { |job| scope.include_job?(job.id) }
    end
  end
end
