module Steps
  # First step of Initial / Replay workflows. Spawns claude with
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
      workspace.setup

      # Cron Jobs arrive with a pre-rendered prompt (variables
      # already expanded at fire time); skip the GitHub round-trip
      # entirely. Issue Jobs need the issue body to compose
      # Prompts::Implement.
      if run.prompt.blank?
        issue = fetch_issue
        job.update!(issue_title: issue.title, issue_body: issue.body) if job.issue?
        ctx = workflow.artifacts&.dig("replay_context")
        run.update!(prompt: Prompts::Implement.new(issue: issue, replay_context: ctx).to_s)
      end

      target_label = if job.issue?
        "#{repository.slug}##{job.issue_number}"
      elsif job.adhoc?
        "ad hoc job ##{job.id}"
      else
        "scheduled task ##{job.scheduled_task_id}"
      end
      log("invoking agent for #{target_label} (workflow ##{workflow.id}, step ##{step.id} implement)")

      run_agent(prompt: run.prompt)

      commit_agent_changes
      assert_branch_history_intact!

      diff = diff_against_default
      raise StepFailed, "agent produced no changes" if diff.blank?

      run.update!(agent_diff: diff, head_sha: head_sha)
    end

    private

    def fetch_issue
      return job.synthetic_issue if job.cron? || job.adhoc?
      GithubClient.for(job.user).fetch_issue(repository.slug, job.issue_number)
    end

    # Same logic as RunJob#commit_agent_changes — agent edits
    # files; we commit them locally with a placeholder message.
    # The eventual commit message gets rewritten to
    # workflow.artifacts["pr_title"] either by Steps::Summarize's
    # downstream amend or (for legacy compatibility) Steps::PrOpen.
    def commit_agent_changes
      chdir = workspace.path.to_s
      git = streaming_git
      status = git.run("status", "--porcelain", chdir: chdir)
      return if status.strip.empty?

      git.run("add", "-A", chdir: chdir)
      git.run(
        "-c", "user.name=Syrus",
        "-c", "user.email=syrus@noreply.invalid",
        "commit", "-m", "Syrus implement step (will be rewritten by summarize)",
        chdir: chdir
      )
    end
  end
end
