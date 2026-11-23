module ReviewPlanning
  class WorkflowKinds
    include Syrus::Plugin::WorkflowKinds

    def self.step_kinds
      [
        {
          kind: "review_plan", handler: "ReviewPlanning::Step",
          label: "Review plan", style: "bg-orange-100 text-orange-700", agentic: true,
          agent_role: AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
          required_mcp_tools: %w[submit_review_plan],
          fail_policy: :advance,
          resource_profile_fallback_step_kinds: %w[implement],
          skip_if_artifact: "review_plan"
        }
      ]
    end
  end
end
