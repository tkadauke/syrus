module Steps
  class MergeabilityPreflight < Base
    include AutoMergeControl

    def call
      pr_repo = job.effective_pr_repository
      client = GithubClient.for(repository: pr_repo, user: job.user)
      pr = client.pull_request(pr_repo.slug, job.pr_number, bypass_cache: true)
      persist_github_mergeability(pr)

      gate = AutoMergeGate.new(job: job, client: client, bypass_cache: true, pr: pr).evaluate
      case gate.outcome
      when :closed
        log("auto_merge: PR ##{job.pr_number} is already closed; cancelling workflow", kind: "system")
        close_job_for_closed_pull_request!(pr, client)
        cancel_workflow!
      when :transient
        handle_transient!(gate)
      when :needs_rebase
        handle_needs_rebase!(gate, client: client)
      else
        raise StepFailed, "auto_merge: #{gate.reason}" unless gate.merge_ready?

        decision = landing_validation_decision(client, pr_repo, pr)
        record_landing_validation_decision!(decision, pr)
        if decision.reusable?
          skip_revalidated_landing_steps!(pr, decision)
        else
          log("auto_merge: landing graders will run - #{decision.reason}", kind: "system")
        end
      end
    end

    private

    def close_job_for_closed_pull_request!(pr, client)
      return unless job.open?

      job.close_with_reason!(ClosedPullRequestResolution.reason(job: job, pr: pr, client: client))
    end

    def landing_validation_decision(client, pr_repo, pr)
      return LandingValidationCache.decision_for_pr(job: job, pr: pr) unless LandingValidationCache.green_validation_present?(job)

      LandingValidationCache.decision_for_pr(
        job: job,
        pr: pr,
        tree_sha: current_tree_sha(client, pr_repo, pr),
        grader_fingerprint: current_grader_fingerprint,
        changed_files_fingerprint: current_changed_files_fingerprint(pr)
      )
    end

    def handle_transient!(gate)
      local = LocalMergeabilityCheck.new(job: job, pr: gate.pr).call
      MergeabilityRecorder.record_local!(job: job, result: local)

      if local.conflict?
        rebase_gate = AutoMergeGate::Result.new(
          outcome: :needs_rebase,
          approved: gate.approved?,
          reason: "local mergeability check found conflicts while GitHub mergeable_state is #{deferred_mergeable_state(gate).inspect}",
          pr: gate.pr
        )
        handle_needs_rebase!(
          rebase_gate,
          defer_reason: "#{rebase_gate.reason}; local_mergeable_state=#{local.state}",
          client: GithubClient.for(repository: job.effective_pr_repository, user: job.user)
        )
        return
      end

      detail = local.clean? ? "; local rebase preflight passed" : "; local rebase preflight #{local.state}: #{local.message}"
      if local.clean?
        log("auto_merge: continuing - mergeable_state=#{deferred_mergeable_state(gate)}#{detail}", kind: "system")
        return
      end

      log("auto_merge: deferred - mergeable_state=#{deferred_mergeable_state(gate)}#{detail}", kind: "system")
      defer_landing_if_possible!
      LandingQueueProcessorJob.set(wait: LandingQueueProcessor::MERGEABILITY_RECHECK_DELAY).perform_later
      cancel_workflow!
    end

    def skip_revalidated_landing_steps!(pr, decision)
      log(
        "auto_merge: reusing cached landing validation (#{decision.match_type}) for " \
          "#{MergeabilityRecorder.head_sha(pr)&.first(7)}/#{MergeabilityRecorder.base_sha(pr)&.first(7)} - #{decision.reason}",
        kind: "system"
      )
      Step.suppress_cancel_cascade do
        cursor = step.next_step
        while cursor && cursor.kind != "auto_merge"
          if cursor.may_cancel?
            cursor.cancellation_reason = "landing_validation_cached"
            cursor.cancel!
            cursor.save!
          end
          cursor = cursor.next_step
        end
      end
    end

    def record_landing_validation_decision!(decision, pr)
      LandingThroughputMetrics.record_validation_decision!(
        workflow: workflow,
        decision: decision,
        context: "auto_merge",
        head_sha: MergeabilityRecorder.head_sha(pr),
        base_sha: MergeabilityRecorder.base_sha(pr)
      )
    end

    def current_tree_sha(client, pr_repo, pr)
      client.commit_tree_sha(pr_repo.slug, MergeabilityRecorder.head_sha(pr)).to_s.presence
    rescue StandardError => e
      log("auto_merge: could not read current tree SHA for landing validation cache: #{e.message}", kind: "system")
      nil
    end

    def current_changed_files_fingerprint(pr)
      workspace.setup
      base_sha = MergeabilityRecorder.base_sha(pr).presence || default_branch_ref
      files = GitRunner.new.run("diff", "--name-only", "#{base_sha}...HEAD", chdir: workspace.path.to_s)
        .split("\n").map(&:strip).reject(&:empty?)
      LandingValidationCache.changed_files_fingerprint(files)
    rescue StandardError => e
      log("auto_merge: could not fingerprint current changed-file selection: #{e.message}", kind: "system")
      nil
    end

    def current_grader_fingerprint
      workspace.setup
      plan = RepoGradePlan.for(workspace.path)
      plan = fast_grader_plan(plan)
      GraderConclusionCache.fingerprint_for_plan(plan)
    rescue StandardError => e
      log("auto_merge: could not fingerprint current landing graders: #{e.message}", kind: "system")
      nil
    end

    def fast_grader_plan(plan)
      LandingGraderPlan.landing(plan)
    end
  end
end
