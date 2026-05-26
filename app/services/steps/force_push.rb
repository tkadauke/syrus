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
      log("force_push: pushing rebased #{workspace.branch_name} (workflow ##{workflow.id})")

      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      push_url = repository.authenticated_push_url(GithubClient.for(repository: repository, user: job.user).access_token)
      git.run("push", force_with_lease_arg, push_url,
              "HEAD:refs/heads/#{workspace.branch_name}",
              chdir: workspace.path.to_s)
    rescue GitRunner::GitError => e
      raise unless lease_rejected?(e)

      message = "force_push: lease rejected for #{workspace.branch_name}; remote branch moved after Syrus fetched it. " \
                "Refusing to overwrite newer remote work."
      log(message)
      raise StepFailed, message
    end

    private

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

    def lease_rejected?(error)
      error.output.to_s.match?(/stale info|fetch first|rejected/i)
    end
  end
end
