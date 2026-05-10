module Steps
  # Final step of PrFeedback / CiFailure workflows. Non-agentic.
  # Pushes the existing branch to origin (no PR opening — PR
  # already exists from the original Initial workflow).
  class Push < Base
    def call
      workspace.setup
      log("push: pushing branch #{workspace.branch_name} (workflow ##{workflow.id})")
      git = streaming_git(env: { "GIT_TERMINAL_PROMPT" => "0" })
      push_url = repository.authenticated_push_url(job.user.github_token)
      git.run("push", push_url, "HEAD:refs/heads/#{workspace.branch_name}",
              chdir: workspace.path.to_s)
      update_pr_cost_footer
    end

    private

    def update_pr_cost_footer
      return if job.pr_number.blank?

      client = GithubClient.for(job.user)
      pr = client.pull_request(repository.slug, job.pr_number, bypass_cache: true)
      body = PrCostFooter.apply(pr.body.to_s, job)
      client.update_pull_request_body(repository.slug, job.pr_number, body)
      log("push: updated PR ##{job.pr_number} cost footer")
    end
  end
end
