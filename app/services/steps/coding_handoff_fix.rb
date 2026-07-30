module Steps
  # Agentic repair pass for pre-PR Coding Mode handoffs. Runs inside the
  # coding_handoff grade retry loop, after the initial committed handoff branch
  # has failed required graders and before PR creation.
  class CodingHandoffFix < Base
    def call
      perform_agentic_change_step(
        log_message: "invoking agent for coding_handoff_fix step (#{workflow.slug}, coding_handoff)",
        commit_message: "Syrus coding handoff grader fix"
      ) do
        run.update!(prompt: compose_prompt) if run.prompt.blank?
      end
    end

    private

    def compose_prompt
      issue = job.issue? ? fetch_issue : job.synthetic_issue
      prompt = Prompts::CodingHandoffFix.new(
        issue: issue,
        repo_slug: repository.slug,
        branch_name: workspace.branch_name,
        handoff_snapshot: workflow.artifact("coding_handoff"),
        recent_commits: recent_branch_commits,
        epic: job.epic,
        job: job
      ).to_s

      append_grade_failure_feedback(prompt)
    end
  end
end
