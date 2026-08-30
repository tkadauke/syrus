module Steps
  # Metadata-only step for Initial / Retry / Skill workflows. It asks the
  # configured agent to call `submit_summary` from fresh bounded job context
  # instead of resuming the upstream coding session, so a stale or long
  # implementation transcript cannot continue writing code during summarize.
  # The MCP tool writes pr_title / pr_body / summary onto the Run; this handler
  # then promotes them onto Workflow.artifacts so downstream steps can read them.
  #
  # Also rewrites the upstream step's placeholder commit message
  # to use the agent-authored pr_title — keeping the GH commit
  # log human-readable.
  class Summarize < Base
    # The prompt is short, but Claude may spend turns waiting for the MCP
    # sidecar/tool list to become available before it can call submit_summary.
    SUMMARIZE_TURN_BUDGET = 25

    # implement (Initial/Retry) or run_skill (Skill) — whichever agentic
    # step precedes summarize in this workflow's chain.
    UPSTREAM_AGENT_STEP_KINDS = %w[implement run_skill].freeze

    def call
      workspace.setup

      if coding_handoff?
        raise StepFailed, "#{workflow.slug} is missing coding handoff summary artifacts" if workflow.artifact("pr_title").blank? || workflow.artifact("pr_body").blank?

        log("coding handoff supplied PR summary artifacts — skipping agent call")
        return
      end

      if (impl_run = implement_run_with_summary)
        log("implement step already called submit_summary — skipping agent call")
        promote_artifacts!(from: impl_run)
        restore_run_checkpoint_if_needed!(impl_run, context: "summarize")
        assert_workspace_contains_successful_implement_head!
        rewrite_implement_commit_message!
        return
      end
      if (summary_run = prior_summarize_run_with_summary)
        log("prior summarize run already called submit_summary — reusing captured PR copy")
        promote_artifacts!(from: summary_run)
        restore_run_checkpoint_if_needed!(successful_implement_run, context: "summarize")
        assert_workspace_contains_successful_implement_head!
        rewrite_implement_commit_message!
        return
      end
      raise StepFailed, "#{workflow.slug} has no completed implement run to summarize" if missing_required_implement_run?

      restore_run_checkpoint_if_needed!(successful_implement_run, context: "summarize")
      assert_workspace_contains_successful_implement_head!
      run.update!(prompt: fallback_prompt)
      git_state_before_agent = capture_workspace_git_state

      log("invoking agent for summarize step (#{workflow.slug}, fresh metadata-only context)")
      run_agent(
        prompt: run.prompt,
        max_turns: SUMMARIZE_TURN_BUDGET,
        resume_session_id: nil,
        required_mcp_tools: %w[submit_summary]
      )

      assert_workspace_git_state_unchanged!(git_state_before_agent, context: "summarize")
      assert_workspace_contains_successful_implement_head!
      promote_artifacts!
      rewrite_implement_commit_message!
    end

    private

    def coding_handoff?
      workflow.trigger_kind == "coding_handoff"
    end

    def implement_run_with_summary
      impl_run = successful_implement_run
      impl_run if impl_run&.agent_pr_title.present?
    end

    def prior_summarize_run_with_summary
      Run
        .joins(:step)
        .where(steps: { workflow_id: workflow.id, kind: "summarize" })
        .where.not(id: run.id)
        .where.not(agent_pr_title: [ nil, "" ])
        .order(created_at: :desc)
        .first
    end

    def successful_implement_run
      latest_succeeded_run_for(UPSTREAM_AGENT_STEP_KINDS)
    end

    def missing_required_implement_run?
      workflow.steps.exists?(kind: UPSTREAM_AGENT_STEP_KINDS) && successful_implement_run.blank?
    end

    def fallback_prompt
      Prompts::SummarizeFallback.new(
        issue: fallback_issue,
        diff: fallback_diff
      ).to_s
    end

    def fallback_issue
      job.synthetic_issue || Struct.new(:title, :body).new(job.title, job.issue_body.to_s)
    end

    def fallback_diff
      successful_implement_run&.agent_diff.presence || diff_against_default
    end

    def promote_artifacts!(from: nil)
      unless from
        run.reload  # MCP sidecar writes here mid-run
      end
      source = from || run
      if source.agent_pr_title.blank?
        capture_mcp_sidecar_stderr
        raise StepFailed, "agent didn't call submit_summary"
      end

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
      # --allow-empty for parity with SummarizeAmend: if the implement step's
      # HEAD is an empty commit, relabeling it must not fail with "amending
      # would make it empty". Harmless (no-op) for the normal non-empty commit.
      streaming_git.run(
        "commit", "--amend", "--allow-empty", "-m", message,
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

    def assert_workspace_contains_successful_implement_head!
      expected_sha = successful_implement_run&.head_sha.to_s.strip
      return if expected_sha.blank?

      actual_sha = head_sha
      return if actual_sha == expected_sha
      return if implement_head_ancestor_of?(actual_sha, expected_sha)
      return if workspace_head_matches_summary_commit_message?

      raise StepFailed,
            "summarize refused to rewrite commit message because workspace HEAD #{actual_sha} " \
            "does not contain implement run HEAD #{expected_sha}"
    end

    def implement_head_ancestor_of?(actual_sha, expected_sha)
      GitRunner.new.run("merge-base", "--is-ancestor", expected_sha, actual_sha, chdir: workspace.path.to_s)
      true
    rescue GitRunner::GitError
      false
    end

    def workspace_head_matches_summary_commit_message?
      title = workflow.artifact("pr_title")
      return false if title.blank?

      body = workflow.artifact("pr_body")
      expected = build_pr_commit_message(title, body).strip
      actual = GitRunner.new.run("log", "-1", "--pretty=%B", chdir: workspace.path.to_s).strip
      actual == expected || actual.start_with?("#{expected}\n\nCo-authored-by:")
    rescue GitRunner::GitError
      false
    end
  end
end
