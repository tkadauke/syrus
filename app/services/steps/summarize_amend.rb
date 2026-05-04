module Steps
  # Second step of PrFeedback / CiFailure workflows. Same shape
  # as Steps::Summarize: short claude call --resumed against the
  # upstream agentic step's session, calls submit_summary, we
  # promote the result onto Workflow.artifacts and rewrite the
  # placeholder commit message.
  #
  # Distinct from Summarize because the prompt framing is "this
  # is a follow-up commit, not a fresh PR" — produces a commit
  # message, not a PR title.
  class SummarizeAmend < Base
    SUMMARIZE_TURN_BUDGET = 5

    def call
      workspace.setup
      run.update!(prompt: Prompts::SummarizeAmend.new.to_s) if run.prompt.blank?

      log("invoking agent for summarize_amend step (workflow ##{workflow.id}, --resume)")
      run_agent(prompt: run.prompt, max_turns: SUMMARIZE_TURN_BUDGET)

      promote_artifacts!
      rewrite_amend_commit_message!
    end

    private

    def promote_artifacts!
      run.reload
      raise StepFailed, "agent didn't call submit_summary" if run.agent_pr_title.blank?

      # Each round overwrites — the artifact represents the most
      # recent commit message / body for THIS workflow.
      workflow.set_artifact!("amend_commit_subject", run.agent_pr_title)
      workflow.set_artifact!("amend_commit_body",    run.agent_pr_body)  if run.agent_pr_body.present?
      workflow.set_artifact!("summary",              run.agent_summary)  if run.agent_summary.present?
    end

    def rewrite_amend_commit_message!
      subject = workflow.artifact("amend_commit_subject")
      return if subject.blank?

      body    = workflow.artifact("amend_commit_body")
      message = body.present? ? [ subject, "", body ].join("\n") : subject
      streaming_git.run(
        "-c", "user.name=Syrus", "-c", "user.email=syrus@noreply.invalid",
        "commit", "--amend", "-m", message,
        chdir: workspace.path.to_s
      )
    end
  end
end
