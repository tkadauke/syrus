module Steps
  # Short agentic step for `investigation` Workflows. Resumes the
  # investigate step's session and asks the agent to turn its findings
  # into a narrative report via the submit_report MCP tool -- the
  # narrative-producing step this chain exists to reach instead of
  # dead-ending on a blank diff. Shape mirrors TestPlan: skip the agent
  # call if the report was already submitted (e.g. investigate called it
  # directly), resume from the investigate session, and fail loudly if the
  # agent never calls the tool.
  class SubmitReport < Base
    # The prompt is short, but Claude may spend turns waiting for the MCP
    # sidecar/tool list to become available before it can call submit_report.
    SUBMIT_REPORT_TURN_BUDGET = 25

    def call
      workspace.setup

      if workflow.artifact("investigation_report").present?
        log("investigation report already submitted — skipping agent call")
        return
      end

      raise StepFailed, "#{workflow.slug} has no completed investigate run to report on" if missing_required_investigate_run?

      run.update!(prompt: Prompts::SubmitReportInstructions::TEXT) if run.prompt.blank?

      log("invoking agent for submit_report step (#{workflow.slug}, --resume from investigate)")

      run_agent(
        prompt: run.prompt,
        max_turns: SUBMIT_REPORT_TURN_BUDGET,
        required_mcp_tools: %w[submit_report]
      )

      workflow.reload
      verify_report!
    end

    private

    def verify_report!
      if workflow.artifact("investigation_report").blank?
        capture_mcp_sidecar_stderr
        raise StepFailed, "agent didn't call submit_report"
      end
    end

    def parent_session_id
      return nil if agent_resume_disabled?

      explicit_parent_session_id || investigate_session_id || super
    end

    def investigate_session_id
      successful_investigate_run&.provider_session&.session_id
    end

    def successful_investigate_run
      latest_succeeded_run_for("investigate")
    end

    def missing_required_investigate_run?
      workflow.steps.exists?(kind: "investigate") && successful_investigate_run.blank?
    end
  end
end
