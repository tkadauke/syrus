module Steps
  # Final step of PrFeedback / CiFailure workflows. Non-agentic.
  # Pushes the existing branch to origin (no PR opening — PR
  # already exists from the original Initial workflow).
  class Push < Base
    class RemoteBranchAdvancedRebaseConflict < StepFailed
      FAILURE_CODE = "remote_branch_advanced_rebase_conflict".freeze
    end

    def call
      workspace.setup
      if workflow.trigger_kind == "manual_agentic_run" && workflow.artifact("manual_agentic_run_push") == false
        log("push: skipped because manual_agentic_run requested push=false")
        return
      end

      log("push: pushing branch #{workspace.branch_name} (#{workflow.slug})")
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      authenticated_git(git, "git_push") { |push_url| push_branch(git, push_url) }
      apply_job_metadata_refresh
      update_managed_pr_footers unless refreshed_job_metadata_applied?
    end

    private

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
      git.run("push", push_url, "HEAD:refs/heads/#{workspace.branch_name}",
              chdir: workspace.path.to_s)
    end

    def authenticated_git(git, operation_type, &block)
      GithubAuthenticatedGit.run(
        repository: repository,
        user: job.user,
        git: git,
        operation_type: operation_type,
        log: method(:log),
        &block
      )
    end

    def rebase_onto_remote_branch!(git, push_url)
      branch = workspace.branch_name
      git.run("fetch", push_url, "+refs/heads/#{branch}:refs/remotes/origin/#{branch}",
              chdir: workspace.path.to_s)
      workflow.set_artifact!("push_rebase_remote_ref", "refs/remotes/origin/#{branch}")
      workflow.set_artifact!("push_rebase_remote_sha", git.run("rev-parse", "refs/remotes/origin/#{branch}", chdir: workspace.path.to_s).strip)
      workflow.set_artifact!("push_rebase_branch", branch)
      workflow.set_artifact!("push_rebase_started_at", Time.current.iso8601)
      run_rebase_onto_remote_branch!(git, branch)
    end

    def run_rebase_onto_remote_branch!(git, branch)
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
