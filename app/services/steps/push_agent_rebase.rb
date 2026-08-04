module Steps
  # Agentic recovery after a follow-up Push discovered that the remote PR
  # branch advanced and a deterministic rebase of the local follow-up commit
  # conflicted. This step recreates the rebase conflict in the workflow
  # workspace, lets the agent resolve it, then verifies a clean rebased HEAD.
  class PushAgentRebase < Base
    def call
      abort_rebase_if_present
      workspace.setup

      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      remote_ref = GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_push_rebase_fetch", log: method(:log)) do |push_url|
        fetch_remote_branch!(git, push_url)
      end
      pre_sha = head_sha

      if deterministic_rebase_succeeded?(git, remote_ref)
        log("push_agent_rebase: deterministic retry rebased cleanly onto #{remote_ref}")
      else
        run.update!(prompt: compose_prompt(remote_ref)) if run.prompt.blank?
        log("invoking agent for push_agent_rebase step (#{workflow.slug})")
        run_agent(prompt: run.prompt)
      end

      verify_rebase_complete!(git, remote_ref)
      post_sha = head_sha
      raise StepFailed, "push_agent_rebase: HEAD did not move after rebasing onto #{remote_ref}" if pre_sha == post_sha

      workflow.set_artifact!("push_rebase_resolved_head_sha", post_sha)
      run.update!(head_sha: post_sha)
      log("push_agent_rebase: rebased #{pre_sha[0, 7]} -> #{post_sha[0, 7]}")
    end

    private

    def fetch_remote_branch!(git, push_url)
      branch = workspace.branch_name
      remote_ref = "refs/remotes/origin/#{branch}"
      git.run("fetch", push_url, "+refs/heads/#{branch}:#{remote_ref}", chdir: workspace.path.to_s)
      workflow.set_artifact!("push_rebase_remote_ref", remote_ref)
      workflow.set_artifact!("push_rebase_remote_sha", git.run("rev-parse", remote_ref, chdir: workspace.path.to_s).strip)
      remote_ref
    end

    def deterministic_rebase_succeeded?(git, remote_ref)
      git.run("rebase", remote_ref, chdir: workspace.path.to_s)
      true
    rescue GitRunner::GitError
      false
    end

    def compose_prompt(remote_ref)
      Prompts::PushRebase.new(
        repo_slug: repository.slug,
        branch_name: workspace.branch_name,
        remote_ref: remote_ref,
        pr_number: job.pr_number || job.external_pr_number
      ).to_s
    end

    def verify_rebase_complete!(git, remote_ref)
      if rebase_in_progress?(git)
        raise StepFailed, "push_agent_rebase: rebase is still in progress; run git rebase --continue until it completes"
      end

      status = git.run("status", "--porcelain", chdir: workspace.path.to_s).strip
      raise StepFailed, "push_agent_rebase: working tree is not clean after rebase" if status.present?

      git.run("merge-base", "--is-ancestor", remote_ref, "HEAD", chdir: workspace.path.to_s)
    rescue GitRunner::GitError => e
      raise StepFailed, "push_agent_rebase: rebased HEAD does not contain #{remote_ref}: #{e.message}"
    end

    def rebase_in_progress?(git)
      path = git.run("rev-parse", "--git-path", "rebase-merge", chdir: workspace.path.to_s).strip
      return true if path.present? && File.exist?(absolute_git_path(path))

      path = git.run("rev-parse", "--git-path", "rebase-apply", chdir: workspace.path.to_s).strip
      path.present? && File.exist?(absolute_git_path(path))
    rescue GitRunner::GitError
      false
    end

    def absolute_git_path(path)
      pathname = Pathname.new(path)
      pathname.absolute? ? pathname : workspace.path.join(pathname)
    end

    def abort_rebase_if_present
      return unless workspace.path.exist?

      GitRunner.new.run("rebase", "--abort", chdir: workspace.path.to_s)
    rescue GitRunner::GitError
      nil
    end
  end
end
