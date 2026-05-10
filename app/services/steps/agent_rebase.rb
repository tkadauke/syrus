module Steps
  # Second step of Rebase workflow. Agentic: spawns claude with
  # Prompts::Rebase to resolve the conflicts that AutoRebase
  # couldn't.
  #
  # Note: this handler ONLY runs when reached. AutoRebase cancels
  # this step on a clean rebase, so the dispatcher advances to
  # ForcePush in that case and we never get here.
  class AgentRebase < Base
    def call
      workspace.setup
      run.update!(prompt: compose_prompt) if run.prompt.blank?

      log("invoking agent for agent_rebase step (workflow ##{workflow.id})")
      pre_sha = head_sha
      run_agent(prompt: run.prompt)

      post_sha = head_sha
      raise StepFailed, "agent_rebase: agent didn't move HEAD (rebase aborted or no-op)" if pre_sha == post_sha

      log("agent_rebase: rebased #{pre_sha[0, 7]} → #{post_sha[0, 7]}")
      run.update!(head_sha: post_sha)
    end

    private

    def compose_prompt
      pr_number = job.pr_number || job.external_pr_number
      Prompts::Rebase.new(
        repo_slug: repository.slug,
        branch_name: job.branch_name,
        base_branch: repository.default_branch,
        pr_number: pr_number
      ).to_s
    end
  end
end
