module Invariants
  # Approved and landing work must progress.
  #
  # An approved or landing Job is the end of the pipeline: a person has said
  # "ship it". Something must then be visibly moving it, or visibly holding it:
  # a queued or running Run, an active WorkUnit it belongs to (directly or
  # through its Epic's merge train), a waiting WorkIntent with a reason, or a
  # named reason in the landing queue (a blocker, the Jobs ahead of it, a
  # pause). A Job with none of those for longer than `threshold` is stranded:
  # nothing will ever pick it up and nothing says why.
  class LandingProgress < Base
    DEFAULTS = { threshold: 2.hours }.freeze
    JOB_STATES = %w[approved landing].freeze

    def violations
      jobs = scope.restrict(Job.where(state: JOB_STATES)).to_a
      return [] if jobs.empty?

      job_ids = jobs.map(&:id)
      active_run_job_ids = Run.where(job_id: job_ids, state: Run::ACTIVE_STATES).distinct.pluck(:job_id).to_set
      units_by_job = active_units_by_job(jobs)
      waiting_intents_by_job = WorkIntent.where(scope_type: "job", scope_id: job_ids, state: "waiting")
                                         .where.not(wait_reason: nil)
                                         .pluck(:scope_id, :wait_reason)
                                         .group_by(&:first)
      latest_run_at = Run.where(job_id: job_ids).group(:job_id).maximum(:updated_at)
      latest_workflow_at = Workflow.where(job_id: job_ids).group(:job_id).maximum(:updated_at)
      latest_unit_at = WorkUnitMember.joins(:work_unit).where(job_id: job_ids).group(:job_id).maximum("work_units.updated_at")

      jobs.filter_map do |job|
        next if active_run_job_ids.include?(job.id)
        next if units_by_job[job.id].present?
        next if waiting_intents_by_job[job.id].present?
        next if named_landing_blocker(job)

        last_progress_at = [ job.approved_at, latest_run_at[job.id], latest_workflow_at[job.id], latest_unit_at[job.id] ].compact.max
        next unless older_than?(last_progress_at, options.fetch(:threshold))

        latest = latest_workflow(job)
        violation(
          severity: :critical,
          subject_type: "Job",
          subject_id: job.id,
          since: last_progress_at,
          message_params: { job: job.slug, state: job.state, hours: hours_since(last_progress_at) },
          affected_ids: { job_ids: [ job.id ], workflow_ids: [ latest&.id ] },
          details: {
            job: job_ref(job),
            approved_at: iso(job.approved_at),
            last_progress_at: iso(last_progress_at),
            idle_hours: hours_since(last_progress_at),
            active_runs: 0,
            active_work_units: 0,
            landing_queue: {
              cached_at: iso(job.landing_queue_cached_at),
              position: job.landing_queue_position,
              blocked_reason: job.landing_queue_blocked_reason,
              blocker_job_ids: Array(job.landing_queue_blocker_job_ids),
              waiting_job_ids: Array(job.landing_queue_waiting_job_ids)
            },
            latest_workflow: latest && {
              id: latest.id,
              state: latest.state,
              trigger_kind: latest.trigger_kind,
              failure_reason: latest.failure_reason,
              finished_at: iso(latest.finished_at)
            }
          }
        )
      end
    end

    private

    # A Job counts as held when any active unit names it, including a blocked
    # unit: a blocked unit carries its reason. Whether a blocked unit is
    # entitled to hold a slot is SlotHolders' question, not this one's.
    def active_units_by_job(jobs)
      by_job = Hash.new { |hash, key| hash[key] = [] }
      WorkUnitMember.joins(:work_unit)
                    .where(job_id: jobs.map(&:id), work_units: { state: WorkUnits::Ownership::ACTIVE_STATES })
                    .pluck(:job_id, :work_unit_id)
                    .each { |job_id, unit_id| by_job[job_id] << unit_id }

      epic_ids = jobs.filter_map(&:epic_id).uniq
      if epic_ids.any?
        epic_units = WorkUnit.where(scope_type: "epic", scope_id: epic_ids, state: WorkUnits::Ownership::ACTIVE_STATES)
                             .pluck(:scope_id, :id)
                             .group_by(&:first)
        jobs.each do |job|
          Array(epic_units[job.epic_id]).each { |(_, unit_id)| by_job[job.id] << unit_id }
        end
      end
      by_job
    end

    def named_landing_blocker(job)
      return "manual_pause" if job.manual_paused?
      # A requested-changes or unapplied-feedback hold keeps the Job out of the
      # landing queue altogether (queue_candidates drops it), so the queue never
      # persists a reason for it. It is the blocker blockage_for names for the
      # same attention reason; reading the column keeps this check query-free.
      attention_key = LandingQueueProcessor::ATTENTION_BLOCKER_KEYS[job.needs_attention_reason]
      return attention_key if attention_key

      reason = job.landing_queue_blocked_reason
      if reason.present?
        key = reason.is_a?(Hash) ? (reason["key"] || reason[:key]) : reason
        return key.to_s.presence || "landing_queue_blocked"
      end
      return "waiting_behind_jobs" if Array(job.landing_queue_blocker_job_ids).any? || Array(job.landing_queue_waiting_job_ids).any?
      return "landing_capacity_full" if landing_capacity_full?(job)

      nil
    end

    # Every landing lane of the Job's branch is held, so the landing queue
    # cannot dispatch it: the Job waits for the landing ahead of it, which
    # answers for itself (its Run, its WorkUnit's blocked reason, or this
    # invariant). The queue does not record that wait as a blocker, so a
    # landing held for hours -- a provider outage, say -- made every Job
    # behind it read as stranded.
    def landing_capacity_full?(job)
      return false unless job.approved?

      @delivery_policies ||= {}
      policy = @delivery_policies[job.repository_id] ||= DeliveryPolicy.for(repository: job.repository)
      WorkDefinitions.landing_capacity_full?(job, policy: policy)
    rescue StandardError
      false
    end

    def latest_workflow(job)
      Workflow.where(job_id: job.id)
              .select(:id, :state, :trigger_kind, :failure_reason, :finished_at, :created_at)
              .reorder(created_at: :desc, id: :desc)
              .first
    end
  end
end
