module Coworkers
  class WorkflowKinds
    include Syrus::Plugin::WorkflowKinds

    def self.trigger_kinds
      [ {
        kind: "coworker_run", template: "Coworkers::Workflow",
        label: "Coworker run", style: "bg-violet-100 text-violet-700",
        retry_label: nil, feedback_kind: nil, runtime_role: "infrastructure",
        owns_job_lifecycle: true
      } ]
    end

    def self.step_kinds
      [
        {
          kind: "coworker_run", handler: "Coworkers::RunStep",
          label: "Coworker run", style: "bg-violet-100 text-violet-700",
          agentic: true, agent_role: AgentRole::COWORKER
        },
        {
          kind: "post_to_chat", handler: "Coworkers::PostToChat",
          label: "Post to chat", style: "bg-violet-100 text-violet-700",
          agentic: false
        },
        {
          kind: "coworker_review", handler: "Coworkers::ReviewStep",
          label: "Coworker review", style: "bg-violet-100 text-violet-700", agentic: true,
          agent_role: AgentRole::WORKFLOW_COWORKER_REVIEWER, panel_capable: true,
          reviewer_target_required: true, required_mcp_tools: %w[submit_coworker_review],
          resource_profile_fallback_step_kinds: %w[implement],
          review_gate: {
            artifact_key: "coworker_review_iterations", exit_verdicts: %w[approved skipped],
            cancellation_reason: "coworker_review_approved"
          }
        }
      ]
    end

    def self.job_kinds
      [ { kind: "coworker_task", infrastructure: true, issueless: true } ]
    end

    def self.work_definitions
      [ Coworkers::WorkDefinition ]
    end
  end
end
