module Workflows
  class LifecyclePropagation
    def self.started!(workflow) = new(workflow).started!
    def self.succeeded!(workflow) = new(workflow).succeeded!
    def self.failed!(workflow) = new(workflow).failed!
    def self.cancelled!(workflow) = new(workflow).cancelled!
    def self.blocked!(workflow) = new(workflow).blocked!
    def self.reopened!(workflow) = new(workflow).reopened!

    def initialize(workflow)
      @workflow = workflow
    end

    def started!
      workflow.started_at ||= Time.current
      unless workflow.syncing_from_terminal_work_unit
        workflow.job.clear_needs_attention!(reason: GraderLoopProgress::NO_PROGRESS_REASON)
        workflow.job.clear_needs_attention!(reason: "agent_cannot_proceed")
      end
      workflow.sync_work_unit_running!
      workflow.propagate_start_to_job!
    end

    def succeeded!
      workflow.finished_at = Time.current
      workflow.sync_work_unit_terminal!("succeeded")
      workflow.cleanup_workspace!
      workflow.job.clear_needs_attention!(reason: GraderLoopProgress::NO_PROGRESS_REASON)
      workflow.propagate_succeed_to_job!
      workflow.cancel_superseded_retry_workflows!
      dispatch_hook(:after_success)
    end

    def failed!
      workflow.finished_at = Time.current
      workflow.sync_work_unit_terminal!("failed")
      workflow.cancel_orphan_active_runs!
      workflow.propagate_fail_to_job!
      dispatch_hook(:after_fail)
      workflow.cleanup_workspace! if workflow.infrastructure_workflow?
    end

    def cancelled!
      workflow.finished_at = Time.current
      # Invariant: a root event exists before any cleanup runs. Direct
      # `workflow.cancel!` callers that supplied none surface as unattributed.
      Workflows::CancellationAttribution.record!(workflow, reason: workflow.artifact("cancelled_reason").presence || "unspecified")
      Workflows::CancellationAttribution.with_parent(workflow) do
        workflow.sync_work_unit_terminal!("cancelled")
        workflow.cancel_active_descendants!
        workflow.propagate_cancel_to_job!
        workflow.cleanup_workspace!
        dispatch_hook(:after_cancel)
      end
    end

    def blocked!
      workflow.finished_at = Time.current
      if Workflow::TriggerKind.non_approval_blocking?(workflow.trigger_kind)
        # Auxiliary work must give back its locks when it cannot proceed. A
        # WorkUnit has no blocked *outcome*, and a blocked unit would keep
        # holding the Job-wide lock behind an already-terminal Workflow.
        workflow.sync_work_unit_terminal!("failed")
      else
        workflow.work_unit&.block!(
          reason: "agent_cannot_proceed",
          details: workflow.artifact("cannot_proceed").to_h
        )
      end
      workflow.job.set_needs_attention!(reason: "agent_cannot_proceed")
      workflow.cleanup_workspace!
    end

    def reopened!
      workflow.finished_at = nil
      workflow.sync_work_unit_running!
      workflow.propagate_reopen_to_job!
    end

    private

    attr_reader :workflow

    def dispatch_hook(name)
      workflow.send(:dispatch_hook, name)
    end
  end
end
