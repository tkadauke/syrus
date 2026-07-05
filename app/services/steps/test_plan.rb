module Steps
  # Short agentic step for Initial workflows. The resumed agent turns
  # its implementation context into a reviewer-facing test plan and
  # stores it through the submit_test_plan MCP tool.
  class TestPlan < Base
    TEST_PLAN_TURN_BUDGET = 5

    def call
      workspace.setup
      raise StepFailed, "#{workflow.slug} has no completed implement run for test_plan" if missing_required_implement_run?

      if workflow.artifact("test_plan").present?
        log("implement step already called submit_test_plan — skipping agent call")
        return
      end

      run.update!(prompt: Prompts::TestPlan.new.to_s) if run.prompt.blank?

      log("invoking agent for test_plan step (#{workflow.slug}, --resume from implement)")

      run_agent(prompt: run.prompt, max_turns: TEST_PLAN_TURN_BUDGET)

      workflow.reload
      raise StepFailed, "agent didn't call submit_test_plan" if workflow.artifact("test_plan").blank?
    end

    private

    def parent_session_id
      run.parent_session_id.presence || implement_session_id || super
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
  end
end
