module Steps
  # Final step of Rebase workflow. Non-agentic. Force-pushes the
  # rebased branch to origin.
  #
  # Note: for clean auto-rebases this still runs after AgentRebase is
  # skipped, keeping "rebase succeeded" and "branch was pushed" as
  # separate workflow facts.
  class ForcePush < Base
    def call
      if noop_auto_rebase?
        log("force_push: skipped — deterministic rebase was a no-op")
        return
      end

      workspace.setup
      log("force_push: pushing rebased #{workspace.branch_name} (#{workflow.slug})")

      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      push_url = repository.authenticated_push_url(GithubClient.for(repository: repository, user: job.user).access_token)
      git.run("push", force_with_lease_arg, push_url,
              "HEAD:refs/heads/#{workspace.branch_name}",
              chdir: workspace.path.to_s)

      carry_forward_landing_validation!
    rescue GitRunner::GitError => e
      raise unless push_rejected?(e)

      message = "force_push: lease rejected for #{workspace.branch_name}; remote branch moved after Syrus fetched it. " \
                "Refusing to overwrite newer remote work."
      log(message)
      raise StepFailed, message
    end

    private

    # Opt-in (Repository#trust_clean_rebase_grade): when a PR already
    # passed required graders and the only change since is a *clean*
    # (conflict-free, agent-untouched) rebase onto a new base, re-stamp
    # the landing validation for the just-pushed head/base so the next
    # auto_merge preflight skips re-grading. The operator accepts the
    # residual risk that a clean rebase can still produce a logical
    # conflict the graders would have caught. Recording the *exact*
    # post-rebase head/base SHAs keeps the consumer
    # (LandingValidationCache.valid_for?) unchanged and safe: a wrong
    # SHA is merely a cache miss (re-grade), never an unsafe merge.
    def carry_forward_landing_validation!
      return unless repository.trust_clean_rebase_grade?
      return unless clean_auto_rebase?

      grader_fingerprint = current_landing_grader_fingerprint
      changed_files_fingerprint = current_changed_files_fingerprint
      source = LandingValidationCache.carry_forward_source_for(
        job: job,
        grader_fingerprint: grader_fingerprint,
        changed_files_fingerprint: changed_files_fingerprint
      )
      unless source.reusable?
        log("force_push: did not carry green grade across clean rebase - #{source.reason}", kind: "system")
        return
      end

      head_sha = streaming_git.run("rev-parse", "HEAD", chdir: workspace.path.to_s).strip
      tree_sha = streaming_git.run("rev-parse", "HEAD^{tree}", chdir: workspace.path.to_s).to_s.strip.presence
      base_sha = job.mergeability_base_sha.presence
      base_ref = job.mergeability_base_ref.presence
      if head_sha.blank? || base_sha.blank?
        log("force_push: did not carry green grade across clean rebase - current head/base SHA unavailable", kind: "system")
        return
      end

      LandingValidationCache.record!(
        workflow: workflow,
        head_sha: head_sha,
        tree_sha: tree_sha,
        base_sha: base_sha,
        base_ref: base_ref,
        grader_fingerprint: grader_fingerprint,
        changed_files_fingerprint: changed_files_fingerprint,
        validation_source: "clean_rebase"
      )
      log("force_push: carried green grade across clean rebase (#{repository.slug}: trust_clean_rebase_grade, #{source.reason}); next landing will skip re-grading head #{head_sha.first(7)}")
    rescue StandardError => e
      Rails.logger.warn("[ForcePush] carry-forward landing validation failed for Workflow ##{workflow.id}: #{e.class}: #{e.message}")
      nil
    end

    def current_landing_grader_fingerprint
      plan = RepoGradePlan.for(workspace.path)
      plan = LandingGraderPlan.landing(plan)
      GraderConclusionCache.fingerprint_for_plan(plan)
    rescue StandardError => e
      log("force_push: could not fingerprint current landing graders for carry-forward: #{e.message}", kind: "system")
      nil
    end

    def current_changed_files_fingerprint
      base_sha = job.mergeability_base_sha.presence || default_branch_ref
      files = streaming_git.run("diff", "--name-only", "#{base_sha}...HEAD", chdir: workspace.path.to_s)
        .split("\n").map(&:strip).reject(&:empty?)
      LandingValidationCache.changed_files_fingerprint(files)
    rescue StandardError => e
      log("force_push: could not fingerprint current changed-file selection for carry-forward: #{e.message}", kind: "system")
      nil
    end

    def clean_auto_rebase?
      result = workflow.artifact("auto_rebase_result")
      result.is_a?(Hash) && result["succeeded"] == true
    end

    def noop_auto_rebase?
      result = workflow.artifact("auto_rebase_result")
      result.is_a?(Hash) && result["changed"] == false && result["reason"] == "rebased"
    end

    def force_with_lease_arg
      expected_sha = expected_remote_sha
      return "--force-with-lease=refs/heads/#{workspace.branch_name}:#{expected_sha}" if expected_sha

      "--force-with-lease"
    end

    def expected_remote_sha
      auto_rebase_result = workflow.artifact("auto_rebase_result")
      return unless auto_rebase_result.is_a?(Hash)

      if auto_rebase_result["reason"] == "rebased" && auto_rebase_result["changed"] == true
        auto_rebase_result["post_sha"].presence
      else
        auto_rebase_result["pre_sha"].presence
      end
    end
  end
end
