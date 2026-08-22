module Steps
  module AutoMergeControl
    private

    def persist_github_mergeability(pr)
      return unless pr

      MergeabilityRecorder.record_github!(job: job, pr: pr)
    end

    def cancel_workflow!
      run.cancel! if run.may_cancel?
      run.save!
      step.cancel! if step.may_cancel?
      step.save!
      workflow.cancel! if workflow.may_cancel?
      workflow.save!
    end

    def defer_landing_if_possible!
      return unless job.may_defer_landing?

      job.defer_landing!
      job.save! if job.changed?
    end

    def handle_needs_rebase!(gate, defer_reason: "mergeable_state=#{deferred_mergeable_state(gate)}", client:)
      if RebaseLoopGuard.noop_rebase_for?(job: job, pr: gate.pr, client: client)
        log("auto_merge: deferred - #{defer_reason}; latest rebase was a no-op for this PR head/base, waiting for GitHub mergeability to refresh", kind: "system")
        defer_landing_if_possible!
        cancel_workflow!
        return
      end

      if rebase_attempt_cap_reached?(gate.pr)
        log("auto_merge: needs_rebase but #{PollRebaseJob::REBASE_ATTEMPT_CAP} consecutive rebase attempts have failed; failing landing", kind: "system")
        raise Base::StepFailed, "auto_merge: #{gate.reason} and rebase cap reached"
      end

      log("auto_merge: deferred - #{defer_reason}; dispatching rebase workflow inline", kind: "system")
      defer_landing_if_possible!

      unless rebase_workflow_active?
        rebase_workflow = RebaseWorkflowSelector.instantiate(job: job, pr: gate.pr)
        log("auto_merge: dispatched rebase #{rebase_workflow.slug}", kind: "system")
        WorkUnits::Launcher.start!(rebase_workflow)
      end

      cancel_workflow!
    end

    def rebase_workflow_active?
      RebaseWorkflowSelector.active_for_stack?(job) || RebaseWorkflowSelector.active_merge_train_for_stack?(job)
    end

    def rebase_attempt_cap_reached?(pr)
      RebaseAttemptGuard.cap_reached?(job, pr: pr)
    end

    def deferred_mergeable_state(gate)
      MergeabilityRecorder.github_state(gate.pr) || "nil"
    end
  end
end
