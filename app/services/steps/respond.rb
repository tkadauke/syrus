module Steps
  # First step of PrFeedback workflow. Agent receives the new
  # review comments + the original issue/diff context (via
  # Prompts::PrFeedback), addresses each piece of feedback,
  # commits to the existing branch.
  #
  # Cross-workflow boundary: NO --resume from the prior Initial
  # workflow's session. The prompt carries the context the agent
  # needs.
  class Respond < Base
    def call
      perform_agentic_change_step(
        log_message: "invoking agent for respond step (workflow ##{workflow.id}, pr_comment)",
        commit_message: "Syrus respond step (will be rewritten by summarize_amend)"
      ) do
        run.update!(prompt: compose_prompt) if run.prompt.blank?
      end
    end

    private

    def compose_prompt
      comments = workflow.artifact("pr_comments") || []
      issue = job.issue? ? GithubClient.for(repository: repository, user: job.user).fetch_issue(repository.slug, job.issue_number) : job.synthetic_issue
      prompt = Prompts::PrFeedback.new(issue: issue, comments: hydrate_comments(comments)).to_s
      return prompt unless run.iteration > 1

      [
        prompt,
        Prompts::GradeFailureFeedback.new(
          iterations: workflow.artifacts.fetch("iterations", [])
        ).to_s
      ].join("\n\n")
    end

    # The polling job stashes raw comment data on the workflow
    # artifact when instantiating; rehydrate it into objects that
    # Prompts::PrFeedback expects (responds to #user.login,
    # #body, #path, etc.). Tolerant — anything missing renders
    # as a generic string.
    def hydrate_comments(raw)
      raw.map do |c|
        Struct.new(:user, :body, :path, :line, :diff_hunk, :created_at).new(
          Struct.new(:login).new(c["author"] || "reviewer"),
          c["body"], c["path"], c["line"], c["diff_hunk"], c["created_at"]
        )
      end
    end
  end
end
