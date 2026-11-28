module Steps
  # Final step of PrFeedback / CiFailure workflows. Non-agentic.
  # Pushes the existing branch to origin (no PR opening — PR
  # already exists from the original Initial workflow).
  class Push < Base
    class RemoteBranchAdvancedRebaseConflict < StepFailed
      FAILURE_CODE = "remote_branch_advanced_rebase_conflict".freeze
      problem_code :branch_diverged
    end

    def call
      workspace.setup
      if workflow.trigger_kind == "manual_agentic_run" && workflow.artifact("manual_agentic_run_push") == false
        log("push: skipped because manual_agentic_run requested push=false")
        verify_manual_break_glass_outcomes!
        return
      end

      log("push: pushing branch #{workspace.branch_name} (#{workflow.slug})")
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      begin
        authenticated_git("git_push", git: git) { |push_url| push_branch(git, push_url) }
      rescue GithubPushProtection::Rejected => e
        handle_push_protection_rejection!(e) do
          authenticated_git("git_push_protection_repair_push", git: git) do |push_url|
            git.run("-c", "core.hooksPath=/dev/null", "push", push_url, "HEAD:refs/heads/#{workspace.branch_name}", chdir: workspace.path.to_s)
          end
        end
      end
      record_accepted_push!
      persist_pushed_all_changes_version!
      apply_job_metadata_refresh
      update_managed_pr_footers unless refreshed_job_metadata_applied?
      verify_manual_break_glass_outcomes!
    end

    private

    def verify_manual_break_glass_outcomes!
      return unless workflow.trigger_kind == "manual_agentic_run"
      return unless workflow.artifact("manual_agentic_run_github_access") == true

      ManualAgenticRun::OutcomeVerifier.new(workflow).verify!
      log("push: verified declared break-glass GitHub outcomes through the provider client")
    end

    def apply_job_metadata_refresh
      result = JobMetadataRefreshApplier.new(workflow).call
      log("push: #{result}") if result.present?
    end

    def refreshed_job_metadata_applied?
      workflow.reload.artifact("job_metadata_applied").is_a?(Hash) &&
        workflow.artifact("job_metadata_applied")["changed"] == true
    end

    def push_branch(git, push_url)
      git.run("push", push_url, "HEAD:refs/heads/#{workspace.branch_name}",
              chdir: workspace.path.to_s)
    rescue GitRunner::GitError => e
      raise unless push_rejected?(e)

      log("push: remote branch advanced; rebasing #{workspace.branch_name} onto the current remote tip and retrying")
      rebase_onto_remote_branch!(git, push_url)
      push_after_remote_refresh!(git, push_url)
    end

    # The push was rejected, so the remote moved. BranchTruth decides which
    # copy is true:
    # - the remote already holds this workflow's work: adopt it, push nothing;
    # - local holds every remote patch on a base at least as fresh (a repair
    #   that deliberately rebased the branch): replace the observed remote
    #   tip under a lease. Rebasing that correct history back onto the stale
    #   remote would replay every base commit;
    # - otherwise (the remote was rebased under us, or holds other work):
    #   replay the local commits onto it, which drops the patch-equivalent
    #   ones, and push the result as a fast-forward.
    def push_after_remote_refresh!(git, push_url)
      branch = workspace.branch_name
      remote_sha = workflow.artifact("push_rebase_remote_sha")
      truth = BranchTruth.classify(git: git, chdir: workspace.path, local: "HEAD", remote: remote_sha, base: push_base_ref(git, push_url))
      workflow.set_artifact!("push_branch_truth", truth.to_h)
      log("push: #{branch} remote=#{remote_sha.to_s.first(9)} is #{truth.relation} -> #{truth.outcome}")

      if truth.up_to_date? || truth.adopt_remote?
        git.run("reset", "--hard", remote_sha, chdir: workspace.path.to_s)
        workflow.set_artifact!(BranchTruth::ADOPTED_ARTIFACT, truth.to_h.merge("branch" => branch, "context" => "push", "adopted_at" => Time.current.iso8601))
        log("push: the remote branch already holds this workflow's work (#{truth.relation}); adopting it instead of pushing")
      elsif truth.publish?
        log("push: local branch preserves the remote patches on a base at least as fresh; replacing the observed remote tip with force-with-lease")
        git.run(
          "push", "--force-with-lease=refs/heads/#{branch}:#{truth.lease_sha}",
          push_url, "HEAD:refs/heads/#{branch}", chdir: workspace.path.to_s
        )
      else
        run_rebase_onto_remote_branch!(git, branch)
        git.run("push", push_url, "HEAD:refs/heads/#{branch}", chdir: workspace.path.to_s)
      end
    end

    # The branch's intended base, so BranchTruth can tell base commits from
    # the branch's own work and see which side was rebased later. Without it
    # the rule assumes the remote is the fresher copy.
    def push_base_ref(git, push_url)
      base = RebaseTarget.branch_for(job: job, workflow: workflow).presence
      return nil if base.blank? || base == workspace.branch_name

      ref = "refs/remotes/origin/#{base}"
      git.run("fetch", push_url, "+refs/heads/#{base}:#{ref}", chdir: workspace.path.to_s)
      ref
    rescue StandardError => e
      log("push: could not fetch the branch base for classification (#{e.class}); classifying without it", kind: "system")
      nil
    end

    def rebase_onto_remote_branch!(git, push_url)
      branch = workspace.branch_name
      git.run("fetch", push_url, "+refs/heads/#{branch}:refs/remotes/origin/#{branch}",
              chdir: workspace.path.to_s)
      workflow.set_artifact!("push_rebase_remote_ref", "refs/remotes/origin/#{branch}")
      workflow.set_artifact!("push_rebase_remote_sha", git.run("rev-parse", "refs/remotes/origin/#{branch}", chdir: workspace.path.to_s).strip)
      workflow.set_artifact!("push_rebase_branch", branch)
      workflow.set_artifact!("push_rebase_started_at", Time.current.iso8601)
    end

    def run_rebase_onto_remote_branch!(git, branch)
      GitMergeDrivers.register!(git: git, path: workspace.path)
      git.run("rebase", "refs/remotes/origin/#{branch}", chdir: workspace.path.to_s)
    rescue GitRunner::GitError => e
      abort_rebase(git)
      mark_failure_code!(RemoteBranchAdvancedRebaseConflict::FAILURE_CODE)
      raise RemoteBranchAdvancedRebaseConflict,
        "push: remote branch advanced and automatic rebase failed for #{branch}: #{e.message}"
    end

    def abort_rebase(git)
      git.run("rebase", "--abort", chdir: workspace.path.to_s)
    rescue GitRunner::GitError
      nil
    end

    def update_managed_pr_footers
      return if job.pr_number.blank?

      pr_repo = job.effective_pr_repository
      client = GithubClient.for(repository: pr_repo, user: job.user)
      pr = client.pull_request(pr_repo.slug, job.pr_number, bypass_cache: true)
      body = PrCostFooter.apply(PrStackFooter.apply(pr.body.to_s, job), job)
      client.update_pull_request_body(pr_repo.slug, job.pr_number, body)
      log("push: updated PR ##{job.pr_number} managed footers")
    end
  end
end
