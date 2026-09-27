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
        }
      ]
    end

    def self.step_kinds
      [
        {
          kind: "briefing_generate_run", handler: "OperatorBriefing::GenerateRunStep",
          label: "Generate briefing", style: "bg-sky-100 text-sky-700", agentic: true,
          required_mcp_tools: %w[submit_briefing_block]
        }
      ]
    end

    def self.job_kinds
      [ { kind: "briefing_generate", infrastructure: true, issueless: true, investigable: true } ]
    end

    def self.work_definitions
      [ OperatorBriefing::WorkDefinition ]
    end
  end
end
