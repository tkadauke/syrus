module Steps
  # Short agentic step for Initial workflows. The resumed agent turns
  # its implementation context into a reviewer-facing test plan and
  # stores it through the submit_test_plan MCP tool.
  class TestPlan < Base
    TEST_PLAN_TURN_BUDGET = 5

    def call
      workspace.setup
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
      workflow.steps.where(kind: "implement", state: "succeeded")
        .order(:position)
        .last
        &.latest_run
        &.claude_session
        &.session_id
    end
  end
end
