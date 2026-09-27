module OperatorBriefing
  class WorkflowKinds
    include Syrus::Plugin::WorkflowKinds

    def self.trigger_kinds
      [
        {
          kind: "briefing_generate", template: "OperatorBriefing::Workflow",
          label: "Briefing generation", style: "bg-sky-100 text-sky-700",
          retry_label: nil, feedback_kind: nil, runtime_role: "infrastructure",
          owns_job_lifecycle: true
        },
        {
          kind: "briefing_dive", template: "OperatorBriefing::DiveWorkflow",
          label: "Briefing dive", style: "bg-cyan-100 text-cyan-700",
          retry_label: nil, feedback_kind: nil, runtime_role: "child"
        }
      ]
    end

    def self.step_kinds
      [
        {
          kind: "briefing_generate_run", handler: "OperatorBriefing::GenerateRunStep",
          label: "Generate briefing", style: "bg-sky-100 text-sky-700", agentic: true,
          agent_role: AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
          required_mcp_tools: %w[submit_briefing_block],
          placement_policy: Step::PlacementPolicy::CONTROL_PLANE
        },
        {
          kind: "briefing_dive_investigate", handler: "OperatorBriefing::DiveInvestigateStep",
          label: "Investigate dive", style: "bg-cyan-100 text-cyan-700", agentic: true,
          agent_role: AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
          required_mcp_tools: %w[read_briefing]
        },
        {
          kind: "submit_dive_report", handler: "OperatorBriefing::SubmitDiveReportStep",
          label: "Submit dive report", style: "bg-cyan-200 text-cyan-800", agentic: true,
          agent_role: AgentRole::WORKFLOW_SUMMARY_TEST_PLAN,
          required_mcp_tools: %w[read_briefing list_briefing_topics read_briefing_topic submit_dive_report],
          skip_if_artifact: "briefing_dive_report"
        }
      ]
    end

    def self.job_kinds
      [ { kind: "briefing_generate", infrastructure: true, issueless: true, investigable: true } ]
    end

    def self.work_definitions
      [ OperatorBriefing::WorkDefinition, OperatorBriefing::DiveWorkDefinition ]
    end
  end
end
