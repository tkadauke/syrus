module Steps
  module AutoMergeControl
    MERGE_BASE_MOVED_MESSAGE = "base branch moved after landing validation".freeze
    RETRYABLE_MERGE_RACE_ERROR = /
      (?:base\s+branch|head\s+branch|pull\s+request\s+head).*?(?:modified|changing)|
      review\s+and\s+try\s+(?:the\s+)?merge
    /ix

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
      WorkUnits::WorkflowCancellation.cancel!(
        workflow,
        reason: "landing_deferred",
        artifacts: {
          "cancelled_reason" => "landing_deferred",
          "cancelled_at" => Time.current.iso8601
        }
      )
    end

    def defer_landing_if_possible!
      return unless job.may_defer_landing?

      job.defer_landing!
      job.save! if job.changed?
    end

    def defer_landing_for_retry!(context:, reason:)
      log("#{context}: deferred - #{reason}", kind: "system")
      defer_landing_if_possible!
      LandingQueueProcessorJob.set(wait: LandingQueueProcessor::MERGEABILITY_RECHECK_DELAY).perform_later
      cancel_workflow!
    end

    def retryable_merge_race_error?(error)
      RETRYABLE_MERGE_RACE_ERROR.match?(error.message.to_s)
    end

    def defer_if_base_moved_since_validation!(client, pr, context:)
      validated_base_sha = job.mergeability_base_sha.to_s.presence
      base_ref = MergeabilityRecorder.base_ref(pr).presence || job.mergeability_base_ref.presence || repository.default_branch
      return false if validated_base_sha.blank? || base_ref.blank?

      current_base_sha =
        begin
          client.branch_head_sha(repository.slug, base_ref).to_s.presence
        rescue StandardError => e
          log("#{context}: could not verify base SHA before merge: #{e.class}: #{e.message}", kind: "system")
          return false
        end
      return false if current_base_sha.blank? || current_base_sha == validated_base_sha

      workflow.set_artifact!(
        "landing_base_moved",
        {
          "validated_base_sha" => validated_base_sha,
          "current_base_sha" => current_base_sha,
          "base_ref" => base_ref,
          "reason" => "base_moved_after_validation",
          "detected_at" => Time.current.iso8601
        }
      )
      defer_landing_for_retry!(
        context: context,
        reason: "#{MERGE_BASE_MOVED_MESSAGE} (#{base_ref} #{validated_base_sha.first(12)} -> #{current_base_sha.first(12)})"
      )
      true
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
