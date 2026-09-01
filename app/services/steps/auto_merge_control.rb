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

    def defer_if_base_moved_since_validation!(client, pr, context:, branch_name: nil)
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

      rebase_outcome = rebase_and_continue_after_base_move!(client, pr, context: context, base_ref: base_ref, current_base_sha: current_base_sha, branch_name: branch_name)
      return false if rebase_outcome == :continue
      return true if rebase_outcome == :deferred

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

    def rebase_and_continue_after_base_move!(client, pr, context:, base_ref:, current_base_sha:, branch_name:)
      unless repository.trust_clean_rebase_grade?
        log("#{context}: base moved after validation; #{repository.slug} does not trust clean rebases, deferring for revalidation", kind: "system")
        return nil
      end

      branch = branch_name.presence || job.branch_name.presence || pr&.head&.ref.to_s.presence
      unless branch
        log("#{context}: base moved after validation but no rebased branch is available; deferring for revalidation", kind: "system")
        return nil
      end

      result = ::AutoRebase.new(job, base_branch: base_ref, branch_name: branch).call
      workflow.set_artifact!("landing_base_moved_rebase", result.to_h)

      unless result.succeeded?
        rebase_gate = AutoMergeGate::Result.new(
          outcome: :needs_rebase,
          approved: true,
          reason: "#{context} base moved after landing validation and clean rebase failed: #{result}",
          pr: pr
        )
        handle_needs_rebase!(
          rebase_gate,
          defer_reason: "#{rebase_gate.reason}; rebase_result=#{result.reason}",
          client: client
        )
        return :deferred
      end

      post_sha = result.post_sha.presence || MergeabilityRecorder.head_sha(pr)
      base_sha = result.base_sha.presence || current_base_sha
      MergeabilityRecorder.record_local!(
        job: job,
        result: LocalMergeabilityCheck::Result.new(
          state: "clean",
          mergeable: true,
          message: result.note.presence || "final clean rebase passed",
          head_sha: post_sha,
          base_sha: base_sha,
          base_ref: base_ref
        )
      )
      job.update!(
        mergeability_head_sha: post_sha,
        mergeability_base_sha: base_sha,
        mergeability_base_ref: base_ref,
        mergeability_checked_at: Time.current
      )
      workflow.set_artifact!("external_pr_head_sha", post_sha) if context == "external_pr_merge" && post_sha.present?
      carry_forward_current_landing_validation_after_base_move!(post_sha: post_sha, base_sha: base_sha, base_ref: base_ref)
      log("#{context}: base moved after validation; clean rebase #{result.note}, continuing landing on #{base_ref} #{base_sha.first(12)}", kind: "system")
      :continue
    end

    def carry_forward_current_landing_validation_after_base_move!(post_sha:, base_sha:, base_ref:)
      validation = workflow.artifact(LandingValidationCache::ARTIFACT_KEY)
      return unless validation.is_a?(Hash) && validation["required_graders_passed"] == true
      return if post_sha.blank? || base_sha.blank?

      LandingValidationCache.record!(
        workflow: workflow,
        head_sha: post_sha,
        tree_sha: commit_tree_sha_for_current_landing_validation(post_sha),
        base_sha: base_sha,
        base_ref: base_ref,
        grader_fingerprint: validation["grader_fingerprint"],
        changed_files_fingerprint: validation["changed_files_fingerprint"],
        validation_source: "final_clean_rebase"
      )
    rescue StandardError => e
      log("auto_merge: could not carry landing validation across final clean rebase: #{e.class}: #{e.message}", kind: "system")
    end

    def commit_tree_sha_for_current_landing_validation(head_sha)
      GithubClient.for(repository: repository, user: job.user).commit_tree_sha(repository.slug, head_sha).to_s.presence
    rescue StandardError
      nil
    end
  end
end
