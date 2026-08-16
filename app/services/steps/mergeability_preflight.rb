module Steps
  class MergeabilityPreflight < Base
    include AutoMergeControl

    RefSnapshot = Struct.new(:sha, :ref, :repo, keyword_init: true)
    PullRequestSnapshot = Struct.new(:state, :mergeable, :mergeable_state, :labels, :head, :base, keyword_init: true)

    def call
      if job.external_pr?
        call_for_external_pr
        return
      end

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

        rebase_result = mechanically_rebase_before_landing!(gate, client: client)
        pr_for_validation = pr_after_mechanical_rebase(pr, rebase_result)

        decision = landing_validation_decision(client, pr_repo, pr_for_validation)
        record_landing_validation_decision!(decision, pr_for_validation)
        if decision.reusable?
          skip_revalidated_landing_steps!(pr_for_validation, decision)
        else
          log("auto_merge: landing graders will run - #{decision.reason}", kind: "system")
        end
      end
    end

    private

    # Simplified preflight for external PRs: verify the PR is still open
    # and GitHub reports it as mergeable. We don't own the branch, so
    # rebase dispatch and landing-validation caching don't apply.
    def call_for_external_pr
      client = GithubClient.for(repository: repository, user: job.user)
      pr = client.pull_request(repository.slug, job.external_pr_number, bypass_cache: true)
      persist_github_mergeability(pr)
      record_external_pr_head!(pr)

      if pr.state == "closed"
        log("external_pr_merge: PR ##{job.external_pr_number} is already closed; cancelling workflow", kind: "system")
        close_job_for_closed_pull_request_external!(pr)
        cancel_workflow!
        return
      end

      mergeable_state = pr.respond_to?(:mergeable_state) ? pr.mergeable_state : nil
      case mergeable_state
      when "clean", "unstable", nil
        mechanically_rebase_external_pr_before_landing!(pr, client: client) if same_repository_external_pr?(pr)
      when *AutoMergeGate::TRANSIENT_MERGEABLE_STATES
        log("external_pr_merge: deferred - mergeable_state=#{mergeable_state.inspect}", kind: "system")
        defer_landing_if_possible!
        LandingQueueProcessorJob.set(wait: LandingQueueProcessor::MERGEABILITY_RECHECK_DELAY).perform_later
        cancel_workflow!
      else
        raise StepFailed, "external_pr_merge: PR ##{job.external_pr_number} not mergeable (mergeable_state=#{mergeable_state.inspect})"
      end
    end

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
        base_tree_sha: current_base_tree_sha(client, pr_repo, pr),
        grader_fingerprint: current_grader_fingerprint,
        changed_files_fingerprint: current_changed_files_fingerprint(pr)
      )
    end

    def close_job_for_closed_pull_request_external!(pr)
      return unless job.open?

      reason = pr.merged ? "external_pr_merged" : "external_pr_closed"
      job.close_with_reason!(reason)
    end

    def record_external_pr_head!(pr)
      workflow.set_artifact!("external_pr_head_repo", pr.head&.repo&.full_name)
      workflow.set_artifact!("external_pr_head_ref", pr.head&.ref)
      workflow.set_artifact!("external_pr_head_sha", pr.head&.sha)
    end

    def same_repository_external_pr?(pr)
      pr.head&.repo&.full_name == repository.slug && pr.head&.ref.to_s.present?
    end

    def mechanically_rebase_external_pr_before_landing!(pr, client:)
      gate = AutoMergeGate::Result.new(
        outcome: :ready,
        approved: true,
        reason: "external PR is approved for landing",
        pr: pr
      )
      result = mechanically_rebase_before_landing!(
        gate,
        client: client,
        context: "external_pr_merge",
        branch_name: pr.head&.ref
      )
      return unless result&.changed?

      workflow.set_artifact!("external_pr_head_sha", result.post_sha)
    end

    def mechanically_rebase_before_landing!(gate, client:, context: "auto_merge", branch_name: nil)
      result = auto_rebase_for(gate.pr, branch_name: branch_name).call
      workflow.set_artifact!("mergeability_preflight_rebase", result.to_h)

      if result.succeeded?
        MergeabilityRecorder.record_local!(
          job: job,
          result: LocalMergeabilityCheck::Result.new(
            state: "clean",
            mergeable: true,
            message: result.note.presence || "mechanical rebase passed",
            head_sha: result.post_sha.presence || MergeabilityRecorder.head_sha(gate.pr),
            base_sha: result.base_sha.presence || MergeabilityRecorder.base_sha(gate.pr),
            base_ref: MergeabilityRecorder.base_ref(gate.pr)
          )
        )
        if result.changed?
          job.update!(
            mergeability_head_sha: result.post_sha,
            mergeability_base_sha: result.base_sha.presence || job.mergeability_base_sha,
            mergeability_checked_at: Time.current
          )
          log("#{context}: mechanically rebased and pushed #{branch_name.presence || job.branch_name} before landing graders - #{result.note}", kind: "system")
        else
          log("#{context}: mechanical rebase before landing graders passed - #{result.note}", kind: "system")
        end
        return result
      end

      rebase_gate = AutoMergeGate::Result.new(
        outcome: :needs_rebase,
        approved: gate.approved?,
        reason: "#{context} mechanical rebase before landing graders failed: #{result}",
        pr: gate.pr
      )
      handle_needs_rebase!(
        rebase_gate,
        defer_reason: "#{rebase_gate.reason}; rebase_result=#{result.reason}",
        client: client
      )
      nil
    end

    def auto_rebase_for(pr, branch_name:)
      kwargs = { base_branch: MergeabilityRecorder.base_ref(pr) }
      kwargs[:branch_name] = branch_name if branch_name.present?
      ::AutoRebase.new(job, **kwargs)
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
        cursor = step.reload.next_step
        while cursor && cursor.kind != "auto_merge"
          cursor.skip_with_reason!("landing_validation_cached") if cursor.may_skip?
          cursor = cursor.next_step
        end
      end
    end

    def pr_after_mechanical_rebase(pr, result)
      return pr unless result&.changed?

      PullRequestSnapshot.new(
        state: pr.state,
        mergeable: pr.mergeable,
        mergeable_state: pr.mergeable_state,
        labels: pr.respond_to?(:labels) ? pr.labels : [],
        head: RefSnapshot.new(
          sha: result.post_sha.presence || MergeabilityRecorder.head_sha(pr),
          ref: pr.head&.ref,
          repo: pr.head&.repo
        ),
        base: RefSnapshot.new(
          ref: MergeabilityRecorder.base_ref(pr),
          sha: result.base_sha.presence || MergeabilityRecorder.base_sha(pr)
        )
      )
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

    def current_base_tree_sha(client, pr_repo, pr)
      client.commit_tree_sha(pr_repo.slug, MergeabilityRecorder.base_sha(pr)).to_s.presence
    rescue StandardError => e
      log("auto_merge: could not read current base tree SHA for landing validation cache: #{e.message}", kind: "system")
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
