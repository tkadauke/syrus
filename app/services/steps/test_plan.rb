module Steps
  # Short agentic step for Initial workflows. The resumed agent turns
  # its implementation context into a reviewer-facing test plan and
  # stores it through the submit_test_plan MCP tool.
  class TestPlan < Base
    # The prompt is short, but Claude may spend turns waiting for the MCP
    # sidecar/tool list to become available before it can call submit_test_plan.
    TEST_PLAN_TURN_BUDGET = 25

    def call
      workspace.setup

      if workflow.artifact("test_plan").present?
        log("test plan already submitted — skipping agent call")
        return
      end

      raise StepFailed, "#{workflow.slug} is missing coding handoff test plan artifacts" if workflow.trigger_kind == "coding_handoff"

      raise StepFailed, "#{workflow.slug} has no completed implement run for test_plan" if missing_required_implement_run?

      run.update!(prompt: Prompts::TestPlan.new.to_s) if run.prompt.blank?

      log("invoking agent for test_plan step (#{workflow.slug}, --resume from implement)")

      begin
        run_agent(
          prompt: run.prompt,
          max_turns: TEST_PLAN_TURN_BUDGET,
          required_mcp_tools: %w[submit_test_plan]
        )
      rescue StepFailed
        raise unless codex_resume_unavailable_failure?

        log("test_plan Codex resume state was unavailable; retrying test plan without --resume")
        run_agent(
          prompt: fallback_prompt,
          max_turns: TEST_PLAN_TURN_BUDGET,
          resume_session_id: nil,
          required_mcp_tools: %w[submit_test_plan]
        )
      end

      workflow.reload
      verify_test_plan!
    rescue StepFailed => e
      raise unless mcp_sidecar_failure?(e)

      write_fallback_test_plan!
    end

    private

    def verify_test_plan!
      if workflow.artifact("test_plan").blank?
        capture_mcp_sidecar_stderr
        raise StepFailed, "agent didn't call submit_test_plan"
      end
    end

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id || implement_session_id || super
    end

    def implement_session_id
      successful_implement_run&.claude_session&.session_id
    end

    def successful_implement_run
      workflow.steps.where(kind: "implement")
        .order(:position)
        .flat_map { |step| step.runs.select(&:succeeded?) }
        .max_by(&:created_at)
    end

    def missing_required_implement_run?
      workflow.steps.exists?(kind: "implement") && successful_implement_run.blank?
    end

    def codex_resume_unavailable_failure?
      run.job_logs
        .order(sequence: :desc)
        .limit(25)
        .pluck(:chunk)
        .any? { |chunk| RunFailureClassifier.agent_resume_unavailable_text?(chunk) }
    end

    def fallback_prompt
      Prompts::TestPlanFallback.new(
        issue: fallback_issue,
        summary: workflow.artifact("summary").presence || workflow.artifact("pr_body").to_s,
        diff: fallback_diff
      ).to_s
    end

    def fallback_issue
      job.synthetic_issue || Struct.new(:title, :body).new(job.title, job.issue_body.to_s)
    end

    def fallback_diff
      successful_implement_run&.agent_diff.presence || diff_against_default
    end

    def mcp_sidecar_failure?(error)
      error.message.include?("mcp_sidecar_failed")
    end

    def write_fallback_test_plan!
      workflow.set_artifact!("test_plan", {
        steps: fallback_test_plan_steps,
        notes: "Syrus generated this fallback because the test-plan MCP sidecar was unavailable. Review the PR summary and completed grader results for context."
      })
      log("[test_plan] MCP sidecar unavailable; wrote fallback test plan")
    end

    def fallback_test_plan_steps
      grader_steps = workflow.steps.where(kind: "grader").order(:position).filter_map do |grader_step|
        details = grader_step.details || {}
        next unless details["required"] != false

        command = details["command"].to_s.strip
        name = details["name"].to_s.strip
        if command.present?
          "Run #{name.presence || "the configured grader"}: `#{command}`"
        elsif name.present?
          "Run the configured Syrus grader: #{name}"
        end
      end.uniq

      [
        "Review the PR diff and summary for the intended behavior.",
        *(grader_steps.presence || [ "Run the required Syrus graders for this repository." ])
      ]
    end
  end
end
