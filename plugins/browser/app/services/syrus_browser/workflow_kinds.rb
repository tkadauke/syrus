module SyrusBrowser
  class WorkflowKinds
    include Syrus::Plugin::WorkflowKinds

    def self.step_kinds
      [
        {
          kind: "visual_review", handler: "SyrusBrowser::VisualReviewStep",
          label: "Visual review", style: "bg-pink-100 text-pink-700", agentic: true,
          agent_role: AgentRole::WORKFLOW_VISUAL_REVIEWER,
          required_mcp_tools: %w[submit_visual_review],
          resource_profile_fallback_step_kinds: %w[implement],
          review_gate: {
            artifact_key: "visual_review_iterations",
            exit_verdicts: %w[approved skipped],
            cancellation_reason: "visual_review_approved"
          }
        },
        {
          kind: "visual_diff", handler: "SyrusBrowser::VisualDiffStep",
          label: "Before/after visual comparison", style: "bg-pink-50 text-pink-700", agentic: true,
          required_mcp_tools: %w[submit_visual_artifact]
        }
      ]
    end
  end
end
