module Steps
  class LifecyclePropagation
    def self.succeeded!(step) = new(step).succeeded!
    def self.succeeded_grade!(step) = new(step).succeeded_grade!
    def self.failed!(step) = new(step).failed!
    def self.cancelled!(step) = new(step).cancelled!

    def initialize(step)
      @step = step
    end

    # When a Step succeeds, hand off to the dispatcher to start the next one
    # (if any). Linear chain: next_step is at most one. The dispatcher creates
    # the Run on the next Step; this propagation only signals that the current
    # Step is done.
    def succeeded!
      StepDispatcher.advance_from(step)
    end

    def succeeded_grade!
      AutoApprovalRule.for(step.workflow.job).apply_after_grader_success!(step)
    end

    # When a Step fails, the linear chain cannot advance. Mark the Workflow
    # failed, which fires Workflow cleanup and lifecycle hooks.
    def failed!
      StepDispatcher.fail_from(step)
    end

    # When a Step is cancelled, anything queued behind it is orphaned because
    # the dispatcher advances only on success. Cascade the cancel to downstream
    # queued Steps, then cancel the Workflow if no active descendants remain.
    def cancelled!
      return if Thread.current[:syrus_step_suppress_cancel_cascade]

      Step.suppress_cancel_cascade { cancel_downstream_queued_steps! }
      cancel_workflow_if_idle!
    end

    private

    attr_reader :step

    def cancel_downstream_queued_steps!
      cursor = step.next_step
      while cursor
        if cursor.may_cancel?
          cursor.cancel!
          cursor.save!
        end
        cursor = cursor.next_step
      end
    end

    def cancel_workflow_if_idle!
      workflow = step.workflow
      return unless workflow.may_cancel?
      return if workflow.active_descendants?

      workflow.cancel!
      workflow.save!
    end
  end
end
