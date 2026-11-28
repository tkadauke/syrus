# Stops a Job that is executing out of turn without closing it: cancels its
# active Runs and Workflows through the normal cancellation path (which retires
# the WorkUnits and releases their locks) and returns the Job to the waiting
# state. Its PR and branch are untouched.
#
# Used by the `hold_job` pending action and by dependency edits that opt in
# with `hold_running: true`.
class JobHold
  Result = Struct.new(:cancelled_run_ids, :cancelled_workflow_ids, :state, keyword_init: true)

  class << self
    # Why the Job cannot be held, as operator-facing messages naming the next
    # valid action. Empty when a hold is allowed.
    def blockers(job, to_backlog: false)
      return [ "#{job.slug} is closed; reopen it before holding it." ] if job.closed?

      blockers = []
      if active_runs(job).empty? && active_workflows(job).empty?
        blockers << "#{job.slug} has no active Runs or Workflows to cancel; there is nothing to hold. " \
                    "Use explain_stuck_job to see why it is not progressing."
      end
      if to_backlog
        if job.pr_number.present? || job.external_pr_number.present? || job.fork_review_pr_number.present?
          blockers << "#{job.slug} already has a PR and cannot be moved to backlog; hold it without to_backlog to wait on its dependencies."
        end
      elsif !gate_unmet?(job)
        blockers << "All dependencies of #{job.slug} are satisfied, so there is nothing to wait for. " \
                    "Use cancel_stale_work to cancel stale work, or pass to_backlog to park the Job in backlog."
      end
      blockers
    end

    # True when the Job must not execute yet: an unsatisfied dependency or an
    # unready stack parent. Stacked branches still let a dependent run once its
    # parent has an open PR; this only asks the existing gate.
    def gate_unmet?(job)
      !(job.dependencies_satisfied_for_execution? && job.stack_ready_for_execution?)
    end

    def active_runs(job) = job.runs.active.to_a

    def active_workflows(job)
      job.active_runtime_workflows.select { |workflow| workflow.queued? || workflow.running? || workflow.blocked? }
    end

    def call(job:, reason:, to_backlog: false, control_path: "job_hold", source: {})
      cancelled_runs = []
      cancelled_workflows = []
      ApplicationRecord.transaction do
        job.lock!
        failures = blockers(job, to_backlog: to_backlog)
        raise ArgumentError, failures.join("; ") if failures.any?

        StateTransition.with_source("operator", reason: "job_hold") do
          active_runs(job).each do |run|
            next unless run.may_cancel?

            run.cancel!
            run.save!
            cancelled_runs << run.id
          end

          active_workflows(job).each do |workflow|
            WorkUnits::WorkflowCancellation.cancel!(
              workflow,
              reason: "operator_job_hold",
              cause: job.operator_cancellation_cause(control_path, source.merge("job_id" => job.id, "workflow_id" => workflow.id)),
              artifacts: {
                "cancelled_reason" => "operator_job_hold",
                "cancelled_at" => Time.current.iso8601,
                "operator_hold_reason" => reason
              }
            )
            cancelled_workflows << workflow.id
          end

          job.reload(lock: true)
          job.retry_after_failure! if job.may_retry_after_failure?
          job.move_to_backlog! if to_backlog && job.may_move_to_backlog?
          job.save!
        end
        WorkIntents::JobWakeup.call(job)
      end
      Result.new(cancelled_run_ids: cancelled_runs, cancelled_workflow_ids: cancelled_workflows, state: job.reload.state)
    end
  end
end
