module AgentInsights
  class WorkflowKinds
    include Syrus::Plugin::WorkflowKinds

    def self.trigger_kinds
      [
        {
          kind: "agent_insight", template: "AgentInsights::Workflow",
          label: "Agent insight", style: "bg-amber-100 text-amber-700",
          retry_label: nil, feedback_kind: nil, runtime_role: "infrastructure",
          owns_job_lifecycle: true
        }
      ]
    end

    def self.step_kinds
      [
        {
          kind: "agent_insight_run", handler: "AgentInsights::RunStep",
          label: "Agent insight", style: "bg-amber-100 text-amber-700", agentic: true,
          agent_role: AgentRole::AGENT_INSIGHT
        }
      ]
    end

    # Insight sweeps run on their own Job kind: repository-scoped, no GitHub
    # issue behind them, and hidden from the operator's Job lists.
    def self.job_kinds
      [ { kind: "agent_insight", infrastructure: true, issueless: true } ]
    end

    def self.work_definitions
      [ AgentInsights::WorkDefinition ]
    end
  end
end
