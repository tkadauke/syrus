module Steps
  # Agentic repair pass for Local Mode handoffs. Runs inside the
  # local_mode_handoff grade retry loop after required graders fail.
  class LocalModeHandoffFix < Base
    def call
      perform_agentic_change_step(
        log_message: "invoking agent for local_mode_handoff_fix step (#{workflow.slug}, local_mode_handoff)",
        commit_message: "Syrus local mode handoff grader fix"
      ) do
        run.update!(prompt: compose_prompt) if run.prompt.blank?
      end
    end

    private

    def compose_prompt
      issue = job.issue? ? fetch_issue : job.synthetic_issue
      prompt = Prompts::LocalModeHandoffFix.new(
        issue: issue,
        repo_slug: repository.slug,
        branch_name: workspace.branch_name,
        recent_commits: recent_branch_commits,
        epic: job.epic,
        job: job
      ).to_s

      append_grade_failure_feedback(prompt)
    end
  end
end
