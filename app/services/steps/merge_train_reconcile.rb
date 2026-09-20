module Steps
  # Agentic reconciliation pass for Epic merge trains. Runs on the built
  # integration branch, allows no-op success, and commits focused changes onto
  # that integration branch before the normal landing gates run.
  class MergeTrainReconcile < Base
    include MergeTrainStep

    def call
      train = merge_train
      if train.integration_branch.blank?
        fail_with!(:merge_train_rebuild_required, "merge_train_reconcile: integration branch is missing; rebuild required",
                   evidence: { merge_train_id: train.id })
      end

      workspace.setup
      checkout_integration_branch!(git, train, chdir: workspace.path.to_s, context: "merge_train_reconcile")

      run.update!(prompt: compose_prompt(train)) if run.prompt.blank?
      log("invoking agent for merge_train_reconcile step (#{workflow.slug}, #{train.integration_branch})")

      base_sha = head_sha
      run_agent(prompt: run.prompt)
      commit_agent_changes("Syrus merge-train reconciliation")
      assert_branch_history_intact!
      ensure_clean_worktree!

      post_sha = head_sha
      step_diff = diff_against_sha(base_sha)
      run.update!(
        base_sha: base_sha,
        head_sha: post_sha,
        agent_diff: step_diff,
        step_agent_diff: step_diff
      )
      train.update!(integration_sha: post_sha, state: "grading")
      publish_run_checkpoint!

      if step_diff.blank?
        log("merge_train_reconcile: no reconciliation changes needed at #{post_sha.first(9)}")
        reuse_validation_after_reconcile!(train, post_sha)
      else
        log("merge_train_reconcile: committed reconciliation changes #{base_sha.first(9)} -> #{post_sha.first(9)}")
        requeue_cached_validation_steps!
        record_reconcile_commit!(train, post_sha)
      end
    end

    private

    # Additive bookkeeping; any failure here must not fail the reconcile step.
    def record_reconcile_commit!(train, sha)
      return if sha.blank?

      landable = landed_commit_landable(train)
      return unless landable

      LandedCommit.create!(landable: landable, sha: sha, kind: "reconcile", position: 0)
    rescue StandardError => e
      log("merge_train_reconcile: could not record reconcile commit: #{e.class}: #{e.message}", kind: "system")
    end

    def git
      @git ||= streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0", "GIT_EDITOR" => "true" })
    end

    def compose_prompt(train)
      Prompts::MergeTrainReconcile.new(
        epic: train.epic,
        jobs: train.member_jobs,
        repo_slug: repository.slug,
        integration_branch: train.integration_branch,
        base_branch: train.base_branch
      ).to_s
    end

    def ensure_clean_worktree!
      status = git.run("status", "--porcelain", chdir: workspace.path.to_s).to_s.strip
      if status.present?
        fail_with!(:merge_train_rebase_conflict, "merge_train_reconcile: working tree is not clean after reconciliation")
      end
    end

    def reuse_validation_after_reconcile!(train, sha)
      base_sha = workflow.artifact("merge_train_base_sha")
      decision = LandingValidationCache.reusable_for?(
        job: job,
        head_sha: sha,
        tree_sha: current_tree_sha,
        base_sha: base_sha,
        base_ref: train.base_branch,
        grader_fingerprint: current_grader_fingerprint,
        changed_files_fingerprint: current_changed_files_fingerprint(base_sha)
      )
      LandingThroughputMetrics.record_validation_decision!(
        workflow: workflow,
        decision: decision,
        context: "merge_train_reconcile",
        head_sha: sha,
        base_sha: base_sha
      )

      if decision.reusable?
        skip_revalidated_grade_steps!(sha, decision)
      else
        log("merge_train_reconcile: landing graders will run - #{decision.reason}", kind: "system")
      end
    end

    def skip_revalidated_grade_steps!(sha, decision)
      log("merge_train_reconcile: reusing cached grading validation (#{decision.match_type}) for #{sha.first(7)} - #{decision.reason}", kind: "system")
      Step.suppress_cancel_cascade do
        cursor = step.next_step
        while cursor && cursor.kind != "merge_train_land"
          cursor.skip_with_reason!("landing_validation_cached") if cursor.may_skip?
          cursor = cursor.next_step
        end
      end
    end

    def requeue_cached_validation_steps!
      Step.transaction do
        cursor = step.next_step
        while cursor && cursor.kind != "merge_train_land"
          requeue_cached_validation_step!(cursor)
          cursor = cursor.next_step
        end
      end
    end

    def requeue_cached_validation_step!(candidate)
      return unless candidate.skipped?
      return unless candidate.details.to_h["skip_reason"] == "landing_validation_cached"

      details = candidate.details.to_h.except("skipped", "skip_reason")
      candidate.update!(state: "queued", finished_at: nil, details: details)
    end

    def current_tree_sha
      git.run("rev-parse", "HEAD^{tree}", chdir: workspace.path.to_s).strip
    rescue StandardError => e
      log("merge_train_reconcile: could not fingerprint reconciled tree: #{e.message}", kind: "system")
      nil
    end

    def current_grader_fingerprint
      plan = RepoGradePlan.for(workspace.path)
      GraderConclusionCache.fingerprint_for_plan(LandingGraderPlan.landing(plan), target_graph: TargetGraph::Compiler.compile(workspace.path))
    rescue StandardError => e
      log("merge_train_reconcile: could not fingerprint current landing graders: #{e.message}", kind: "system")
      nil
    end

    def current_changed_files_fingerprint(base_sha)
      return nil if base_sha.blank?

      files = git.run("diff", "--name-only", "#{base_sha}...HEAD", chdir: workspace.path.to_s)
        .split("\n").map(&:strip).reject(&:empty?)
      LandingValidationCache.changed_files_fingerprint(files)
    rescue StandardError => e
      log("merge_train_reconcile: could not fingerprint current changed-file selection: #{e.message}", kind: "system")
      nil
    end
  end
end
