module Steps
  # Agentic final pass before auto-merge. Runs on the approved PR
  # branch immediately before graders and the merge API call, so
  # post-rebase or post-review integration failures can be fixed on
  # the exact tree Syrus is about to land.
  class LandingFix < Base
    def call
      perform_agentic_change_step(
        log_message: "invoking agent for landing_fix step (#{workflow.slug}, auto_merge)",
        commit_message: "Syrus pre-merge fix"
      ) do
        run.update!(prompt: compose_prompt) if run.prompt.blank?
      end
    end

    private

    def compose_prompt
      issue = job.issue? ? fetch_issue : job.synthetic_issue
      prompt = Prompts::LandingFix.new(
        issue: issue,
        pr_number: job.pr_number || job.external_pr_number,
        repo_slug: repository.slug,
        branch_name: job.branch_name || workflow.artifact("external_pr_head_ref"),
        recent_commits: recent_branch_commits,
        epic: job.epic,
        job: job
      ).to_s

      append_grade_failure_feedback(prompt)
    end

  end
end
