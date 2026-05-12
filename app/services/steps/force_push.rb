module Steps
  # Final step of Rebase workflow. Non-agentic. Force-pushes the
  # rebased branch to origin.
  #
  # Note: for clean auto-rebases this still runs after AgentRebase is
  # skipped, keeping "rebase succeeded" and "branch was pushed" as
  # separate workflow facts.
  class ForcePush < Base
    def call
      workspace.setup
      log("force_push: pushing rebased #{workspace.branch_name} (workflow ##{workflow.id})")

      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      push_url = repository.authenticated_push_url(GithubClient.for(repository: repository, user: job.user).access_token)
      git.run("push", "--force", push_url,
              "HEAD:refs/heads/#{workspace.branch_name}",
              chdir: workspace.path.to_s)
    end
  end
end
