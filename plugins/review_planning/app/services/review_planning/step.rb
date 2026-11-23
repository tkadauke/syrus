module ReviewPlanning
  # Optional agentic step contributed at `workflow:post_pr`. The resumed agent
  # does a self-review pass over its own diff and posts a structured "pay
  # attention to X because Y" comment on the PR. Opt-in per `.syrus.yml` via a
  # bare `review_plan: true` key.
  #
  # Best-effort: this step must never fail the parent Job/Workflow, even if the
  # agent errors, gives up after retries, or the MCP sidecar is unavailable. Any
  # StepFailed raised anywhere in #call is caught, logged, and swallowed.
  class Step < Steps::Base
    # Short prompt, but turns may be spent waiting on the MCP sidecar/tool list.
    REVIEW_PLAN_TURN_BUDGET = 25

    def call
      workspace.setup

      unless pr_was_opened_in_this_workflow?
        log("[review_plan] no pr_open step in this workflow — skipping")
        return
      end

      unless review_plan_enabled?
        log("[review_plan] not configured in .syrus.yml — skipping")
        return
      end

      if workflow.artifact("review_plan").present?
        log("review plan already submitted — skipping agent call")
        return
      end

      run.update!(prompt: ReviewPlanning::Prompt.new.to_s) if run.prompt.blank?

      log("invoking agent for review_plan step (#{workflow.slug}, --resume from implement)")

      begin
        run_agent(prompt: run.prompt, max_turns: REVIEW_PLAN_TURN_BUDGET, required_mcp_tools: %w[submit_review_plan])
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

    # post_pr is also applied to feedback chains that push to an existing PR
    # instead of opening one; there is no self-review to post for those.
    def pr_was_opened_in_this_workflow?
      workflow.steps.where(kind: "pr_open").exists?
    end

    def review_plan_enabled?
      path = workspace.path
      return false unless path.join(SyrusYml::CONFIG_FILE).exist?

      SyrusYml.load_repo(path).plugin_configurations[ReviewPlanning::RepositoryConfiguration::KEY] == true
    rescue SyrusYml::ParseError => e
      log("[review_plan] .syrus.yml parse error: #{e.message}")
      false
    end

    def verify_review_plan!
      return if workflow.artifact("review_plan").present?

      capture_mcp_sidecar_stderr
      raise StepFailed, "agent didn't call submit_review_plan"
    end

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id || implement_session_id || super
    end

    def implement_session_id
      latest_succeeded_run_for("implement")&.provider_session&.session_id
    end

    def post_review_plan_comment
      artifact = workflow.artifact("review_plan")
      return if artifact.blank?

      body = ReviewPlanning::Formatter.new(artifact).format
      if body.blank?
        log("[review_plan] no notable review points — skipping comment")
        return
      end

      pr_number = job.pr_number
      unless pr_number.present?
        log("[review_plan] no PR number for job — skipping comment")
        return
      end

      pr_repo = job.effective_pr_repository
      client = GithubClient.for(repository: pr_repo, user: job.user)
      upsert_review_plan_comment(client, pr_repo.slug, pr_number, body)
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
        comment.body.to_s.include?(ReviewPlanning::Formatter::MARKER)
      end
    rescue => e
      log("[review_plan] failed to list PR comments: #{e.class}: #{e.message} — will post new comment")
      nil
    end
  end
end
