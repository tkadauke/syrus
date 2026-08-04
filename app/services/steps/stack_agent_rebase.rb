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

    def fetch_pending_branches
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      current_branch = current_branch_name(git)
      fetched_branches = {}

      GithubAuthenticatedGit.run(repository: repository, user: job.user, git: git, operation_type: "git_stack_rebase_fetch", log: method(:log)) do |push_url|
        pending_entries.each do |entry|
          branch = entry.fetch("branch_name")
          base = entry.fetch("base_branch")
          fetch_remote_branch_once(git, push_url, branch, fetched_branches)
          if branch == current_branch
            git.run("reset", "--hard", "refs/remotes/origin/#{branch}", chdir: workspace.path.to_s)
          else
            git.run("branch", "-f", branch, "refs/remotes/origin/#{branch}", chdir: workspace.path.to_s)
          end
          fetch_remote_branch_once(git, push_url, base, fetched_branches)
        end
      end
      git.run("checkout", pending_entries.first.fetch("branch_name"), chdir: workspace.path.to_s) if pending_entries.any?
    end

    def fetch_remote_branch_once(git, push_url, branch, fetched_branches)
      return if fetched_branches[branch]

      fetch_remote_branch(git, push_url, branch)
      fetched_branches[branch] = true
    end

    def fetch_remote_branch(git, push_url, branch)
      git.run("fetch", push_url, "refs/heads/#{branch}:refs/remotes/origin/#{branch}", chdir: workspace.path.to_s)
    end

    def current_branch_name(git)
      git.run("rev-parse", "--abbrev-ref", "HEAD", chdir: workspace.path.to_s).strip
    rescue GitRunner::GitError
      nil
    end

    def rev_parse(ref)
      GitRunner.new.run("rev-parse", ref, chdir: workspace.path.to_s).strip
    rescue GitRunner::GitError => e
      raise StepFailed, "stack_agent_rebase: expected local branch #{ref.inspect} after agent run: #{e.message}"
    end
  end
end
