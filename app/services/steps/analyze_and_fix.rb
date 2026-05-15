module Steps
  # First step of CiFailure workflow. Agent gets the failing-checks
  # payload (via Prompts::CiFailure), reads the test output,
  # diagnoses the cause, fixes the code or test, commits.
  #
  # Cross-workflow boundary: NO --resume from prior workflows.
  class AnalyzeAndFix < Base
    def call
      perform_agentic_change_step(
        log_message: "invoking agent for analyze_and_fix step (workflow ##{workflow.id}, ci_failure)",
        commit_message: "Syrus analyze_and_fix step (will be rewritten by summarize_amend)"
      ) do
        run.update!(prompt: compose_prompt) if run.prompt.blank?
      end
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
  end
end
