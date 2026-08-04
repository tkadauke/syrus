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
    # The prompt is short, but Claude may spend turns waiting for the MCP
    # sidecar/tool list to become available before it can call submit_summary.
    SUMMARIZE_TURN_BUDGET = 25

    def call
      workspace.setup

      if (upstream_run = upstream_run_with_summary)
        log("upstream step already called submit_summary — skipping agent call")
        promote_artifacts!(from: upstream_run)
        rewrite_amend_commit_message!
        return
      end

      run.update!(prompt: Prompts::SummarizeAmend.new.to_s) if run.prompt.blank?

      log("invoking agent for summarize_amend step (#{workflow.slug}, --resume)")
      run_agent(
        prompt: run.prompt,
        max_turns: SUMMARIZE_TURN_BUDGET,
        required_mcp_tools: %w[submit_summary]
      )

      promote_artifacts!
      rewrite_amend_commit_message!
    end

    private

    def upstream_run_with_summary
      workflow.steps.where(kind: %w[respond analyze_and_fix manual_agentic_run])
        .order(:position)
        .flat_map { |step| step.runs.select(&:succeeded?) }
        .max_by(&:created_at)
        .then { |r| r if r&.agent_pr_title.present? }
    end

    def promote_artifacts!(from: nil)
      unless from
        run.reload
      end
      source = from || run
      if source.agent_pr_title.blank?
        capture_mcp_sidecar_stderr
        raise StepFailed, "agent didn't call submit_summary"
      end

      # Each round overwrites — the artifact represents the most
      # recent commit message / body for THIS workflow.
      workflow.set_artifact!("amend_commit_subject", source.agent_pr_title)
      workflow.set_artifact!("amend_commit_body",    source.agent_pr_body)  if source.agent_pr_body.present?
      workflow.set_artifact!("summary",              source.agent_summary)  if source.agent_summary.present?
    end

    def rewrite_amend_commit_message!
      subject = workflow.artifact("amend_commit_subject")
      return if subject.blank?

      body    = workflow.artifact("amend_commit_body")
      message = body.present? ? [ subject, "", body ].join("\n") : subject
      message = BotIdentity.for(job).append_co_authored_by(message)
      # --allow-empty: the upstream agentic step may legitimately leave an
      # empty commit at HEAD — e.g. a transient CI failure where the fix is a
      # no-op and the agent creates an empty "re-trigger CI" commit. Relabeling
      # that commit is a safe, intended operation; without --allow-empty git
      # refuses ("amending would make it empty") and fails the whole workflow.
      # For the normal non-empty case --allow-empty is a no-op.
      streaming_git.run(
        "commit", "--amend", "--allow-empty", "-m", message,
        chdir: workspace.path.to_s
      )
    end
  end
end
