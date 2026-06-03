module Steps
  class StackAgentRebase < Base
    def call
      workspace.setup
      fetch_pending_branches
      pre_shas = pending_entries.to_h { |entry| [ entry.fetch("branch_name"), rev_parse(entry.fetch("branch_name")) ] }
      workflow.set_artifact!(StackRebasePlan::AGENT_PRE_SHAS_ARTIFACT, pre_shas)
      run.update!(prompt: compose_prompt) if run.prompt.blank?

      log("invoking agent for stack_agent_rebase step (workflow ##{workflow.id})")
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
      push_url = repository.authenticated_push_url(GithubClient.for(repository: repository, user: job.user).access_token)

      pending_entries.each do |entry|
        branch = entry.fetch("branch_name")
        base = entry.fetch("base_branch")
        git.run("fetch", push_url, "refs/heads/#{branch}:refs/heads/#{branch}", chdir: workspace.path.to_s)
        git.run("fetch", push_url, "refs/heads/#{base}:refs/remotes/origin/#{base}", chdir: workspace.path.to_s)
      end
      git.run("checkout", pending_entries.first.fetch("branch_name"), chdir: workspace.path.to_s) if pending_entries.any?
    end

    def rev_parse(ref)
      GitRunner.new.run("rev-parse", ref, chdir: workspace.path.to_s).strip
    rescue GitRunner::GitError => e
      raise StepFailed, "stack_agent_rebase: expected local branch #{ref.inspect} after agent run: #{e.message}"
    end
  end
end
