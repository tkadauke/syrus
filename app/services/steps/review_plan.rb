module Steps
  # Optional agentic step for Initial/Retry workflows, inserted after
  # pr_open. The resumed agent does a self-review pass over its own diff
  # and posts a structured "pay attention to X because Y" comment on the
  # PR. Opt-in per `.syrus.yml` via a bare `review_plan: true` key.
  #
  # Best-effort: this step must never fail the parent Job/Workflow, even
  # if the agent errors, gives up after retries, or the MCP sidecar is
  # unavailable. Any StepFailed raised anywhere in #call is caught,
  # logged, and swallowed.
  class ReviewPlan < Base
    # Same rationale as TestPlan::TEST_PLAN_TURN_BUDGET — short prompt, but
    # turns may be spent waiting on the MCP sidecar/tool list.
    REVIEW_PLAN_TURN_BUDGET = 25

    def call
      workspace.setup

      unless review_plan_enabled?
        log("[review_plan] not configured in .syrus.yml — skipping")
        return
      end

      if workflow.artifact("review_plan").present?
        log("review plan already submitted — skipping agent call")
        return
      end

      run.update!(prompt: Prompts::ReviewPlan.new.to_s) if run.prompt.blank?

      log("invoking agent for review_plan step (#{workflow.slug}, --resume from implement)")

      begin
        run_agent(
          prompt: run.prompt,
          max_turns: REVIEW_PLAN_TURN_BUDGET,
          required_mcp_tools: %w[submit_review_plan]
        )
      rescue StepFailed
        raise unless codex_resume_unavailable_failure?

        log("review_plan Codex resume state was unavailable; retrying without --resume")
        run_agent(
          prompt: run.prompt,
          max_turns: REVIEW_PLAN_TURN_BUDGET,
          resume_session_id: nil,
          required_mcp_tools: %w[submit_review_plan]
        )
      end

      workflow.reload
      verify_review_plan!
      post_review_plan_comment
    rescue StepFailed => e
      log("[review_plan] best-effort step did not complete — not failing the workflow: #{e.class}: #{e.message}")
    end

    private

    def review_plan_enabled?
      path = workspace.path
      return false unless path.join(SyrusYml::CONFIG_FILE).exist?

      SyrusYml.load_repo(path).review_plan
    rescue SyrusYml::ParseError => e
      log("[review_plan] .syrus.yml parse error: #{e.message}")
      false
    end

    def verify_review_plan!
      if workflow.artifact("review_plan").blank?
        capture_mcp_sidecar_stderr
        raise StepFailed, "agent didn't call submit_review_plan"
      end
    end

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id || implement_session_id || super
    end

    def implement_session_id
      successful_implement_run&.provider_session&.session_id
    end

    def successful_implement_run
      latest_succeeded_run_for("implement")
    end

    def post_review_plan_comment
      artifact = workflow.artifact("review_plan")
      return if artifact.blank?

      body = ReviewPlanFormatter.new(artifact).format
      if body.blank?
        log("[review_plan] no notable review points — skipping comment")
        return
      end

      pr_number = job.pr_number
      unless pr_number.present?
        log("[review_plan] no PR number for job — skipping comment")
        return
      end

      pr_repo   = job.effective_pr_repository
      client    = GithubClient.for(repository: pr_repo, user: job.user)
      repo_slug = pr_repo.slug

      upsert_review_plan_comment(client, repo_slug, pr_number, body)
    rescue => e
      log("[review_plan] failed to post PR comment: #{e.class}: #{e.message}")
    end

    def upsert_review_plan_comment(client, repo_slug, pr_number, body)
      existing = find_existing_review_plan_comment(client, repo_slug, pr_number)

      if existing
        client.update_issue_comment(repo_slug, existing.id, body)
        log("[review_plan] updated review plan comment ##{existing.id} on #{repo_slug}##{pr_number}")
      else
        client.add_issue_comment(repo_slug, pr_number, body)
        log("[review_plan] posted review plan comment on #{repo_slug}##{pr_number}")
      end
    end

    def find_existing_review_plan_comment(client, repo_slug, pr_number)
      client.pr_issue_comments(repo_slug, pr_number).find do |comment|
        comment.body.to_s.include?(ReviewPlanFormatter::MARKER)
      end
    rescue => e
      log("[review_plan] failed to list PR comments: #{e.class}: #{e.message} — will post new comment")
      nil
    end
  end
end
