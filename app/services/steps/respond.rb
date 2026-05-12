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
      workspace.setup
      run.update!(prompt: compose_prompt) if run.prompt.blank?

      log("invoking agent for respond step (workflow ##{workflow.id}, pr_comment)")
      run_agent(prompt: run.prompt)

      commit_agent_changes
      assert_branch_history_intact!
      diff = diff_against_default
      raise StepFailed, "agent produced no changes" if diff.blank?

      run.update!(agent_diff: diff, head_sha: head_sha)
    end

    private

    def compose_prompt
      comments = workflow.artifact("pr_comments") || []
      issue = job.issue? ? GithubClient.for(repository: repository, user: job.user).fetch_issue(repository.slug, job.issue_number) : job.synthetic_issue
      Prompts::PrFeedback.new(issue: issue, comments: hydrate_comments(comments)).to_s
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

    def commit_agent_changes
      chdir = workspace.path.to_s
      git = streaming_git
      status = git.run("status", "--porcelain", chdir: chdir)
      return if status.strip.empty?
      git.run("add", "-A", chdir: chdir)
      git.run(
        "-c", "user.name=Syrus", "-c", "user.email=syrus@noreply.invalid",
        "commit", "-m", "Syrus respond step (will be rewritten by summarize_amend)",
        chdir: chdir
      )
    end
  end
end
