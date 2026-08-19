module Steps
  # Second step of Initial / Retry / Skill workflows. Short claude call
  # (--resumed against the upstream agentic step's session) whose only
  # job is to call `submit_summary` via the MCP sidecar. The
  # MCP tool writes pr_title / pr_body / summary onto the Run;
  # this handler then promotes them onto Workflow.artifacts so
  # downstream steps (and future workflow rounds) can read them.
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
        assert_workspace_matches_successful_implement_head!
        promote_artifacts!(from: impl_run)
        rewrite_implement_commit_message!
        return
      end
      raise StepFailed, "#{workflow.slug} has no completed implement run to summarize" if missing_required_implement_run?

      run.update!(prompt: Prompts::Summarize.new.to_s) if run.prompt.blank?
      git_state_before_agent = capture_workspace_git_state

      log("invoking agent for summarize step (#{workflow.slug}, --resume from implement)")

      begin
        run_agent(
          prompt: run.prompt,
          max_turns: SUMMARIZE_TURN_BUDGET,
          required_mcp_tools: %w[submit_summary]
        )
      rescue StepFailed => e
        raise unless resume_fallback_failure?(e)

        log("#{resume_fallback_reason(e)}; retrying summary without --resume")
        run.update!(agent_pr_title: nil, agent_pr_body: nil, agent_summary: nil)
        run_agent(
          prompt: fallback_prompt,
          max_turns: SUMMARIZE_TURN_BUDGET,
          resume_session_id: nil,
          required_mcp_tools: %w[submit_summary]
        )
      end

      assert_workspace_git_state_unchanged!(git_state_before_agent, context: "summarize")
      assert_workspace_matches_successful_implement_head!
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

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id || implement_session_id || super
    end

    def implement_session_id
      successful_implement_run&.provider_session&.session_id
    end

    def successful_implement_run
      workflow.steps.where(kind: UPSTREAM_AGENT_STEP_KINDS)
        .order(:position)
        .flat_map { |step| step.runs.select(&:succeeded?) }
        .max_by(&:created_at)
    end

    def missing_required_implement_run?
      workflow.steps.exists?(kind: UPSTREAM_AGENT_STEP_KINDS) && successful_implement_run.blank?
    end

    def resume_fallback_failure?(error)
      prompt_too_long_failure?(error) || codex_resume_unavailable_failure?
    end

    def resume_fallback_reason(error)
      return "summarize resume prompt was too large" if prompt_too_long_failure?(error)
      return "summarize Codex resume state was unavailable" if codex_resume_unavailable_failure?

      "summarize resume failed"
    end

    def prompt_too_long_failure?(error)
      return true if error.message.match?(/prompt is too long/i)

      run.job_logs
        .order(sequence: :desc)
        .limit(25)
        .pluck(:chunk)
        .any? { |chunk| chunk.to_s.match?(/prompt is too long/i) }
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

    def assert_workspace_matches_successful_implement_head!
      expected_sha = successful_implement_run&.head_sha.to_s.strip
      return if expected_sha.blank?

      actual_sha = head_sha
      return if actual_sha == expected_sha

      raise StepFailed,
            "summarize refused to rewrite commit message because workspace HEAD #{actual_sha} " \
            "does not match implement run HEAD #{expected_sha}"
    end
  end
end
