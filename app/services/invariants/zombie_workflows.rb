module Invariants
  # Workflow and Job state must describe work that is actually happening.
  #
  # Two shapes of the same lie:
  # * zombie_workflow: a queued or running Workflow with no queued/running Run
  #   and no queued/running Step, whose WorkUnit is not blocked on a named
  #   reason, untouched for `threshold`. Nothing can advance it, and it still
  #   reads as in progress.
  # * job_workflow_drift: a running Job with no queued/running Workflow whose
  #   latest Workflow ended (`threshold`) or is blocked (`blocked_threshold`,
  #   since a blocked workflow legitimately waits on a person for a while).
  #   A Job once sat running for weeks on a blocked workflow.
  class ZombieWorkflows < Base
    DEFAULTS = { threshold: 2.hours, blocked_threshold: 3.days }.freeze
    WORKFLOW_COLUMNS = %i[id job_id state trigger_kind failure_reason started_at finished_at created_at updated_at].freeze

    def violations
      zombie_workflow_violations + job_workflow_drift_violations
    end

    private

    def zombie_workflow_violations
      workflows = scope.restrict(Workflow.where(state: Workflow::TriggerKind::ACTIVE_STATES), :job_id)
                       .select(*WORKFLOW_COLUMNS)
                       .to_a
      return [] if workflows.empty?

      ids = workflows.map(&:id)
      active_step_ids = Step.where(workflow_id: ids, state: Step::ACTIVE_STATES).distinct.pluck(:workflow_id).to_set
      active_run_ids = Run.joins(:step).where(steps: { workflow_id: ids }, state: Run::ACTIVE_STATES).distinct.pluck("steps.workflow_id").to_set
      units = WorkUnit.where(workflow_id: ids).pluck(:workflow_id, :id, :state, :blocked_reason).to_h { |wf, *rest| [ wf, rest ] }
      latest_step_at = Step.where(workflow_id: ids).group(:workflow_id).maximum(:updated_at)
      latest_run_at = Run.joins(:step).where(steps: { workflow_id: ids }).group("steps.workflow_id").maximum("runs.updated_at")
      jobs = Job.where(id: workflows.map(&:job_id)).index_by(&:id)

      workflows.filter_map do |workflow|
        next if active_step_ids.include?(workflow.id) || active_run_ids.include?(workflow.id)

        unit_id, unit_state, blocked_reason = units[workflow.id]
        next if unit_state == "blocked" && blocked_reason.present?

        last_activity_at = [ workflow.updated_at, latest_step_at[workflow.id], latest_run_at[workflow.id] ].compact.max
        next unless older_than?(last_activity_at, options.fetch(:threshold))

        job = jobs[workflow.job_id]
        violation(
          severity: :critical,
          subject_type: "Workflow",
          subject_id: workflow.id,
          discriminator: "zombie_workflow",
          since: last_activity_at,
          message_params: { subject: workflow.slug, condition: "zombie_workflow", state: workflow.state, hours: hours_since(last_activity_at) },
          affected_ids: { workflow_ids: [ workflow.id ], job_ids: [ workflow.job_id ], work_unit_ids: [ unit_id ] },
          details: {
            condition: "zombie_workflow",
            workflow: workflow_ref(workflow),
            job: job && job_ref(job),
            work_unit: unit_id && { id: unit_id, state: unit_state, blocked_reason: blocked_reason },
            last_activity_at: iso(last_activity_at),
            idle_hours: hours_since(last_activity_at),
            active_steps: 0,
            active_runs: 0
          }
        )
      end
    end

    def job_workflow_drift_violations
      jobs = scope.restrict(Job.where(state: "running")).to_a
      return [] if jobs.empty?

      job_ids = jobs.map(&:id)
      active_job_ids = Workflow.where(job_id: job_ids, state: Workflow::TriggerKind::ACTIVE_STATES).distinct.pluck(:job_id).to_set
      candidates = jobs.reject { |job| active_job_ids.include?(job.id) }
      return [] if candidates.empty?

      latest_by_job = latest_workflows(candidates.map(&:id))

      candidates.filter_map do |job|
        latest = latest_by_job[job.id]
        since = latest ? (latest.finished_at || latest.updated_at) : job.updated_at
        threshold = latest&.state == "blocked" ? options.fetch(:blocked_threshold) : options.fetch(:threshold)
        next unless older_than?(since, threshold)

        condition = latest ? "job_running_workflow_#{latest.state}" : "job_running_without_workflow"
        violation(
          severity: :critical,
          subject_type: "Job",
          subject_id: job.id,
          discriminator: "job_workflow_drift",
          since: since,
          message_params: { subject: job.slug, condition: condition, state: job.state, hours: hours_since(since) },
          affected_ids: { job_ids: [ job.id ], workflow_ids: [ latest&.id ] },
          details: {
            condition: condition,
            job: job_ref(job),
            latest_workflow: workflow_ref(latest),
            since: iso(since),
            hours: hours_since(since)
          }
        )
      end
    end

    def latest_workflows(job_ids)
      Workflow.where(job_id: job_ids)
              .select(*WORKFLOW_COLUMNS)
              .reorder(:job_id, created_at: :desc, id: :desc)
              .to_a
              .group_by(&:job_id)
              .transform_values(&:first)
    end

    def workflow_ref(workflow)
      return nil unless workflow

      {
        id: workflow.id,
        slug: workflow.slug,
        state: workflow.state,
        trigger_kind: workflow.trigger_kind,
        failure_reason: workflow.failure_reason,
        started_at: iso(workflow.started_at),
        finished_at: iso(workflow.finished_at)
      }
    end
  end
end
