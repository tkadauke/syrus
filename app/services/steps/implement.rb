module Steps
  # First step of Initial / Retry workflows. Spawns claude with
  # Prompts::Implement (issue title + body + the standard safety
  # block + a "don't call submit_summary here" nudge). Agent reads
  # the codebase, makes file changes; this handler commits them
  # locally; verifies HEAD shares ancestry with the default branch
  # (orphan-branch defense); records the diff for downstream pages
  # to render.
  #
  # Doesn't push. Doesn't open a PR. Those are pr_open's job.
  class Implement < Base
    def call
      perform_agentic_change_step(
        log_message: "invoking agent for #{target_label} (workflow ##{workflow.id}, step ##{step.id} implement)",
        commit_message: "Syrus implement step (will be rewritten by summarize)"
      ) do
        persist_prompt_if_needed
      end
    end

    private

    def persist_prompt_if_needed
      # Cron Jobs arrive with a pre-rendered prompt (variables
      # already expanded at fire time); skip the GitHub round-trip
      # entirely. Issue Jobs need the issue body to compose
      # Prompts::Implement.
      return if run.prompt.present?

      issue = fetch_issue
      job.update!(issue_title: issue.title, issue_body: issue.body) if job.issue?
      ctx = workflow.artifacts&.dig("replay_context")
      run.update!(prompt: implement_prompt(issue: issue, replay_context: ctx))
    end

    def target_label
      if job.issue?
        "#{repository.slug}##{job.issue_number}"
      elsif job.adhoc?
        "ad hoc job ##{job.id}"
      else
        "scheduled task ##{job.scheduled_task_id}"
      end
    end

    def fetch_issue
      return job.synthetic_issue if job.cron? || job.adhoc?
      GithubClient.for(repository: repository, user: job.user).fetch_issue(repository.slug, job.issue_number)
    end

    def implement_prompt(issue:, replay_context:)
      prompt = Prompts::Implement.new(issue: issue, replay_context: replay_context).to_s
      return prompt unless run.iteration > 1

      [
        prompt,
        Prompts::GradeFailureFeedback.new(
          iterations: workflow.artifacts.fetch("iterations", [])
        ).to_s
      ].join("\n\n")
    end
  end
end
