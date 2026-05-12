module Steps
  # First step of CiFailure workflow. Agent gets the failing-checks
  # payload (via Prompts::CiFailure), reads the test output,
  # diagnoses the cause, fixes the code or test, commits.
  #
  # Cross-workflow boundary: NO --resume from prior workflows.
  class AnalyzeAndFix < Base
    def call
      workspace.setup
      run.update!(prompt: compose_prompt) if run.prompt.blank?

      log("invoking agent for analyze_and_fix step (workflow ##{workflow.id}, ci_failure)")
      run_agent(prompt: run.prompt)

      commit_agent_changes
      assert_branch_history_intact!
      diff = diff_against_default
      raise StepFailed, "agent produced no changes" if diff.blank?

      run.update!(agent_diff: diff, head_sha: head_sha)
    end

    private

    def compose_prompt
      issue = job.issue? ? GithubClient.for(repository: repository, user: job.user).fetch_issue(repository.slug, job.issue_number) : job.synthetic_issue
      failed = workflow.artifact("failed_checks") || []
      head_sha = workflow.artifact("head_sha")
      Prompts::CiFailure.new(
        issue: issue,
        pr_number: job.pr_number || job.external_pr_number,
        repo_slug: repository.slug,
        branch_name: job.branch_name,
        head_sha: head_sha,
        failed_checks: failed
      ).to_s
    end

    def commit_agent_changes
      chdir = workspace.path.to_s
      git = streaming_git
      status = git.run("status", "--porcelain", chdir: chdir)
      return if status.strip.empty?
      git.run("add", "-A", chdir: chdir)
      git.run(
        "commit", "-m", "Syrus analyze_and_fix step (will be rewritten by summarize_amend)",
        chdir: chdir
      )
    end
  end
end
