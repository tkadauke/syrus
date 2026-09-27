module Workflows
  class LifecyclePropagation
    def self.started!(workflow) = new(workflow).started!
    def self.succeeded!(workflow) = new(workflow).succeeded!
    def self.failed!(workflow) = new(workflow).failed!
    def self.cancelled!(workflow) = new(workflow).cancelled!
    def self.reopened!(workflow) = new(workflow).reopened!

    def initialize(workflow)
      @workflow = workflow
    end

    def started!
      workflow.started_at ||= Time.current
      workflow.sync_work_unit_running!
      workflow.propagate_start_to_job!
    end

    def succeeded!
      workflow.finished_at = Time.current
      workflow.sync_work_unit_terminal!("succeeded")
      workflow.cleanup_workspace!
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
      workflow.sync_work_unit_terminal!("cancelled")
      workflow.cancel_active_descendants!
      workflow.propagate_cancel_to_job!
      workflow.cleanup_workspace!
      dispatch_hook(:after_cancel)
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
