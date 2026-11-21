# The one way to close a Job without leaving Workflows running for it.
#
# Invariant (formal/SyrusModel/JobClosure.lean, `ClosedQuiet`): no active
# runtime Workflow works on a closed Job. Closing used to cancel only active
# Runs, so queued or between-steps Workflows survived the close -- a rebase
# created moments before a merged PR was noticed started on the closed Job
# with a force-push queued -- until the reconciler cancelled them.
#
# - `close_now!` cancels the Job's other active runtime Workflows, then closes.
# - Workflows record closures with `Workflow#request_job_closure!`;
#   `apply_pending!` runs when the Workflow finishes, whatever its outcome.
# - `request!` is for closers outside any Workflow (PR pollers, grace expiry):
#   an active landing Workflow working on the Job is finishing the work, so the
#   closure is deferred to it; otherwise the Job closes now.
class JobClosure
  CANCELLED_REASON = "job_closed".freeze

  def self.close_now!(job, reason, except_workflow: nil)
    new(job).close_now!(reason, except_workflow: except_workflow)
  end

  def self.request!(job, reason)
    new(job).request!(reason)
  end

  def self.apply_pending!(workflow)
    closures = workflow.pending_job_closures_by_id
    closures.each do |job_id, reason|
      job = Job.find_by(id: job_id)
      next unless job

      closed = StateTransition.with_source("system") do
        new(job).close_now!(reason, except_workflow: workflow)
      end
      next if closed || job.reload.closed?

      Rails.logger.warn("[JobClosure] #{workflow.slug} finished but #{job.slug} (#{job.state}) could not close as #{reason}")
      workflow.set_artifact!("job_closure_failed", { "job_id" => job.id, "reason" => reason, "job_state" => job.state })
    end
    # The caller goes on to propagate the outcome to `workflow.job`. A cached
    # copy still in its pre-close state would save that state over the close.
    workflow.job&.reload if closures.key?(workflow.job_id)
  end

  def initialize(job)
    @job = job
  end

  # Returns :deferred, :closed, or :noop.
  def request!(reason)
    if (owner = active_landing_owner)
      owner.request_job_closure!(job, reason)
      return :deferred
    end

    close_now!(reason) ? :closed : :noop
  end

  # Cancelling happens before the Job row is touched and outside any Job lock:
  # WorkflowCancellation locks the Workflow and then writes the Job, so taking
  # the Job lock first would invert that order.
  def close_now!(reason, except_workflow: nil)
    job.reload
    return false unless job.may_close?

    other_active_workflows(except_workflow).each do |workflow|
      WorkUnits::WorkflowCancellation.cancel!(
        workflow,
        reason: CANCELLED_REASON,
        artifacts: { "cancelled_reason" => CANCELLED_REASON, "cancelled_at" => Time.current.iso8601 }
      )
    end
    job.runs.active.find_each do |run|
      next if except_workflow && run.step&.workflow_id == except_workflow.id

      run.cancel! if run.may_cancel?
      run.save!
    end

    job.reload
    return false unless job.may_close?

    job.close_with_reason!(reason)
    true
  end

  private

  attr_reader :job

  # Deliberately not Job#active_runtime_workflows: that first runs
  # TerminalWorkflowSync, which -- while the finishing Workflow is mid-
  # transition (unit already terminal, row not yet saved) -- would cancel that
  # same Workflow again and re-enter apply_pending!.
  def other_active_workflows(except_workflow)
    ids = WorkUnits::Ownership.active_workflow_ids([ job.id ], kinds: WorkDefinitions.first_class_work_unit_kinds).to_a
    ids -= [ except_workflow.id ] if except_workflow
    Workflow.where(id: ids, state: %w[queued running]).order(:created_at, :id).to_a
  end

  # Ownership is by WorkUnit membership, so a merge train owns each member Job.
  def active_landing_owner
    Workflow.where(id: WorkUnits::Ownership.active_workflow_ids([ job.id ]).to_a).order(:id).detect(&:landing_workflow?)
  end
end
