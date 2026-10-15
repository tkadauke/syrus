module Steps
  class StackAgentRebase < Base
    def call
      workspace.setup
      fetch_pending_branches
      pre_shas = pending_entries.to_h { |entry| [ entry.fetch("branch_name"), rev_parse(entry.fetch("branch_name")) ] }
      workflow.set_artifact!(StackRebasePlan::AGENT_PRE_SHAS_ARTIFACT, pre_shas)
      run.update!(prompt: compose_prompt) if run.prompt.blank?

      log("invoking agent for stack_agent_rebase step (#{workflow.slug})")
      run_agent(prompt: run.prompt)

      pushes = pending_entries.map do |entry|
        branch = entry.fetch("branch_name")
        entry.merge("pre_sha" => pre_shas[branch], "post_sha" => rev_parse(branch))
      end
      verify_rebases_complete!(pushes)
      workflow.set_artifact!(StackRebasePlan::AGENT_PUSHES_ARTIFACT, pushes)
      run.update!(head_sha: pushes.last&.fetch("post_sha", nil))
    end

    private

    def pending_entries
      Array(workflow.artifact(StackRebasePlan::AGENT_PENDING_ARTIFACT))
    end

    def compose_prompt
      Prompts::StackRebase.new(repo_slug: repository.slug, stack_entries: pending_entries).to_s
    end

    def verify_rebases_complete!(pushes)
      git = GitRunner.new

      if rebase_in_progress?(git)
        raise StepFailed, "stack_agent_rebase: rebase is still in progress; run git rebase --continue until it completes"
      end

      status = git.run("status", "--porcelain", chdir: workspace.path.to_s).strip
      raise StepFailed, "stack_agent_rebase: working tree is not clean after rebase" if status.present?

      pushes.each do |entry|
        branch = entry.fetch("branch_name")
        if entry.fetch("pre_sha") == entry.fetch("post_sha")
          raise StepFailed, "stack_agent_rebase: #{branch} did not move after rebase"
        end

        base = entry.fetch("base_branch")
        git.run("merge-base", "--is-ancestor", base, branch, chdir: workspace.path.to_s)
      rescue GitRunner::GitError => e
        raise StepFailed, "stack_agent_rebase: #{branch} was not rebased onto #{base}: #{e.message}"
      end
    end

    def fetch_pending_branches
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      fetched_branches = {}
      abort_rebase_if_present(git)

      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_stack_rebase_fetch", log: method(:log)) do |push_url|
        pending_entries.each do |entry|
          branch = entry.fetch("branch_name")
          base = entry.fetch("base_branch")
          fetch_remote_branch_once(git, push_url, branch, fetched_branches)
          fetch_remote_branch_once(git, push_url, base, fetched_branches)
        end
      end

      detach_worktree(git) if pending_entries.any?
      pending_entries.each do |entry|
        branch = entry.fetch("branch_name")
        git.run("branch", "-f", "--", branch, "refs/remotes/origin/#{branch}", chdir: workspace.path.to_s)
      end
      git.run("switch", "--", pending_entries.first.fetch("branch_name"), chdir: workspace.path.to_s) if pending_entries.any?
    end

    def fetch_remote_branch_once(git, push_url, branch, fetched_branches)
      return if fetched_branches[branch]

      fetch_remote_branch(git, push_url, branch)
      fetched_branches[branch] = true
    end

    def fetch_remote_branch(git, push_url, branch)
      git.run("fetch", push_url, "refs/heads/#{branch}:refs/remotes/origin/#{branch}", chdir: workspace.path.to_s)
    end

    def detach_worktree(git)
      git.run("checkout", "--detach", "HEAD", chdir: workspace.path.to_s)
    end

    def abort_rebase_if_present(git)
      return unless rebase_in_progress?(git)

      log("stack_agent_rebase: aborting leftover rebase before resetting stack branches")
      git.run("rebase", "--abort", chdir: workspace.path.to_s)
    rescue GitRunner::GitError
      nil
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

    def rev_parse(ref)
      GitRunner.new.run("rev-parse", "--verify", "refs/heads/#{ref}", chdir: workspace.path.to_s).strip
    rescue GitRunner::GitError => e
      raise StepFailed, "stack_agent_rebase: expected local branch #{ref.inspect} after agent run: #{e.message}"
    end
  end
end
