module Steps
  # Second step of Initial / Retry workflows. Short claude call
  # (--resumed against the implement step's session) whose only
  # job is to call `submit_summary` via the MCP sidecar. The
  # MCP tool writes pr_title / pr_body / summary onto the Run;
  # this handler then promotes them onto Workflow.artifacts so
  # downstream steps (and future workflow rounds) can read them.
  #
  # Also rewrites the implement step's placeholder commit message
  # to use the agent-authored pr_title — keeping the GH commit
  # log human-readable.
  class Summarize < Base
    SUMMARIZE_TURN_BUDGET = 5  # short prompt, no exploration needed

    def call
      workspace.setup

      if (impl_run = implement_run_with_summary)
        log("implement step already called submit_summary — skipping agent call")
        promote_artifacts!(from: impl_run)
        rewrite_implement_commit_message!
        return
      end

      run.update!(prompt: Prompts::Summarize.new.to_s) if run.prompt.blank?

      log("invoking agent for summarize step (#{workflow.slug}, --resume from implement)")

      run_agent(prompt: run.prompt, max_turns: SUMMARIZE_TURN_BUDGET)

      promote_artifacts!
      rewrite_implement_commit_message!
    end

    private

    def implement_run_with_summary
      impl_run = step.previous_step&.latest_run
      impl_run if impl_run&.agent_pr_title.present?
    end

    def promote_artifacts!(from: nil)
      unless from
        run.reload  # MCP sidecar writes here mid-run
      end
      source = from || run
      raise StepFailed, "agent didn't call submit_summary" if source.agent_pr_title.blank?

      workflow.set_artifact!("pr_title", utf8(source.agent_pr_title))
      workflow.set_artifact!("pr_body",  utf8(source.agent_pr_body)) if source.agent_pr_body.present?
      workflow.set_artifact!("summary",  utf8(source.agent_summary)) if source.agent_summary.present?
    end

    # Replace the implement step's placeholder commit message with
    # the agent-authored pr_title + pr_body. Including the body
    # means GitHub squash-merge picks it up as the merge commit
    # description, not just the title. `Closes #N` is prepended
    # defensively so auto-close works even if the agent omits it.
    def rewrite_implement_commit_message!
      title = workflow.artifact("pr_title")
      return if title.blank?

      body    = workflow.artifact("pr_body")
      message = BotIdentity.for(job).append_co_authored_by(build_pr_commit_message(title, body))
      streaming_git.run(
        "commit", "--amend", "-m", message,
        chdir: workspace.path.to_s
      )
    end

    def build_pr_commit_message(title, body)
      return title if body.blank?

      parts = [ title, "" ]
      if job.issue? && body !~ /Closes\s+##{job.issue_number}/
        parts << "Closes ##{job.issue_number}"
        parts << ""
      end
      parts << body
      parts.join("\n")
    end
  end
end
