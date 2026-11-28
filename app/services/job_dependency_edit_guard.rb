# Keeps a Job from executing out of turn after its dependency set changes.
#
# Dependency edits used to re-evaluate only queued, unstarted Workflows, so a
# Job already running (or blocked) kept its `running` label and kept executing
# against dependencies that were no longer satisfied.
#
# After an edit, `enforce!` evaluates the Job's start gate:
#
# * gate met -> nothing to do.
# * gate unmet, active Run -> reject (the caller's transaction rolls the edit
#   back). Holding running work is a confirmed `hold_job` pending action; the
#   dependency tools' `hold_running: true` requests one that carries the edit,
#   and the confirmed hold applies it inside `deferring_to_hold`.
# * gate unmet, no active Run (blocked, failed, idle with an open Workflow) ->
#   started Workflows are retired and the Job returns to the waiting state so
#   `Job#state` agrees with its work intent. A Workflow that blocked with
#   retryable: false is resumed with the normal `retry` in implementation mode
#   once the dependency lands (explain_stuck_job offers it).
class JobDependencyEditGuard
  class ActiveRunRejection < StandardError; end

  DEFER_KEY = :job_dependency_edit_guard_deferred_job_ids

  class << self
    def enforce!(job)
      job.reload
      return :ok unless job.running?
      return :ok unless JobHold.gate_unmet?(job)

      runs = JobHold.active_runs(job)
      if runs.any?
        # A confirmed hold applies the edit and then holds the Job itself.
        return :deferred if deferred_job_ids.include?(job.id)

        raise ActiveRunRejection,
          "#{job.slug} is executing (#{runs.map(&:slug).join(', ')}) and would no longer be unblocked by its new dependencies. " \
          "Pass hold_running: true to request a confirmed hold that applies this edit, or use hold_job first."
      end

      demote_idle!(job)
      :waiting
    end

    # Lets a confirmed hold apply a dependency edit to a Job that is still
    # running; the caller holds the Job in the same transaction.
    def deferring_to_hold(job)
      previous = deferred_job_ids
      Thread.current[DEFER_KEY] = previous + [ job.id ]
      yield
    ensure
      Thread.current[DEFER_KEY] = previous
    end

    def deferred_job_ids = Thread.current[DEFER_KEY] || []

    # The Job has no active Run: retire started Workflows and return it to the
    # waiting state. Also run after dependency edits that bypass the tools.
    def demote_if_gate_unmet!(job)
      job.reload
      return unless job.running?
      return if JobHold.active_runs(job).any?
      return unless JobHold.gate_unmet?(job)

      demote_idle!(job)
    end

    def demote_idle!(job)
      return unless job.running?

      StateTransition.with_source("propagate", reason: "dependency_edit") do
        JobHold.active_workflows(job).reject(&:queued?).each do |workflow|
          WorkUnits::WorkflowCancellation.cancel!(
            workflow,
            reason: "dependency_edit",
            cause: job.operator_cancellation_cause("dependency_edit", "job_id" => job.id, "workflow_id" => workflow.id),
            artifacts: { "cancelled_reason" => "dependency_edit", "cancelled_at" => Time.current.iso8601 }
          )
        end
        job.reload
        job.retry_after_failure! if job.may_retry_after_failure?
        job.save!
      end
      job.clear_needs_attention!(reason: "agent_cannot_proceed")
      WorkIntents::JobWakeup.call(job)
    end
  end
end
