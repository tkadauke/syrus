module Steps
  # Agentic reconciliation pass for Epic merge trains. Runs on the built
  # integration branch, allows no-op success, and commits focused changes onto
  # that integration branch before the normal landing gates run.
  class MergeTrainReconcile < Base
    include MergeTrainStep

    def call
      train = merge_train
      raise StepFailed, "merge_train_reconcile: integration branch is missing; rebuild required" if train.integration_branch.blank?

      workspace.setup
      git.run("checkout", train.integration_branch, chdir: workspace.path.to_s)

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

      if step_diff.blank?
        log("merge_train_reconcile: no reconciliation changes needed at #{post_sha.first(9)}")
        skip_revalidated_grade_steps!(post_sha) if LandingValidationCache.valid_head_for?(job: job, head_sha: post_sha)
      else
        log("merge_train_reconcile: committed reconciliation changes #{base_sha.first(9)} -> #{post_sha.first(9)}")
      end
    end

    private

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
      raise StepFailed, "merge_train_reconcile: working tree is not clean after reconciliation" if status.present?
    end

    def skip_revalidated_grade_steps!(sha)
      log("merge_train_reconcile: reusing cached grading validation for #{sha.first(7)}", kind: "system")
      Step.suppress_cancel_cascade do
        cursor = step.next_step
        while cursor && cursor.kind != "merge_train_land"
          if cursor.may_cancel?
            cursor.cancellation_reason = "landing_validation_cached"
            cursor.cancel!
            cursor.save!
          end
          cursor = cursor.next_step
        end
      end
    end
  end
end
